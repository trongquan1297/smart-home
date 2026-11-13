//! Kiểm soát truy cập theo căn hộ. Đây là điểm DUY NHẤT quyết định ai được làm gì trên một home.
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::{ApiError, ApiResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Guest,  // chỉ xem
    Member, // xem + điều khiển thiết bị
    Admin,  // quản lý phòng/thiết bị/thành viên/gateway
    Owner,
}

impl Role {
    pub fn parse(s: &str) -> Option<Role> {
        Some(match s {
            "guest" => Role::Guest,
            "member" => Role::Member,
            "admin" => Role::Admin,
            "owner" => Role::Owner,
            _ => return None,
        })
    }
}

/// Vai trò hiệu lực của user trên home. Quản trị tenant (owner/admin) mặc nhiên là Admin của mọi home trong tenant.
/// Không có quyền → NotFound (không lộ sự tồn tại của home thuộc tenant khác).
pub async fn home_role(db: &PgPool, user: Uuid, home: Uuid) -> ApiResult<Role> {
    let row: Option<(Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT hm.role, tm.role
         FROM homes h
         LEFT JOIN home_members   hm ON hm.home_id = h.id AND hm.user_id = $1
         LEFT JOIN tenant_members tm ON tm.tenant_id = h.tenant_id AND tm.user_id = $1
         WHERE h.id = $2",
    )
    .bind(user)
    .bind(home)
    .fetch_optional(db)
    .await?;
    let (hm, tm) = row.ok_or(ApiError::NotFound)?;
    let from_home = hm.as_deref().and_then(Role::parse);
    let from_tenant = tm.map(|_| Role::Admin);
    from_home.max(from_tenant).ok_or(ApiError::NotFound)
}

pub async fn require(db: &PgPool, user: Uuid, home: Uuid, min: Role) -> ApiResult<Role> {
    let r = home_role(db, user, home).await?;
    if r < min {
        return Err(ApiError::Forbidden);
    }
    Ok(r)
}
