//! Máy chủ OAuth 2.0 (authorization code flow) để Google Home liên kết tài khoản MSmart (cloud-to-cloud).
//!
//!   Google ──GET /oauth/authorize──▶ trang đăng nhập + đồng ý ──POST──▶ 302 redirect_uri?code=…&state=…
//!   Google ──POST /oauth/token (code | refresh_token)──▶ access_token (1 giờ) + refresh_token (không hết hạn)
//!   Google ──Bearer access_token──▶ endpoint fulfillment (dùng extractor `OAuthUser`)
//!
//! Theo developers.home.google.com/cloud-to-cloud/project/authorization: chỉ authorization code; mã sống ~10 phút; access token
//! ~1 giờ; refresh token không hết hạn và không xoay vòng (để không bị hủy liên kết khi Google lỡ lưu token mới); lỗi xác thực mã/
//! refresh token trả `400 {"error":"invalid_grant"}`. Client (Google) cấu hình bằng biến môi trường; mọi mã/token chỉ lưu dạng băm.
use std::sync::OnceLock;

use axum::{
    async_trait,
    extract::{ConnectInfo, FromRequestParts, Query, State},
    http::{header, request::Parts, HeaderMap, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    Form, Json,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{Duration, Utc};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use serde_json::json;
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    auth,
    error::{ApiError, ApiResult},
    routes::{peer_ip, LOGIN_FAIL_PER_ACCOUNT, LOGIN_FAIL_PER_IP, LOGIN_WINDOW},
    AppState,
};

const CODE_TTL_MIN: i64 = 10;
const ACCESS_TTL_SECS: i64 = 3600;
/// Trang đăng nhập phải được gửi lại trong khoảng này (chữ ký trên các tham số của Google hết hạn).
const FORM_TTL_SECS: i64 = 30 * 60;

/// Một client OAuth (hiện chỉ có Google Home), đọc từ biến môi trường.
pub struct Client {
    pub id: String,
    secret_hash: String,
    redirects: Vec<String>,
    pub name: &'static str,
}

/// GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET: do mình tự đặt rồi nhập vào Google Home Developer Console.
/// GOOGLE_PROJECT_ID: chỉ chấp nhận đúng hai redirect_uri của Google cho dự án này (sản phẩm thật + sandbox).
fn clients() -> &'static [Client] {
    static C: OnceLock<Vec<Client>> = OnceLock::new();
    C.get_or_init(|| {
        let get = |k: &str| std::env::var(k).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        match (get("GOOGLE_OAUTH_CLIENT_ID"), get("GOOGLE_OAUTH_CLIENT_SECRET"), get("GOOGLE_PROJECT_ID")) {
            (Some(id), Some(secret), Some(project)) => {
                if secret.len() < 32 {
                    tracing::error!("oauth: GOOGLE_OAUTH_CLIENT_SECRET phải dài ít nhất 32 ký tự — Google Home bị tắt");
                    return vec![];
                }
                tracing::info!(client_id = %id, project = %project, "oauth: Google Home account linking enabled");
                vec![Client {
                    id,
                    secret_hash: auth::hash_token(&secret),
                    redirects: vec![
                        format!("https://oauth-redirect.googleusercontent.com/r/{project}"),
                        format!("https://oauth-redirect-sandbox.googleusercontent.com/r/{project}"),
                    ],
                    name: "Google",
                }]
            }
            _ => {
                tracing::info!("oauth: Google Home chưa cấu hình (GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET, GOOGLE_PROJECT_ID)");
                vec![]
            }
        }
    })
}

fn client(id: &str) -> Option<&'static Client> {
    clients().iter().find(|c| c.id == id)
}

/// So sánh thời gian hằng (hai chuỗi băm cùng độ dài).
fn ct_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

fn enc(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

// ───────────────────────── /oauth/authorize ─────────────────────────

#[derive(Deserialize, Clone)]
pub struct AuthorizeQuery {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    redirect_uri: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    scope: String,
    #[serde(default)]
    response_type: String,
}

/// Lỗi trước khi xác định được redirect_uri hợp lệ: KHÔNG chuyển hướng (tránh open redirect), chỉ hiện trang lỗi.
fn check(q: &AuthorizeQuery) -> Result<&'static Client, &'static str> {
    let c = client(&q.client_id).ok_or("Ứng dụng yêu cầu liên kết không hợp lệ.")?;
    if !c.redirects.iter().any(|r| r == &q.redirect_uri) {
        return Err("Địa chỉ quay lại không hợp lệ.");
    }
    if q.response_type != "code" {
        return Err("Chỉ hỗ trợ response_type=code.");
    }
    if q.state.len() > 2048 || q.scope.len() > 512 {
        return Err("Yêu cầu quá dài.");
    }
    Ok(c)
}

/// Chữ ký HMAC trên các tham số của Google + hạn: trang đăng nhập không thể bị sửa redirect_uri/client giữa GET và POST.
fn sign(secret: &[u8], q: &AuthorizeQuery, exp: i64) -> String {
    let mut m = Hmac::<Sha256>::new_from_slice(secret).expect("hmac key");
    for part in ["oauth-form", &q.client_id, &q.redirect_uri, &q.state, &q.scope, &exp.to_string()] {
        m.update(part.as_bytes());
        m.update(&[0]);
    }
    hex::encode(m.finalize().into_bytes())
}

fn page(status: StatusCode, body: String) -> Response {
    let mut r = (status, Html(body)).into_response();
    let h = r.headers_mut();
    // Không cho nhúng trang đăng nhập vào khung (chống clickjacking), không lưu cache, không gửi Referer ra ngoài.
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    h.insert("x-frame-options", HeaderValue::from_static("DENY"));
    h.insert("content-security-policy", HeaderValue::from_static("default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://oauth-redirect.googleusercontent.com https://oauth-redirect-sandbox.googleusercontent.com; frame-ancestors 'none'"));
    // `same-origin`, KHÔNG dùng `no-referrer`: với no-referrer trình duyệt gửi form POST kèm `Origin: null` (chuẩn Fetch),
    // same_origin() từ chối → "phiên đã hết hạn". same-origin vẫn không gửi Referer (URL chứa state/code) sang Google.
    h.insert("referrer-policy", HeaderValue::from_static("same-origin"));
    r
}

const CSS: &str = "*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:linear-gradient(160deg,#0ea5e9,#60a5fa);min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px;color:#0f172a}
.card{background:#fff;border-radius:24px;max-width:420px;width:100%;padding:28px 24px;box-shadow:0 20px 50px rgba(2,6,23,.18)}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:20px;color:#0369a1}.logo{width:40px;height:40px;border-radius:12px;background:#e0f2fe;display:flex;align-items:center;justify-content:center;font-size:22px}
h1{font-size:22px;margin:18px 0 6px}p{color:#475569;line-height:1.5;margin:0 0 14px;font-size:15px}
label{display:block;font-size:13px;font-weight:600;color:#334155;margin:12px 0 6px}input{width:100%;font-size:16px;padding:13px 14px;border-radius:12px;border:1px solid #cbd5e1;background:#f8fafc}
input:focus{outline:2px solid #0ea5e9;border-color:transparent}button{width:100%;margin-top:18px;padding:14px;border:0;border-radius:14px;background:#0ea5e9;color:#fff;font-size:16px;font-weight:700}
.err{background:#fee2e2;color:#991b1b;border-radius:12px;padding:10px 12px;font-size:14px;margin-top:12px}.note{font-size:13px;color:#64748b;margin-top:16px}";

fn shell(inner: &str) -> String {
    format!(r#"<!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Liên kết MSmart</title><style>{CSS}</style></head><body><div class="card"><div class="brand"><div class="logo">🏠</div>MSmart</div>{inner}</div></body></html>"#)
}

fn error_page(msg: &str) -> Response {
    page(StatusCode::BAD_REQUEST, shell(&format!("<h1>Không thể liên kết</h1><p>{}</p><p class=\"note\">Hãy thử lại từ ứng dụng Google Home.</p>", esc(msg))))
}

fn login_page(st: &AppState, q: &AuthorizeQuery, c: &Client, email: &str, error: Option<&str>) -> Response {
    let exp = Utc::now().timestamp() + FORM_TTL_SECS;
    let sig = sign(&st.jwt_secret, q, exp);
    let hidden = [("client_id", &q.client_id), ("redirect_uri", &q.redirect_uri), ("state", &q.state), ("scope", &q.scope), ("response_type", &q.response_type)]
        .iter()
        .map(|(k, v)| format!(r#"<input type="hidden" name="{k}" value="{}">"#, esc(v)))
        .collect::<String>();
    let err = error.map(|e| format!(r#"<div class="err">{}</div>"#, esc(e))).unwrap_or_default();
    let status = if error.is_some() { StatusCode::UNAUTHORIZED } else { StatusCode::OK };
    page(
        status,
        shell(&format!(
            r#"<h1>Liên kết tài khoản với {name}</h1>
<p>Đăng nhập tài khoản MSmart để dùng thiết bị trong nhà với {name}.</p>
<form method="post" action="/oauth/authorize" autocomplete="on">{hidden}
<input type="hidden" name="exp" value="{exp}"><input type="hidden" name="sig" value="{sig}">
<label for="email">Email</label><input id="email" name="email" type="email" required autocomplete="username" value="{email}">
<label for="password">Mật khẩu</label><input id="password" name="password" type="password" required autocomplete="current-password">
{err}<button type="submit">Đăng nhập và cho phép</button></form>
<p class="note">Khi đăng nhập, bạn cho phép {name} xem và điều khiển các thiết bị MSmart của bạn. Bạn có thể huỷ liên kết bất cứ lúc nào trong ứng dụng Google Home.</p>"#,
            name = c.name,
            email = esc(email),
        )),
    )
}

pub async fn authorize_page(State(st): State<AppState>, Query(q): Query<AuthorizeQuery>) -> Response {
    match check(&q) {
        Ok(c) => login_page(&st, &q, c, "", None),
        Err(e) => error_page(e),
    }
}

/// Tất cả là chuỗi (form-urlencoded); `exp` tự đổi sang số.
#[derive(Deserialize)]
pub struct AuthorizeForm {
    #[serde(default)]
    client_id: String,
    #[serde(default)]
    redirect_uri: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    scope: String,
    #[serde(default)]
    response_type: String,
    #[serde(default)]
    email: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    exp: String,
    #[serde(default)]
    sig: String,
}

/// Trình duyệt gửi Origin khác máy chủ này = form bị gửi từ trang khác (login CSRF) → từ chối.
fn same_origin(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) else { return true };
    if origin == "null" {
        return false;
    }
    let host = headers.get("x-forwarded-host").or_else(|| headers.get(header::HOST)).and_then(|v| v.to_str().ok()).unwrap_or_default();
    origin.split("://").nth(1).is_some_and(|o| o.eq_ignore_ascii_case(host))
}

pub async fn authorize_submit(
    State(st): State<AppState>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    headers: HeaderMap,
    Form(f): Form<AuthorizeForm>,
) -> Response {
    let q = AuthorizeQuery { client_id: f.client_id, redirect_uri: f.redirect_uri, state: f.state, scope: f.scope, response_type: f.response_type };
    let exp: i64 = f.exp.parse().unwrap_or(0);
    let c = match check(&q) {
        Ok(c) => c,
        Err(e) => return error_page(e),
    };
    if !same_origin(&headers) || exp < Utc::now().timestamp() || !ct_eq(&sign(&st.jwt_secret, &q, exp), &f.sig) {
        return error_page("Phiên đăng nhập đã hết hạn. Hãy bắt đầu lại từ ứng dụng Google Home.");
    }

    // Cùng giới hạn tốc độ với đăng nhập trong app.
    let ip = peer_ip(&st, &headers, peer);
    let email = f.email.trim().to_lowercase();
    let (ip_key, acct_key) = (format!("login-ip:{ip}"), format!("login-acct:{email}"));
    if st.limiter.check(&ip_key, LOGIN_FAIL_PER_IP, LOGIN_WINDOW).is_err() || st.limiter.check(&acct_key, LOGIN_FAIL_PER_ACCOUNT, LOGIN_WINDOW).is_err() {
        return login_page(&st, &q, c, &email, Some("Thử quá nhiều lần. Vui lòng đợi khoảng 15 phút rồi thử lại."));
    }
    let user = match verify_login(&st, &email, f.password).await {
        Ok(Some(u)) => u,
        Ok(None) => {
            st.limiter.record(&ip_key);
            st.limiter.record(&acct_key);
            tracing::warn!(%ip, "oauth login failed");
            return login_page(&st, &q, c, &email, Some("Email hoặc mật khẩu không đúng."));
        }
        Err(e) => {
            tracing::error!("oauth login: {e:?}");
            return error_page("Máy chủ đang gặp sự cố. Vui lòng thử lại sau.");
        }
    };
    st.limiter.clear(&acct_key);

    let code = auth::random_token("ac");
    let ins = sqlx::query("INSERT INTO oauth_codes (code_hash, client_id, user_id, redirect_uri, scope, expires_at) VALUES ($1,$2,$3,$4,$5,$6)")
        .bind(auth::hash_token(&code))
        .bind(&c.id)
        .bind(user)
        .bind(&q.redirect_uri)
        .bind(&q.scope)
        .bind(Utc::now() + Duration::minutes(CODE_TTL_MIN))
        .execute(&st.db)
        .await;
    if let Err(e) = ins {
        tracing::error!("oauth code insert: {e}");
        return error_page("Máy chủ đang gặp sự cố. Vui lòng thử lại sau.");
    }
    tracing::info!(%user, client = %c.id, "oauth: account linking authorized");
    let mut r = Redirect::to(&format!("{}?code={}&state={}", q.redirect_uri, enc(&code), enc(&q.state))).into_response();
    r.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    r
}

/// Some(user) khi đúng email + mật khẩu. Email không tồn tại vẫn băm một lần để không lộ email nào có tài khoản.
async fn verify_login(st: &AppState, email: &str, password: String) -> ApiResult<Option<Uuid>> {
    if email.is_empty() || email.len() > 254 || password.len() > 256 {
        return Ok(None);
    }
    let row: Option<(Uuid, String)> = sqlx::query_as("SELECT id, password_hash FROM users WHERE lower(email) = lower($1)").bind(email).fetch_optional(&st.db).await?;
    Ok(match row {
        Some((id, hash)) => auth::verify_password(password, hash).await.then_some(id),
        None => {
            auth::verify_password(password, st.dummy_hash.as_ref().clone()).await;
            None
        }
    })
}

// ───────────────────────── /oauth/token ─────────────────────────

#[derive(Deserialize)]
pub struct TokenForm {
    #[serde(default)]
    grant_type: String,
    code: Option<String>,
    redirect_uri: Option<String>,
    refresh_token: Option<String>,
    client_id: Option<String>,
    client_secret: Option<String>,
}

fn oauth_err(status: StatusCode, error: &str) -> Response {
    let mut r = (status, Json(json!({ "error": error }))).into_response();
    r.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    if status == StatusCode::UNAUTHORIZED {
        r.headers_mut().insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Basic realm=\"msmart\""));
    }
    r
}

/// Client gửi id/secret trong body (mặc định của Google) hoặc HTTP Basic (tuỳ chọn trong Developer Console).
fn client_auth(headers: &HeaderMap, f: &TokenForm) -> Option<&'static Client> {
    let basic = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Basic "))
        .and_then(|b| B64.decode(b.trim()).ok())
        .and_then(|b| String::from_utf8(b).ok())
        .and_then(|s| s.split_once(':').map(|(a, b)| (a.to_string(), b.to_string())));
    let (id, secret) = basic.or_else(|| Some((f.client_id.clone()?, f.client_secret.clone()?)))?;
    let c = client(&id)?;
    ct_eq(&auth::hash_token(&secret), &c.secret_hash).then_some(c)
}

async fn issue_access(st: &AppState, grant: Uuid) -> ApiResult<String> {
    let token = auth::random_token("at");
    sqlx::query("INSERT INTO oauth_tokens (token_hash, grant_id, expires_at) VALUES ($1,$2,$3)")
        .bind(auth::hash_token(&token))
        .bind(grant)
        .bind(Utc::now() + Duration::seconds(ACCESS_TTL_SECS))
        .execute(&st.db)
        .await?;
    Ok(token)
}

fn token_ok(body: serde_json::Value) -> Response {
    let mut r = Json(body).into_response();
    r.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    r.headers_mut().insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    r
}

pub async fn token(State(st): State<AppState>, headers: HeaderMap, Form(f): Form<TokenForm>) -> Response {
    let Some(c) = client_auth(&headers, &f) else {
        tracing::warn!("oauth token: invalid client credentials");
        return oauth_err(StatusCode::UNAUTHORIZED, "invalid_client");
    };
    let r = match f.grant_type.as_str() {
        "authorization_code" => exchange_code(&st, c, &f).await,
        "refresh_token" => refresh(&st, c, &f).await,
        _ => return oauth_err(StatusCode::BAD_REQUEST, "unsupported_grant_type"),
    };
    match r {
        Ok(Some(body)) => token_ok(body),
        Ok(None) => oauth_err(StatusCode::BAD_REQUEST, "invalid_grant"),
        Err(e) => {
            tracing::error!("oauth token: {e:?}");
            oauth_err(StatusCode::INTERNAL_SERVER_ERROR, "server_error")
        }
    }
}

/// None = invalid_grant (mã sai/hết hạn/đã dùng, sai client hoặc redirect_uri).
async fn exchange_code(st: &AppState, c: &Client, f: &TokenForm) -> ApiResult<Option<serde_json::Value>> {
    let Some(code) = f.code.as_deref() else { return Ok(None) };
    let hash = auth::hash_token(code);
    let mut tx = st.db.begin().await?;
    let row: Option<(String, Uuid, String, String, chrono::DateTime<Utc>, Option<chrono::DateTime<Utc>>, Option<Uuid>)> =
        sqlx::query_as("SELECT client_id, user_id, redirect_uri, scope, expires_at, used_at, grant_id FROM oauth_codes WHERE code_hash = $1 FOR UPDATE")
            .bind(&hash)
            .fetch_optional(&mut *tx)
            .await?;
    let Some((client_id, user, redirect, scope, expires, used, prev_grant)) = row else { return Ok(None) };
    if used.is_some() {
        // Mã bị dùng lại (có thể đã lộ): thu hồi luôn liên kết đã cấp từ mã này (RFC 6749 §4.1.2).
        if let Some(g) = prev_grant {
            sqlx::query("UPDATE oauth_grants SET revoked_at = now() WHERE id = $1").bind(g).execute(&mut *tx).await?;
            sqlx::query("DELETE FROM oauth_tokens WHERE grant_id = $1").bind(g).execute(&mut *tx).await?;
            tracing::warn!(%user, grant = %g, "oauth: authorization code reused — grant revoked");
        }
        tx.commit().await?;
        return Ok(None);
    }
    if client_id != c.id || expires < Utc::now() || f.redirect_uri.as_deref() != Some(redirect.as_str()) {
        return Ok(None);
    }
    let refresh = auth::random_token("rt");
    let grant: Uuid = sqlx::query_scalar("INSERT INTO oauth_grants (client_id, user_id, scope, refresh_hash) VALUES ($1,$2,$3,$4) RETURNING id")
        .bind(&c.id)
        .bind(user)
        .bind(&scope)
        .bind(auth::hash_token(&refresh))
        .fetch_one(&mut *tx)
        .await?;
    sqlx::query("UPDATE oauth_codes SET used_at = now(), grant_id = $2 WHERE code_hash = $1").bind(&hash).bind(grant).execute(&mut *tx).await?;
    tx.commit().await?;
    let access = issue_access(st, grant).await?;
    tracing::info!(%user, client = %c.id, %grant, "oauth: account linked");
    Ok(Some(json!({"token_type": "Bearer", "access_token": access, "refresh_token": refresh, "expires_in": ACCESS_TTL_SECS})))
}

/// Refresh token không xoay vòng (khuyến nghị "persistent linking" của Google): chỉ cấp access token mới.
async fn refresh(st: &AppState, c: &Client, f: &TokenForm) -> ApiResult<Option<serde_json::Value>> {
    let Some(rt) = f.refresh_token.as_deref() else { return Ok(None) };
    let grant: Option<Uuid> = sqlx::query_scalar(
        "UPDATE oauth_grants SET last_used_at = now() WHERE refresh_hash = $1 AND client_id = $2 AND revoked_at IS NULL RETURNING id",
    )
    .bind(auth::hash_token(rt))
    .bind(&c.id)
    .fetch_optional(&st.db)
    .await?;
    let Some(grant) = grant else { return Ok(None) };
    let access = issue_access(st, grant).await?;
    Ok(Some(json!({"token_type": "Bearer", "access_token": access, "expires_in": ACCESS_TTL_SECS})))
}

// ───────────────────────── dùng access token ─────────────────────────

/// Extractor cho các endpoint Google gọi bằng `Authorization: Bearer <access_token>` (fulfillment SYNC/QUERY/EXECUTE).
pub struct OAuthUser {
    pub user_id: Uuid,
    #[allow(dead_code)] // sau này có thêm client khác ngoài Google
    pub client_id: String,
    pub grant_id: Uuid,
}

#[async_trait]
impl FromRequestParts<AppState> for OAuthUser {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, st: &AppState) -> Result<Self, ApiError> {
        let token = auth::bearer(&parts.headers).ok_or(ApiError::Unauthorized)?;
        let row: Option<(Uuid, String, Uuid)> = sqlx::query_as(
            "SELECT g.user_id, g.client_id, g.id FROM oauth_tokens t JOIN oauth_grants g ON g.id = t.grant_id
              WHERE t.token_hash = $1 AND t.expires_at > now() AND g.revoked_at IS NULL",
        )
        .bind(auth::hash_token(&token))
        .fetch_optional(&st.db)
        .await?;
        let (user_id, client_id, grant_id) = row.ok_or(ApiError::Unauthorized)?;
        Ok(OAuthUser { user_id, client_id, grant_id })
    }
}

/// Dọn mã/token hết hạn (gọi định kỳ). Grant bị thu hồi giữ lại 30 ngày để tra cứu.
pub async fn purge(st: &AppState) {
    let q = [
        "DELETE FROM oauth_codes WHERE expires_at < now() - interval '1 day'",
        "DELETE FROM oauth_tokens WHERE expires_at < now()",
        "DELETE FROM oauth_grants WHERE revoked_at < now() - interval '30 days'",
    ];
    for s in q {
        if let Err(e) = sqlx::query(s).execute(&st.db).await {
            tracing::warn!("oauth purge: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        assert!(ct_eq("abc", "abc") && !ct_eq("abc", "abd") && !ct_eq("ab", "abc"));
        assert_eq!(esc(r#"<a href="x">'&"#), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;");
        assert_eq!(enc("a b/c?d=e&f"), "a%20b%2Fc%3Fd%3De%26f");
    }

    #[test]
    fn signature_binds_every_parameter() {
        let q = AuthorizeQuery { client_id: "g".into(), redirect_uri: "https://r".into(), state: "s".into(), scope: "".into(), response_type: "code".into() };
        let base = sign(b"k", &q, 100);
        assert_eq!(base, sign(b"k", &q, 100));
        let mut q2 = q.clone();
        q2.redirect_uri = "https://evil".into();
        assert_ne!(base, sign(b"k", &q2, 100));
        let mut q3 = q.clone();
        q3.state = "s2".into();
        assert_ne!(base, sign(b"k", &q3, 100));
        assert_ne!(base, sign(b"k", &q, 101));
        assert_ne!(base, sign(b"other", &q, 100));
    }

    #[test]
    fn origin_check() {
        let mut h = HeaderMap::new();
        h.insert(header::HOST, "api.example.com".parse().unwrap());
        assert!(same_origin(&h), "không có Origin (một số trình duyệt) vẫn cho qua — chữ ký form đã ràng buộc tham số");
        h.insert(header::ORIGIN, "https://api.example.com".parse().unwrap());
        assert!(same_origin(&h));
        h.insert(header::ORIGIN, "https://evil.example".parse().unwrap());
        assert!(!same_origin(&h));
        h.insert(header::ORIGIN, "null".parse().unwrap());
        assert!(!same_origin(&h));
    }
}
