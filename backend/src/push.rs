//! Thông báo đẩy qua Firebase Cloud Messaging (HTTP v1), dùng chung cho Android và iOS (iOS đi qua APNs đã khai báo
//! trong dự án Firebase). TUỲ CHỌN: chỉ bật khi đặt `FCM_SERVICE_ACCOUNT_FILE` (đường dẫn tới JSON service account của
//! dự án Firebase). Chưa đặt thì mọi lời gọi là no-op: thông báo vẫn được lưu và đẩy realtime tới app đang mở.
//!
//! CHƯA ĐƯỢC KIỂM CHỨNG với FCM thật (cần dự án Firebase + thiết bị thật); phần dựng nội dung tin nhắn có unit test.
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{gsa::ServiceAccount, AppState};

pub struct Fcm {
    sa: ServiceAccount,
}

#[derive(Debug, PartialEq)]
pub enum SendResult {
    Ok,
    /// Token không còn hợp lệ (gỡ app, đổi thiết bị): nên xoá khỏi DB.
    InvalidToken,
    Failed(String),
}

impl Fcm {
    pub fn from_env() -> Option<Fcm> {
        let path = std::env::var("FCM_SERVICE_ACCOUNT_FILE").ok().filter(|p| !p.trim().is_empty())?;
        let sa = ServiceAccount::load(&path, "https://www.googleapis.com/auth/firebase.messaging", "push")?;
        tracing::info!(project = %sa.project_id, "push: FCM đã bật");
        Some(Fcm { sa })
    }

    pub async fn send(&self, device_token: &str, title: &str, body: &str, data: &Value) -> SendResult {
        let access = match self.sa.access_token().await {
            Ok(t) => t,
            Err(e) => return SendResult::Failed(format!("lấy access token: {e}")),
        };
        let url = format!("https://fcm.googleapis.com/v1/projects/{}/messages:send", self.sa.project_id);
        let res = match self.sa.http.post(url).bearer_auth(access).json(&message_body(device_token, title, body, data)).send().await {
            Ok(r) => r,
            Err(e) => return SendResult::Failed(e.to_string()),
        };
        let status = res.status();
        if status.is_success() {
            return SendResult::Ok;
        }
        let text = res.text().await.unwrap_or_default();
        if status.as_u16() == 404 || text.contains("UNREGISTERED") {
            SendResult::InvalidToken
        } else {
            SendResult::Failed(format!("HTTP {status}: {}", text.chars().take(200).collect::<String>()))
        }
    }
}

/// Nội dung tin nhắn FCM v1. `data` của FCM chỉ nhận chuỗi nên mọi giá trị được đổi sang chuỗi.
pub fn message_body(device_token: &str, title: &str, body: &str, data: &Value) -> Value {
    let data: serde_json::Map<String, Value> = data
        .as_object()
        .map(|o| o.iter().map(|(k, v)| (k.clone(), Value::String(v.as_str().map(str::to_owned).unwrap_or_else(|| v.to_string())))).collect())
        .unwrap_or_default();
    json!({
        "message": {
            "token": device_token,
            "notification": { "title": title, "body": body },
            "data": data,
            "android": { "priority": "HIGH", "notification": { "channel_id": "alerts", "sound": "default" } },
            "apns": { "headers": { "apns-priority": "10" }, "payload": { "aps": { "sound": "default" } } }
        }
    })
}

/// Gửi tới mọi thiết bị đã đăng ký của thành viên có quyền điều khiển (chủ nhà, quản trị, thành viên và quản trị tenant).
/// Khách thuê và khách xem không nhận thông báo cảnh báo.
pub async fn notify_home(st: &AppState, home: Uuid, title: &str, body: &str, data: Value) {
    let Some(fcm) = st.push.as_ref() else { return };
    let tokens: Vec<String> = match sqlx::query_scalar(
        "SELECT DISTINCT pt.token FROM push_tokens pt
          WHERE pt.user_id IN (
                  SELECT user_id FROM home_members WHERE home_id = $1 AND role IN ('owner','admin','member')
                  UNION
                  SELECT tm.user_id FROM tenant_members tm JOIN homes h ON h.tenant_id = tm.tenant_id WHERE h.id = $1)",
    )
    .bind(home)
    .fetch_all(&st.db)
    .await
    {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("push: không lấy được token: {e}");
            return;
        }
    };
    for t in tokens {
        match fcm.send(&t, title, body, &data).await {
            SendResult::Ok => {}
            SendResult::InvalidToken => {
                let _ = sqlx::query("DELETE FROM push_tokens WHERE token = $1").bind(&t).execute(&st.db).await;
            }
            SendResult::Failed(e) => tracing::warn!("push: gửi thất bại: {e}"), // không ghi token
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_has_notification_and_stringified_data() {
        let m = message_body("tok-123", "Cửa vừa mở", "Cửa chính vừa mở", &json!({"kind": "door_open", "n": 5, "ok": true}));
        let msg = &m["message"];
        assert_eq!(msg["token"], "tok-123");
        assert_eq!(msg["notification"]["title"], "Cửa vừa mở");
        // FCM data chỉ nhận chuỗi
        assert_eq!(msg["data"]["kind"], "door_open");
        assert_eq!(msg["data"]["n"], "5");
        assert_eq!(msg["data"]["ok"], "true");
        assert_eq!(msg["android"]["priority"], "HIGH");
        assert_eq!(msg["apns"]["headers"]["apns-priority"], "10");
    }

    #[test]
    fn disabled_without_env() {
        // không đặt biến môi trường → tắt, không lỗi
        std::env::remove_var("FCM_SERVICE_ACCOUNT_FILE");
        assert!(Fcm::from_env().is_none());
    }
}
