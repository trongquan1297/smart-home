//! Ngữ cảnh (scene): nhóm hành động bật/tắt thiết bị, chạy bằng tay hoặc tự kích hoạt vào khung giờ.
//!
//! - Admin tạo/sửa/xoá; thành viên (không phải khách) chạy được bằng tay.
//! - Tự kích hoạt: giờ cố định theo múi giờ căn hộ + các ngày trong tuần. Bộ chạy là vòng lặp nền trong backend
//!   (20 giây/lần). Mỗi lần chạy được "giành" bằng một câu UPDATE có điều kiện nên không chạy đôi (kể cả nhiều bản
//!   backend). Gateway offline lúc đến giờ: thử lại trong 5 phút, quá hạn thì ghi `missed` — không chạy bù muộn
//!   (bật đèn trễ nhiều giờ còn tệ hơn bỏ lỡ).
use std::collections::HashMap;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use chrono::{DateTime, Datelike, NaiveTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    alerts,
    auth::AuthUser,
    error::{ApiError, ApiResult},
    routes::validate_command,
    AppState,
};

const SCENE_ICONS: [&str; 10] = ["home", "bed", "sun", "moon", "away", "movie", "party", "work", "eco", "lock"];
const MAX_PER_HOME: i64 = 50;
const MAX_ACTIONS: usize = 50;
/// Quá hạn này kể từ giờ định thì không chạy nữa (ghi missed).
const GRACE_SECS: i64 = 300;
const DEFAULT_TZ: &str = "Asia/Ho_Chi_Minh";

fn name_of(s: &str) -> ApiResult<String> {
    let s = s.trim();
    if s.is_empty() || s.chars().count() > 60 {
        return Err(ApiError::BadRequest("name must be 1..60 chars".into()));
    }
    Ok(s.to_owned())
}

/// Chuẩn hoá và kiểm tra danh sách hành động: payload theo whitelist lệnh điều khiển, không cho TOGGLE
/// (lặp lại một lịch/ngữ cảnh phải cho cùng kết quả), thiết bị phải thuộc căn hộ.
async fn validate_actions(st: &AppState, hid: Uuid, v: &Value) -> ApiResult<Value> {
    let arr = v.as_array().filter(|a| !a.is_empty() && a.len() <= MAX_ACTIONS).ok_or_else(|| ApiError::BadRequest(format!("actions must be 1..{MAX_ACTIONS} items")))?;
    let mut out = Vec::with_capacity(arr.len());
    let mut ids = Vec::with_capacity(arr.len());
    for a in arr {
        let did = a.get("device_id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()).ok_or_else(|| ApiError::BadRequest("action.device_id must be a uuid".into()))?;
        let payload = a.get("payload").ok_or_else(|| ApiError::BadRequest("action.payload required".into()))?;
        validate_command(payload)?;
        if payload.as_object().is_some_and(|o| o.values().any(|x| x.as_str() == Some("TOGGLE"))) {
            return Err(ApiError::BadRequest("TOGGLE is not allowed in scenes/schedules; use ON or OFF".into()));
        }
        ids.push(did);
        out.push(json!({ "device_id": did, "payload": payload }));
    }
    let mut uniq = ids.clone();
    uniq.sort();
    uniq.dedup();
    let found: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE home_id = $1 AND id = ANY($2)")
        .bind(hid)
        .bind(&uniq)
        .fetch_one(&st.db)
        .await?;
    if found as usize != uniq.len() {
        return Err(ApiError::BadRequest("unknown device in actions".into()));
    }
    Ok(Value::Array(out))
}

#[derive(Default)]
pub(crate) struct RunOutcome {
    pub total: usize,
    pub sent: usize,
}

/// Gửi các hành động xuống gateway. Thiết bị đã xoá hoặc gateway offline tính là không gửi được.
pub(crate) async fn execute(st: &AppState, hid: Uuid, actions: &Value, user: Option<Uuid>) -> ApiResult<RunOutcome> {
    let arr = actions.as_array().cloned().unwrap_or_default();
    let ids: Vec<Uuid> = arr.iter().filter_map(|a| a.get("device_id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok())).collect();
    let rows: Vec<(Uuid, Uuid, String)> = sqlx::query_as("SELECT id, gateway_id, friendly_name FROM devices WHERE home_id = $1 AND id = ANY($2)")
        .bind(hid)
        .bind(&ids)
        .fetch_all(&st.db)
        .await?;
    let devs: HashMap<Uuid, (Uuid, String)> = rows.into_iter().map(|(id, gw, n)| (id, (gw, n))).collect();
    let mut out = RunOutcome { total: arr.len(), sent: 0 };
    for a in &arr {
        let Some(did) = a.get("device_id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok()) else { continue };
        let (Some((gw, fname)), Some(payload)) = (devs.get(&did), a.get("payload")) else { continue };
        // Dữ liệu lưu từ trước vẫn được kiểm tra lại trước khi chạm vào MQTT.
        if validate_command(payload).is_err() {
            continue;
        }
        let msg = json!({ "type": "set", "friendly_name": fname, "payload": payload }).to_string();
        if !st.hub.send_gateway(*gw, msg).await {
            continue;
        }
        out.sent += 1;
        sqlx::query("INSERT INTO command_log (device_id, home_id, user_id, payload) VALUES ($1,$2,$3,$4)")
            .bind(did)
            .bind(hid)
            .bind(user)
            .bind(payload)
            .execute(&st.db)
            .await?;
    }
    Ok(out)
}

fn status_of(o: &RunOutcome) -> &'static str {
    if o.sent == o.total && o.total > 0 {
        "ok"
    } else if o.sent > 0 {
        "partial"
    } else {
        "failed"
    }
}

// ───────────────────────── scenes ─────────────────────────

#[derive(FromRow, Serialize)]
pub struct SceneOut {
    id: Uuid,
    home_id: Uuid,
    name: String,
    icon: String,
    actions: Value,
    auto_enabled: bool,
    /// "HH:MM" theo múi giờ của căn hộ
    auto_time: Option<String>,
    /// ISO: 1 = thứ Hai … 7 = Chủ nhật
    auto_days: Vec<i16>,
    last_run_at: Option<DateTime<Utc>>,
    last_status: Option<String>,
    /// Cảm biến (hiện diện / cửa) được báo khi ngữ cảnh này đang bật.
    alert_devices: Vec<Uuid>,
    /// Tự chạy khi người cuối cùng rời nhà (cần căn hộ đã đặt vị trí).
    auto_leave: bool,
    /// Loa Cast đọc thông báo khi ngữ cảnh này TỰ chạy (rỗng = im lặng) và câu tuỳ chỉnh (null = câu tự sinh).
    speaker_ids: Vec<Uuid>,
    speak_text: Option<String>,
    /// Ngữ cảnh đang bật của căn hộ (chạy gần nhất); chỉ ngữ cảnh đang bật mới sinh cảnh báo.
    active: bool,
}

const SCENE_COLS: &str = "id, home_id, name, icon, actions, auto_enabled, to_char(auto_time, 'HH24:MI') AS auto_time, auto_days, last_run_at, last_status, alert_devices, auto_leave, speaker_ids, speak_text,
    EXISTS(SELECT 1 FROM homes h WHERE h.active_scene_id = scenes.id) AS active";

pub async fn list_scenes(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<SceneOut>>> {
    access::require(&st.db, uid, hid, Role::Guest).await?;
    Ok(Json(sqlx::query_as(&format!("SELECT {SCENE_COLS} FROM scenes WHERE home_id = $1 ORDER BY name")).bind(hid).fetch_all(&st.db).await?))
}

#[derive(Deserialize)]
pub struct SceneReq {
    name: Option<String>,
    icon: Option<String>,
    actions: Option<Value>,
    auto_enabled: Option<bool>,
    /// "HH:MM"
    auto_time: Option<String>,
    auto_days: Option<Vec<i16>>,
    /// Danh sách cảm biến hiện diện / cửa cần báo (thay thế toàn bộ danh sách cũ).
    alert_devices: Option<Vec<Uuid>>,
    /// Chạy khi người cuối cùng rời nhà; chỉ một ngữ cảnh mỗi căn hộ (bật cho ngữ cảnh này thì tắt ở ngữ cảnh khác).
    auto_leave: Option<bool>,
    /// Loa Cast sẽ đọc thông báo khi ngữ cảnh tự chạy (thay thế toàn bộ danh sách).
    speaker_ids: Option<Vec<Uuid>>,
    /// Câu đọc tuỳ chỉnh; chuỗi rỗng = quay về câu tự sinh.
    speak_text: Option<String>,
}

/// Mỗi cảm biến được chọn phải thuộc căn hộ và có thuộc tính `occupancy` hoặc `contact` (nhìn từ exposes).
async fn validate_alert_devices(st: &AppState, hid: Uuid, ids: &[Uuid]) -> ApiResult<Vec<Uuid>> {
    let mut v = ids.to_vec();
    v.sort();
    v.dedup();
    if v.len() > 20 {
        return Err(ApiError::BadRequest("at most 20 alert sensors per scene".into()));
    }
    let ok: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM devices WHERE home_id = $1 AND id = ANY($2)
            AND jsonb_path_exists(exposes, '$.** ? (@.property == \"occupancy\" || @.property == \"contact\")')",
    )
    .bind(hid)
    .bind(&v)
    .fetch_one(&st.db)
    .await?;
    if ok as usize != v.len() {
        return Err(ApiError::BadRequest("alert_devices must be presence or door sensors of this home".into()));
    }
    Ok(v)
}

/// Bật `auto_leave` cần căn hộ đã có vị trí; chỉ giữ một ngữ cảnh `auto_leave` mỗi căn hộ.
async fn claim_auto_leave(st: &AppState, hid: Uuid, keep: Option<Uuid>) -> ApiResult<()> {
    let has: bool = sqlx::query_scalar("SELECT geo_lat IS NOT NULL AND geo_lng IS NOT NULL FROM homes WHERE id = $1").bind(hid).fetch_one(&st.db).await?;
    if !has {
        return Err(ApiError::BadRequest("home location is not set".into()));
    }
    sqlx::query("UPDATE scenes SET auto_leave = false WHERE home_id = $1 AND auto_leave AND id IS DISTINCT FROM $2").bind(hid).bind(keep).execute(&st.db).await?;
    Ok(())
}

fn icon_of(i: &str) -> ApiResult<String> {
    SCENE_ICONS.contains(&i).then(|| i.to_owned()).ok_or_else(|| ApiError::BadRequest(format!("icon must be one of {SCENE_ICONS:?}")))
}

fn time_of(s: &str) -> ApiResult<NaiveTime> {
    NaiveTime::parse_from_str(s.trim(), "%H:%M").map_err(|_| ApiError::BadRequest("auto_time must be HH:MM (24h)".into()))
}

fn days_of(d: &[i16]) -> ApiResult<Vec<i16>> {
    let mut v = d.to_vec();
    v.sort_unstable();
    v.dedup();
    if v.is_empty() || v.iter().any(|x| !(1..=7).contains(x)) {
        return Err(ApiError::BadRequest("auto_days must be a non-empty list of 1..7 (1 = Monday)".into()));
    }
    Ok(v)
}

pub async fn create_scene(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<SceneReq>) -> ApiResult<(StatusCode, Json<SceneOut>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = name_of(b.name.as_deref().unwrap_or(""))?;
    let icon = icon_of(b.icon.as_deref().unwrap_or("home"))?;
    let actions = validate_actions(&st, hid, b.actions.as_ref().unwrap_or(&Value::Null)).await?;
    let time = b.auto_time.as_deref().map(time_of).transpose()?;
    let days = days_of(b.auto_days.as_deref().unwrap_or(&[1, 2, 3, 4, 5, 6, 7]))?;
    let enabled = b.auto_enabled.unwrap_or(false);
    if enabled && time.is_none() {
        return Err(ApiError::BadRequest("auto_time is required when auto_enabled".into()));
    }
    let alerts = validate_alert_devices(&st, hid, b.alert_devices.as_deref().unwrap_or(&[])).await?;
    let speakers = crate::speak::validate_speakers(&st, hid, b.speaker_ids.as_deref().unwrap_or(&[])).await?;
    let speak_text = crate::speak::clean_text(b.speak_text.as_deref())?.filter(|t| !t.is_empty());
    let leave = b.auto_leave.unwrap_or(false);
    if leave {
        claim_auto_leave(&st, hid, None).await?;
    }
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM scenes WHERE home_id = $1").bind(hid).fetch_one(&st.db).await?;
    if n >= MAX_PER_HOME {
        return Err(ApiError::BadRequest(format!("at most {MAX_PER_HOME} scenes per home")));
    }
    // last_run_at = now(): tạo lúc 10:02 cho khung 10:00 thì không chạy "bù" lần đã qua.
    let s = sqlx::query_as(&format!(
        "INSERT INTO scenes (home_id, name, icon, actions, auto_enabled, auto_time, auto_days, last_run_at, alert_devices, auto_leave, speaker_ids, speak_text)
         VALUES ($1,$2,$3,$4,$5,$6,$7, now(), $8, $9, $10, $11) RETURNING {SCENE_COLS}"
    ))
    .bind(hid)
    .bind(name)
    .bind(icon)
    .bind(actions)
    .bind(enabled)
    .bind(time)
    .bind(days)
    .bind(&alerts)
    .bind(leave)
    .bind(&speakers)
    .bind(speak_text)
    .fetch_one(&st.db)
    .await?;
    Ok((StatusCode::CREATED, Json(s)))
}

async fn scene_home(st: &AppState, sid: Uuid) -> ApiResult<Uuid> {
    sqlx::query_scalar("SELECT home_id FROM scenes WHERE id = $1").bind(sid).fetch_optional(&st.db).await?.ok_or(ApiError::NotFound)
}

pub async fn update_scene(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(sid): Path<Uuid>, Json(b): Json<SceneReq>) -> ApiResult<Json<SceneOut>> {
    let hid = scene_home(&st, sid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = b.name.as_deref().map(name_of).transpose()?;
    let icon = b.icon.as_deref().map(icon_of).transpose()?;
    let actions = match &b.actions {
        Some(a) => Some(validate_actions(&st, hid, a).await?),
        None => None,
    };
    let time = b.auto_time.as_deref().map(time_of).transpose()?;
    let days = b.auto_days.as_deref().map(days_of).transpose()?;
    let alerts = match &b.alert_devices {
        Some(ids) => Some(validate_alert_devices(&st, hid, ids).await?),
        None => None,
    };
    let speakers = match &b.speaker_ids {
        Some(ids) => Some(crate::speak::validate_speakers(&st, hid, ids).await?),
        None => None,
    };
    let speak_text = crate::speak::clean_text(b.speak_text.as_deref())?;
    if b.auto_leave == Some(true) {
        claim_auto_leave(&st, hid, Some(sid)).await?;
    }
    // Bật tự động thì phải có giờ (đã lưu từ trước hoặc gửi kèm).
    let (cur_enabled, cur_time): (bool, Option<NaiveTime>) = sqlx::query_as("SELECT auto_enabled, auto_time FROM scenes WHERE id = $1").bind(sid).fetch_one(&st.db).await?;
    if b.auto_enabled.unwrap_or(cur_enabled) && time.or(cur_time).is_none() {
        return Err(ApiError::BadRequest("auto_time is required when auto_enabled".into()));
    }
    // Đổi giờ/ngày/bật-tắt → tính lại từ bây giờ (không chạy bù lần đã qua trong ngày).
    let reschedule = time.is_some() || days.is_some() || b.auto_enabled.is_some();
    Ok(Json(
        sqlx::query_as(&format!(
            "UPDATE scenes SET name = COALESCE($2, name), icon = COALESCE($3, icon), actions = COALESCE($4, actions),
               auto_enabled = COALESCE($5, auto_enabled), auto_time = COALESCE($6, auto_time), auto_days = COALESCE($7, auto_days),
               last_run_at = CASE WHEN $8 THEN now() ELSE last_run_at END,
               last_status = CASE WHEN $8 THEN NULL ELSE last_status END,
               alert_devices = COALESCE($9, alert_devices),
               auto_leave = COALESCE($10, auto_leave),
               speaker_ids = COALESCE($11, speaker_ids),
               speak_text = CASE WHEN $12::text IS NULL THEN speak_text ELSE NULLIF($12, '') END
             WHERE id = $1 RETURNING {SCENE_COLS}"
        ))
        .bind(sid)
        .bind(name)
        .bind(icon)
        .bind(actions)
        .bind(b.auto_enabled)
        .bind(time)
        .bind(days)
        .bind(reschedule)
        .bind(alerts)
        .bind(b.auto_leave)
        .bind(speakers)
        .bind(speak_text)
        .fetch_one(&st.db)
        .await?,
    ))
}

pub async fn delete_scene(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(sid): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = scene_home(&st, sid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("DELETE FROM scenes WHERE id = $1").bind(sid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn run_scene(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(sid): Path<Uuid>) -> ApiResult<Json<Value>> {
    let hid = scene_home(&st, sid).await?;
    access::require(&st.db, uid, hid, Role::Member).await?;
    let actions: Value = sqlx::query_scalar("SELECT actions FROM scenes WHERE id = $1").bind(sid).fetch_one(&st.db).await?;
    let o = execute(&st, hid, &actions, Some(uid)).await?;
    if o.sent == 0 {
        return Err(ApiError::Unavailable("gateway offline or devices missing".into()));
    }
    activate_scene(&st, hid, sid).await;
    Ok(Json(json!({ "status": status_of(&o), "sent": o.sent, "total": o.total })))
}

/// Ngữ cảnh vừa chạy (bằng tay hoặc theo giờ) trở thành ngữ cảnh "đang bật" của căn hộ. Ngữ cảnh không có cảnh báo
/// cũng thay thế ngữ cảnh trước đó, nên chạy "Về nhà" là tắt cảnh báo của "Đi vắng".
async fn activate_scene(st: &AppState, hid: Uuid, sid: Uuid) {
    match sqlx::query("UPDATE homes SET active_scene_id = $2, active_since = now() WHERE id = $1").bind(hid).bind(sid).execute(&st.db).await {
        Ok(_) => st.hub.publish(hid, json!({"type": "scene_active", "scene_id": sid}).to_string()),
        Err(e) => tracing::warn!(%hid, "activate scene: {e}"),
    }
}

/// Không còn ai ở nhà: chạy ngữ cảnh `auto_leave` của căn hộ (nếu có). Gateway offline thì ngữ cảnh không chạy (ghi `failed`):
/// rời nhà là sự kiện một lần, không thử lại sau đó.
pub async fn run_auto_leave(st: &AppState, hid: Uuid) {
    let row: Option<(Uuid, Value)> = sqlx::query_as("SELECT id, actions FROM scenes WHERE home_id = $1 AND auto_leave").bind(hid).fetch_optional(&st.db).await.unwrap_or(None);
    let Some((sid, actions)) = row else { return };
    let _ = sqlx::query("UPDATE scenes SET last_run_at = now(), last_status = 'running' WHERE id = $1").bind(sid).execute(&st.db).await;
    let outcome = execute(st, hid, &actions, None).await.unwrap_or_default();
    let status = status_of(&outcome);
    tracing::info!(scene = %sid, sent = outcome.sent, total = outcome.total, status, "scene auto-ran on leave");
    if outcome.sent > 0 {
        activate_scene(st, hid, sid).await;
    }
    let _ = sqlx::query("UPDATE scenes SET last_status = $2 WHERE id = $1").bind(sid).bind(status).execute(&st.db).await;
    alerts::scene_auto_ran(st, hid, sid, alerts::AutoRun::Leave, outcome.sent > 0).await;
}

/// Tắt chế độ đang bật (ngừng mọi cảnh báo cảm biến theo ngữ cảnh). Thành viên trở lên.
pub async fn deactivate_scene(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    sqlx::query("UPDATE homes SET active_scene_id = NULL, active_since = NULL WHERE id = $1").bind(hid).execute(&st.db).await?;
    st.hub.publish(hid, json!({"type": "scene_active", "scene_id": null}).to_string());
    Ok(StatusCode::NO_CONTENT)
}

// ───────────────────────── bộ chạy tự động ─────────────────────────

/// Thời điểm (UTC) gần nhất ≤ `now` mà lịch được định chạy: hôm nay hoặc hôm qua (theo giờ địa phương của căn hộ),
/// và ngày đó nằm trong `days`. Giờ không tồn tại (nhảy giờ mùa hè) thì bỏ qua; giờ lặp lấy lần đầu.
pub fn due_instant(tz: &str, time: NaiveTime, days: &[i16], now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let tz: chrono_tz::Tz = tz.parse().unwrap_or_else(|_| DEFAULT_TZ.parse().expect("valid default tz"));
    let today = now.with_timezone(&tz).date_naive();
    for back in 0..2 {
        let date = today - chrono::Days::new(back);
        if !days.contains(&(date.weekday().number_from_monday() as i16)) {
            continue;
        }
        let Some(local) = tz.from_local_datetime(&date.and_time(time)).earliest() else { continue };
        let utc = local.with_timezone(&Utc);
        if utc <= now {
            return Some(utc);
        }
    }
    None
}

#[derive(FromRow)]
struct DueRow {
    id: Uuid,
    home_id: Uuid,
    time_of_day: NaiveTime,
    days: Vec<i16>,
    last_run_at: Option<DateTime<Utc>>,
    actions: Value,
    timezone: String,
}

pub async fn scheduler(st: AppState) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(20));
    loop {
        tick.tick().await;
        if let Err(e) = run_due(&st).await {
            tracing::warn!("scheduler: {e:?}");
        }
    }
}

async fn run_due(st: &AppState) -> ApiResult<()> {
    let rows: Vec<DueRow> = sqlx::query_as(
        "SELECT s.id, s.home_id, s.auto_time AS time_of_day, s.auto_days AS days, s.last_run_at, s.actions, h.timezone
           FROM scenes s JOIN homes h ON h.id = s.home_id
          WHERE s.auto_enabled AND s.auto_time IS NOT NULL",
    )
    .fetch_all(&st.db)
    .await?;
    let now = Utc::now();
    for r in rows {
        let Some(at) = due_instant(&r.timezone, r.time_of_day, &r.days, now) else { continue };
        if r.last_run_at.is_some_and(|t| t >= at) {
            continue; // lần định này đã xử lý
        }
        if (now - at).num_seconds() > GRACE_SECS {
            sqlx::query("UPDATE scenes SET last_run_at = $2, last_status = 'missed' WHERE id = $1 AND (last_run_at IS NULL OR last_run_at < $2)")
                .bind(r.id)
                .bind(at)
                .execute(&st.db)
                .await?;
            tracing::warn!(scene = %r.id, "scene auto-run missed (gateway offline or backend down at the scheduled time)");
            continue;
        }
        if st.hub.gateway_for_home(r.home_id).is_none() {
            continue; // thử lại ở lần tick sau cho tới hết thời gian chờ
        }
        let claimed = sqlx::query("UPDATE scenes SET last_run_at = now(), last_status = 'running' WHERE id = $1 AND (last_run_at IS NULL OR last_run_at < $2)")
            .bind(r.id)
            .bind(at)
            .execute(&st.db)
            .await?
            .rows_affected()
            == 1;
        if !claimed {
            continue;
        }
        let outcome = execute(st, r.home_id, &r.actions, None).await.unwrap_or_default();
        let status = status_of(&outcome);
        tracing::info!(scene = %r.id, sent = outcome.sent, total = outcome.total, status, "scene auto-ran");
        if outcome.sent > 0 {
            activate_scene(st, r.home_id, r.id).await;
            alerts::scene_auto_ran(st, r.home_id, r.id, alerts::AutoRun::Schedule(r.time_of_day.format("%H:%M").to_string()), true).await;
        }
        sqlx::query("UPDATE scenes SET last_status = $2 WHERE id = $1").bind(r.id).bind(status).execute(&st.db).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(h: u32, m: u32) -> NaiveTime {
        NaiveTime::from_hms_opt(h, m, 0).unwrap()
    }
    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }
    const ALL: [i16; 7] = [1, 2, 3, 4, 5, 6, 7];

    #[test]
    fn local_time_uses_home_timezone() {
        // 18:00 giờ Việt Nam (UTC+7) = 11:00 UTC. 2026-11-13 là thứ Sáu.
        let at = due_instant("Asia/Ho_Chi_Minh", t(18, 0), &ALL, utc("2026-11-13T11:00:30Z")).unwrap();
        assert_eq!(at, utc("2026-11-13T11:00:00Z"));
        // chưa tới giờ: trả về lần của hôm qua (đã qua) chứ không phải hôm nay
        let before = due_instant("Asia/Ho_Chi_Minh", t(18, 0), &ALL, utc("2026-11-13T10:59:00Z")).unwrap();
        assert_eq!(before, utc("2026-11-12T11:00:00Z"));
    }

    #[test]
    fn respects_days_of_week() {
        // Chỉ thứ Hai (1). 2026-11-13 là thứ Sáu → lần gần nhất là thứ Hai 2026-11-09 nhưng hàm chỉ nhìn 2 ngày → None.
        assert!(due_instant("Asia/Ho_Chi_Minh", t(18, 0), &[1], utc("2026-11-13T12:00:00Z")).is_none());
        // Chỉ thứ Sáu (5)
        assert!(due_instant("Asia/Ho_Chi_Minh", t(18, 0), &[5], utc("2026-11-13T12:00:00Z")).is_some());
    }

    #[test]
    fn crosses_midnight_in_local_time() {
        // Lịch 23:58, bây giờ 00:01 ngày hôm sau (giờ VN) = 17:01 UTC → phải tìm ra lần 23:58 của hôm qua
        let at = due_instant("Asia/Ho_Chi_Minh", t(23, 58), &ALL, utc("2026-11-13T17:01:00Z")).unwrap();
        assert_eq!(at, utc("2026-11-13T16:58:00Z"));
        // ... nhưng nếu hôm qua (thứ Sáu = 5) không nằm trong days (chỉ T7, CN) thì không chạy
        assert!(due_instant("Asia/Ho_Chi_Minh", t(23, 58), &[6, 7], utc("2026-11-13T17:01:00Z")).is_none());
    }

    #[test]
    fn dst_gap_is_skipped_and_bad_tz_falls_back() {
        // America/New_York nhảy giờ 2026-03-08: 02:30 không tồn tại
        assert!(due_instant("America/New_York", t(2, 30), &[7], utc("2026-03-08T12:00:00Z")).is_none());
        let at = due_instant("không-có-múi-giờ-này", t(18, 0), &ALL, utc("2026-11-13T11:00:30Z")).unwrap();
        assert_eq!(at, utc("2026-11-13T11:00:00Z"), "múi giờ sai → dùng Asia/Ho_Chi_Minh");
    }

    #[test]
    fn status_labels() {
        assert_eq!(status_of(&RunOutcome { total: 3, sent: 3 }), "ok");
        assert_eq!(status_of(&RunOutcome { total: 3, sent: 1 }), "partial");
        assert_eq!(status_of(&RunOutcome { total: 3, sent: 0 }), "failed");
        assert_eq!(status_of(&RunOutcome::default()), "failed");
    }

    #[test]
    fn input_validation() {
        assert!(time_of("07:30").is_ok() && time_of("7:05").is_ok());
        assert!(time_of("25:00").is_err() && time_of("abc").is_err());
        assert_eq!(days_of(&[3, 1, 3]).unwrap(), vec![1, 3]);
        assert!(days_of(&[]).is_err() && days_of(&[0]).is_err() && days_of(&[8]).is_err());
        assert!(icon_of("moon").is_ok() && icon_of("rocket").is_err());
    }
}
