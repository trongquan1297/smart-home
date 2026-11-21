//! Máy lọc nước Bluetooth (Karofi) trong addon: tìm máy, đọc số liệu định kỳ, đặt lại lõi lọc.
//!
//! Với cloud, mỗi máy lọc là một thiết bị bình thường của căn hộ (giống thiết bị Zigbee): addon gửi `devices`,
//! `state`, `availability` cùng định dạng gateway Zigbee, và nhận `set` (đặt lại lõi lọc). Không có bí mật nào:
//! addon chỉ nhớ địa chỉ MAC trong `$DATA_DIR/purifiers.json`.
//!
//! Bluetooth qua BlueZ (D-Bus hệ thống của máy chủ): container cần mount `/run/dbus`. Mọi thao tác radio
//! (quét, kết nối) đi tuần tự qua một khoá — adapter Bluetooth của Pi làm một việc một lúc thì ổn định nhất.
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};

use anyhow::{anyhow, Context};
use btleplug::{
    api::{bleuuid::uuid_from_u16, BDAddr, Central, CharPropFlags, Characteristic, Manager as _, Peripheral as _, ScanFilter, WriteType},
    platform::{Adapter, Manager, Peripheral},
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{mpsc, Mutex as AsyncMutex};
use tracing::{info, warn};

pub mod karofi;

use self::karofi::Status;

/// Sau bao nhiêu lần đọc hỏng liên tiếp thì báo máy offline.
const FAILS_OFFLINE: u32 = 3;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const CONNECT_ATTEMPTS: u32 = 6;
const NOTIFY_WAIT: Duration = Duration::from_millis(3500);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Saved {
    /// Tên quảng bá Bluetooth (vd TCM-112233), làm "model" hiển thị.
    pub ble_name: String,
}

#[derive(Default)]
struct Live {
    status: Status,
    fails: u32,
    online: bool,
    sent_state: Option<Value>,
}

pub struct Purifiers {
    path: PathBuf,
    saved: Mutex<BTreeMap<String, Saved>>,
    live: Mutex<HashMap<String, Live>>,
    radio: AsyncMutex<Option<Adapter>>,
    up: mpsc::Sender<String>,
    poll_every: Duration,
}

/// Tên Zigbee-style dùng làm khoá định tuyến `state`/`set` với cloud (duy nhất trong addon).
pub fn friendly(mac: &str) -> String {
    format!("karofi-{}", mac.replace(':', "").to_lowercase())
}

/// Chuẩn hoá MAC về dạng AA:BB:CC:DD:EE:FF; None nếu không hợp lệ.
pub fn norm_mac(s: &str) -> Option<String> {
    let hex: String = s.chars().filter(|c| !matches!(c, ':' | '-' | '.' | ' ')).collect();
    if hex.len() != 12 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(hex.to_uppercase().as_bytes().chunks(2).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join(":"))
}

/// Lỗi trả về app: mã ngắn.
pub fn short_err(e: &anyhow::Error) -> &'static str {
    let s = format!("{e:#}");
    if s.contains("NotReady") || s.contains("Powered") || s.contains("rfkill") || s.contains("Blocked") {
        "bluetooth_off"
    } else if s.contains("no bluetooth") || s.contains("D-Bus") || s.contains("dbus") {
        "bluetooth_unavailable"
    } else if s.contains("not found") {
        "not_found"
    } else {
        "unreachable"
    }
}

impl Purifiers {
    pub fn load(path: PathBuf, up: mpsc::Sender<String>) -> Self {
        let saved: BTreeMap<String, Saved> = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let poll = std::env::var("PURIFIER_POLL_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(60u64).clamp(20, 3600);
        Purifiers { path, saved: Mutex::new(saved), live: Mutex::new(HashMap::new()), radio: AsyncMutex::new(None), up, poll_every: Duration::from_secs(poll) }
    }

    pub fn count(&self) -> usize {
        self.saved.lock().unwrap().len()
    }

    fn save(&self) -> std::io::Result<()> {
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(&*self.saved.lock().unwrap())?)?;
        std::fs::rename(tmp, &self.path)
    }

    fn mac_of(&self, friendly_name: &str) -> Option<String> {
        self.saved.lock().unwrap().keys().find(|m| friendly(m) == friendly_name).cloned()
    }

    /// Danh sách thiết bị theo định dạng `bridge/devices` của Zigbee2MQTT (cloud dùng chung đường xử lý).
    pub fn devices_msg(&self) -> String {
        let devices: Vec<Value> = self
            .saved
            .lock()
            .unwrap()
            .iter()
            .map(|(mac, s)| {
                json!({
                    "ieee_address": mac,
                    "friendly_name": friendly(mac),
                    "type": "EndDevice",
                    "definition": {
                        "vendor": "Karofi",
                        "model": s.ble_name,
                        "description": "Water purifier (Bluetooth)",
                        "exposes": [
                            {"type": "numeric", "property": "tds", "unit": "ppm", "access": 1},
                            {"type": "enum", "property": "quality", "access": 1, "values": ["good", "fair", "poor", "unknown"]},
                            {"type": "composite", "property": "filters", "access": 1},
                            {"type": "numeric", "property": "filter_min", "unit": "%", "access": 1},
                            {"type": "list", "property": "errors", "access": 1},
                            {"type": "numeric", "property": "reset_filter", "access": 2, "value_min": 1, "value_max": karofi::MAX_FILTERS}
                        ]
                    }
                })
            })
            .collect();
        json!({"type": "devices", "devices": devices}).to_string()
    }

    /// Gửi lại toàn bộ (khi vừa kết nối cloud): danh sách, online/offline, trạng thái cuối.
    pub fn resend_all(&self) {
        let _ = self.up.try_send(self.devices_msg());
        let mut live = self.live.lock().unwrap();
        for mac in self.saved.lock().unwrap().keys() {
            let l = live.entry(mac.clone()).or_default();
            let _ = self.up.try_send(json!({"type": "availability", "friendly_name": friendly(mac), "online": l.online}).to_string());
            if let Some(s) = &l.sent_state {
                let _ = self.up.try_send(json!({"type": "state", "friendly_name": friendly(mac), "payload": s}).to_string());
            }
        }
    }

    async fn adapter(&self, slot: &mut Option<Adapter>) -> anyhow::Result<Adapter> {
        if let Some(a) = slot.as_ref() {
            return Ok(a.clone());
        }
        let m = Manager::new().await.context("D-Bus/BlueZ")?;
        let a = m.adapters().await?.into_iter().next().ok_or_else(|| anyhow!("no bluetooth adapter"))?;
        *slot = Some(a.clone());
        Ok(a)
    }

    /// Quét `secs` giây, trả về các máy Karofi thấy được: (MAC, tên, RSSI).
    async fn scan_with(adapter: &Adapter, secs: u64) -> anyhow::Result<Vec<(String, String, Option<i16>)>> {
        adapter.start_scan(ScanFilter::default()).await?;
        tokio::time::sleep(Duration::from_secs(secs)).await;
        let _ = adapter.stop_scan().await;
        let svc = uuid_from_u16(karofi::SERVICE);
        let mut out = Vec::new();
        for p in adapter.peripherals().await? {
            let Ok(Some(props)) = p.properties().await else { continue };
            let name = props.local_name.clone().unwrap_or_default();
            if karofi::is_karofi_name(&name) || props.services.contains(&svc) {
                out.push((p.address().to_string().to_uppercase(), name, props.rssi));
            }
        }
        Ok(out)
    }

    pub async fn scan(&self) -> anyhow::Result<Value> {
        let mut slot = self.radio.lock().await;
        let adapter = self.adapter(&mut slot).await?;
        let found = Self::scan_with(&adapter, 8).await?;
        let saved = self.saved.lock().unwrap();
        Ok(json!(found
            .into_iter()
            .map(|(mac, name, rssi)| json!({"mac": mac, "name": name, "rssi": rssi, "added": saved.contains_key(&mac)}))
            .collect::<Vec<_>>()))
    }

    async fn find(adapter: &Adapter, mac: &str) -> anyhow::Result<Peripheral> {
        let addr: BDAddr = mac.parse().map_err(|_| anyhow!("bad mac"))?;
        for attempt in 0..2 {
            if let Some(p) = adapter.peripherals().await?.into_iter().find(|p| p.address() == addr) {
                return Ok(p);
            }
            if attempt == 0 {
                // BlueZ quên thiết bị không ghép đôi sau một lúc: quét ngắn để thấy lại.
                adapter.start_scan(ScanFilter::default()).await?;
                let until = Instant::now() + Duration::from_secs(10);
                while Instant::now() < until {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    if adapter.peripherals().await?.iter().any(|p| p.address() == addr) {
                        break;
                    }
                }
                let _ = adapter.stop_scan().await;
            }
        }
        Err(anyhow!("purifier not found nearby"))
    }

    /// Một phiên kết nối: đọc mọi đặc tính dữ liệu + yêu cầu máy gửi số liệu qua notify. Trả về các khối byte thô.
    async fn read_raw(p: &Peripheral) -> anyhow::Result<Vec<Vec<u8>>> {
        let chars = p.characteristics();
        let (svc, cmd_svc) = (uuid_from_u16(karofi::SERVICE), uuid_from_u16(karofi::CMD_SERVICE));
        let (notify_u, cmd_u, wifi_u) = (uuid_from_u16(karofi::NOTIFY), uuid_from_u16(karofi::COMMAND), uuid_from_u16(karofi::WIFI_PROV));
        let mut out = Vec::new();

        // 1) Đọc trực tiếp các đặc tính dữ liệu của dịch vụ 12ac (bỏ kênh lệnh/OTA).
        let data: Vec<&Characteristic> =
            chars.iter().filter(|c| c.service_uuid == svc && c.properties.contains(CharPropFlags::READ) && ![notify_u, cmd_u, wifi_u].contains(&c.uuid)).collect();
        for c in &data {
            if let Ok(Ok(v)) = tokio::time::timeout(Duration::from_secs(4), p.read(c)).await {
                if !v.is_empty() {
                    out.push(v);
                }
            }
        }

        // 2) Bật notify rồi gửi {"et":"NP"}: máy trả số liệu, hoặc trả {"id": "<uuid>"} = "hãy đọc đặc tính này".
        let notify = chars
            .iter()
            .find(|c| c.uuid == notify_u && c.properties.intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE))
            .or_else(|| chars.iter().find(|c| c.service_uuid == svc && c.properties.intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE)));
        let writable = CharPropFlags::WRITE | CharPropFlags::WRITE_WITHOUT_RESPONSE;
        let cmd = chars
            .iter()
            .find(|c| c.service_uuid == cmd_svc && c.uuid == cmd_u && c.properties.intersects(writable))
            .or_else(|| notify.filter(|c| c.properties.intersects(writable)));
        let (Some(notify), Some(cmd)) = (notify, cmd) else { return Ok(out) };
        p.subscribe(notify).await?;
        let mut stream = p.notifications().await?;
        write_chunked(p, cmd, karofi::READ_REQUEST).await?;
        let mut stream_bytes = Vec::new();
        let deadline = tokio::time::Instant::now() + NOTIFY_WAIT;
        let mut probe = Status::default();
        while let Ok(Some(n)) = tokio::time::timeout_at(deadline, stream.next()).await {
            stream_bytes.extend_from_slice(&n.value);
            // Gói báo "đọc đặc tính <id>": đọc ngay đặc tính đó trong dịch vụ 12ac.
            for m in karofi::json_dicts(&n.value) {
                if let Some(id) = m.get("id").map(|v| v.as_str().map(str::to_lowercase).unwrap_or_else(|| v.to_string())) {
                    if let Some(c) = chars.iter().find(|c| c.service_uuid == svc && c.uuid.to_string().contains(&id)) {
                        if let Ok(Ok(v)) = tokio::time::timeout(Duration::from_secs(4), p.read(c)).await {
                            out.push(v);
                        }
                    }
                }
            }
            if probe.apply(&stream_bytes) && probe.tds.is_some() && !probe.filters.is_empty() {
                break; // đủ TDS + lõi lọc, không cần chờ hết thời gian
            }
        }
        out.push(stream_bytes);
        let _ = p.unsubscribe(notify).await;
        Ok(out)
    }

    async fn with_device<T>(&self, mac: &str, f: impl AsyncFnOnce(&Peripheral) -> anyhow::Result<T>) -> anyhow::Result<T> {
        let mut slot = self.radio.lock().await;
        let adapter = match self.adapter(&mut slot).await {
            Ok(a) => a,
            Err(e) => return Err(e),
        };
        let r = async {
            let p = Self::find(&adapter, mac).await?;
            // Kết nối LE tới máy lọc chập chờn (thử trên Pi 4: ~1/4 lần thành công, lỗi 0x3e "Connection Failed to be
            // Established" — BlueZ báo le-connection-abort-by-local). Mỗi lần hỏng chỉ mất < 1 giây nên thử lại nhiều lần,
            // giống bleak-retry-connector của tích hợp karofi gốc.
            let mut attempt = 0;
            loop {
                attempt += 1;
                match tokio::time::timeout(CONNECT_TIMEOUT, p.connect()).await {
                    Ok(Ok(())) => break,
                    Ok(Err(e)) if attempt < CONNECT_ATTEMPTS => tracing::debug!(attempt, "connect failed: {e}"),
                    Ok(Err(e)) => return Err(anyhow!(e).context(format!("connect failed after {attempt} attempts"))),
                    Err(_) => return Err(anyhow!("connect timed out")),
                }
                tokio::time::sleep(Duration::from_millis(500 * attempt as u64)).await;
            }
            let r = async {
                tokio::time::timeout(Duration::from_secs(15), p.discover_services()).await.map_err(|_| anyhow!("discover timed out"))??;
                f(&p).await
            }
            .await;
            let _ = tokio::time::timeout(Duration::from_secs(5), p.disconnect()).await;
            r
        }
        .await;
        if r.is_err() {
            // BlueZ có thể vừa khởi động lại (đối tượng D-Bus cũ không còn) → lần sau tạo kết nối D-Bus mới.
            *slot = None;
        }
        r
    }

    /// Đọc một máy; cập nhật trạng thái và báo cloud nếu có thay đổi.
    pub async fn poll(&self, mac: &str) -> anyhow::Result<Value> {
        let raw = self.with_device(mac, async |p: &Peripheral| Self::read_raw(p).await).await;
        let mut live = self.live.lock().unwrap();
        let l = live.entry(mac.to_string()).or_default();
        let name = friendly(mac);
        match raw {
            Ok(chunks) => {
                let mut got = false;
                for c in &chunks {
                    got |= l.status.apply(c);
                }
                if !got {
                    l.fails += 1;
                    return Err(anyhow!("no data from purifier"));
                }
                l.fails = 0;
                if !l.online {
                    l.online = true;
                    let _ = self.up.try_send(json!({"type": "availability", "friendly_name": name, "online": true}).to_string());
                }
                let s = l.status.to_json();
                if l.sent_state.as_ref() != Some(&s) {
                    let _ = self.up.try_send(json!({"type": "state", "friendly_name": name, "payload": s}).to_string());
                    l.sent_state = Some(s.clone());
                }
                Ok(s)
            }
            Err(e) => {
                l.fails += 1;
                if l.online && l.fails >= FAILS_OFFLINE {
                    l.online = false;
                    let _ = self.up.try_send(json!({"type": "availability", "friendly_name": name, "online": false}).to_string());
                }
                Err(e)
            }
        }
    }

    /// Thêm máy: phải đọc được số liệu thật thì mới lưu.
    pub async fn add(&self, mac: &str) -> anyhow::Result<Value> {
        let mac = norm_mac(mac).ok_or_else(|| anyhow!("bad mac"))?;
        let ble_name = {
            let mut slot = self.radio.lock().await;
            let adapter = self.adapter(&mut slot).await?;
            let p = Self::find(&adapter, &mac).await?;
            p.properties().await.ok().flatten().and_then(|pr| pr.local_name).unwrap_or_else(|| "Karofi".into())
        };
        let fresh = !self.saved.lock().unwrap().contains_key(&mac);
        self.saved.lock().unwrap().insert(mac.clone(), Saved { ble_name: ble_name.chars().take(32).collect() });
        match self.poll(&mac).await {
            Ok(state) => {
                if let Err(e) = self.save() {
                    // Không lưu được (vd /data sai quyền) thì đừng giữ máy trong bộ nhớ: lần khởi động sau sẽ mất máy.
                    if fresh {
                        self.saved.lock().unwrap().remove(&mac);
                        self.live.lock().unwrap().remove(&mac);
                    }
                    return Err(anyhow!(e).context("save purifiers.json"));
                }
                let _ = self.up.try_send(self.devices_msg());
                if let Some(s) = self.live.lock().unwrap().get(&mac).and_then(|l| l.sent_state.clone()) {
                    let _ = self.up.try_send(json!({"type": "state", "friendly_name": friendly(&mac), "payload": s}).to_string());
                }
                info!(purifier = %mask(&mac), "purifier added");
                Ok(json!({"mac": mac, "friendly_name": friendly(&mac), "model": ble_name, "state": state}))
            }
            Err(e) => {
                if fresh {
                    self.saved.lock().unwrap().remove(&mac);
                    self.live.lock().unwrap().remove(&mac);
                }
                Err(e)
            }
        }
    }

    pub fn remove(&self, mac: &str) -> anyhow::Result<()> {
        let mac = norm_mac(mac).ok_or_else(|| anyhow!("bad mac"))?;
        if self.saved.lock().unwrap().remove(&mac).is_some() {
            self.live.lock().unwrap().remove(&mac);
            self.save()?;
            let _ = self.up.try_send(self.devices_msg());
            info!(purifier = %mask(&mac), "purifier removed");
        }
        Ok(())
    }

    /// Lệnh `set` từ cloud: hiện chỉ có `reset_filter` (số thứ tự lõi lọc, đếm từ 1). Không phải máy lọc thì bỏ qua.
    pub async fn set(&self, friendly_name: &str, payload: &Value) {
        let Some(mac) = self.mac_of(friendly_name) else { return };
        let Some(no) = payload.get("reset_filter").and_then(Value::as_u64).filter(|n| (1..=karofi::MAX_FILTERS as u64).contains(n)) else { return };
        let cmd = karofi::reset_command(no as usize - 1);
        let r = self
            .with_device(&mac, async |p: &Peripheral| {
                let chars = p.characteristics();
                let notify_u = uuid_from_u16(karofi::NOTIFY);
                let writable = CharPropFlags::WRITE | CharPropFlags::WRITE_WITHOUT_RESPONSE;
                // Ứng dụng của hãng ghi lệnh vào đặc tính notify/ghi (ac02), không phải kênh Wi‑Fi (ab02).
                let target = chars
                    .iter()
                    .find(|c| c.uuid == notify_u && c.properties.intersects(writable))
                    .or_else(|| chars.iter().find(|c| c.uuid == uuid_from_u16(karofi::COMMAND) && c.properties.intersects(writable)))
                    .ok_or_else(|| anyhow!("no command characteristic"))?;
                if target.properties.intersects(CharPropFlags::NOTIFY) {
                    let _ = p.subscribe(target).await;
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
                let wt = if target.properties.contains(CharPropFlags::WRITE) { WriteType::WithResponse } else { WriteType::WithoutResponse };
                p.write(target, &cmd, wt).await?;
                tokio::time::sleep(Duration::from_secs(1)).await;
                Ok(())
            })
            .await;
        match r {
            Ok(()) => {
                info!(purifier = %mask(&mac), filter = no, "filter reset sent");
                tokio::time::sleep(Duration::from_secs(2)).await;
                if let Err(e) = self.poll(&mac).await {
                    warn!(purifier = %mask(&mac), "poll after reset failed: {e:#}");
                }
            }
            Err(e) => warn!(purifier = %mask(&mac), "filter reset failed: {e:#}"),
        }
    }

    /// Đọc lần lượt mọi máy mỗi `PURIFIER_POLL_SECS` (mặc định 60 giây).
    pub async fn run(&self) {
        let mut tick = tokio::time::interval(self.poll_every);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut warned: Option<Instant> = None;
        loop {
            tick.tick().await;
            let macs: BTreeSet<String> = self.saved.lock().unwrap().keys().cloned().collect();
            for mac in macs {
                if let Err(e) = self.poll(&mac).await {
                    // Lỗi Bluetooth lặp lại mỗi phút: chỉ ghi log mỗi giờ một lần.
                    if warned.is_none_or(|w| w.elapsed() > Duration::from_secs(3600)) {
                        warn!(purifier = %mask(&mac), "poll failed: {e:#}");
                        warned = Some(Instant::now());
                    }
                }
            }
        }
    }

    /// Thiết bị `friendly_name` có phải máy lọc của addon này không (định tuyến lệnh `set`).
    pub fn owns(&self, friendly_name: &str) -> bool {
        self.mac_of(friendly_name).is_some()
    }

    /// Bản tin cloud → addon dành cho máy lọc: `pur_scan`, `pur_add`, `pur_remove` (trả `pur_reply` cùng `id`) và `set`.
    pub async fn handle(&self, v: &Value) {
        let id = v.get("id").cloned().unwrap_or(Value::Null);
        let mac = v.get("mac").and_then(Value::as_str).unwrap_or_default();
        let r = match v.get("type").and_then(Value::as_str) {
            Some("pur_scan") => self.scan().await.map(|d| json!({ "devices": d })),
            Some("pur_add") => self.add(mac).await.map(|info| json!({ "info": info })),
            Some("pur_remove") => self.remove(mac).map(|()| json!({ "ok": true })),
            Some("set") => {
                if let (Some(name), Some(p)) = (v.get("friendly_name").and_then(Value::as_str), v.get("payload")) {
                    self.set(name, p).await;
                }
                return;
            }
            _ => return,
        };
        if id.is_null() {
            return;
        }
        let mut body = r.unwrap_or_else(|e| {
            warn!("purifier request failed: {e:#}");
            json!({ "error": short_err(&e) })
        });
        body["type"] = json!("pur_reply");
        body["id"] = id;
        let _ = self.up.try_send(body.to_string());
    }
}

async fn write_chunked(p: &Peripheral, c: &Characteristic, data: &[u8]) -> anyhow::Result<()> {
    let wt = if c.properties.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) { WriteType::WithoutResponse } else { WriteType::WithResponse };
    for chunk in data.chunks(karofi::CHUNK) {
        if p.write(c, chunk, wt).await.is_err() {
            let other = if wt == WriteType::WithResponse { WriteType::WithoutResponse } else { WriteType::WithResponse };
            p.write(c, chunk, other).await?;
        }
    }
    Ok(())
}

/// Che MAC trong log: chỉ giữ 2 byte cuối.
fn mask(mac: &str) -> String {
    format!("**:**:**:**:{}", &mac[mac.len().saturating_sub(5)..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_and_names() {
        assert_eq!(norm_mac("aa-bb-cc-11-22-33").as_deref(), Some("AA:BB:CC:11:22:33"));
        assert_eq!(norm_mac("aabbcc112233").as_deref(), Some("AA:BB:CC:11:22:33"));
        assert_eq!(norm_mac("xx"), None);
        assert_eq!(friendly("AA:BB:CC:11:22:33"), "karofi-aabbcc112233");
        assert_eq!(mask("AA:BB:CC:11:22:33"), "**:**:**:**:22:33");
    }
}
