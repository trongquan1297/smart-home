//! Máy lọc nước Bluetooth (Karofi) qua addon trong nhà (cùng addon với camera, khả năng `purifier`).
//!
//! Máy lọc là một hàng `devices` bình thường (kind = `purifier`, ieee_address = MAC Bluetooth): trạng thái, online/offline,
//! phòng, Google Home… đi chung đường với thiết bị Zigbee (gateway_ws). File này chỉ lo phần riêng:
//!  * tìm máy quanh addon và thêm máy (addon phải đọc được số liệu thật mới nhận),
//!  * gỡ máy,
//!  * cảnh báo: máy báo lỗi (thiếu nước, rò nước…) và lõi lọc sắp hết hạn — gửi cho cả căn hộ, không phụ thuộc ngữ cảnh.
use std::time::{Duration, Instant};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{
    access::{self, Role},
    alerts::Event,
    auth::AuthUser,
    error::{ApiError, ApiResult},
    push, AppState,
};

/// Lõi lọc còn ≤ mức này (%) thì nhắc thay.
pub const FILTER_LOW_PCT: i64 = 10;
const MAX_PURIFIERS: i64 = 8;

/// Chuẩn hoá MAC Bluetooth (AA:BB:CC:DD:EE:FF).
fn norm_mac(s: &str) -> Option<String> {
    let hex: String = s.chars().filter(|c| !matches!(c, ':' | '-' | '.' | ' ')).collect();
    (hex.len() == 12 && hex.chars().all(|c| c.is_ascii_hexdigit()))
        .then(|| hex.to_uppercase().as_bytes().chunks(2).map(|c| String::from_utf8_lossy(c).into_owned()).collect::<Vec<_>>().join(":"))
}

/// Phải khớp `friendly()` của addon: khoá định tuyến state/set.
fn friendly(mac: &str) -> String {
    format!("karofi-{}", mac.replace(':', "").to_lowercase())
}

fn addon_error(reply: &Value) -> Option<ApiError> {
    let e = reply.get("error").and_then(Value::as_str)?;
    Some(match e {
        "bluetooth_off" => ApiError::Unavailable("bluetooth_off".into()),
        "bluetooth_unavailable" => ApiError::Unavailable("bluetooth_unavailable".into()),
        "not_found" => ApiError::BadRequest("purifier not found nearby".into()),
        "bad mac" => ApiError::BadRequest("invalid mac".into()),
        _ => ApiError::Unavailable("purifier unreachable".into()),
    })
}

async fn ask(st: &AppState, gw: Uuid, msg: Value, secs: u64) -> ApiResult<Value> {
    match st.hub.request_gateway(gw, msg, Duration::from_secs(secs)).await {
        Ok(r) => match addon_error(&r) {
            Some(e) => Err(e),
            None => Ok(r),
        },
        Err(crate::hub::RequestError::Offline) => Err(ApiError::Unavailable("addon offline".into())),
        Err(crate::hub::RequestError::Timeout) => Err(ApiError::Unavailable("addon did not respond".into())),
    }
}

/// Tìm máy lọc Bluetooth quanh mọi addon đang online của căn hộ (mất ~10 giây).
pub async fn scan(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Value>> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let gws = st.hub.purifier_gateways_for_home(hid);
    if gws.is_empty() {
        return Err(ApiError::Unavailable("addon offline".into()));
    }
    let replies = futures::future::join_all(gws.iter().map(|gw| async { (*gw, st.hub.request_gateway(*gw, json!({"type": "pur_scan"}), Duration::from_secs(25)).await) })).await;
    let added: Vec<String> = sqlx::query_scalar("SELECT ieee_address FROM devices WHERE home_id = $1 AND kind = 'purifier'").bind(hid).fetch_all(&st.db).await?;
    let mut found = Vec::new();
    let mut errors = Vec::new();
    for (gw, r) in replies {
        let Ok(reply) = r else { continue };
        if let Some(e) = reply.get("error").and_then(Value::as_str) {
            errors.push(e.chars().take(32).collect::<String>());
            continue;
        }
        for d in reply["devices"].as_array().cloned().unwrap_or_default().into_iter().take(32) {
            let Some(mac) = d["mac"].as_str().and_then(norm_mac) else { continue };
            let name: String = d["name"].as_str().unwrap_or_default().chars().filter(|c| !c.is_control()).take(32).collect();
            found.push(json!({"gateway_id": gw, "mac": mac, "name": name, "rssi": d["rssi"].as_i64(), "added": d["added"].as_bool().unwrap_or(false) || added.contains(&mac)}));
        }
    }
    // Không addon nào quét được (Bluetooth tắt…) → báo lỗi để app hướng dẫn, thay vì "không thấy máy nào".
    if found.is_empty() && !errors.is_empty() {
        return Err(addon_error(&json!({"error": errors[0]})).unwrap_or_else(|| ApiError::Unavailable("bluetooth_unavailable".into())));
    }
    Ok(Json(json!({ "devices": found })))
}

#[derive(Deserialize)]
pub struct AddReq {
    mac: String,
    name: String,
    room_id: Option<Uuid>,
    gateway_id: Option<Uuid>,
}

/// Thêm máy lọc: addon kết nối và đọc thử, được thì máy thành một thiết bị của căn hộ.
pub async fn add(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<AddReq>) -> ApiResult<(StatusCode, Json<Value>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let mac = norm_mac(&b.mac).ok_or_else(|| ApiError::BadRequest("invalid mac".into()))?;
    let name = b.name.trim();
    if name.is_empty() || name.chars().count() > 60 || name.chars().any(char::is_control) {
        return Err(ApiError::BadRequest("name must be 1..60 characters".into()));
    }
    if let Some(r) = b.room_id {
        let ok: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM rooms WHERE id = $1 AND home_id = $2)").bind(r).bind(hid).fetch_one(&st.db).await?;
        if !ok {
            return Err(ApiError::BadRequest("unknown room".into()));
        }
    }
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE home_id = $1 AND kind = 'purifier'").bind(hid).fetch_one(&st.db).await?;
    if n >= MAX_PURIFIERS {
        return Err(ApiError::BadRequest("too many purifiers".into()));
    }
    let online = st.hub.purifier_gateways_for_home(hid);
    let gw = match b.gateway_id {
        Some(g) if online.contains(&g) => g,
        Some(_) => return Err(ApiError::Unavailable("addon offline".into())),
        None => *online.first().ok_or_else(|| ApiError::Unavailable("addon offline".into()))?,
    };
    // Máy đã gắn với addon KHÁC của căn hộ thì không thêm lần nữa (một máy chỉ một addon đọc).
    let taken: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE home_id = $1 AND ieee_address = $2 AND gateway_id <> $3)")
        .bind(hid)
        .bind(&mac)
        .bind(gw)
        .fetch_one(&st.db)
        .await?;
    if taken {
        return Err(ApiError::Conflict("purifier already added".into()));
    }
    tracing::info!(home = %hid, user = %uid, "purifier add requested");
    let reply = ask(&st, gw, json!({"type": "pur_add", "mac": mac}), 60).await?;
    let model: Option<String> = reply["info"]["model"].as_str().map(|s| s.chars().filter(|c| !c.is_control()).take(32).collect());
    let state = reply["info"]["state"].clone();
    let state = if state.is_object() { state } else { json!({}) };
    // Addon cũng gửi danh sách thiết bị (gateway_ws) — ai tới trước cũng được: ở đây chỉ đặt tên/phòng người dùng chọn.
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO devices (tenant_id, home_id, gateway_id, room_id, ieee_address, friendly_name, name, vendor, model, kind, description, state, online, last_seen_at)
         SELECT h.tenant_id, h.id, $2, $3, $4, $5, $6, 'Karofi', $7, 'purifier', 'Water purifier (Bluetooth)', $8, true, now() FROM homes h WHERE h.id = $1
         ON CONFLICT (gateway_id, ieee_address) DO UPDATE SET name = EXCLUDED.name, room_id = EXCLUDED.room_id, online = true
         RETURNING id",
    )
    .bind(hid)
    .bind(gw)
    .bind(b.room_id)
    .bind(&mac)
    .bind(friendly(&mac))
    .bind(name)
    .bind(model)
    .bind(&state)
    .fetch_one(&st.db)
    .await?;
    st.hub.publish(hid, json!({"type": "devices_changed"}).to_string());
    crate::homegraph::home_changed(&st, hid);
    Ok((StatusCode::CREATED, Json(json!({ "id": id }))))
}

/// Gỡ máy lọc (chỉ thiết bị Bluetooth qua addon mới gỡ được từ app; thiết bị Zigbee gỡ qua bộ điều khiển).
pub async fn remove(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(did): Path<Uuid>) -> ApiResult<StatusCode> {
    let row: Option<(Uuid, Uuid, String, String)> = sqlx::query_as("SELECT home_id, gateway_id, ieee_address, kind FROM devices WHERE id = $1").bind(did).fetch_optional(&st.db).await?;
    let (hid, gw, mac, kind) = row.ok_or(ApiError::NotFound)?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    if kind != "purifier" {
        return Err(ApiError::BadRequest("only bluetooth purifiers can be removed here".into()));
    }
    // Addon phải quên máy, nếu không lần kết nối sau nó gửi lại và máy hiện lại.
    ask(&st, gw, json!({"type": "pur_remove", "mac": mac}), 15).await?;
    sqlx::query("DELETE FROM devices WHERE id = $1").bind(did).execute(&st.db).await?;
    st.hub.publish(hid, json!({"type": "devices_changed"}).to_string());
    crate::homegraph::home_changed(&st, hid);
    tracing::warn!(home = %hid, user = %uid, device = %did, "purifier removed");
    Ok(StatusCode::NO_CONTENT)
}

/// Lệnh đặt lại lõi lọc hợp lệ: `{"reset_filter": n}` với n là số thứ tự lõi (1..=16).
pub fn valid_reset(p: &Value) -> bool {
    p.as_object().is_some_and(|o| o.len() == 1 && o.get("reset_filter").and_then(Value::as_u64).is_some_and(|n| (1..=16).contains(&n)))
}

pub fn error_text(code: i64) -> String {
    match code {
        1 => "Bơm chạy liên tục quá 5 giờ".into(),
        2 => "Áp lực nước vào yếu".into(),
        4 => "Không có nước vào máy".into(),
        5 => "Máy có thể đang rò nước".into(),
        100 => "TDS nước sau lọc cao".into(),
        c => format!("Mã lỗi {c}"),
    }
}

fn codes(v: &Value) -> Option<Vec<i64>> {
    v.get("errors")?.as_array().map(|a| a.iter().filter_map(Value::as_i64).collect())
}

/// (lõi số, % còn lại) của lõi thấp nhất.
fn lowest_filter(v: &Value) -> Option<(i64, i64)> {
    v.get("filters")?.as_array()?.iter().filter_map(|f| Some((f.get("no")?.as_i64()?, f.get("percent")?.as_i64()?))).min_by_key(|(_, p)| *p)
}

/// Sự kiện cần báo khi trạng thái máy lọc đổi. Chỉ tính khi trạng thái cũ đã biết (tránh báo lại lúc addon gửi lại toàn bộ).
pub fn detect(old: &Value, new: &Value) -> Vec<(Event, String, String)> {
    let mut out = Vec::new();
    if let (Some(o), Some(n)) = (codes(old), codes(new)) {
        for c in n.iter().filter(|c| !o.contains(c)) {
            out.push((Event::PurifierError, "Máy lọc nước báo lỗi".to_string(), error_text(*c)));
        }
    }
    let pct = |v: &Value| v.get("filter_min").and_then(Value::as_i64);
    if let (Some(o), Some(n)) = (pct(old), pct(new)) {
        if o > FILTER_LOW_PCT && n <= FILTER_LOW_PCT {
            let detail = lowest_filter(new).map(|(no, p)| format!("Lõi lọc số {no} còn {p}%")).unwrap_or_else(|| format!("Lõi lọc còn {n}%"));
            out.push((Event::FilterLow, "Sắp đến hạn thay lõi lọc".to_string(), detail));
        }
    }
    out
}

/// Gọi từ gateway_ws khi một máy lọc báo trạng thái mới.
pub async fn on_state(st: &AppState, home: Uuid, device: Uuid, old: &Value, new: &Value) {
    let events = detect(old, new);
    if events.is_empty() {
        return;
    }
    let name: String = match sqlx::query_scalar("SELECT name FROM devices WHERE id = $1 AND kind = 'purifier'").bind(device).fetch_optional(&st.db).await {
        Ok(Some(n)) => n,
        _ => return,
    };
    for (ev, title, detail) in events {
        let key = (device, ev);
        if st.alert_seen.get(&key).is_some_and(|t| t.elapsed() < Duration::from_secs(600)) {
            continue;
        }
        st.alert_seen.insert(key, Instant::now());
        let body = format!("{name}: {detail}");
        let ins: Result<(i64, chrono::DateTime<chrono::Utc>), _> =
            sqlx::query_as("INSERT INTO notifications (home_id, device_id, kind, title, body) VALUES ($1,$2,$3,$4,$5) RETURNING id, created_at")
                .bind(home)
                .bind(device)
                .bind(ev.kind())
                .bind(&title)
                .bind(&body)
                .fetch_one(&st.db)
                .await;
        let Ok((id, at)) = ins else { continue };
        tracing::info!(%home, %device, kind = ev.kind(), "purifier alert");
        st.hub.publish(home, json!({"type": "alert", "id": id, "kind": ev.kind(), "title": title, "body": body, "device_id": device, "created_at": at}).to_string());
        let st2 = st.clone();
        tokio::spawn(async move {
            push::notify_home(&st2, home, &title, &body, json!({"kind": ev.kind(), "home_id": home, "device_id": device})).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_and_friendly_match_addon() {
        assert_eq!(norm_mac("aa:bb:cc:11:22:33").as_deref(), Some("AA:BB:CC:11:22:33"));
        assert_eq!(norm_mac("AA:BB"), None);
        assert_eq!(friendly("AA:BB:CC:11:22:33"), "karofi-aabbcc112233");
    }

    #[test]
    fn reset_validation() {
        assert!(valid_reset(&json!({"reset_filter": 3})));
        assert!(!valid_reset(&json!({"reset_filter": 0})));
        assert!(!valid_reset(&json!({"reset_filter": 3, "state": "ON"})));
        assert!(!valid_reset(&json!({"reset_filter": "3"})));
    }

    #[test]
    fn alerts_only_on_transitions() {
        let old = json!({"errors": [], "filter_min": 15, "filters": [{"no": 1, "percent": 15}, {"no": 2, "percent": 60}]});
        let new = json!({"errors": [4], "filter_min": 9, "filters": [{"no": 1, "percent": 9}, {"no": 2, "percent": 60}]});
        let ev = detect(&old, &new);
        assert_eq!(ev.len(), 2);
        assert_eq!(ev[0].2, "Không có nước vào máy");
        assert_eq!(ev[1].2, "Lõi lọc số 1 còn 9%");
        // lỗi cũ vẫn còn / lõi vẫn thấp: không báo lại
        assert!(detect(&new, &new).is_empty());
        // trạng thái cũ chưa biết (máy mới thêm): không báo
        assert!(detect(&json!({}), &new).is_empty());
    }
}
