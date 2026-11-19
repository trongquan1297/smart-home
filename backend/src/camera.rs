//! Camera Wi‑Fi qua addon camera (go2rtc + ONVIF, chạy trong nhà, kết nối như một gateway có khả năng "camera").
//! Backend chỉ điều phối: chuyển yêu cầu của app xuống addon (thêm camera, WebRTC, ảnh chụp, PTZ) và biến sự kiện chuyển động
//! thành cảnh báo. Mật khẩu camera đi qua RAM tới addon, không lưu ở đây.
use std::time::{Duration, Instant};

use axum::{
    extract::{Path, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    alerts,
    auth::AuthUser,
    error::{ApiError, ApiResult},
    push, AppState,
};

const MAX_CAMERAS: i64 = 32;
const COLS: &str = "id, home_id, gateway_id, room_id, name, host, manufacturer, model, has_ptz, has_events, motion_alerts, online, created_at";

#[derive(FromRow, Serialize)]
pub struct CameraOut {
    id: Uuid,
    home_id: Uuid,
    gateway_id: Uuid,
    room_id: Option<Uuid>,
    name: String,
    host: String,
    manufacturer: Option<String>,
    model: Option<String>,
    has_ptz: bool,
    has_events: bool,
    motion_alerts: bool,
    online: bool,
    created_at: chrono::DateTime<chrono::Utc>,
}

/// Gửi yêu cầu xuống addon và chờ trả lời; lỗi của addon thành lỗi API có mã ngắn để app hiển thị.
async fn ask(st: &AppState, gw: Uuid, msg: Value, wait: u64) -> ApiResult<Value> {
    let reply = st.hub.request_gateway(gw, msg, Duration::from_secs(wait)).await.map_err(|e| match e {
        crate::hub::RequestError::Offline => ApiError::Unavailable("camera addon offline".into()),
        crate::hub::RequestError::Timeout => ApiError::Unavailable("camera addon did not respond".into()),
    })?;
    match reply.get("error").and_then(Value::as_str) {
        None => Ok(reply),
        Some("unauthorized") => Err(ApiError::BadRequest("camera_unauthorized".into())),
        Some("unreachable") => Err(ApiError::BadRequest("camera_unreachable".into())),
        Some("onvif_error") => Err(ApiError::BadRequest("camera_onvif_error".into())),
        Some(e) => Err(ApiError::Unavailable(format!("camera: {e}"))),
    }
}

/// Camera + căn hộ của nó; kiểm tra quyền tối thiểu.
async fn camera_for(st: &AppState, uid: Uuid, id: Uuid, min: Role) -> ApiResult<(Uuid, Uuid)> {
    let row: Option<(Uuid, Uuid)> = sqlx::query_as("SELECT home_id, gateway_id FROM cameras WHERE id = $1").bind(id).fetch_optional(&st.db).await?;
    let (hid, gw) = row.ok_or(ApiError::NotFound)?;
    access::require(&st.db, uid, hid, min).await?;
    Ok((hid, gw))
}

/// Camera là thông tin riêng tư của gia đình: khách thuê và khách xem không thấy.
pub async fn list(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<CameraOut>>> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    Ok(Json(sqlx::query_as(&format!("SELECT {COLS} FROM cameras WHERE home_id = $1 ORDER BY created_at")).bind(hid).fetch_all(&st.db).await?))
}

/// Tìm camera ONVIF trong LAN của mọi addon camera đang online.
pub async fn scan(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Value>> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let gws = st.hub.camera_gateways_for_home(hid);
    if gws.is_empty() {
        return Err(ApiError::Unavailable("camera addon offline".into()));
    }
    let replies = futures::future::join_all(gws.iter().map(|gw| async { (*gw, st.hub.request_gateway(*gw, json!({"type": "cam_scan"}), Duration::from_secs(12)).await) })).await;
    let added: Vec<String> = sqlx::query_scalar("SELECT host FROM cameras WHERE home_id = $1").bind(hid).fetch_all(&st.db).await?;
    let mut found = Vec::new();
    for (gw, r) in replies {
        let Ok(reply) = r else { continue };
        for mut d in reply["devices"].as_array().cloned().unwrap_or_default().into_iter().take(64) {
            if d["host"].as_str().is_some_and(|h| h.parse::<std::net::IpAddr>().is_ok()) {
                d["gateway_id"] = json!(gw);
                d["added"] = json!(d["host"].as_str().is_some_and(|h| added.iter().any(|a| a == h)));
                found.push(d);
            }
        }
    }
    Ok(Json(json!({ "devices": found })))
}

#[derive(Deserialize)]
pub struct AddReq {
    name: String,
    room_id: Option<Uuid>,
    gateway_id: Option<Uuid>,
    /// ONVIF: địa chỉ IP/tên máy + cổng ONVIF (thường 80, 2020 với Tapo, 8000/8899 với một số hãng).
    host: Option<String>,
    port: Option<u16>,
    username: Option<String>,
    password: Option<String>,
    /// Camera không có ONVIF: nhập thẳng URL RTSP (không có PTZ/cảnh báo).
    rtsp_url: Option<String>,
}

fn clean_name(n: &str) -> ApiResult<String> {
    let n = n.trim();
    if n.is_empty() || n.chars().count() > 60 || n.chars().any(char::is_control) {
        return Err(ApiError::BadRequest("name must be 1..60 characters".into()));
    }
    Ok(n.to_string())
}

fn valid_host(h: &str) -> bool {
    !h.is_empty() && h.len() <= 253 && (h.parse::<std::net::IpAddr>().is_ok() || h.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-'))
}

async fn check_room(st: &AppState, hid: Uuid, room: Option<Uuid>) -> ApiResult<()> {
    if let Some(r) = room {
        let ok: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM rooms WHERE id = $1 AND home_id = $2)").bind(r).bind(hid).fetch_one(&st.db).await?;
        if !ok {
            return Err(ApiError::BadRequest("unknown room".into()));
        }
    }
    Ok(())
}

/// Thêm camera: addon thử kết nối thật (ONVIF/RTSP) rồi mới lưu. Mất ~vài giây.
pub async fn add(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<AddReq>) -> ApiResult<(StatusCode, Json<CameraOut>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = clean_name(&b.name)?;
    check_room(&st, hid, b.room_id).await?;
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM cameras WHERE home_id = $1").bind(hid).fetch_one(&st.db).await?;
    if n >= MAX_CAMERAS {
        return Err(ApiError::BadRequest("too many cameras".into()));
    }
    let online = st.hub.camera_gateways_for_home(hid);
    let gw = match b.gateway_id {
        Some(g) if online.contains(&g) => g,
        Some(_) => return Err(ApiError::Unavailable("camera addon offline".into())),
        None => *online.first().ok_or_else(|| ApiError::Unavailable("camera addon offline".into()))?,
    };
    let (user, pass) = (b.username.unwrap_or_default(), b.password.unwrap_or_default());
    if user.len() > 64 || pass.len() > 128 {
        return Err(ApiError::BadRequest("credentials too long".into()));
    }
    let rtsp = b.rtsp_url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty());
    let mut msg = json!({"type": "cam_add", "username": user, "password": pass});
    match &rtsp {
        Some(u) if (u.starts_with("rtsp://") || u.starts_with("rtsps://")) && u.len() <= 512 && !u.chars().any(char::is_whitespace) => msg["rtsp_url"] = json!(u),
        Some(_) => return Err(ApiError::BadRequest("rtsp_url must be rtsp://…".into())),
        None => {
            let host = b.host.as_deref().map(str::trim).filter(|h| valid_host(h)).ok_or_else(|| ApiError::BadRequest("invalid host".into()))?;
            msg["host"] = json!(host);
            msg["port"] = json!(b.port.filter(|p| *p > 0).unwrap_or(80));
        }
    }
    let id = Uuid::new_v4();
    msg["camera_id"] = json!(id.to_string());
    tracing::info!(home = %hid, user = %uid, camera = %id, "camera add requested");
    let reply = ask(&st, gw, msg, 30).await?;
    let info = &reply["info"];
    let s = |k: &str, max: usize| info.get(k).and_then(Value::as_str).map(|v| v.chars().take(max).collect::<String>());
    let host = s("host", 253).filter(|h| valid_host(h)).unwrap_or_else(|| "?".into());
    let row = sqlx::query_as(&format!(
        "INSERT INTO cameras (id, home_id, gateway_id, room_id, name, host, manufacturer, model, has_ptz, has_events, online)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,true) RETURNING {COLS}"
    ))
    .bind(id)
    .bind(hid)
    .bind(gw)
    .bind(b.room_id)
    .bind(name)
    .bind(host)
    .bind(s("manufacturer", 60))
    .bind(s("model", 60))
    .bind(info["ptz"].as_bool().unwrap_or(false))
    .bind(info["events"].as_bool().unwrap_or(false))
    .fetch_one(&st.db)
    .await?;
    st.hub.publish(hid, json!({"type": "cameras_changed"}).to_string());
    Ok((StatusCode::CREATED, Json(row)))
}

#[derive(Deserialize)]
pub struct UpdateReq {
    name: Option<String>,
    room_id: Option<Uuid>,
    #[serde(default)]
    clear_room: bool,
    motion_alerts: Option<bool>,
}

pub async fn update(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Json(b): Json<UpdateReq>) -> ApiResult<Json<CameraOut>> {
    let (hid, _) = camera_for(&st, uid, id, Role::Admin).await?;
    let name = b.name.as_deref().map(clean_name).transpose()?;
    check_room(&st, hid, b.room_id).await?;
    let row = sqlx::query_as(&format!(
        "UPDATE cameras SET name = COALESCE($2, name),
           room_id = CASE WHEN $4 THEN NULL ELSE COALESCE($3, room_id) END,
           motion_alerts = COALESCE($5, motion_alerts)
         WHERE id = $1 RETURNING {COLS}"
    ))
    .bind(id)
    .bind(name)
    .bind(b.room_id)
    .bind(b.clear_room)
    .bind(b.motion_alerts)
    .fetch_one(&st.db)
    .await?;
    st.hub.publish(hid, json!({"type": "cameras_changed"}).to_string());
    Ok(Json(row))
}

pub async fn remove(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>) -> ApiResult<StatusCode> {
    let (hid, gw) = camera_for(&st, uid, id, Role::Admin).await?;
    tracing::info!(home = %hid, user = %uid, camera = %id, "camera removed");
    // Báo addon xoá mật khẩu + luồng; addon offline thì vẫn xoá ở cloud (addon tự bỏ camera lạ khi đồng bộ lại).
    let _ = st.hub.send_gateway(gw, json!({"type": "cam_remove", "camera_id": id.to_string()}).to_string()).await;
    sqlx::query("DELETE FROM cameras WHERE id = $1").bind(id).execute(&st.db).await?;
    st.hub.publish(hid, json!({"type": "cameras_changed"}).to_string());
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct WebrtcReq {
    sdp: String,
}

/// Xem trực tiếp: chuyển SDP offer của app tới go2rtc qua addon, trả SDP answer. Hình đi thẳng điện thoại ↔ go2rtc.
pub async fn webrtc(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Json(b): Json<WebrtcReq>) -> ApiResult<Response> {
    let (_, gw) = camera_for(&st, uid, id, Role::Member).await?;
    if b.sdp.len() > 64 * 1024 || !b.sdp.starts_with("v=0") {
        return Err(ApiError::BadRequest("invalid sdp".into()));
    }
    let reply = ask(&st, gw, json!({"type": "cam_webrtc", "camera_id": id.to_string(), "sdp": b.sdp}), 20).await?;
    let sdp = reply["sdp"].as_str().filter(|s| s.starts_with("v=0") && s.len() <= 64 * 1024).ok_or_else(|| ApiError::Unavailable("camera: bad answer".into()))?;
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(json!({"type": "answer", "sdp": sdp}))).into_response())
}

#[derive(Deserialize)]
pub struct SnapQuery {
    w: Option<u32>,
}

/// Ảnh JPEG hiện tại (dự phòng khi WebRTC không nối được, và ảnh xem trước trong danh sách).
pub async fn snapshot(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Query(q): Query<SnapQuery>) -> ApiResult<Response> {
    let (_, gw) = camera_for(&st, uid, id, Role::Member).await?;
    let w = q.w.unwrap_or(640).clamp(160, 1280);
    let reply = ask(&st, gw, json!({"type": "cam_snapshot", "camera_id": id.to_string(), "width": w}), 15).await?;
    let jpeg = reply["jpeg"].as_str().and_then(|s| B64.decode(s).ok()).filter(|b| b.starts_with(&[0xFF, 0xD8])).ok_or_else(|| ApiError::Unavailable("camera: bad snapshot".into()))?;
    Ok(([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "no-store")], jpeg).into_response())
}

#[derive(Deserialize)]
pub struct PtzReq {
    #[serde(default)]
    pan: f32,
    #[serde(default)]
    tilt: f32,
    #[serde(default)]
    zoom: f32,
}

/// Quay/nghiêng/zoom liên tục theo vận tốc (-1..1); gửi toàn 0 để dừng. Không chờ camera trả lời.
pub async fn ptz(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Json(b): Json<PtzReq>) -> ApiResult<StatusCode> {
    let (_, gw) = camera_for(&st, uid, id, Role::Member).await?;
    let ok = |v: f32| v.is_finite() && (-1.0..=1.0).contains(&v);
    if !(ok(b.pan) && ok(b.tilt) && ok(b.zoom)) {
        return Err(ApiError::BadRequest("pan/tilt/zoom must be within -1..1".into()));
    }
    let has: bool = sqlx::query_scalar("SELECT has_ptz FROM cameras WHERE id = $1").bind(id).fetch_one(&st.db).await?;
    if !has {
        return Err(ApiError::BadRequest("camera has no PTZ".into()));
    }
    if !st.hub.send_gateway(gw, json!({"type": "cam_ptz", "camera_id": id.to_string(), "pan": b.pan, "tilt": b.tilt, "zoom": b.zoom}).to_string()).await {
        return Err(ApiError::Unavailable("camera addon offline".into()));
    }
    Ok(StatusCode::ACCEPTED)
}

// ───────────────────────── từ addon ─────────────────────────

/// Camera thuộc đúng addon đã gửi bản tin (addon khác không giả mạo được).
async fn owned(st: &AppState, gw: Uuid, camera: Uuid) -> ApiResult<Option<(Uuid, String, bool)>> {
    Ok(sqlx::query_as("SELECT home_id, name, motion_alerts FROM cameras WHERE id = $1 AND gateway_id = $2").bind(camera).bind(gw).fetch_optional(&st.db).await?)
}

pub async fn on_status(st: &AppState, gw: Uuid, camera: Uuid, online: bool) -> ApiResult<()> {
    if let Some((hid, _, _)) = owned(st, gw, camera).await? {
        sqlx::query("UPDATE cameras SET online = $2 WHERE id = $1").bind(camera).bind(online).execute(&st.db).await?;
        st.hub.publish(hid, json!({"type": "camera_online", "camera_id": camera, "online": online}).to_string());
    }
    Ok(())
}

/// Addon vừa kết nối báo danh sách camera nó đang giữ: camera của addon này mà không có trong danh sách (mất dữ liệu addon)
/// thì coi như offline.
pub async fn on_list(st: &AppState, gw: Uuid, home: Uuid, cams: &[(Uuid, bool)]) -> ApiResult<()> {
    let (ids, online): (Vec<Uuid>, Vec<bool>) = cams.iter().copied().unzip();
    sqlx::query(
        "UPDATE cameras SET online = COALESCE((SELECT x.online FROM unnest($2::uuid[], $3::bool[]) AS x(id, online) WHERE x.id = cameras.id), false)
          WHERE gateway_id = $1",
    )
    .bind(gw)
    .bind(&ids)
    .bind(&online)
    .execute(&st.db)
    .await?;
    st.hub.publish(home, json!({"type": "cameras_changed"}).to_string());
    Ok(())
}

/// Addon mất kết nối: mọi camera của nó offline.
pub async fn on_gateway_gone(st: &AppState, gw: Uuid, home: Uuid) {
    if let Ok(r) = sqlx::query("UPDATE cameras SET online = false WHERE gateway_id = $1 AND online").bind(gw).execute(&st.db).await {
        if r.rows_affected() > 0 {
            st.hub.publish(home, json!({"type": "cameras_changed"}).to_string());
        }
    }
}

/// Camera báo chuyển động → cảnh báo (lưu lịch sử, WebSocket, FCM), tối đa 1 lần/phút mỗi camera.
pub async fn on_motion(st: &AppState, gw: Uuid, camera: Uuid) -> ApiResult<()> {
    let Some((hid, name, enabled)) = owned(st, gw, camera).await? else { return Ok(()) };
    if !enabled {
        return Ok(());
    }
    let key = (camera, alerts::Event::Motion);
    if st.alert_seen.get(&key).is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
        return Ok(());
    }
    st.alert_seen.insert(key, Instant::now());
    let (title, body) = ("Camera phát hiện chuyển động".to_string(), name.clone());
    let (id, at): (i64, chrono::DateTime<chrono::Utc>) =
        sqlx::query_as("INSERT INTO notifications (home_id, camera_id, kind, title, body) VALUES ($1,$2,'camera_motion',$3,$4) RETURNING id, created_at")
            .bind(hid)
            .bind(camera)
            .bind(&title)
            .bind(&body)
            .fetch_one(&st.db)
            .await?;
    tracing::info!(home = %hid, %camera, "camera motion alert");
    st.hub.publish(hid, json!({"type": "alert", "id": id, "kind": "camera_motion", "title": title, "body": body, "camera_id": camera, "created_at": at}).to_string());
    let st2 = st.clone();
    tokio::spawn(async move {
        push::notify_home(&st2, hid, &title, &body, json!({"kind": "camera_motion", "home_id": hid, "camera_id": camera})).await;
    });
    Ok(())
}
