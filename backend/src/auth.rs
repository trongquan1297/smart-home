use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    async_trait,
    extract::FromRequestParts,
    http::{header, request::Parts, HeaderMap},
};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    error::{ApiError, ApiResult},
    AppState,
};

/// Access token (JWT) sống ngắn; client dùng refresh token để lấy cái mới.
pub const ACCESS_TTL_SECS: u64 = 15 * 60;
/// Mỗi refresh token sống 30 ngày kể từ lần cấp (trượt khi xoay vòng) nhưng cả phiên không quá 90 ngày.
const REFRESH_TTL_DAYS: i64 = 30;
const SESSION_MAX_DAYS: i64 = 90;

/// Argon2 tốn ~19 MiB RAM mỗi lần băm: giới hạn số lần băm đồng thời để không bị bóp RAM/CPU (Pi, VPS nhỏ).
static HASH_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: Uuid,
    exp: u64,
}

pub fn sign(secret: &[u8], user_id: Uuid) -> ApiResult<String> {
    let exp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| ApiError::Internal(e.into()))?
        .as_secs()
        + ACCESS_TTL_SECS;
    encode(&Header::default(), &Claims { sub: user_id, exp }, &EncodingKey::from_secret(secret))
        .map_err(|e| ApiError::Internal(e.into()))
}

pub fn verify(secret: &[u8], token: &str) -> ApiResult<Uuid> {
    verify_claims(secret, token).map(|(u, _)| u)
}

/// (user, exp theo epoch giây). Chỉ chấp nhận HS256 và yêu cầu `exp`.
pub fn verify_claims(secret: &[u8], token: &str) -> ApiResult<(Uuid, u64)> {
    let mut v = Validation::new(jsonwebtoken::Algorithm::HS256);
    v.leeway = 5;
    decode::<Claims>(token, &DecodingKey::from_secret(secret), &v)
        .map(|d| (d.claims.sub, d.claims.exp))
        .map_err(|_| ApiError::Unauthorized)
}

pub async fn hash_password(pw: String) -> ApiResult<String> {
    let _slot = HASH_SLOTS.acquire().await.map_err(|e| ApiError::Internal(e.into()))?;
    tokio::task::spawn_blocking(move || {
        let salt = SaltString::generate(&mut OsRng);
        Argon2::default().hash_password(pw.as_bytes(), &salt).map(|h| h.to_string())
    })
    .await
    .map_err(|e| ApiError::Internal(e.into()))?
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("hash: {e}")))
}

pub async fn verify_password(pw: String, hash: String) -> bool {
    let Ok(_slot) = HASH_SLOTS.acquire().await else { return false };
    tokio::task::spawn_blocking(move || {
        PasswordHash::new(&hash)
            .map(|h| Argon2::default().verify_password(pw.as_bytes(), &h).is_ok())
            .unwrap_or(false)
    })
    .await
    .unwrap_or(false)
}

/// Token ngẫu nhiên 256-bit (dùng cho gateway token, invite token).
pub fn random_token(prefix: &str) -> String {
    let bytes: [u8; 32] = rand::random();
    format!("{prefix}_{}", hex::encode(bytes))
}

pub fn hash_token(t: &str) -> String {
    hex::encode(Sha256::digest(t.as_bytes()))
}

pub fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::to_owned)
}

/// Extractor: người dùng đã đăng nhập (JWT trong header Authorization).
pub struct AuthUser(pub Uuid);

#[async_trait]
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, st: &AppState) -> Result<Self, ApiError> {
        let token = bearer(&parts.headers).ok_or(ApiError::Unauthorized)?;
        Ok(AuthUser(verify(&st.jwt_secret, &token)?))
    }
}

// ───────────────────────── refresh token ─────────────────────────

/// Cặp token trả về cho client sau đăng nhập / đăng ký / làm mới.
pub struct Tokens {
    pub access: String,
    pub refresh: String,
}

impl Tokens {
    pub fn into_json(self, user: serde_json::Value) -> serde_json::Value {
        // `token` giữ tên cũ để tương thích client; thêm refresh_token + expires_in.
        serde_json::json!({
            "token": self.access,
            "expires_in": ACCESS_TTL_SECS,
            "refresh_token": self.refresh,
            "user": user,
        })
    }
}

/// Bắt đầu phiên mới (family mới) — dùng sau khi đã xác thực mật khẩu.
pub async fn start_session(st: &AppState, user: Uuid) -> ApiResult<Tokens> {
    let refresh = random_token("rt");
    sqlx::query(
        "INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
         VALUES ($1, gen_random_uuid(), $2, now() + make_interval(days => $3))",
    )
    .bind(user)
    .bind(hash_token(&refresh))
    .bind(REFRESH_TTL_DAYS as i32)
    .execute(&st.db)
    .await?;
    Ok(Tokens { access: sign(&st.jwt_secret, user)?, refresh })
}

/// Đổi refresh token lấy cặp mới (xoay vòng). Token cũ chỉ dùng được MỘT lần: trình lại token đã dùng /
/// đã thu hồi → thu hồi toàn bộ phiên (family) vì có thể đã bị đánh cắp.
pub async fn rotate(st: &AppState, presented: &str) -> ApiResult<(Uuid, Tokens)> {
    if presented.len() > 200 {
        return Err(ApiError::Unauthorized);
    }
    let mut tx = st.db.begin().await?;
    let row: Option<(Uuid, Uuid, Uuid, bool, bool, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        "SELECT id, user_id, family_id, (used_at IS NOT NULL OR revoked_at IS NOT NULL), (expires_at <= now()), family_started_at
           FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE",
    )
    .bind(hash_token(presented))
    .fetch_optional(&mut *tx)
    .await?;
    let Some((id, user, family, spent, expired, started)) = row else {
        return Err(ApiError::Unauthorized);
    };
    if spent {
        sqlx::query("UPDATE refresh_tokens SET revoked_at = now() WHERE family_id = $1 AND revoked_at IS NULL")
            .bind(family)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        tracing::warn!(user = %user, "refresh token reuse detected; session family revoked");
        return Err(ApiError::Unauthorized);
    }
    if expired {
        return Err(ApiError::Unauthorized);
    }
    let refresh = random_token("rt");
    sqlx::query("UPDATE refresh_tokens SET used_at = now() WHERE id = $1").bind(id).execute(&mut *tx).await?;
    let inserted = sqlx::query(
        "INSERT INTO refresh_tokens (user_id, family_id, family_started_at, token_hash, expires_at)
         SELECT $1, $2, $3, $4, LEAST(now() + make_interval(days => $5), $3 + make_interval(days => $6))
         WHERE $3 + make_interval(days => $6) > now()",
    )
    .bind(user)
    .bind(family)
    .bind(started)
    .bind(hash_token(&refresh))
    .bind(REFRESH_TTL_DAYS as i32)
    .bind(SESSION_MAX_DAYS as i32)
    .execute(&mut *tx)
    .await?;
    if inserted.rows_affected() == 0 {
        // phiên đã quá tuổi tuyệt đối → bắt đăng nhập lại
        tx.commit().await?;
        return Err(ApiError::Unauthorized);
    }
    tx.commit().await?;
    Ok((user, Tokens { access: sign(&st.jwt_secret, user)?, refresh }))
}

/// Đăng xuất: thu hồi cả phiên chứa refresh token này. Luôn thành công (không lộ token có hợp lệ hay không).
pub async fn revoke_session(st: &AppState, presented: &str) -> ApiResult<()> {
    sqlx::query(
        "UPDATE refresh_tokens SET revoked_at = now()
          WHERE revoked_at IS NULL AND family_id IN (SELECT family_id FROM refresh_tokens WHERE token_hash = $1)",
    )
    .bind(hash_token(presented))
    .execute(&st.db)
    .await?;
    Ok(())
}

/// Đăng xuất mọi thiết bị của một người dùng.
pub async fn revoke_all(st: &AppState, user: Uuid) -> ApiResult<u64> {
    let r = sqlx::query("UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL")
        .bind(user)
        .execute(&st.db)
        .await?;
    Ok(r.rows_affected())
}

/// Xoá token đã hết hạn hơn 1 ngày (gọi định kỳ).
pub async fn purge_expired(st: &AppState) {
    if let Err(e) = sqlx::query("DELETE FROM refresh_tokens WHERE expires_at < now() - interval '1 day'")
        .execute(&st.db)
        .await
    {
        tracing::warn!("purge refresh tokens: {e}");
    }
}

/// Băm giả dùng khi email không tồn tại, để thời gian phản hồi không lộ email nào có tài khoản.
pub async fn dummy_hash() -> String {
    hash_password("dummy-password-for-timing".into()).await.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn access_token_roundtrip_and_tamper() {
        let secret = b"0123456789abcdef0123456789abcdef";
        let uid = Uuid::new_v4();
        let t = sign(secret, uid).unwrap();
        let (u, exp) = verify_claims(secret, &t).unwrap();
        assert_eq!(u, uid);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        assert!(exp > now && exp <= now + ACCESS_TTL_SECS);
        assert!(verify(b"another-secret-another-secret-aaaa", &t).is_err(), "sai khoá");
        assert!(verify(secret, &format!("{t}x")).is_err(), "bị sửa");
    }

    #[test]
    fn expired_access_token_is_rejected() {
        let secret = b"0123456789abcdef0123456789abcdef";
        let claims = Claims { sub: Uuid::new_v4(), exp: 1_000_000 };
        let t = encode(&Header::default(), &claims, &EncodingKey::from_secret(secret)).unwrap();
        assert!(verify(secret, &t).is_err());
    }
}
