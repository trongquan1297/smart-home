//! Xoá tài khoản ngay trong app (App Store Review Guideline 5.1.1(v)).
//!
//!  * Tenant mà người dùng là thành viên quản lý DUY NHẤT → xoá cả tenant: mọi căn hộ, phòng, thiết bị, gateway, ngữ cảnh…
//!    (thành viên/khách khác của các căn hộ đó mất quyền). Tenant còn người quản lý khác → giữ, chỉ gỡ người dùng.
//!  * Xoá người dùng: phiên đăng nhập, token thông báo, danh tính Google/Apple, liên kết Google Home… xoá theo (CASCADE);
//!    lịch sử điều khiển ở căn hộ còn lại giữ nhưng bỏ tên người (SET NULL).
//!  * Sau đó (lỗi chỉ ghi log): thu hồi token Sign in with Apple, xoá người dùng khỏi Google HomeGraph, ngắt gateway đã xoá.
use axum::{extract::State, Json};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{ApiError, ApiResult},
    AppState,
};

/// Tenant sẽ bị xoá cùng tài khoản: người dùng là thành viên quản lý duy nhất.
const SOLE_TENANTS: &str = "SELECT tm.tenant_id FROM tenant_members tm WHERE tm.user_id = $1
     AND NOT EXISTS (SELECT 1 FROM tenant_members o WHERE o.tenant_id = tm.tenant_id AND o.user_id <> $1)";

/// GET /v1/me/deletion — app hiện trong hộp xác nhận: căn hộ nào sẽ bị xoá theo.
pub async fn preview(State(st): State<AppState>, AuthUser(uid): AuthUser) -> ApiResult<Json<Value>> {
    let homes: Vec<(Uuid, String, i64)> = sqlx::query_as(&format!(
        "SELECT h.id, h.name, (SELECT count(*) FROM home_members m WHERE m.home_id = h.id AND m.user_id <> $1)
           FROM homes h WHERE h.tenant_id IN ({SOLE_TENANTS}) ORDER BY h.created_at"
    ))
    .bind(uid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!({
        "homes": homes.into_iter().map(|(id, name, others)| json!({"id": id, "name": name, "other_members": others})).collect::<Vec<_>>()
    })))
}

#[derive(Deserialize)]
pub struct DeleteReq {
    /// Phải đúng "DELETE": tránh xoá nhầm do gọi API sai.
    confirm: String,
}

/// DELETE /v1/me {"confirm":"DELETE"}
pub async fn delete(State(st): State<AppState>, AuthUser(uid): AuthUser, Json(b): Json<DeleteReq>) -> ApiResult<Json<Value>> {
    if b.confirm != "DELETE" {
        return Err(ApiError::BadRequest("confirm must be \"DELETE\"".into()));
    }
    let mut tx = st.db.begin().await?;
    let apple: Vec<(String, String)> = sqlx::query_as(
        "SELECT apple_client_id, apple_refresh_token FROM user_identities
          WHERE user_id = $1 AND provider = 'apple' AND apple_refresh_token IS NOT NULL AND apple_client_id IS NOT NULL",
    )
    .bind(uid)
    .fetch_all(&mut *tx)
    .await?;
    let had_google_link: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM oauth_grants WHERE user_id = $1)").bind(uid).fetch_one(&mut *tx).await?;
    let gateways: Vec<Uuid> = sqlx::query_scalar(&format!(
        "SELECT g.id FROM gateways g JOIN homes h ON h.id = g.home_id WHERE h.tenant_id IN ({SOLE_TENANTS})"
    ))
    .bind(uid)
    .fetch_all(&mut *tx)
    .await?;
    let deleted_homes: Vec<Uuid> = sqlx::query_scalar(&format!("SELECT id FROM homes WHERE tenant_id IN ({SOLE_TENANTS})"))
        .bind(uid)
        .fetch_all(&mut *tx)
        .await?;
    sqlx::query(&format!("DELETE FROM tenants WHERE id IN ({SOLE_TENANTS})")).bind(uid).execute(&mut *tx).await?;
    // Mã mời do người này tạo ở căn hộ còn lại (cột created_by không CASCADE).
    sqlx::query("DELETE FROM home_invites WHERE created_by = $1").bind(uid).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM users WHERE id = $1").bind(uid).execute(&mut *tx).await?;
    tx.commit().await?;
    tracing::warn!(user = %uid, homes = deleted_homes.len(), "account deleted by user");

    for gw in gateways {
        st.hub.kick_gateway(gw);
    }
    for h in &deleted_homes {
        st.hub.publish(*h, json!({"type": "home_deleted"}).to_string());
    }
    let st2 = st.clone();
    tokio::spawn(async move {
        if let Some(api) = st2.apple.as_ref() {
            for (client, token) in apple {
                match api.revoke(&client, &token).await {
                    Ok(()) => tracing::info!(user = %uid, "apple: đã thu hồi token khi xoá tài khoản"),
                    Err(e) => tracing::warn!(user = %uid, "apple: thu hồi token thất bại: {e:#}"),
                }
            }
        }
        if had_google_link {
            crate::homegraph::delete_agent(&st2, uid).await;
        }
    });
    Ok(Json(json!({"deleted": true, "homes_deleted": deleted_homes.len()})))
}
