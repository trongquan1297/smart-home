//! Vị trí căn hộ + trạng thái "đang ở nhà / đã rời" của từng thành viên, dùng để tự chạy ngữ cảnh khi người cuối cùng rời đi.
//! Điện thoại tự theo dõi geofence quanh vị trí căn hộ và chỉ báo lên "trong/ngoài"; máy chủ không lưu toạ độ cá nhân.
use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    error::{ApiError, ApiResult},
    auth::AuthUser,
    triggers, AppState,
};

/// Trạng thái cũ hơn mức này bị coi là không còn thông tin (điện thoại hết pin, gỡ app…), tránh kẹt "còn người ở nhà" mãi.
const STALE_DAYS: i32 = 7;

#[derive(Deserialize)]
pub struct LocationReq {
    lat: f64,
    lng: f64,
    radius_m: Option<i32>,
}

/// Đặt vị trí căn hộ (quản trị). Bán kính 50–2000 m, mặc định 150 m.
pub async fn set_location(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<LocationReq>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let r = b.radius_m.unwrap_or(150);
    if !b.lat.is_finite() || !b.lng.is_finite() || !(-90.0..=90.0).contains(&b.lat) || !(-180.0..=180.0).contains(&b.lng) || !(50..=2000).contains(&r) {
        return Err(ApiError::BadRequest("invalid lat/lng or radius_m (50..2000)".into()));
    }
    sqlx::query("UPDATE homes SET geo_lat = $2, geo_lng = $3, geo_radius_m = $4 WHERE id = $1").bind(hid).bind(b.lat).bind(b.lng).bind(r).execute(&st.db).await?;
    // Đổi vị trí thì trạng thái trong/ngoài cũ không còn đúng.
    sqlx::query("DELETE FROM member_presence WHERE home_id = $1").bind(hid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Xoá vị trí căn hộ: tắt luôn `auto_leave` / `auto_arrive` của mọi ngữ cảnh.
pub async fn clear_location(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("UPDATE homes SET geo_lat = NULL, geo_lng = NULL, geo_radius_m = 150 WHERE id = $1").bind(hid).execute(&st.db).await?;
    sqlx::query("UPDATE scenes SET auto_leave = false, auto_arrive = false WHERE home_id = $1").bind(hid).execute(&st.db).await?;
    sqlx::query("DELETE FROM member_presence WHERE home_id = $1").bind(hid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Có ai ở nhà không, tính theo trạng thái gần đây (≤ `STALE_DAYS`) của chủ nhà / quản trị / thành viên còn quyền.
/// `None` = chưa ai báo trạng thái (không biết); `Some(true)` = có ít nhất một người "trong"; `Some(false)` = mọi người đều "ngoài".
pub async fn home_presence(st: &AppState, hid: Uuid) -> ApiResult<Option<bool>> {
    let (known, inside): (bool, bool) = sqlx::query_as(
        "SELECT count(*) > 0, bool_or(p.inside) IS TRUE
           FROM member_presence p
          WHERE p.home_id = $1 AND p.updated_at > now() - make_interval(days => $2)
            AND (EXISTS(SELECT 1 FROM home_members hm WHERE hm.home_id = p.home_id AND hm.user_id = p.user_id AND hm.role IN ('owner','admin','member'))
                 OR EXISTS(SELECT 1 FROM tenant_members tm JOIN homes h ON h.tenant_id = tm.tenant_id WHERE h.id = p.home_id AND tm.user_id = p.user_id))",
    )
    .bind(hid)
    .bind(STALE_DAYS)
    .fetch_one(&st.db)
    .await?;
    Ok(known.then_some(inside))
}

/// Trạng thái chung trước/sau một lần báo → sự kiện rời nhà / về nhà (nếu có).
/// Chỉ tính khi trạng thái trước đã biết: lần báo đầu tiên (vd mới bật geofence lúc đang ở nhà) chỉ đặt mốc, không phải "về nhà".
fn transition(before: Option<bool>, after: Option<bool>) -> Option<triggers::Fired> {
    match (before, after) {
        (Some(true), Some(false)) => Some(triggers::Fired::Leave),
        (Some(false), Some(true)) => Some(triggers::Fired::Arrive),
        _ => None,
    }
}

#[derive(Deserialize)]
pub struct PresenceReq {
    inside: bool,
}

/// Điện thoại báo đã vào/ra vùng căn hộ. Trạng thái chung chuyển "có người" → "không còn ai" thì xét các ngữ cảnh `auto_leave`;
/// "không còn ai" → "có người" thì xét các ngữ cảnh `auto_arrive` (triggers.rs). Trạng thái trước chưa biết thì không kích hoạt gì.
pub async fn report(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<PresenceReq>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    let has_geo: bool = sqlx::query_scalar("SELECT geo_lat IS NOT NULL FROM homes WHERE id = $1").bind(hid).fetch_one(&st.db).await?;
    if !has_geo {
        return Err(ApiError::BadRequest("home location is not set".into()));
    }
    let before = home_presence(&st, hid).await?;
    sqlx::query(
        "INSERT INTO member_presence (home_id, user_id, inside) VALUES ($1,$2,$3)
         ON CONFLICT (home_id, user_id) DO UPDATE SET inside = EXCLUDED.inside, updated_at = now()",
    )
    .bind(hid)
    .bind(uid)
    .bind(b.inside)
    .execute(&st.db)
    .await?;
    if let Some(fired) = transition(before, home_presence(&st, hid).await?) {
        tracing::info!(%hid, ?fired, "home presence changed");
        // Chạy nền: ngữ cảnh giãn cách có thể mất hàng chục giây, điện thoại (callback geofence nền) không phải chờ.
        let st2 = st.clone();
        tokio::spawn(async move { triggers::on_presence(&st2, hid, fired).await });
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use triggers::Fired;

    #[test]
    fn leave_and_arrive_need_a_known_previous_state() {
        assert_eq!(transition(Some(true), Some(false)), Some(Fired::Leave));
        assert_eq!(transition(Some(false), Some(true)), Some(Fired::Arrive));
        assert_eq!(transition(None, Some(true)), None, "lần báo đầu tiên chỉ đặt mốc");
        assert_eq!(transition(None, Some(false)), None);
        assert_eq!(transition(Some(true), Some(true)), None);
        assert_eq!(transition(Some(false), Some(false)), None);
    }
}
