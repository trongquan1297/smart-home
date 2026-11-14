//! Vị trí căn hộ + trạng thái "đang ở nhà / đã rời" của từng thành viên, dùng để tự chạy ngữ cảnh khi người cuối cùng rời đi.
//! Điện thoại tự theo dõi geofence quanh vị trí căn hộ và chỉ báo lên "trong/ngoài"; máy chủ không lưu toạ độ cá nhân.
use axum::{extract::{Path, State}, http::StatusCode, Json};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    automation,
    error::{ApiError, ApiResult},
    auth::AuthUser,
    AppState,
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

/// Xoá vị trí căn hộ: tắt luôn `auto_leave` của mọi ngữ cảnh.
pub async fn clear_location(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("UPDATE homes SET geo_lat = NULL, geo_lng = NULL, geo_radius_m = 150 WHERE id = $1").bind(hid).execute(&st.db).await?;
    sqlx::query("UPDATE scenes SET auto_leave = false WHERE home_id = $1").bind(hid).execute(&st.db).await?;
    sqlx::query("DELETE FROM member_presence WHERE home_id = $1").bind(hid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Còn ai (chủ nhà, quản trị, thành viên — chưa bị gỡ quyền) được báo "đang ở nhà" gần đây không.
async fn anyone_home(st: &AppState, hid: Uuid) -> ApiResult<bool> {
    Ok(sqlx::query_scalar(
        "SELECT EXISTS(
           SELECT 1 FROM member_presence p
            WHERE p.home_id = $1 AND p.inside AND p.updated_at > now() - make_interval(days => $2)
              AND (EXISTS(SELECT 1 FROM home_members hm WHERE hm.home_id = p.home_id AND hm.user_id = p.user_id AND hm.role IN ('owner','admin','member'))
                   OR EXISTS(SELECT 1 FROM tenant_members tm JOIN homes h ON h.tenant_id = tm.tenant_id WHERE h.id = p.home_id AND tm.user_id = p.user_id)))",
    )
    .bind(hid)
    .bind(STALE_DAYS)
    .fetch_one(&st.db)
    .await?)
}

#[derive(Deserialize)]
pub struct PresenceReq {
    inside: bool,
}

/// Điện thoại báo đã vào/ra vùng căn hộ. Khi trạng thái chung chuyển từ "có người" sang "không còn ai" thì chạy ngữ cảnh `auto_leave`.
/// Báo "ngoài" khi trước đó chưa ai báo "trong" không kích hoạt gì (vd mới cài app lúc đang ở xa).
pub async fn report(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<PresenceReq>) -> ApiResult<StatusCode> {
    access::require(&st.db, uid, hid, Role::Member).await?;
    let has_geo: bool = sqlx::query_scalar("SELECT geo_lat IS NOT NULL FROM homes WHERE id = $1").bind(hid).fetch_one(&st.db).await?;
    if !has_geo {
        return Err(ApiError::BadRequest("home location is not set".into()));
    }
    let before = anyone_home(&st, hid).await?;
    sqlx::query(
        "INSERT INTO member_presence (home_id, user_id, inside) VALUES ($1,$2,$3)
         ON CONFLICT (home_id, user_id) DO UPDATE SET inside = EXCLUDED.inside, updated_at = now()",
    )
    .bind(hid)
    .bind(uid)
    .bind(b.inside)
    .execute(&st.db)
    .await?;
    if before && !anyone_home(&st, hid).await? {
        tracing::info!(%hid, "last member left home");
        automation::run_auto_leave(&st, hid).await;
    }
    Ok(StatusCode::NO_CONTENT)
}
