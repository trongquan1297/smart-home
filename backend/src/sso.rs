//! Đăng nhập bằng Google / Apple (song song với email + mật khẩu).
//!
//! App (hoặc trang liên kết Google Home) lấy **ID token** từ Google/Apple rồi gửi lên; backend tự kiểm tra:
//! chữ ký RS256 theo khoá công khai (JWKS) của nhà cung cấp, `iss`, `aud` ∈ client ID đã cấu hình, hạn dùng, `nonce`.
//! Sau đó cấp phiên của MSmart như đăng nhập thường (Google/Apple chỉ dùng để xác minh danh tính).
//!
//! Gắn tài khoản:
//!  1. Đã từng đăng nhập bằng (nhà cung cấp, `sub`) → đúng tài khoản đó.
//!  2. Email đã được nhà cung cấp xác minh trùng tài khoản email/mật khẩu có sẵn → gộp vào tài khoản đó, đồng thời
//!     XOÁ mật khẩu cũ và đăng xuất mọi phiên cũ: đăng ký bằng email không xác minh email, nên người khác có thể đã
//!     đăng ký trước bằng email này ("pre-hijacking"); chủ thật của email đã chứng minh qua Google/Apple.
//!  3. Còn lại → tạo tài khoản mới (không có mật khẩu).
//!
//! Cấu hình (để trống = tắt nhà cung cấp đó):
//!   GOOGLE_SIGNIN_CLIENT_IDS  client ID OAuth của app iOS, Android (web client dùng làm serverClientId) và web, phân tách bằng dấu phẩy
//!   APPLE_SIGNIN_CLIENT_IDS   bundle ID của app iOS (vd com.newmoon22.msmart) và Services ID cho web, phân tách bằng dấu phẩy
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{error::ApiError, AppState};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Google,
    Apple,
}

impl Provider {
    pub fn parse(s: &str) -> Option<Provider> {
        match s {
            "google" => Some(Provider::Google),
            "apple" => Some(Provider::Apple),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Provider::Google => "google",
            Provider::Apple => "apple",
        }
    }
    fn default_jwks_url(self) -> &'static str {
        match self {
            Provider::Google => "https://www.googleapis.com/oauth2/v3/certs",
            Provider::Apple => "https://appleid.apple.com/auth/keys",
        }
    }
    fn issuers(self) -> &'static [&'static str] {
        match self {
            Provider::Google => &["https://accounts.google.com", "accounts.google.com"],
            Provider::Apple => &["https://appleid.apple.com"],
        }
    }
}

/// Danh tính đã xác minh.
#[derive(Debug, Clone, PartialEq)]
pub struct Identity {
    pub provider: Provider,
    pub sub: String,
    pub email: Option<String>,
    pub email_verified: bool,
    pub name: Option<String>,
    /// `aud` của ID token (client ID / bundle ID đã cấp token): Apple cần nó để đổi mã ủy quyền và thu hồi token.
    pub client_id: String,
}

#[derive(Deserialize)]
struct Claims {
    sub: String,
    #[serde(default)]
    email: Option<String>,
    /// Google: bool; Apple: bool hoặc chuỗi "true"/"false".
    #[serde(default)]
    email_verified: Option<Value>,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    aud: Value,
}

struct Jwks {
    keys: Vec<(String, DecodingKey)>,
    fetched: Instant,
}

struct ProviderCfg {
    client_ids: Vec<String>,
    jwks_url: String,
    jwks: Mutex<Option<Jwks>>,
}

pub struct Sso {
    google: ProviderCfg,
    apple: ProviderCfg,
    /// Client web Google / Services ID Apple cho nút đăng nhập trên trang liên kết Google Home (cũng được chấp nhận làm `aud`).
    web_google: Option<String>,
    web_apple: Option<String>,
    http: reqwest::Client,
}

const JWKS_TTL: Duration = Duration::from_secs(3600);
/// Gặp `kid` lạ thì tải lại JWKS, nhưng không quá 1 lần/phút (token giả với kid ngẫu nhiên không làm mình spam Google/Apple).
const JWKS_MIN_REFRESH: Duration = Duration::from_secs(60);

fn ids(var: &str) -> Vec<String> {
    std::env::var(var).unwrap_or_default().split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

impl Sso {
    pub fn from_env() -> Sso {
        let one = |v: &str| std::env::var(v).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        let (wg, wa) = (one("GOOGLE_SIGNIN_WEB_CLIENT_ID"), one("APPLE_SIGNIN_WEB_SERVICE_ID"));
        let (mut g, mut a) = (ids("GOOGLE_SIGNIN_CLIENT_IDS"), ids("APPLE_SIGNIN_CLIENT_IDS"));
        g.extend(wg.clone().filter(|w| !g.contains(w)));
        a.extend(wa.clone().filter(|w| !a.contains(w)));
        let mut s = Sso::new(g, a);
        s.web_google = wg;
        s.web_apple = wa;
        // CHỈ để thử nghiệm với máy chủ JWKS giả lập (như HOMEGRAPH_URL); để trống khi chạy thật.
        for (p, var) in [(Provider::Google, "GOOGLE_SIGNIN_JWKS_URL"), (Provider::Apple, "APPLE_SIGNIN_JWKS_URL")] {
            if let Some(u) = std::env::var(var).ok().filter(|u| !u.is_empty()) {
                tracing::warn!(provider = p.as_str(), url = %u, "sso: dùng JWKS thay thế (chỉ dành cho thử nghiệm)");
                match p {
                    Provider::Google => s.google.jwks_url = u,
                    Provider::Apple => s.apple.jwks_url = u,
                }
            }
        }
        s
    }

    pub fn new(google: Vec<String>, apple: Vec<String>) -> Sso {
        let s = Sso {
            google: ProviderCfg { client_ids: google, jwks_url: Provider::Google.default_jwks_url().into(), jwks: Mutex::new(None) },
            apple: ProviderCfg { client_ids: apple, jwks_url: Provider::Apple.default_jwks_url().into(), jwks: Mutex::new(None) },
            http: reqwest::Client::builder().timeout(Duration::from_secs(10)).build().expect("http client"),
            web_google: None,
            web_apple: None,
        };
        tracing::info!(google = s.enabled(Provider::Google), apple = s.enabled(Provider::Apple), "sso: đăng nhập Google/Apple");
        s
    }

    fn cfg(&self, p: Provider) -> &ProviderCfg {
        match p {
            Provider::Google => &self.google,
            Provider::Apple => &self.apple,
        }
    }

    pub fn enabled(&self, p: Provider) -> bool {
        !self.cfg(p).client_ids.is_empty()
    }

    pub fn web_google(&self) -> Option<&str> {
        self.web_google.as_deref()
    }

    pub fn web_apple(&self) -> Option<&str> {
        self.web_apple.as_deref()
    }

    #[cfg(test)]
    fn set_keys(&self, p: Provider, keys: Vec<(String, DecodingKey)>) {
        *self.cfg(p).jwks.lock().unwrap() = Some(Jwks { keys, fetched: Instant::now() });
    }

    async fn key(&self, p: Provider, kid: &str) -> anyhow::Result<DecodingKey> {
        let cfg = self.cfg(p);
        let stale = {
            let g = cfg.jwks.lock().unwrap();
            match g.as_ref() {
                Some(j) => {
                    if let Some((_, k)) = j.keys.iter().find(|(id, _)| id == kid) {
                        if j.fetched.elapsed() < JWKS_TTL {
                            return Ok(k.clone());
                        }
                    }
                    j.fetched.elapsed() >= JWKS_MIN_REFRESH
                }
                None => true,
            }
        };
        if stale {
            let v: Value = self.http.get(&cfg.jwks_url).send().await?.error_for_status()?.json().await?;
            let keys: Vec<(String, DecodingKey)> = v["keys"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|k| k["kty"] == "RSA")
                .filter_map(|k| Some((k["kid"].as_str()?.to_string(), DecodingKey::from_rsa_components(k["n"].as_str()?, k["e"].as_str()?).ok()?)))
                .collect();
            *cfg.jwks.lock().unwrap() = Some(Jwks { keys, fetched: Instant::now() });
        }
        let g = cfg.jwks.lock().unwrap();
        g.as_ref().and_then(|j| j.keys.iter().find(|(id, _)| id == kid)).map(|(_, k)| k.clone()).ok_or_else(|| anyhow::anyhow!("unknown kid"))
    }

    /// Kiểm tra ID token. `nonce`: giá trị gốc app đã tạo (Apple: app gửi sha256(nonce) cho Apple, token chứa bản băm).
    pub async fn verify(&self, p: Provider, id_token: &str, nonce: Option<&str>) -> Result<Identity, ApiError> {
        let cfg = self.cfg(p);
        if cfg.client_ids.is_empty() {
            return Err(ApiError::BadRequest(format!("{} sign-in is not enabled", p.as_str())));
        }
        if id_token.len() > 8192 {
            return Err(ApiError::Unauthorized);
        }
        let header = decode_header(id_token).map_err(|_| ApiError::Unauthorized)?;
        if header.alg != Algorithm::RS256 {
            return Err(ApiError::Unauthorized);
        }
        let kid = header.kid.ok_or(ApiError::Unauthorized)?;
        let key = self.key(p, &kid).await.map_err(|e| {
            tracing::warn!(provider = p.as_str(), "sso: không lấy được khoá: {e:#}");
            ApiError::Unauthorized
        })?;
        let mut v = Validation::new(Algorithm::RS256);
        v.set_audience(&cfg.client_ids);
        v.set_issuer(p.issuers());
        v.leeway = 60;
        v.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        let c = decode::<Claims>(id_token, &key, &v).map_err(|_| ApiError::Unauthorized)?.claims;
        // Token có nonce thì bắt buộc app gửi đúng nonce gốc (chống dùng lại token bị lộ).
        if let Some(n) = c.nonce.as_deref() {
            let raw = nonce.ok_or(ApiError::Unauthorized)?;
            let hashed = hex::encode(Sha256::digest(raw.as_bytes()));
            if !(crate::oauth::ct_eq(n, &hashed) || crate::oauth::ct_eq(n, raw)) {
                return Err(ApiError::Unauthorized);
            }
        }
        if c.sub.is_empty() || c.sub.len() > 255 {
            return Err(ApiError::Unauthorized);
        }
        let email_verified = match &c.email_verified {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => s == "true",
            _ => false,
        };
        let email = c.email.map(|e| e.trim().to_lowercase()).filter(|e| e.contains('@') && e.len() <= 254);
        // aud có thể là chuỗi hoặc mảng; lấy giá trị nằm trong danh sách client ID đã cấu hình (thư viện đã kiểm tra là có).
        let client_id = match &c.aud {
            Value::String(a) => a.clone(),
            Value::Array(a) => a.iter().filter_map(Value::as_str).find(|a| cfg.client_ids.iter().any(|c| c == a)).unwrap_or_default().to_string(),
            _ => String::new(),
        };
        Ok(Identity { provider: p, sub: c.sub, email, email_verified, name: c.name.filter(|n| !n.trim().is_empty()), client_id })
    }
}

/// Sign in with Apple REST API (đổi mã ủy quyền lấy refresh token; thu hồi token khi người dùng xoá tài khoản —
/// App Store yêu cầu). Cần khoá "Sign in with Apple" (.p8) tạo trong Apple Developer:
///   APPLE_TEAM_ID, APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_KEY_FILE (đường dẫn file .p8). Thiếu = bỏ qua (đăng nhập vẫn chạy).
pub struct AppleApi {
    team_id: String,
    key_id: String,
    key: jsonwebtoken::EncodingKey,
    http: reqwest::Client,
}

impl AppleApi {
    pub fn from_env() -> Option<AppleApi> {
        let var = |k: &str| std::env::var(k).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let (team_id, key_id, file) = (var("APPLE_TEAM_ID")?, var("APPLE_SIGNIN_KEY_ID")?, var("APPLE_SIGNIN_KEY_FILE")?);
        let pem = std::fs::read(&file).map_err(|e| tracing::error!("apple: không đọc được {file}: {e}")).ok()?;
        let key = jsonwebtoken::EncodingKey::from_ec_pem(&pem).map_err(|e| tracing::error!("apple: khoá .p8 không hợp lệ: {e}")).ok()?;
        tracing::info!(team = %team_id, key = %key_id, "apple: REST API (đổi mã, thu hồi token) đã bật");
        Some(AppleApi { team_id, key_id, key, http: reqwest::Client::builder().timeout(Duration::from_secs(10)).build().ok()? })
    }

    /// client_secret: JWT ES256 ký bằng khoá .p8 (iss = Team ID, sub = client ID, aud = appleid.apple.com).
    fn client_secret(&self, client_id: &str) -> anyhow::Result<String> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
        let mut h = jsonwebtoken::Header::new(Algorithm::ES256);
        h.kid = Some(self.key_id.clone());
        let claims = serde_json::json!({"iss": self.team_id, "iat": now, "exp": now + 300, "aud": "https://appleid.apple.com", "sub": client_id});
        Ok(jsonwebtoken::encode(&h, &claims, &self.key)?)
    }

    /// Đổi authorizationCode (app nhận khi đăng nhập Apple, dùng một lần trong vài phút) lấy refresh token.
    pub async fn exchange(&self, client_id: &str, code: &str) -> anyhow::Result<String> {
        let secret = self.client_secret(client_id)?;
        let form = [("client_id", client_id), ("client_secret", secret.as_str()), ("code", code), ("grant_type", "authorization_code")];
        let r = self.http.post("https://appleid.apple.com/auth/token").form(&form).send().await?;
        let status = r.status();
        let v: Value = r.json().await.unwrap_or_default();
        if !status.is_success() {
            anyhow::bail!("HTTP {status}: {}", v["error"].as_str().unwrap_or("?"));
        }
        v["refresh_token"].as_str().map(str::to_string).ok_or_else(|| anyhow::anyhow!("thiếu refresh_token"))
    }

    /// Thu hồi refresh token: Apple gỡ liên kết app khỏi Apple ID của người dùng.
    pub async fn revoke(&self, client_id: &str, refresh_token: &str) -> anyhow::Result<()> {
        let secret = self.client_secret(client_id)?;
        let form = [("client_id", client_id), ("client_secret", secret.as_str()), ("token", refresh_token), ("token_type_hint", "refresh_token")];
        let r = self.http.post("https://appleid.apple.com/auth/revoke").form(&form).send().await?;
        if !r.status().is_success() {
            anyhow::bail!("HTTP {}", r.status());
        }
        Ok(())
    }
}

/// Sau khi đăng nhập Apple: lưu refresh token để sau này thu hồi được khi xoá tài khoản (lỗi chỉ ghi log).
pub async fn store_apple_code(st: &AppState, id: &Identity, code: &str) {
    let Some(api) = st.apple.as_ref() else { return };
    match api.exchange(&id.client_id, code).await {
        Ok(rt) => {
            let r = sqlx::query("UPDATE user_identities SET apple_refresh_token = $3, apple_client_id = $4 WHERE provider = $1 AND subject = $2")
                .bind(id.provider.as_str())
                .bind(&id.sub)
                .bind(rt)
                .bind(&id.client_id)
                .execute(&st.db)
                .await;
            if let Err(e) = r {
                tracing::warn!("apple: lưu refresh token: {e}");
            }
        }
        Err(e) => tracing::warn!("apple: đổi mã ủy quyền thất bại: {e:#}"),
    }
}

/// Tìm hoặc tạo tài khoản cho danh tính đã xác minh. `name_hint`: tên app gửi kèm (Apple chỉ trả tên ở lần đầu).
pub async fn resolve_user(st: &AppState, id: &Identity, name_hint: Option<&str>) -> Result<Uuid, ApiError> {
    let mut tx = st.db.begin().await?;
    if let Some(u) = sqlx::query_scalar::<_, Uuid>("SELECT user_id FROM user_identities WHERE provider = $1 AND subject = $2")
        .bind(id.provider.as_str())
        .bind(&id.sub)
        .fetch_optional(&mut *tx)
        .await?
    {
        sqlx::query("UPDATE user_identities SET last_login_at = now(), email = COALESCE($3, email) WHERE provider = $1 AND subject = $2")
            .bind(id.provider.as_str())
            .bind(&id.sub)
            .bind(&id.email)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(u);
    }

    let existing = match (&id.email, id.email_verified) {
        (Some(e), true) => sqlx::query_as::<_, (Uuid, bool)>("SELECT id, password_hash <> '' FROM users WHERE lower(email) = lower($1) FOR UPDATE")
            .bind(e)
            .fetch_optional(&mut *tx)
            .await?,
        _ => None,
    };
    let (user, merged_password) = match existing {
        Some((u, had_password)) => {
            if had_password {
                sqlx::query("UPDATE users SET password_hash = '' WHERE id = $1").bind(u).execute(&mut *tx).await?;
            }
            (u, had_password)
        }
        None => {
            // Email chưa xác minh / bị ẩn hoặc đã thuộc tài khoản khác → không dùng làm email đăng nhập.
            let email = match &id.email {
                Some(e) if id.email_verified => {
                    let taken: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower($1))").bind(e).fetch_one(&mut *tx).await?;
                    if taken {
                        placeholder_email(id)
                    } else {
                        e.clone()
                    }
                }
                _ => placeholder_email(id),
            };
            let name = display_name(id, name_hint);
            let u: Uuid = sqlx::query_scalar("INSERT INTO users (email, password_hash, name) VALUES ($1, '', $2) RETURNING id")
                .bind(&email)
                .bind(&name)
                .fetch_one(&mut *tx)
                .await?;
            (u, false)
        }
    };
    sqlx::query("INSERT INTO user_identities (provider, subject, user_id, email) VALUES ($1, $2, $3, $4)")
        .bind(id.provider.as_str())
        .bind(&id.sub)
        .bind(user)
        .bind(&id.email)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    if merged_password {
        // Mật khẩu cũ có thể do người khác đặt: thu hồi mọi phiên đăng nhập bằng mật khẩu đó.
        crate::auth::revoke_all(st, user).await?;
        tracing::warn!(%user, provider = id.provider.as_str(), "sso: gộp vào tài khoản email có sẵn, đã xoá mật khẩu cũ và thu hồi các phiên cũ");
    } else {
        tracing::info!(%user, provider = id.provider.as_str(), "sso: liên kết danh tính mới");
    }
    Ok(user)
}

/// Email nội bộ không gửi thư được (miền .invalid), chỉ để giữ ràng buộc email duy nhất.
fn placeholder_email(id: &Identity) -> String {
    let h = hex::encode(Sha256::digest(format!("{}:{}", id.provider.as_str(), id.sub).as_bytes()));
    format!("{}-{}@users.msmart.invalid", id.provider.as_str(), &h[..16])
}

fn display_name(id: &Identity, hint: Option<&str>) -> String {
    let pick = hint.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).or_else(|| id.name.clone()).or_else(|| {
        id.email.as_deref().and_then(|e| e.split('@').next()).filter(|s| !s.is_empty()).map(str::to_string)
    });
    let n = pick.unwrap_or_else(|| match id.provider {
        Provider::Google => "Người dùng Google".into(),
        Provider::Apple => "Người dùng Apple".into(),
    });
    n.chars().take(100).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{encode, EncodingKey, Header};
    use serde_json::json;

    // Khoá RSA CHỈ dùng cho test (sinh bằng openssl), không dùng ở đâu khác.
    const TEST_KEY: &str = include_str!("../testdata/sso_test_key.pem");
    const TEST_N: &str = include_str!("../testdata/sso_test_key.n");
    const TEST_E: &str = "AQAB";

    fn sso() -> Sso {
        let s = Sso::new(vec!["web-client.apps.googleusercontent.com".into()], vec!["com.newmoon22.msmart".into()]);
        let k = DecodingKey::from_rsa_components(TEST_N.trim(), TEST_E).unwrap();
        s.set_keys(Provider::Google, vec![("k1".into(), k.clone())]);
        s.set_keys(Provider::Apple, vec![("k1".into(), k)]);
        s
    }

    fn token(claims: Value, kid: &str) -> String {
        let mut h = Header::new(Algorithm::RS256);
        h.kid = Some(kid.into());
        encode(&h, &claims, &EncodingKey::from_rsa_pem(TEST_KEY.as_bytes()).unwrap()).unwrap()
    }

    fn now() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
    }

    fn google_claims() -> Value {
        json!({"iss": "https://accounts.google.com", "aud": "web-client.apps.googleusercontent.com", "sub": "111", "exp": now() + 600,
               "iat": now(), "email": "A@Example.com", "email_verified": true, "name": "An"})
    }

    #[tokio::test]
    async fn google_token_ok() {
        let id = sso().verify(Provider::Google, &token(google_claims(), "k1"), None).await.unwrap();
        assert_eq!(id.sub, "111");
        assert_eq!(id.email.as_deref(), Some("a@example.com"));
        assert!(id.email_verified);
    }

    #[tokio::test]
    async fn rejects_wrong_aud_iss_exp_and_unknown_kid() {
        let s = sso();
        let mut c = google_claims();
        c["aud"] = json!("someone-else");
        assert!(s.verify(Provider::Google, &token(c, "k1"), None).await.is_err(), "aud lạ");
        let mut c = google_claims();
        c["iss"] = json!("https://evil.example");
        assert!(s.verify(Provider::Google, &token(c, "k1"), None).await.is_err(), "iss lạ");
        let mut c = google_claims();
        c["exp"] = json!(now() - 3600);
        assert!(s.verify(Provider::Google, &token(c, "k1"), None).await.is_err(), "hết hạn");
        // Token Google không được dùng làm token Apple (khác iss/aud).
        assert!(s.verify(Provider::Apple, &token(google_claims(), "k1"), None).await.is_err());
        // Chữ ký sai: sửa phần payload.
        let t = token(google_claims(), "k1");
        let mut parts: Vec<&str> = t.split('.').collect();
        let other = token(json!({"iss": "https://accounts.google.com", "aud": "web-client.apps.googleusercontent.com", "sub": "222", "exp": now() + 600}), "k1");
        let p2 = other.split('.').nth(1).unwrap().to_string();
        parts[1] = &p2;
        assert!(s.verify(Provider::Google, &parts.join("."), None).await.is_err(), "chữ ký không khớp payload");
    }

    #[tokio::test]
    async fn apple_nonce_and_string_email_verified() {
        let s = sso();
        let raw = "nonce-raw-123";
        let c = json!({"iss": "https://appleid.apple.com", "aud": "com.newmoon22.msmart", "sub": "000123.abc", "exp": now() + 600,
                       "email": "x@privaterelay.appleid.com", "email_verified": "true", "nonce": hex::encode(Sha256::digest(raw.as_bytes()))});
        let t = token(c, "k1");
        assert!(s.verify(Provider::Apple, &t, None).await.is_err(), "thiếu nonce");
        assert!(s.verify(Provider::Apple, &t, Some("sai")).await.is_err(), "sai nonce");
        let id = s.verify(Provider::Apple, &t, Some(raw)).await.unwrap();
        assert!(id.email_verified);
    }

    #[tokio::test]
    async fn disabled_provider() {
        let s = Sso::new(vec![], vec![]);
        assert!(s.verify(Provider::Google, "x.y.z", None).await.is_err());
    }

    #[test]
    fn apple_client_secret_is_es256_jwt() {
        let api = AppleApi {
            team_id: "TEAM123".into(),
            key_id: "KEY123".into(),
            key: jsonwebtoken::EncodingKey::from_ec_pem(include_bytes!("../testdata/apple_test_key.p8")).unwrap(),
            http: reqwest::Client::new(),
        };
        let jwt = api.client_secret("com.newmoon22.msmart").unwrap();
        let h = decode_header(&jwt).unwrap();
        assert_eq!(h.alg, Algorithm::ES256);
        assert_eq!(h.kid.as_deref(), Some("KEY123"));
        let mut v = Validation::new(Algorithm::ES256);
        v.set_audience(&["https://appleid.apple.com"]);
        v.set_issuer(&["TEAM123"]);
        let key = DecodingKey::from_ec_pem(include_bytes!("../testdata/apple_test_key.pub")).unwrap();
        let c = decode::<Value>(&jwt, &key, &v).unwrap().claims;
        assert_eq!(c["sub"], "com.newmoon22.msmart");
    }

    #[test]
    fn names_and_placeholder() {
        let id = Identity { provider: Provider::Apple, sub: "s".into(), email: None, email_verified: false, name: None, client_id: String::new() };
        assert_eq!(display_name(&id, Some("  Bình ")), "Bình");
        assert_eq!(display_name(&id, None), "Người dùng Apple");
        assert!(placeholder_email(&id).ends_with("@users.msmart.invalid"));
    }
}
