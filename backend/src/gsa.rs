//! Service account Google: đổi JWT (RS256, ký bằng private key trong file JSON) lấy access token OAuth2 theo một scope,
//! giữ token trong bộ nhớ tới gần lúc hết hạn. Dùng chung cho FCM (push.rs) và HomeGraph (homegraph.rs).
use std::time::{Duration, Instant};

use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;

#[derive(Deserialize)]
struct File {
    project_id: String,
    client_email: String,
    private_key: String,
    #[serde(default = "default_token_uri")]
    token_uri: String,
}

fn default_token_uri() -> String {
    "https://oauth2.googleapis.com/token".into()
}

pub struct ServiceAccount {
    pub project_id: String,
    client_email: String,
    token_uri: String,
    key: EncodingKey,
    scope: &'static str,
    pub http: reqwest::Client,
    token: Mutex<Option<(String, Instant)>>,
}

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: u64,
    exp: u64,
}

impl ServiceAccount {
    /// Đọc file JSON service account; lỗi được ghi log với `tag` và trả None (tính năng tắt).
    pub fn load(path: &str, scope: &'static str, tag: &str) -> Option<ServiceAccount> {
        let raw = std::fs::read_to_string(path).map_err(|e| tracing::error!("{tag}: không đọc được {path}: {e}")).ok()?;
        let f: File = serde_json::from_str(&raw).map_err(|e| tracing::error!("{tag}: service account JSON không hợp lệ: {e}")).ok()?;
        let key = EncodingKey::from_rsa_pem(f.private_key.as_bytes()).map_err(|e| tracing::error!("{tag}: private_key không hợp lệ: {e}")).ok()?;
        let http = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().ok()?;
        Some(ServiceAccount { project_id: f.project_id, client_email: f.client_email, token_uri: f.token_uri, key, scope, http, token: Mutex::new(None) })
    }

    pub async fn access_token(&self) -> anyhow::Result<String> {
        let mut g = self.token.lock().await;
        if let Some((t, exp)) = g.as_ref() {
            if *exp > Instant::now() + Duration::from_secs(60) {
                return Ok(t.clone());
            }
        }
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
        let claims = Claims { iss: &self.client_email, scope: self.scope, aud: &self.token_uri, iat: now, exp: now + 3600 };
        let jwt = jsonwebtoken::encode(&Header::new(Algorithm::RS256), &claims, &self.key)?;
        let res: Value = self
            .http
            .post(&self.token_uri)
            .form(&[("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"), ("assertion", jwt.as_str())])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let token = res["access_token"].as_str().ok_or_else(|| anyhow::anyhow!("thiếu access_token"))?.to_owned();
        let ttl = res["expires_in"].as_u64().unwrap_or(3000);
        *g = Some((token.clone(), Instant::now() + Duration::from_secs(ttl)));
        Ok(token)
    }
}
