//! Luật tự động theo gang của từng thiết bị: tự tắt sau khi bật, tự bật lại sau khi tắt, đồng kích hoạt theo thiết bị khác.
//! Chạy trong backend (cần backend + gateway online): mỗi bản tin trạng thái từ gateway được so với trạng thái cũ,
//! chuyển ON/OFF của một gang sẽ hẹn giờ (bảng `pending_actions`, sống sót qua khởi động lại) hoặc kích hoạt luật `link`.
use std::time::{Duration, Instant};

use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    auth::AuthUser,
    automation,
    error::{ApiError, ApiResult},
    AppState,
};

const MAX_PER_HOME: i64 = 300;
/// Lệnh do luật phát ra: bản tin trạng thái phản hồi trong khoảng này không kích hoạt luật `link` khác (không nối chuỗi, tránh vòng lặp).
const ECHO_WINDOW: Duration = Duration::from_secs(20);
/// Hẹn giờ quá hạn mà gateway vẫn offline thì bỏ.
const GRACE_SECS: i64 = 60;

#[derive(FromRow, Serialize)]
pub struct RuleOut {
    id: Uuid,
    home_id: Uuid,
    device_id: Uuid,
    key: String,
    kind: String,
    delay_s: Option<i32>,
    source_device_id: Option<Uuid>,
    source_key: Option<String>,
    source_state: Option<String>,
    target_state: Option<String>,
    enabled: bool,
    /// Loa Cast đọc thông báo khi luật này chạy (rỗng = im lặng) và câu tuỳ chỉnh (null = câu tự sinh).
    speaker_ids: Vec<Uuid>,
    speak_text: Option<String>,
}

const COLS: &str = "id, home_id, device_id, key, kind, delay_s, source_device_id, source_key, source_state, target_state, enabled, speaker_ids, speak_text";

#[derive(Deserialize)]
pub struct RuleReq {
    device_id: Option<Uuid>,
    key: Option<String>,
    kind: Option<String>,
    delay_s: Option<i32>,
    source_device_id: Option<Uuid>,
    source_key: Option<String>,
    source_state: Option<String>,
    target_state: Option<String>,
    enabled: Option<bool>,
    speaker_ids: Option<Vec<Uuid>>,
    speak_text: Option<String>,
}

/// `state` hoặc `state_<gang>` (cùng quy tắc với lệnh điều khiển).
fn key_ok(k: &str) -> bool {
    match k.strip_prefix("state") {
        Some("") => true,
        Some(r) => r.starts_with('_') && (2..=12).contains(&r.len()) && r[1..].chars().all(|c| c.is_ascii_alphanumeric()),
        None => false,
    }
}

fn onoff(s: &str) -> bool {
    matches!(s, "ON" | "OFF")
}

/// Gang phải tồn tại trong `exposes` của thiết bị thuộc căn hộ.
async fn has_key(st: &AppState, hid: Uuid, dev: Uuid, key: &str) -> ApiResult<bool> {
    Ok(sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE id = $1 AND home_id = $2 AND jsonb_path_exists(exposes, '$.** ? (@.property == $k)', jsonb_build_object('k', $3::text)))")
        .bind(dev)
        .bind(hid)
        .bind(key)
        .fetch_one(&st.db)
        .await?)
}

pub async fn list(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<RuleOut>>> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    Ok(Json(sqlx::query_as(&format!("SELECT {COLS} FROM device_rules WHERE home_id = $1 ORDER BY created_at")).bind(hid).fetch_all(&st.db).await?))
}

pub async fn create(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<RuleReq>) -> ApiResult<(StatusCode, Json<RuleOut>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let bad = |m: &str| ApiError::BadRequest(m.into());
    let dev = b.device_id.ok_or_else(|| bad("device_id required"))?;
    let key = b.key.as_deref().filter(|k| key_ok(k)).ok_or_else(|| bad("invalid key"))?;
    if !has_key(&st, hid, dev, key).await? {
        return Err(bad("device has no such switch"));
    }
    let kind = b.kind.as_deref().ok_or_else(|| bad("kind required"))?;
    let speakers = crate::speak::validate_speakers(&st, hid, b.speaker_ids.as_deref().unwrap_or(&[])).await?;
    let speak_text = crate::speak::clean_text(b.speak_text.as_deref())?.filter(|t| !t.is_empty());
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM device_rules WHERE home_id = $1").bind(hid).fetch_one(&st.db).await?;
    if n >= MAX_PER_HOME {
        return Err(bad("too many rules for this home"));
    }
    let row = match kind {
        "auto_off" | "auto_on" => {
            let d = b.delay_s.filter(|d| (1..=86400).contains(d)).ok_or_else(|| bad("delay_s must be 1..86400"))?;
            sqlx::query_as(&format!("INSERT INTO device_rules (home_id, device_id, key, kind, delay_s) VALUES ($1,$2,$3,$4,$5) RETURNING {COLS}"))
                .bind(hid)
                .bind(dev)
                .bind(key)
                .bind(kind)
                .bind(d)
                .fetch_one(&st.db)
                .await
                .map_err(|e| match e {
                    sqlx::Error::Database(ref d) if d.is_unique_violation() => ApiError::Conflict("this switch already has that rule".into()),
                    e => e.into(),
                })?
        }
        "link" => {
            let sd = b.source_device_id.ok_or_else(|| bad("source_device_id required"))?;
            let sk = b.source_key.as_deref().filter(|k| key_ok(k)).ok_or_else(|| bad("invalid source_key"))?;
            let ss = b.source_state.as_deref().filter(|s| onoff(s)).ok_or_else(|| bad("source_state must be ON|OFF"))?;
            let ts = b.target_state.as_deref().filter(|s| onoff(s)).ok_or_else(|| bad("target_state must be ON|OFF"))?;
            if sd == dev && sk == key {
                return Err(bad("a switch cannot trigger itself"));
            }
            if !has_key(&st, hid, sd, sk).await? {
                return Err(bad("source device has no such switch"));
            }
            sqlx::query_as(&format!("INSERT INTO device_rules (home_id, device_id, key, kind, source_device_id, source_key, source_state, target_state) VALUES ($1,$2,$3,'link',$4,$5,$6,$7) RETURNING {COLS}"))
                .bind(hid)
                .bind(dev)
                .bind(key)
                .bind(sd)
                .bind(sk)
                .bind(ss)
                .bind(ts)
                .fetch_one(&st.db)
                .await?
        }
        _ => return Err(bad("kind must be auto_off|auto_on|link")),
    };
    let row: RuleOut = if speakers.is_empty() && speak_text.is_none() {
        row
    } else {
        sqlx::query_as(&format!("UPDATE device_rules SET speaker_ids = $2, speak_text = $3 WHERE id = $1 RETURNING {COLS}")).bind(row.id).bind(&speakers).bind(&speak_text).fetch_one(&st.db).await?
    };
    Ok((StatusCode::CREATED, Json(row)))
}

async fn rule_home(st: &AppState, id: Uuid) -> ApiResult<Uuid> {
    sqlx::query_scalar("SELECT home_id FROM device_rules WHERE id = $1").bind(id).fetch_optional(&st.db).await?.ok_or(ApiError::NotFound)
}

pub async fn update(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Json(b): Json<RuleReq>) -> ApiResult<Json<RuleOut>> {
    let hid = rule_home(&st, id).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let bad = |m: &str| ApiError::BadRequest(m.into());
    if b.delay_s.is_some_and(|d| !(1..=86400).contains(&d)) {
        return Err(bad("delay_s must be 1..86400"));
    }
    if b.source_state.as_deref().is_some_and(|s| !onoff(s)) || b.target_state.as_deref().is_some_and(|s| !onoff(s)) {
        return Err(bad("state must be ON|OFF"));
    }
    let speakers = match &b.speaker_ids {
        Some(ids) => Some(crate::speak::validate_speakers(&st, hid, ids).await?),
        None => None,
    };
    let speak_text = crate::speak::clean_text(b.speak_text.as_deref())?;
    let row: RuleOut = sqlx::query_as(&format!(
        "UPDATE device_rules SET delay_s = CASE WHEN kind <> 'link' THEN COALESCE($2, delay_s) ELSE delay_s END,
           source_state = CASE WHEN kind = 'link' THEN COALESCE($3, source_state) ELSE source_state END,
           target_state = CASE WHEN kind = 'link' THEN COALESCE($4, target_state) ELSE target_state END,
           enabled = COALESCE($5, enabled),
           speaker_ids = COALESCE($6, speaker_ids),
           speak_text = CASE WHEN $7::text IS NULL THEN speak_text ELSE NULLIF($7, '') END
         WHERE id = $1 RETURNING {COLS}"
    ))
    .bind(id)
    .bind(b.delay_s)
    .bind(&b.source_state)
    .bind(&b.target_state)
    .bind(b.enabled)
    .bind(speakers)
    .bind(speak_text)
    .fetch_one(&st.db)
    .await?;
    // Đổi cấu hình thì bỏ hẹn giờ đang chờ (tính lại từ lần chuyển trạng thái kế tiếp).
    sqlx::query("DELETE FROM pending_actions WHERE rule_id = $1").bind(id).execute(&st.db).await?;
    Ok(Json(row))
}

pub async fn delete(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = rule_home(&st, id).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("DELETE FROM device_rules WHERE id = $1").bind(id).execute(&st.db).await?; // pending_actions xoá theo (CASCADE)
    Ok(StatusCode::NO_CONTENT)
}

// ───────────────────────── bộ chạy ─────────────────────────

/// Các gang vừa đổi ON↔OFF (bỏ qua lần báo đầu tiên chưa có trạng thái cũ và các giá trị khác ON/OFF).
pub fn transitions(old: &Value, new: &Value) -> Vec<(String, &'static str)> {
    let (Some(o), Some(n)) = (old.as_object(), new.as_object()) else { return vec![] };
    n.iter()
        .filter(|(k, _)| key_ok(k))
        .filter_map(|(k, v)| {
            let nv = match v.as_str()? {
                "ON" => "ON",
                "OFF" => "OFF",
                _ => return None,
            };
            let ov = o.get(k)?.as_str()?;
            (ov != nv && matches!(ov, "ON" | "OFF")).then(|| (k.clone(), nv))
        })
        .collect()
}

/// Gọi sau mỗi bản tin trạng thái. Lỗi chỉ ghi log.
pub async fn on_state(st: &AppState, home: Uuid, device: Uuid, old: &Value, new: &Value) {
    for (key, state) in transitions(old, new) {
        if let Err(e) = handle(st, home, device, &key, state).await {
            tracing::warn!(%home, %device, key, "device rules: {e:?}");
        }
    }
}

async fn handle(st: &AppState, home: Uuid, device: Uuid, key: &str, state: &'static str) -> ApiResult<()> {
    // Hẹn giờ: BẬT → hẹn tự TẮT (và huỷ hẹn tự bật); TẮT → hẹn tự BẬT (và huỷ hẹn tự tắt).
    let (arm_kind, arm_to, cancel_kind) = if state == "ON" { ("auto_off", "OFF", "auto_on") } else { ("auto_on", "ON", "auto_off") };
    sqlx::query("DELETE FROM pending_actions WHERE rule_id IN (SELECT id FROM device_rules WHERE device_id = $1 AND key = $2 AND kind = $3)")
        .bind(device)
        .bind(key)
        .bind(cancel_kind)
        .execute(&st.db)
        .await?;
    sqlx::query(
        "INSERT INTO pending_actions (rule_id, home_id, device_id, key, state, due_at)
         SELECT id, home_id, device_id, key, $4, now() + make_interval(secs => delay_s) FROM device_rules
          WHERE device_id = $1 AND key = $2 AND kind = $3 AND enabled
         ON CONFLICT (rule_id) DO UPDATE SET due_at = EXCLUDED.due_at, state = EXCLUDED.state",
    )
    .bind(device)
    .bind(key)
    .bind(arm_kind)
    .bind(arm_to)
    .execute(&st.db)
    .await?;

    // Đồng kích hoạt: bỏ qua nếu bản tin này chỉ là phản hồi của lệnh do một luật vừa phát (không nối chuỗi).
    let ck = (device, key.to_string());
    let echo = st.rule_cmds.get(&ck).is_some_and(|e| e.0 == state && e.1.elapsed() < ECHO_WINDOW);
    if echo {
        st.rule_cmds.remove(&ck);
        return Ok(());
    }
    let links: Vec<(Uuid, String, String, Vec<Uuid>, Option<String>)> = sqlx::query_as(
        "SELECT device_id, key, target_state, speaker_ids, speak_text FROM device_rules
          WHERE kind = 'link' AND enabled AND home_id = $1 AND source_device_id = $2 AND source_key = $3 AND source_state = $4",
    )
    .bind(home)
    .bind(device)
    .bind(key)
    .bind(state)
    .fetch_all(&st.db)
    .await?;
    for (target, tkey, tstate, speakers, custom) in links {
        if send(st, home, target, &tkey, &tstate).await == Sent::Yes && !speakers.is_empty() {
            let text = match custom.filter(|t| !t.trim().is_empty()) {
                Some(t) => t,
                None => format!("{} đã {} theo {}", gang_name(st, target, &tkey).await, if tstate == "ON" { "bật" } else { "tắt" }, gang_name(st, device, key).await),
            };
            let _ = crate::speak::say(st, home, &speakers, &text).await;
        }
    }
    Ok(())
}

#[derive(PartialEq, Eq)]
enum Sent {
    /// Đã gửi lệnh xuống gateway.
    Yes,
    /// Gang đã ở trạng thái đích, không cần gửi (và không đọc loa).
    Already,
    No,
}

/// Tên đọc ra loa: tên thiết bị, kèm tên gang nếu người dùng đã đặt.
async fn gang_name(st: &AppState, device: Uuid, key: &str) -> String {
    let r: Option<(String, Option<String>)> = sqlx::query_as("SELECT name, channels->$2->>'name' FROM devices WHERE id = $1").bind(device).bind(key).fetch_optional(&st.db).await.unwrap_or(None);
    match r {
        Some((n, Some(g))) if !g.trim().is_empty() => format!("{n} {}", g.trim()),
        Some((n, _)) => n,
        None => "thiết bị".into(),
    }
}

/// Gửi một lệnh ON/OFF cho một gang. Bỏ qua nếu gang đã ở trạng thái đó.
async fn send(st: &AppState, home: Uuid, device: Uuid, key: &str, state: &str) -> Sent {
    let cur: Option<String> = sqlx::query_scalar("SELECT state->>$2 FROM devices WHERE id = $1").bind(device).bind(key).fetch_optional(&st.db).await.unwrap_or(None).flatten();
    if cur.as_deref() == Some(state) {
        return Sent::Already;
    }
    let actions = json!([{ "device_id": device, "payload": { key: state } }]);
    let ok = automation::execute(st, home, &actions, None).await.map(|o| o.sent > 0).unwrap_or(false);
    if ok {
        st.rule_cmds.insert((device, key.to_string()), (state.to_string(), Instant::now()));
    }
    if ok { Sent::Yes } else { Sent::No }
}

/// Vòng lặp 1 giây: chạy các hẹn giờ đã đến hạn.
pub async fn runner(st: AppState) {
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tick.tick().await;
        if let Err(e) = run_due(&st).await {
            tracing::warn!("device rules runner: {e:?}");
        }
    }
}

async fn run_due(st: &AppState) -> ApiResult<()> {
    let rows: Vec<(Uuid, Uuid, Uuid, String, String, i64, String, Vec<Uuid>, Option<String>)> = sqlx::query_as(
        "SELECT p.rule_id, p.home_id, p.device_id, p.key, p.state, EXTRACT(EPOCH FROM now() - p.due_at)::bigint, r.kind, r.speaker_ids, r.speak_text
           FROM pending_actions p JOIN device_rules r ON r.id = p.rule_id WHERE p.due_at <= now() ORDER BY p.due_at LIMIT 50",
    )
    .fetch_all(&st.db)
    .await?;
    for (rule, home, device, key, state, late, kind, speakers, custom) in rows {
        let res = send(st, home, device, &key, &state).await;
        let sent = res != Sent::No;
        if res == Sent::Yes && !speakers.is_empty() {
            let text = match custom.filter(|t| !t.trim().is_empty()) {
                Some(t) => t,
                None if kind == "auto_on" => format!("Đã tự động bật lại {}", gang_name(st, device, &key).await),
                None => format!("Đã tự động tắt {}", gang_name(st, device, &key).await),
            };
            let _ = crate::speak::say(st, home, &speakers, &text).await;
        }
        if sent || late > GRACE_SECS {
            sqlx::query("DELETE FROM pending_actions WHERE rule_id = $1").bind(rule).execute(&st.db).await?;
            if !sent {
                tracing::warn!(%device, key, "device rule dropped (gateway offline for >{GRACE_SECS}s)");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys() {
        assert!(key_ok("state") && key_ok("state_1") && key_ok("state_l2"));
        assert!(!key_ok("brightness") && !key_ok("state1") && !key_ok("state_"));
    }

    #[test]
    fn detects_only_real_on_off_changes() {
        let t = transitions(&json!({"state_1":"OFF","state_2":"ON"}), &json!({"state_1":"ON","state_2":"ON","state_3":"ON","brightness":5}));
        assert_eq!(t, vec![("state_1".to_string(), "ON")]); // state_3 chưa có trạng thái cũ → không tính
        assert!(transitions(&json!({}), &json!({"state":"ON"})).is_empty());
        assert!(transitions(&json!({"state":"ON"}), &json!({"state":"ON"})).is_empty());
        assert_eq!(transitions(&json!({"state":"ON"}), &json!({"state":"OFF"})), vec![("state".to_string(), "OFF")]);
        assert!(transitions(&json!({"state":"OPEN"}), &json!({"state":"CLOSE"})).is_empty(), "rèm không thuộc luật ON/OFF");
    }
}
