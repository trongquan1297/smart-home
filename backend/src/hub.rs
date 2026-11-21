//! Hub trong bộ nhớ: nối gateway (Pi) ↔ client (app) theo home.
//! Lưu ý scale-out: hub là state cục bộ theo tiến trình. Chạy >1 instance cần pub/sub chung
//! (Postgres LISTEN/NOTIFY, Redis hoặc Durable Objects) — xem docs/ARCHITECTURE.md.
use std::sync::Arc;

use dashmap::DashMap;
use serde_json::{json, Value};
use tokio::sync::{broadcast, mpsc, oneshot, Notify};
use uuid::Uuid;

struct GwConn {
    home_id: Uuid,
    /// Khả năng gateway tự khai báo (`z2m`, `cast`). Rỗng = gateway cũ: coi là có Zigbee2MQTT, không có Cast.
    caps: std::sync::Mutex<Vec<String>>,
    tx: mpsc::Sender<String>,
    kill: Arc<Notify>,
}

struct Pending {
    gw: Uuid,
    tx: oneshot::Sender<Value>,
}

#[derive(Debug)]
pub enum RequestError {
    Offline,
    Timeout,
}

#[derive(Default)]
pub struct Hub {
    gateways: DashMap<Uuid, GwConn>,
    homes: DashMap<Uuid, broadcast::Sender<String>>,
    /// Yêu cầu đang chờ gateway trả lời (matter_*): id -> bộ nhận. Không lưu gì xuống DB.
    pending: DashMap<Uuid, Pending>,
}

impl Hub {
    pub fn register_gateway(&self, gw: Uuid, home_id: Uuid, tx: mpsc::Sender<String>, kill: Arc<Notify>) {
        self.gateways.insert(gw, GwConn { home_id, caps: Default::default(), tx, kill });
    }

    pub fn set_caps(&self, gw: Uuid, caps: Vec<String>) {
        if let Some(c) = self.gateways.get(&gw) {
            *c.caps.lock().unwrap() = caps;
        }
    }

    /// Ngắt kết nối đang mở của gateway (khi thu hồi token / xoá gateway).
    pub fn kick_gateway(&self, gw: Uuid) {
        if let Some((_, c)) = self.gateways.remove(&gw) {
            c.kill.notify_one();
        }
    }

    /// Gateway có Zigbee2MQTT / Matter bridge. Gateway chỉ làm loa Cast hoặc addon camera thì không.
    /// Chưa khai báo khả năng (gateway rất cũ, hoặc chưa kịp gửi hello) = coi là gateway Zigbee.
    fn cast_only(c: &GwConn) -> bool {
        let caps = c.caps.lock().unwrap();
        !caps.is_empty() && !caps.iter().any(|x| x == "z2m")
    }

    fn has_cap(c: &GwConn, cap: &str) -> bool {
        c.caps.lock().unwrap().iter().any(|x| x == cap)
    }

    /// Mọi addon camera đang kết nối của căn hộ.
    pub fn camera_gateways_for_home(&self, home_id: Uuid) -> Vec<Uuid> {
        self.gateways.iter().filter(|g| g.home_id == home_id && Self::has_cap(&g, "camera")).map(|g| *g.key()).collect()
    }

    /// Mọi addon đang kết nối của căn hộ đọc được máy lọc nước Bluetooth.
    pub fn purifier_gateways_for_home(&self, home_id: Uuid) -> Vec<Uuid> {
        self.gateways.iter().filter(|g| g.home_id == home_id && Self::has_cap(&g, "purifier")).map(|g| *g.key()).collect()
    }

    /// Gateway Zigbee/Matter đang kết nối của một căn hộ (mỗi căn hộ dùng một Matter bridge); bỏ qua gateway chỉ làm loa Cast.
    pub fn gateway_for_home(&self, home_id: Uuid) -> Option<Uuid> {
        self.gateways.iter().find(|g| g.home_id == home_id && !Self::cast_only(&g)).map(|g| *g.key())
    }

    /// Mọi gateway Zigbee đang kết nối của căn hộ (để mở ghép nối trên tất cả).
    pub fn z2m_gateways_for_home(&self, home_id: Uuid) -> Vec<Uuid> {
        self.gateways.iter().filter(|g| g.home_id == home_id && !Self::cast_only(&g)).map(|g| *g.key()).collect()
    }

    /// Mọi gateway đang kết nối của căn hộ có khả năng cast tới loa (mDNS chạy được).
    pub fn cast_gateways_for_home(&self, home_id: Uuid) -> Vec<Uuid> {
        self.gateways.iter().filter(|g| g.home_id == home_id && g.caps.lock().unwrap().iter().any(|x| x == "cast")).map(|g| *g.key()).collect()
    }

    pub fn gateway_connected_for(&self, home_id: Uuid, gw: Uuid) -> bool {
        self.gateways.get(&gw).is_some_and(|g| g.home_id == home_id)
    }

    /// Gửi yêu cầu xuống gateway và chờ bản tin trả lời cùng `id`. Bí mật (mã ghép nối) chỉ đi qua RAM.
    pub async fn request_gateway(&self, gw: Uuid, mut msg: Value, wait: std::time::Duration) -> Result<Value, RequestError> {
        let id = Uuid::new_v4();
        msg["id"] = json!(id.to_string());
        let (tx, rx) = oneshot::channel();
        self.pending.insert(id, Pending { gw, tx });
        if !self.send_gateway(gw, msg.to_string()).await {
            self.pending.remove(&id);
            return Err(RequestError::Offline);
        }
        match tokio::time::timeout(wait, rx).await {
            Ok(Ok(v)) => Ok(v),
            _ => {
                self.pending.remove(&id);
                Err(RequestError::Timeout)
            }
        }
    }

    /// Gateway trả lời. Chỉ chấp nhận nếu đúng gateway đã nhận yêu cầu (gateway khác không giả mạo được).
    pub fn resolve(&self, gw: Uuid, id: Uuid, reply: Value) {
        if let Some((_, p)) = self.pending.remove_if(&id, |_, p| p.gw == gw) {
            let _ = p.tx.send(reply);
        }
    }

    pub fn gateway_connected(&self, gw: Uuid) -> bool {
        self.gateways.contains_key(&gw)
    }

    /// Chỉ gỡ nếu kết nối hiện tại vẫn là `tx` (tránh gỡ nhầm kết nối mới khi gateway reconnect).
    pub fn unregister_gateway(&self, gw: Uuid, tx: &mpsc::Sender<String>) {
        self.gateways.remove_if(&gw, |_, c| c.tx.same_channel(tx));
    }

    pub fn gateway_online(&self, home_id: Uuid) -> bool {
        self.gateways.iter().any(|g| g.home_id == home_id && !Self::cast_only(&g))
    }

    /// Gửi lệnh xuống gateway. false = gateway offline / nghẽn.
    pub async fn send_gateway(&self, gw: Uuid, msg: String) -> bool {
        let tx = match self.gateways.get(&gw) {
            Some(c) => c.tx.clone(),
            None => return false,
        };
        tokio::time::timeout(std::time::Duration::from_secs(2), tx.send(msg))
            .await
            .map(|r| r.is_ok())
            .unwrap_or(false)
    }

    pub fn subscribe(&self, home: Uuid) -> broadcast::Receiver<String> {
        self.homes
            .entry(home)
            .or_insert_with(|| broadcast::channel(256).0)
            .subscribe()
    }

    pub fn publish(&self, home: Uuid, msg: String) {
        if let Some(tx) = self.homes.get(&home) {
            let _ = tx.send(msg); // không có subscriber thì bỏ qua
        }
    }
}
