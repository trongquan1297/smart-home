//! Thông báo giọng nói qua loa Google Cast (Google Home / Nest Mini…).
//! Backend chỉ quyết định "nói gì, loa nào": gateway (Pi, cùng mạng LAN với loa) tìm loa bằng mDNS, tạo âm thanh TTS tiếng Việt
//! và cast tới loa. Backend (ở datacenter) không với tới được loa trong LAN nên không tự cast.
use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    auth::AuthUser,
    error::{ApiError, ApiResult},
    AppState,
};

pub const TEST_TEXT: &str = "Xin chào, đây là loa thử nghiệm của MSmart";
/// Google Translate TTS nhận tối đa ~200 ký tự mỗi lần; giữ câu ngắn cho dễ nghe.
pub const MAX_TEXT: usize = 140;
const MAX_SPEAKERS: i64 = 20;

#[derive(FromRow, Serialize)]
pub struct SpeakerOut {
    id: Uuid,
    home_id: Uuid,
    name: String,
    cast_id: String,
    host: Option<String>,
    port: i32,
}

/// Câu tuỳ chỉnh: bỏ khoảng trắng hai đầu, tối đa `MAX_TEXT` ký tự. Chuỗi rỗng = xoá (dùng câu tự sinh).
pub fn clean_text(t: Option<&str>) -> ApiResult<Option<String>> {
    let Some(t) = t else { return Ok(None) };
    let t = t.trim();
    if t.chars().count() > MAX_TEXT || t.chars().any(char::is_control) {
        return Err(ApiError::BadRequest(format!("speak_text must be at most {MAX_TEXT} characters")));
    }
    Ok(Some(t.to_string()))
}

/// Mỗi loa phải thuộc căn hộ; tối đa 10 loa cho một hành động.
pub async fn validate_speakers(st: &AppState, hid: Uuid, ids: &[Uuid]) -> ApiResult<Vec<Uuid>> {
    let mut v = ids.to_vec();
    v.sort();
    v.dedup();
    if v.len() > 10 {
        return Err(ApiError::BadRequest("at most 10 speakers per action".into()));
    }
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM speakers WHERE home_id = $1 AND id = ANY($2)").bind(hid).bind(&v).fetch_one(&st.db).await?;
    if n as usize != v.len() {
        return Err(ApiError::BadRequest("unknown speaker".into()));
    }
    Ok(v)
}

/// Gửi câu nói xuống gateway đã tìm thấy từng loa (gateway cùng LAN với loa). Không chờ kết quả phát; trả false nếu không gateway nào nhận được.
pub async fn say(st: &AppState, home: Uuid, ids: &[Uuid], text: &str) -> bool {
    if ids.is_empty() || text.trim().is_empty() {
        return false;
    }
    let rows: Vec<(String, String, Option<String>, i32, Option<Uuid>)> =
        match sqlx::query_as("SELECT name, cast_id, host, port, gateway_id FROM speakers WHERE home_id = $1 AND id = ANY($2)").bind(home).bind(ids).fetch_all(&st.db).await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(%home, "speak: {e}");
                return false;
            }
        };
    // Gom theo gateway; loa chưa có gateway (thêm từ bản cũ) dùng gateway cast bất kỳ của căn hộ.
    let fallback = st.hub.cast_gateways_for_home(home).into_iter().next();
    let mut by_gw: std::collections::HashMap<Uuid, Vec<Value>> = Default::default();
    for (name, cast_id, host, port, gw) in rows {
        // Loa đã gắn gateway thì chỉ phát qua gateway đó (gateway khác không thấy loa trong LAN); chỉ loa cũ chưa gắn mới dùng gateway cast bất kỳ.
        let target = match gw {
            Some(g) => st.hub.gateway_connected_for(home, g).then_some(g),
            None => fallback,
        };
        let Some(gw) = target else {
            tracing::warn!(%home, speaker = name, "speak skipped: its gateway is offline");
            continue;
        };
        by_gw.entry(gw).or_default().push(json!({"name": name, "cast_id": cast_id, "host": host, "port": port}));
    }
    let mut sent = false;
    for (gw, speakers) in by_gw {
        let msg = json!({"type": "speak", "text": text, "speakers": speakers}).to_string();
        if st.hub.send_gateway(gw, msg).await {
            sent = true;
        } else {
            tracing::warn!(%home, "speak: could not reach gateway");
        }
    }
    sent
}

pub async fn list(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<SpeakerOut>>> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    Ok(Json(sqlx::query_as("SELECT id, home_id, name, cast_id, host, port FROM speakers WHERE home_id = $1 ORDER BY created_at").bind(hid).fetch_all(&st.db).await?))
}

/// Mọi gateway có khả năng cast quét mDNS `_googlecast._tcp` (gateway nào cùng LAN với loa mới thấy) và trả về loa tìm thấy,
/// kèm `gateway_id` đã thấy loa và cờ `added`. Mất vài giây.
pub async fn scan(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Value>> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let gws = st.hub.cast_gateways_for_home(hid);
    if gws.is_empty() {
        return Err(ApiError::Unavailable("no speaker-capable gateway online".into()));
    }
    let replies = futures::future::join_all(gws.iter().map(|gw| async {
        (*gw, st.hub.request_gateway(*gw, json!({"type": "cast_scan"}), std::time::Duration::from_secs(20)).await)
    }))
    .await;
    let mut found: Vec<Value> = Vec::new();
    let (mut timeouts, mut errors) = (0, 0);
    for (gw, r) in replies {
        match r {
            Ok(reply) if reply.get("error").is_some_and(|e| !e.is_null()) => errors += 1,
            Ok(reply) => {
                for mut d in reply["devices"].as_array().cloned().unwrap_or_default() {
                    if d["cast_id"].is_string() && d["host"].is_string() && !found.iter().any(|f| f["cast_id"] == d["cast_id"]) {
                        d["gateway_id"] = json!(gw);
                        found.push(d);
                    }
                }
            }
            Err(_) => timeouts += 1,
        }
    }
    if found.is_empty() && errors + timeouts == gws.len() {
        return Err(ApiError::Unavailable(if timeouts > 0 { "gateway did not respond" } else { "cast discovery unavailable on gateway" }.into()));
    }
    let added: Vec<String> = sqlx::query_scalar("SELECT cast_id FROM speakers WHERE home_id = $1").bind(hid).fetch_all(&st.db).await?;
    for d in &mut found {
        let a = d["cast_id"].as_str().is_some_and(|c| added.iter().any(|x| x == c));
        d["added"] = json!(a);
    }
    Ok(Json(json!({ "devices": found })))
}

#[derive(Deserialize)]
pub struct SpeakerReq {
    cast_id: Option<String>,
    name: Option<String>,
    host: Option<String>,
    port: Option<i32>,
    /// Gateway đã tìm thấy loa (từ kết quả quét); loa này sẽ được phát qua gateway đó.
    gateway_id: Option<Uuid>,
}

fn name_of(n: &str) -> ApiResult<String> {
    let n = n.trim();
    if n.is_empty() || n.chars().count() > 60 || n.chars().any(char::is_control) {
        return Err(ApiError::BadRequest("name must be 1..60 characters".into()));
    }
    Ok(n.to_string())
}

pub async fn add(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<SpeakerReq>) -> ApiResult<(StatusCode, Json<SpeakerOut>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let bad = |m: &str| ApiError::BadRequest(m.into());
    let cast_id = b.cast_id.as_deref().map(str::trim).filter(|c| !c.is_empty() && c.len() <= 100 && c.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-')).ok_or_else(|| bad("invalid cast_id"))?;
    let name = name_of(b.name.as_deref().unwrap_or(""))?;
    let host = b.host.as_deref().map(str::trim).filter(|h| h.parse::<std::net::IpAddr>().is_ok()).map(str::to_string);
    if b.host.is_some() && host.is_none() {
        return Err(bad("host must be an IP address"));
    }
    let port = b.port.unwrap_or(8009);
    if !(1..=65535).contains(&port) {
        return Err(bad("invalid port"));
    }
    if let Some(g) = b.gateway_id {
        let ok: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM gateways WHERE id = $1 AND home_id = $2)").bind(g).bind(hid).fetch_one(&st.db).await?;
        if !ok {
            return Err(bad("unknown gateway"));
        }
    }
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM speakers WHERE home_id = $1").bind(hid).fetch_one(&st.db).await?;
    if n >= MAX_SPEAKERS {
        return Err(bad("too many speakers"));
    }
    let row = sqlx::query_as("INSERT INTO speakers (home_id, name, cast_id, host, port, gateway_id) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id, home_id, name, cast_id, host, port")
        .bind(hid)
        .bind(name)
        .bind(cast_id)
        .bind(host)
        .bind(port)
        .bind(b.gateway_id)
        .fetch_one(&st.db)
        .await
        .map_err(|e| match e {
            sqlx::Error::Database(ref d) if d.is_unique_violation() => ApiError::Conflict("speaker already added".into()),
            e => e.into(),
        })?;
    Ok((StatusCode::CREATED, Json(row)))
}

async fn speaker_home(st: &AppState, id: Uuid) -> ApiResult<Uuid> {
    sqlx::query_scalar("SELECT home_id FROM speakers WHERE id = $1").bind(id).fetch_optional(&st.db).await?.ok_or(ApiError::NotFound)
}

pub async fn rename(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>, Json(b): Json<SpeakerReq>) -> ApiResult<Json<SpeakerOut>> {
    let hid = speaker_home(&st, id).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = name_of(b.name.as_deref().unwrap_or(""))?;
    Ok(Json(sqlx::query_as("UPDATE speakers SET name = $2 WHERE id = $1 RETURNING id, home_id, name, cast_id, host, port").bind(id).bind(name).fetch_one(&st.db).await?))
}

pub async fn remove(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = speaker_home(&st, id).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("DELETE FROM speakers WHERE id = $1").bind(id).execute(&st.db).await?;
    // Bỏ loa này khỏi các ngữ cảnh/luật đang dùng.
    sqlx::query("UPDATE scenes SET speaker_ids = array_remove(speaker_ids, $1) WHERE home_id = $2").bind(id).bind(hid).execute(&st.db).await?;
    sqlx::query("UPDATE device_rules SET speaker_ids = array_remove(speaker_ids, $1) WHERE home_id = $2").bind(id).bind(hid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Phát câu thử trên loa (thành viên trở lên).
pub async fn test(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = speaker_home(&st, id).await?;
    access::require(&st.db, uid, hid, Role::Member).await?;
    if !say(&st, hid, &[id], TEST_TEXT).await {
        return Err(ApiError::Unavailable("no speaker-capable gateway online".into()));
    }
    Ok(StatusCode::ACCEPTED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_rules() {
        assert_eq!(clean_text(None).unwrap(), None);
        assert_eq!(clean_text(Some("  Xin chào  ")).unwrap().as_deref(), Some("Xin chào"));
        assert_eq!(clean_text(Some("   ")).unwrap().as_deref(), Some(""));
        assert!(clean_text(Some(&"a".repeat(141))).is_err());
        assert!(clean_text(Some(&"ạ".repeat(140))).is_ok(), "đếm theo ký tự, không theo byte");
        assert!(clean_text(Some("a\nb")).is_err());
    }
}
