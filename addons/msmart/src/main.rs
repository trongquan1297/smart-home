//! Addon trong nhà của MSmart: MỘT container, MỘT token gateway cho mọi thiết bị không đi qua Zigbee.
//!
//!   Thiết bị trong nhà ⇄ [addon: camera/, purifier/, …] ⇄ WebSocket (outbound) ⇄ Cloud backend ⇄ App
//!
//! main.rs chỉ lo phần chung: kết nối cloud (tự nối lại), khai báo khả năng (`hello.caps`), và chuyển bản tin
//! cloud → đúng module thiết bị. Mỗi loại thiết bị là một module tự chứa, tự lưu dữ liệu trong `$DATA_DIR`,
//! gửi lên cloud qua `Up`:
//! - `camera`   — camera Wi‑Fi qua go2rtc + ONVIF (bản tin `cam_*`).
//! - `purifier` — máy lọc nước Karofi qua Bluetooth LE (`pur_*`, và `set` như gateway Zigbee).
//!
//! Bật/tắt từng loại bằng `ADDON_DEVICES` (mặc định `camera,purifier`).
//! Thêm loại thiết bị mới: tạo module (load/run/on_connect/handle), thêm một trường trong `Hub`,
//! một khả năng trong `caps()` và một nhánh trong `dispatch()`; backend định tuyến theo khả năng đó (hub.rs).
mod camera;
mod purifier;

use std::{sync::Arc, time::Duration};

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
};
use tracing::{info, warn};

/// Hàng đợi gửi lên cloud (bản tin JSON; bỏ khi đang mất kết nối).
pub type Up = mpsc::Sender<String>;

struct Hub {
    camera: Option<Arc<camera::Cameras>>,
    purifier: Option<Arc<purifier::Purifiers>>,
}

impl Hub {
    fn caps(&self) -> Vec<&'static str> {
        let mut c = Vec::new();
        if self.camera.is_some() {
            c.push("camera");
        }
        if self.purifier.is_some() {
            c.push("purifier");
        }
        c
    }

    /// Vừa kết nối cloud: mỗi module gửi lại trạng thái nó đang giữ.
    fn on_connect(&self) {
        if let Some(c) = &self.camera {
            c.on_connect();
        }
        if let Some(p) = &self.purifier {
            p.resend_all();
        }
    }

    /// Chuyển một bản tin cloud → module thiết bị phụ trách.
    async fn dispatch(&self, v: Value) {
        let ty = v.get("type").and_then(Value::as_str).unwrap_or_default();
        if ty.starts_with("cam_") {
            if let Some(c) = &self.camera {
                c.clone().handle(&v).await;
            }
        } else if ty.starts_with("pur_") {
            if let Some(p) = &self.purifier {
                p.handle(&v).await;
            }
        } else if ty == "set" {
            // Lệnh điều khiển thiết bị (định dạng gateway Zigbee): giao cho module sở hữu `friendly_name`.
            let name = v.get("friendly_name").and_then(Value::as_str).unwrap_or_default();
            if let Some(p) = self.purifier.as_ref().filter(|p| p.owns(name)) {
                p.handle(&v).await;
            }
        }
    }
}

fn env_or(k: &str, d: &str) -> String {
    std::env::var(k).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| d.to_string())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let ws_url = env_or("CLOUD_WS_URL", "ws://localhost:8080/gw/ws");
    let token = std::env::var("GATEWAY_TOKEN").unwrap_or_default();
    anyhow::ensure!(!token.is_empty(), "GATEWAY_TOKEN is required (app → Bộ điều khiển trung tâm → Thêm)");
    let data = std::path::PathBuf::from(env_or("DATA_DIR", "/data"));
    std::fs::create_dir_all(&data)?;
    let enabled: Vec<String> = env_or("ADDON_DEVICES", "camera,purifier").split(',').map(|s| s.trim().to_lowercase()).collect();
    let on = |k: &str| enabled.iter().any(|e| e == k);

    let (up, up_rx) = mpsc::channel::<String>(256);
    let hub = Arc::new(Hub {
        camera: on("camera").then(|| camera::Cameras::load(&data, &env_or("GO2RTC_URL", "http://127.0.0.1:1984"), up.clone())),
        purifier: on("purifier").then(|| Arc::new(purifier::Purifiers::load(data.join("purifiers.json"), up.clone()))),
    });
    info!(
        devices = ?hub.caps(),
        cameras = hub.camera.as_ref().map_or(0, |c| c.count()),
        purifiers = hub.purifier.as_ref().map_or(0, |p| p.count()),
        "msmart addon starting"
    );
    anyhow::ensure!(!hub.caps().is_empty(), "ADDON_DEVICES không bật loại thiết bị nào (camera, purifier)");

    if let Some(c) = &hub.camera {
        tokio::spawn(c.clone().run());
    }
    if let Some(p) = &hub.purifier {
        let p = p.clone();
        tokio::spawn(async move { p.run().await });
    }
    cloud_loop(hub, ws_url, token, up_rx).await;
    Ok(())
}

async fn cloud_loop(hub: Arc<Hub>, url: String, token: String, mut up_rx: mpsc::Receiver<String>) {
    let mut backoff = 1u64;
    loop {
        let started = std::time::Instant::now();
        match session(&hub, &url, &token, &mut up_rx).await {
            Ok(()) => info!("cloud connection closed"),
            Err(e) => warn!("cloud connection failed: {e:#}"),
        }
        backoff = if started.elapsed() > Duration::from_secs(30) { 1 } else { (backoff * 2).min(30) };
        tokio::time::sleep(Duration::from_secs(backoff)).await;
    }
}

async fn session(hub: &Arc<Hub>, url: &str, token: &str, up_rx: &mut mpsc::Receiver<String>) -> anyhow::Result<()> {
    let mut req = url.into_client_request()?;
    req.headers_mut().insert("Authorization", format!("Bearer {token}").parse()?);
    let (ws, _) = connect_async(req).await?;
    info!("cloud connected");
    let (mut sink, mut stream) = ws.split();
    while up_rx.try_recv().is_ok() {}
    sink.send(Message::Text(json!({"type": "hello", "caps": hub.caps()}).to_string())).await?;
    hub.on_connect();

    let mut ping = tokio::time::interval(Duration::from_secs(30));
    loop {
        tokio::select! {
            Some(m) = up_rx.recv() => sink.send(Message::Text(m)).await?,
            _ = ping.tick() => sink.send(Message::Text(json!({"type": "ping"}).to_string())).await?,
            inbound = stream.next() => {
                let Some(inbound) = inbound else { return Ok(()) };
                match inbound? {
                    Message::Text(t) => {
                        if let Ok(v) = serde_json::from_str::<Value>(&t) {
                            let hub = hub.clone();
                            tokio::spawn(async move { hub.dispatch(v).await });
                        }
                    }
                    Message::Close(_) => return Ok(()),
                    _ => {}
                }
            }
        }
    }
}
