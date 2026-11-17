//! Smart-home gateway agent (chạy cạnh Zigbee2MQTT trên Raspberry Pi).
//!
//!   Zigbee2MQTT ⇄ MQTT (local) ⇄ [gateway] ⇄ WebSocket (outbound, TLS) ⇄ Cloud backend
//!
//! - Lên cloud: bridge/devices, trạng thái, availability.
//! - Xuống thiết bị: {"type":"set","friendly_name","payload"} → publish `<base>/<name>/set`.
//! - Giữ cache để phát lại toàn bộ trạng thái mỗi khi nối lại cloud.
mod cast;
mod matter;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use futures_util::{SinkExt, StreamExt};
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
};
use tracing::{info, warn};

#[derive(Default)]
struct Cache {
    devices: Option<Value>,
    states: HashMap<String, Value>,
    online: HashMap<String, bool>,
}

fn env_or(k: &str, d: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| d.to_string())
}

/// Gói MQTT lớn nhất nhận từ broker (4 MiB đủ cho hàng trăm thiết bị).
const MQTT_MAX_PACKET: usize = 4 * 1024 * 1024;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let base = env_or("Z2M_BASE", "zigbee2mqtt");
    let host = env_or("MQTT_HOST", "localhost");
    let port: u16 = env_or("MQTT_PORT", "1883").parse()?;
    let ws_url = env_or("CLOUD_WS_URL", "ws://localhost:8080/gw/ws");
    let token = std::env::var("GATEWAY_TOKEN").unwrap_or_default();
    anyhow::ensure!(!token.is_empty(), "GATEWAY_TOKEN is required (create one via POST /v1/homes/:id/gateways)");

    // client id cố định theo gateway; nếu hai gateway cùng dùng một broker (chỉ gặp khi thử nghiệm) phải khác nhau, nếu không broker đá nhau liên tục
    let client_id = env_or("MQTT_CLIENT_ID", "smart-gateway");
    let mut opts = MqttOptions::new(client_id, host, port);
    opts.set_keep_alive(Duration::from_secs(30));
    // Mặc định rumqttc chỉ nhận gói tới 10 KB; bản tin retained `bridge/devices` của Zigbee2MQTT lớn dần theo số thiết bị
    // (mỗi thiết bị kèm cả cây exposes), vượt ngưỡng đó là gateway bị ngắt và kết nối lại vô hạn.
    opts.set_max_packet_size(MQTT_MAX_PACKET, 64 * 1024);
    // Mosquitto yêu cầu đăng nhập (xem infra/mosquitto/acl.conf).
    if let (Ok(user), Ok(pass)) = (std::env::var("MQTT_USER"), std::env::var("MQTT_PASSWORD")) {
        if !user.is_empty() {
            opts.set_credentials(user, pass);
        }
    }
    let (mqtt, mut eventloop) = AsyncClient::new(opts, 128);

    let cache = Arc::new(Mutex::new(Cache::default()));
    let (up_tx, up_rx) = mpsc::channel::<String>(256);
    let reply_tx = up_tx.clone(); // trả lời yêu cầu từ cloud (matter_*)
    let matter_cfg = matter::Config::from_env();
    cast::start(); // mDNS tìm loa Cast + máy chủ HTTP phát TTS (tuỳ chọn: không có loa thì không tốn gì)
    info!("matter bridge integration: {}", if matter_cfg.enabled() { "enabled" } else { "disabled (MATTERBRIDGE_URL not set)" });

    // MQTT_DISABLED=1: gateway chỉ làm loa Cast (chạy ở máy cùng LAN với loa, không có Zigbee2MQTT).
    let mqtt_enabled = std::env::var("MQTT_DISABLED").map(|v| v.is_empty() || v == "0").unwrap_or(true);
    // MQTT → cache + hàng đợi lên cloud
    if mqtt_enabled {
        let (mqtt, cache, base) = (mqtt.clone(), cache.clone(), base.clone());
        tokio::spawn(async move {
            loop {
                match eventloop.poll().await {
                    Ok(Event::Incoming(Packet::ConnAck(_))) => {
                        info!("mqtt connected");
                        for t in [format!("{base}/bridge/devices"), format!("{base}/+"), format!("{base}/+/availability")] {
                            if let Err(e) = mqtt.subscribe(t, QoS::AtLeastOnce).await {
                                warn!("subscribe: {e}");
                            }
                        }
                    }
                    Ok(Event::Incoming(Packet::Publish(p))) => {
                        if let Some(msg) = to_cloud_msg(&base, &p.topic, &p.payload, &cache) {
                            let _ = up_tx.try_send(msg.to_string()); // đầy/offline → bỏ, cache sẽ phát lại
                        }
                    }
                    Ok(_) => {}
                    Err(e) => {
                        warn!("mqtt error: {e}; retry in 3s");
                        tokio::time::sleep(Duration::from_secs(3)).await;
                    }
                }
            }
        });
    }

    cloud_loop(ws_url, token, base, mqtt, cache, up_rx, reply_tx, matter_cfg).await;
    Ok(())
}

/// Chuyển một MQTT message của Zigbee2MQTT thành message gửi lên cloud (và cập nhật cache).
fn to_cloud_msg(base: &str, topic: &str, payload: &[u8], cache: &Mutex<Cache>) -> Option<Value> {
    let rest = topic.strip_prefix(base)?.strip_prefix('/')?;
    let mut c = cache.lock().unwrap();
    if rest == "bridge/devices" {
        let devices: Value = serde_json::from_slice(payload).ok()?;
        devices.as_array()?;
        c.devices = Some(devices.clone());
        return Some(json!({"type": "devices", "devices": devices}));
    }
    if let Some(name) = rest.strip_suffix("/availability") {
        if name.contains('/') {
            return None;
        }
        let s = String::from_utf8_lossy(payload);
        let online = match serde_json::from_slice::<Value>(payload).ok().and_then(|v| v.get("state").and_then(Value::as_str).map(str::to_owned)) {
            Some(st) => st == "online",
            None => s.trim() == "online",
        };
        c.online.insert(name.to_owned(), online);
        return Some(json!({"type": "availability", "friendly_name": name, "online": online}));
    }
    if rest.contains('/') || rest == "bridge" {
        return None;
    }
    let state: Value = serde_json::from_slice(payload).ok().filter(Value::is_object)?;
    c.states.insert(rest.to_owned(), state.clone());
    Some(json!({"type": "state", "friendly_name": rest, "payload": state}))
}

fn replay(cache: &Mutex<Cache>) -> Vec<String> {
    let c = cache.lock().unwrap();
    let mut out = Vec::new();
    if let Some(d) = &c.devices {
        out.push(json!({"type": "devices", "devices": d}).to_string());
    }
    for (n, s) in &c.states {
        out.push(json!({"type": "state", "friendly_name": n, "payload": s}).to_string());
    }
    for (n, o) in &c.online {
        out.push(json!({"type": "availability", "friendly_name": n, "online": o}).to_string());
    }
    out
}

/// Tên thiết bị không được chứa ký tự wildcard/ngăn cấp MQTT (chống topic injection từ cloud).
fn safe_name(n: &str) -> bool {
    !n.is_empty() && !n.contains(['/', '#', '+', '\0']) && n != "bridge"
}

#[allow(clippy::too_many_arguments)]
async fn cloud_loop(url: String, token: String, base: String, mqtt: AsyncClient, cache: Arc<Mutex<Cache>>, mut up_rx: mpsc::Receiver<String>, reply_tx: mpsc::Sender<String>, matter_cfg: matter::Config) {
    let mut backoff = 1u64;
    loop {
        let started = std::time::Instant::now();
        match run_session(&url, &token, &base, &mqtt, &cache, &mut up_rx, &reply_tx, &matter_cfg).await {
            Ok(()) => info!("cloud connection closed"),
            Err(e) => warn!("cloud connection failed: {e:#}"),
        }
        // phiên sống >30s coi như ổn định → reset backoff; ngược lại tăng dần tới 30s
        backoff = if started.elapsed() > Duration::from_secs(30) { 1 } else { (backoff * 2).min(30) };
        tokio::time::sleep(Duration::from_secs(backoff)).await;
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_session(url: &str, token: &str, base: &str, mqtt: &AsyncClient, cache: &Mutex<Cache>, up_rx: &mut mpsc::Receiver<String>, reply_tx: &mpsc::Sender<String>, matter_cfg: &matter::Config) -> anyhow::Result<()> {
    let mut req = url.into_client_request()?;
    req.headers_mut().insert("Authorization", format!("Bearer {token}").parse()?);
    let (ws, _) = connect_async(req).await?;
    info!("cloud connected");
    let (mut sink, mut stream) = ws.split();

    // bỏ hàng đợi cũ rồi phát lại toàn bộ trạng thái hiện hành
    while up_rx.try_recv().is_ok() {}
    // Khai báo khả năng để backend chọn đúng gateway (Zigbee/Matter hay chỉ loa Cast).
    let mut caps = Vec::new();
    if std::env::var("MQTT_DISABLED").map(|v| v.is_empty() || v == "0").unwrap_or(true) {
        caps.push("z2m");
    }
    if cast::get().is_some_and(|c| c.mdns_ok()) {
        caps.push("cast");
    }
    sink.send(Message::Text(json!({"type": "hello", "caps": caps}).to_string())).await?;
    for m in replay(cache) {
        sink.send(Message::Text(m)).await?;
    }

    let mut ping = tokio::time::interval(Duration::from_secs(30));
    loop {
        tokio::select! {
            Some(m) = up_rx.recv() => sink.send(Message::Text(m)).await?,
            _ = ping.tick() => sink.send(Message::Text(json!({"type": "ping"}).to_string())).await?,
            inbound = stream.next() => {
                let Some(inbound) = inbound else { return Ok(()) };
                match inbound? {
                    Message::Text(t) => handle_cmd(&t, base, mqtt, reply_tx, matter_cfg).await,
                    Message::Close(_) => return Ok(()),
                    _ => {}
                }
            }
        }
    }
}

async fn handle_cmd(text: &str, base: &str, mqtt: &AsyncClient, reply_tx: &mpsc::Sender<String>, matter_cfg: &matter::Config) {
    let Ok(v) = serde_json::from_str::<Value>(text) else { return };
    match v.get("type").and_then(Value::as_str) {
        Some("set") => {
            let (Some(name), Some(payload)) = (v.get("friendly_name").and_then(Value::as_str), v.get("payload").filter(|p| p.is_object())) else { return };
            if !safe_name(name) {
                warn!("rejected command for unsafe name {name:?}");
                return;
            }
            let topic = format!("{base}/{name}/set");
            info!("cmd -> {topic} {payload}");
            if let Err(e) = mqtt.publish(topic, QoS::AtLeastOnce, false, payload.to_string()).await {
                warn!("publish failed: {e}");
            }
        }
        Some("matter_get") | Some("matter_pairing") | Some("matter_remove_fabric") => {
            // Chạy nền: gọi Matterbridge có thể mất vài giây, không chặn vòng lặp nhận lệnh điều khiển.
            let (cfg, tx) = (matter_cfg.clone(), reply_tx.clone());
            tokio::spawn(async move {
                let reply = matter::handle(&cfg, &v).await;
                let _ = tx.send(reply.to_string()).await;
            });
        }
        Some("cast_scan") => {
            let Some(cast) = cast::get() else { return };
            let (id, tx) = (v.get("id").cloned().unwrap_or(Value::Null), reply_tx.clone());
            tokio::spawn(async move {
                let mut r = cast.scan().await;
                r["type"] = json!("cast_reply");
                r["id"] = id;
                let _ = tx.send(r.to_string()).await;
            });
        }
        Some("speak") => {
            let Some(cast) = cast::get() else { return };
            tokio::spawn(async move { cast.speak(&v).await });
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::safe_name;

    #[test]
    fn unicode_and_spaces_allowed_but_mqtt_separators_rejected() {
        assert!(safe_name("Đèn phòng khách"));
        assert!(safe_name("Công tắc (tầng 2)"));
        for bad in ["", "a/b", "a#", "a+b", "bridge", "x\0y"] {
            assert!(!safe_name(bad), "{bad:?}");
        }
    }
}
