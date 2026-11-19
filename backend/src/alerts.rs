//! Cảnh báo cảm biến theo ngữ cảnh: khi một ngữ cảnh đang bật có chọn cảm biến hiện diện / cửa, mỗi lần cảm biến đó
//! được kích hoạt thì lưu thông báo, đẩy realtime tới app đang mở (WebSocket) và gửi thông báo đẩy (FCM, nếu đã cấu hình).
use std::time::{Duration, Instant};

use axum::{extract::{Path, State}, http::StatusCode, Json};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    auth::AuthUser,
    error::{ApiError, ApiResult},
    push, AppState,
};

/// Cùng một cảm biến + cùng loại sự kiện chỉ báo tối đa một lần mỗi khoảng này (cảm biến hiện diện nhấp nháy liên tục).
const COOLDOWN: Duration = Duration::from_secs(60);
const KEEP_DAYS: i32 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Event {
    Presence,
    DoorOpen,
    /// Camera báo chuyển động (khoá theo id camera).
    Motion,
}

impl Event {
    pub fn kind(self) -> &'static str {
        match self {
            Event::Presence => "presence",
            Event::DoorOpen => "door_open",
            Event::Motion => "camera_motion",
        }
    }
}

/// So trạng thái cũ và mới của một cảm biến. Chỉ tính là sự kiện khi **thật sự chuyển trạng thái** và trạng thái cũ đã biết:
/// gateway phát lại toàn bộ trạng thái mỗi lần kết nối lại, và thiết bị mới ghép chưa có trạng thái cũ — cả hai không được báo.
/// Quy ước Zigbee2MQTT: `occupancy = true` là có người; `contact = true` là cửa đóng, `false` là cửa mở.
pub fn detect(old: &Value, new: &Value) -> Option<Event> {
    let b = |v: &Value, k: &str| v.get(k).and_then(Value::as_bool);
    if b(new, "occupancy") == Some(true) && b(old, "occupancy") == Some(false) {
        return Some(Event::Presence);
    }
    if b(new, "contact") == Some(false) && b(old, "contact") == Some(true) {
        return Some(Event::DoorOpen);
    }
    None
}

pub fn texts(ev: Event, device: &str, scene: &str) -> (String, String) {
    match ev {
        Event::Presence => ("Phát hiện có người".into(), format!("{device} vừa phát hiện chuyển động · chế độ \"{scene}\"")),
        Event::DoorOpen => ("Cửa vừa mở".into(), format!("{device} vừa mở · chế độ \"{scene}\"")),
        Event::Motion => ("Camera phát hiện chuyển động".into(), device.to_string()),
    }
}

/// Gọi mỗi khi một thiết bị báo trạng thái mới. Lỗi chỉ được ghi log, không làm hỏng luồng đồng bộ trạng thái.
pub async fn on_state(st: &AppState, home: Uuid, device: Uuid, old: &Value, new: &Value) {
    let Some(ev) = detect(old, new) else { return };
    if let Err(e) = raise(st, home, device, ev).await {
        tracing::warn!(%home, %device, "alert failed: {e:?}");
    }
}

async fn raise(st: &AppState, home: Uuid, device: Uuid, ev: Event) -> ApiResult<()> {
    // Chỉ khi ngữ cảnh ĐANG BẬT của căn hộ có chọn cảm biến này.
    let row: Option<(Uuid, String, String)> = sqlx::query_as(
        "SELECT s.id, s.name, d.name FROM homes h
           JOIN scenes s ON s.id = h.active_scene_id
           JOIN devices d ON d.id = $2 AND d.home_id = h.id
          WHERE h.id = $1 AND $2 = ANY(s.alert_devices)",
    )
    .bind(home)
    .bind(device)
    .fetch_optional(&st.db)
    .await?;
    let Some((scene_id, scene_name, device_name)) = row else { return Ok(()) };

    let key = (device, ev);
    if st.alert_seen.get(&key).is_some_and(|t| t.elapsed() < COOLDOWN) {
        return Ok(());
    }
    st.alert_seen.insert(key, Instant::now());

    let (title, body) = texts(ev, &device_name, &scene_name);
    let (id, at): (i64, DateTime<Utc>) = sqlx::query_as(
        "INSERT INTO notifications (home_id, scene_id, device_id, kind, title, body) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id, created_at",
    )
    .bind(home)
    .bind(scene_id)
    .bind(device)
    .bind(ev.kind())
    .bind(&title)
    .bind(&body)
    .fetch_one(&st.db)
    .await?;
    tracing::info!(%home, %device, kind = ev.kind(), "sensor alert raised");

    // App đang mở nhận qua WebSocket (client_ws chỉ chuyển tiếp cho vai trò từ Member trở lên).
    st.hub.publish(
        home,
        json!({"type": "alert", "id": id, "kind": ev.kind(), "title": title, "body": body, "device_id": device, "scene_id": scene_id, "created_at": at}).to_string(),
    );
    // Thông báo đẩy tới mọi thiết bị đã đăng ký của thành viên (chạy nền, không chặn luồng trạng thái).
    let st2 = st.clone();
    tokio::spawn(async move {
        push::notify_home(&st2, home, &title, &body, json!({"kind": ev.kind(), "home_id": home, "device_id": device, "scene_id": scene_id})).await;
    });
    Ok(())
}

/// Vì sao một ngữ cảnh tự chạy (không do người dùng bấm).
pub enum AutoRun {
    /// Đến giờ đã hẹn ("HH:MM" giờ địa phương của căn hộ).
    Schedule(String),
    /// Người cuối cùng đã rời nhà.
    Leave,
}

/// Báo cho thành viên rằng một ngữ cảnh vừa tự chạy (theo giờ hoặc khi rời nhà): lưu lịch sử, đẩy WebSocket và FCM.
/// `ok = false` (gateway offline, không gửi được lệnh nào) chỉ báo cho trường hợp rời nhà vì đó là sự kiện một lần, không thử lại;
/// lịch theo giờ tự thử lại trong 5 phút nên không báo thất bại. Lỗi ở đây chỉ ghi log, không ảnh hưởng việc chạy ngữ cảnh.
pub async fn scene_auto_ran(st: &AppState, home: Uuid, scene: Uuid, why: AutoRun, ok: bool) {
    if !ok && !matches!(why, AutoRun::Leave) {
        return;
    }
    let name: Option<String> = sqlx::query_scalar("SELECT name FROM scenes WHERE id = $1").bind(scene).fetch_optional(&st.db).await.unwrap_or(None);
    let Some(name) = name else { return };
    let (kind, title, body) = match (&why, ok) {
        (AutoRun::Schedule(t), _) => ("scene_auto", format!("Đã tự chuyển sang \"{name}\""), format!("Theo lịch {t}")),
        (AutoRun::Leave, true) => ("scene_auto", format!("Đã tự chuyển sang \"{name}\""), "Không còn ai ở nhà".to_string()),
        (AutoRun::Leave, false) => ("scene_failed", format!("Không chuyển được sang \"{name}\""), "Mọi người đã rời nhà nhưng bộ điều khiển trung tâm đang offline".to_string()),
    };
    let ins: Result<(i64, DateTime<Utc>), _> = sqlx::query_as(
        "INSERT INTO notifications (home_id, scene_id, kind, title, body) VALUES ($1,$2,$3,$4,$5) RETURNING id, created_at",
    )
    .bind(home)
    .bind(scene)
    .bind(kind)
    .bind(&title)
    .bind(&body)
    .fetch_one(&st.db)
    .await;
    let (id, at) = match ins {
        Ok(r) => r,
        Err(e) => return tracing::warn!(%home, "scene auto notification: {e}"),
    };
    st.hub.publish(home, json!({"type": "alert", "id": id, "kind": kind, "title": title, "body": body, "scene_id": scene, "created_at": at}).to_string());
    // Loa Cast (nếu ngữ cảnh có chọn loa): chỉ đọc khi chạy thành công.
    if ok {
        let sp: Option<(Vec<Uuid>, Option<String>)> = sqlx::query_as("SELECT speaker_ids, speak_text FROM scenes WHERE id = $1").bind(scene).fetch_optional(&st.db).await.unwrap_or(None);
        if let Some((ids, custom)) = sp.filter(|(ids, _)| !ids.is_empty()) {
            let text = custom.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| match &why {
                AutoRun::Schedule(_) => format!("Đã chuyển sang chế độ {name}"),
                AutoRun::Leave => format!("Mọi người đã rời nhà. Đã chuyển sang chế độ {name}"),
            });
            let _ = crate::speak::say(st, home, &ids, &text).await;
        }
    }
    let st2 = st.clone();
    tokio::spawn(async move {
        push::notify_home(&st2, home, &title, &body, json!({"kind": kind, "home_id": home, "scene_id": scene})).await;
    });
}

/// Xoá thông báo cũ (gọi định kỳ).
pub async fn purge_old(st: &AppState) {
    if let Err(e) = sqlx::query("DELETE FROM notifications WHERE created_at < now() - make_interval(days => $1)").bind(KEEP_DAYS).execute(&st.db).await {
        tracing::warn!("purge notifications: {e}");
    }
}

// ───────────────────────── API ─────────────────────────

#[derive(Serialize, FromRow)]
pub struct NotificationOut {
    id: i64,
    kind: String,
    title: String,
    body: String,
    device_id: Option<Uuid>,
    scene_id: Option<Uuid>,
    camera_id: Option<Uuid>,
    created_at: DateTime<Utc>,
}

/// Lịch sử thông báo của căn hộ (50 gần nhất). Khách thuê và khách xem không được xem.
pub async fn list_notifications(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<NotificationOut>>> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    Ok(Json(
        sqlx::query_as("SELECT id, kind, title, body, device_id, scene_id, camera_id, created_at FROM notifications WHERE home_id = $1 ORDER BY created_at DESC LIMIT 50")
            .bind(hid)
            .fetch_all(&st.db)
            .await?,
    ))
}

#[derive(Deserialize)]
pub struct TokenReq {
    token: String,
    platform: Option<String>,
}

/// Đăng ký token đẩy của thiết bị cho người dùng hiện tại. Cùng một token chuyển sang người đăng nhập sau
/// (người dùng trước trên cùng máy không còn nhận thông báo).
pub async fn register_token(State(st): State<AppState>, AuthUser(uid): AuthUser, Json(b): Json<TokenReq>) -> ApiResult<StatusCode> {
    let platform = b.platform.as_deref().filter(|p| matches!(*p, "ios" | "android")).ok_or_else(|| ApiError::BadRequest("platform must be ios|android".into()))?;
    let token = b.token.trim();
    if !(20..=4096).contains(&token.len()) || token.chars().any(char::is_whitespace) {
        return Err(ApiError::BadRequest("invalid token".into()));
    }
    sqlx::query(
        "INSERT INTO push_tokens (user_id, platform, token) VALUES ($1,$2,$3)
         ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, last_seen_at = now()",
    )
    .bind(uid)
    .bind(platform)
    .bind(token)
    .execute(&st.db)
    .await?;
    // Giữ tối đa 20 thiết bị mỗi người (token cũ nhất bị bỏ).
    sqlx::query("DELETE FROM push_tokens WHERE user_id = $1 AND id NOT IN (SELECT id FROM push_tokens WHERE user_id = $1 ORDER BY last_seen_at DESC LIMIT 20)")
        .bind(uid)
        .execute(&st.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn delete_token(State(st): State<AppState>, AuthUser(uid): AuthUser, Json(b): Json<TokenReq>) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM push_tokens WHERE user_id = $1 AND token = $2").bind(uid).bind(b.token.trim()).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_only_real_transitions() {
        // có người: false → true
        assert_eq!(detect(&json!({"occupancy": false}), &json!({"occupancy": true})), Some(Event::Presence));
        // đã có người rồi (cập nhật lặp / phát lại) → không báo
        assert_eq!(detect(&json!({"occupancy": true}), &json!({"occupancy": true})), None);
        // hết người → không báo
        assert_eq!(detect(&json!({"occupancy": true}), &json!({"occupancy": false})), None);
        // cửa: true = đóng; đóng → mở là sự kiện
        assert_eq!(detect(&json!({"contact": true}), &json!({"contact": false})), Some(Event::DoorOpen));
        // mở → đóng, hoặc lặp lại trạng thái mở → không báo
        assert_eq!(detect(&json!({"contact": false}), &json!({"contact": true})), None);
        assert_eq!(detect(&json!({"contact": false}), &json!({"contact": false})), None);
    }

    #[test]
    fn unknown_previous_state_never_alerts() {
        // thiết bị mới ghép / lần báo đầu tiên: không có trạng thái cũ → không báo (tránh báo oan khi phát lại)
        assert_eq!(detect(&json!({}), &json!({"occupancy": true})), None);
        assert_eq!(detect(&json!({}), &json!({"contact": false})), None);
        assert_eq!(detect(&json!({"battery": 90}), &json!({"contact": false, "battery": 90})), None);
        // trạng thái không phải bool (dữ liệu lạ) → bỏ qua
        assert_eq!(detect(&json!({"contact": "true"}), &json!({"contact": false})), None);
    }

    #[test]
    fn texts_name_device_and_scene() {
        let (t, b) = texts(Event::DoorOpen, "Cửa chính", "Đi vắng");
        assert_eq!(t, "Cửa vừa mở");
        assert!(b.contains("Cửa chính") && b.contains("Đi vắng"));
        let (t, _) = texts(Event::Presence, "Hành lang", "Đi ngủ");
        assert_eq!(t, "Phát hiện có người");
    }
}
