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
        self.gateways.insert(gw, GwConn { home_id, tx, kill });
    }

    /// Ngắt kết nối đang mở của gateway (khi thu hồi token / xoá gateway).
    pub fn kick_gateway(&self, gw: Uuid) {
        if let Some((_, c)) = self.gateways.remove(&gw) {
            c.kill.notify_one();
        }
    }

    /// Gateway đang kết nối của một căn hộ (mỗi căn hộ dùng một Matter bridge).
    pub fn gateway_for_home(&self, home_id: Uuid) -> Option<Uuid> {
        self.gateways.iter().find(|g| g.home_id == home_id).map(|g| *g.key())
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
        self.gateways.iter().any(|g| g.home_id == home_id)
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
