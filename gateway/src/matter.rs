//! Cầu nối tới Matterbridge (Matter bridge chạy cạnh Zigbee2MQTT trên Pi) để app lấy mã QR ghép nối
//! với Google Home / Apple Home.
//!
//! Matterbridge nói chuyện qua WebSocket (frontend của nó dùng cùng giao thức):
//!   ws://<host>:8283/?password=<mật khẩu frontend, mặc định rỗng>
//!   gửi   {"id":N,"src":"Frontend","dst":"Matterbridge","method":"/api/matter","params":{"id":"Matterbridge", ...}}
//!   nhận  {"id":N,"success":true,"response":{commissioned, qrPairingCode, manualPairingCode, windowStatus, fabricInformations, ...}}
//!   params mở/đóng cửa sổ ghép nối: {"startCommission":true} / {"stopCommission":true}; gỡ ứng dụng: {"removeFabric":<index>}
//!
//! Chỉ trả mã QR/mã thủ công khi bridge đang cho phép ghép nối (chưa ghép lần nào, hoặc cửa sổ ghép nối đang mở):
//! mã này là bí mật cho phép thêm người điều khiển nhà, không để lộ khi không cần.
use std::time::Duration;

use anyhow::{anyhow, bail, Context};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::time::timeout;
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[derive(Clone)]
pub struct Config {
    url: Option<String>,
    password: String,
}

impl Config {
    pub fn from_env() -> Self {
        let url = std::env::var("MATTERBRIDGE_URL").ok().map(|u| u.trim().trim_end_matches('/').to_string()).filter(|u| !u.is_empty());
        Self { url, password: std::env::var("MATTERBRIDGE_PASSWORD").unwrap_or_default() }
    }

    pub fn enabled(&self) -> bool {
        self.url.is_some()
    }
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

/// Gọi `/api/matter` với `params`, trả về `response` thô của Matterbridge.
async fn call(cfg: &Config, params: Value) -> anyhow::Result<Value> {
    let base = cfg.url.as_deref().ok_or_else(|| anyhow!("matter disabled"))?;
    let url = format!("{base}/?password={}", percent_encode(&cfg.password));
    let (ws, _) = timeout(Duration::from_secs(5), connect_async(url.as_str()))
        .await
        .context("timeout connecting to matterbridge")?
        .context("cannot connect to matterbridge")?;
    let (mut sink, mut stream) = ws.split();

    let mut p = json!({ "id": "Matterbridge" });
    if let (Some(dst), Some(src)) = (p.as_object_mut(), params.as_object()) {
        dst.extend(src.clone());
    }
    let req = json!({ "id": 7001, "src": "Frontend", "dst": "Matterbridge", "method": "/api/matter", "params": p });
    sink.send(Message::Text(req.to_string())).await?;

    let wait = async {
        while let Some(m) = stream.next().await {
            if let Message::Text(t) = m? {
                let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                if v.get("id").and_then(Value::as_i64) != Some(7001) {
                    continue; // bản tin broadcast khác của frontend
                }
                if let Some(e) = v.get("error").and_then(Value::as_str) {
                    bail!("matterbridge: {e}");
                }
                return Ok(v.get("response").cloned().unwrap_or(Value::Null));
            }
        }
        bail!("matterbridge closed the connection")
    };
    let out = timeout(Duration::from_secs(10), wait).await.context("timeout waiting for matterbridge")?;
    let _ = sink.close().await;
    out
}

/// Rút gọn dữ liệu Matterbridge thành những trường app cần. Mã ghép nối chỉ có mặt khi `pairing_open`.
fn to_info(r: &Value) -> Value {
    let commissioned = r["commissioned"].as_bool().unwrap_or(false);
    let advertising = r["advertising"].as_bool().unwrap_or(false);
    let window = r["windowStatus"].as_u64().unwrap_or(0) != 0;
    let pairing_open = !commissioned || advertising || window;
    let fabrics: Vec<Value> = r["fabricInformations"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|f| {
                    json!({
                        "index": f["fabricIndex"],
                        "label": f["label"].as_str().unwrap_or(""),
                        "vendor": f["rootVendorName"].as_str().unwrap_or(""),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let mut info = json!({
        "available": true,
        "online": r["online"].as_bool().unwrap_or(false),
        "commissioned": commissioned,
        "pairing_open": pairing_open,
        "fabrics": fabrics,
    });
    if pairing_open {
        info["qr"] = r["qrPairingCode"].clone();
        info["manual_code"] = r["manualPairingCode"].clone();
    }
    info
}

async fn info(cfg: &Config) -> anyhow::Result<Value> {
    Ok(to_info(&call(cfg, json!({})).await?))
}

/// Xử lý yêu cầu từ cloud, trả về bản tin `matter_reply` để gửi lại (luôn có `id` của yêu cầu).
pub async fn handle(cfg: &Config, msg: &Value) -> Value {
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    if !cfg.enabled() {
        return json!({ "type": "matter_reply", "id": id, "info": { "available": false } });
    }
    let result: anyhow::Result<Value> = async {
        match msg.get("type").and_then(Value::as_str) {
            Some("matter_get") => info(cfg).await,
            Some("matter_pairing") => {
                let open = msg.get("open").and_then(Value::as_bool).unwrap_or(false);
                call(cfg, if open { json!({ "startCommission": true }) } else { json!({ "stopCommission": true }) }).await?;
                tokio::time::sleep(Duration::from_millis(400)).await;
                info(cfg).await
            }
            Some("matter_remove_fabric") => {
                let idx = msg.get("fabric_index").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing fabric_index"))?;
                call(cfg, json!({ "removeFabric": idx })).await?;
                tokio::time::sleep(Duration::from_millis(400)).await;
                info(cfg).await
            }
            other => bail!("unsupported matter request {other:?}"),
        }
    }
    .await;
    match result {
        Ok(info) => json!({ "type": "matter_reply", "id": id, "info": info }),
        Err(e) => {
            // Không ghi nội dung phản hồi (có thể chứa mã ghép nối), chỉ ghi lỗi.
            tracing::warn!("matter request failed: {e:#}");
            json!({ "type": "matter_reply", "id": id, "error": "matterbridge unavailable" })
        }
    }
}
