mod access;
mod account;
mod alerts;
mod automation;
mod camera;
mod auth;
mod client_ws;
mod error;
mod gateway_ws;
mod gsa;
mod homegraph;
mod google;
mod hub;
mod oauth;
mod presence;
mod push;
mod rules;
mod ratelimit;
mod routes;
mod speak;
mod sso;

use std::sync::Arc;

use sqlx::postgres::PgPoolOptions;
use tracing_subscriber::EnvFilter;

#[derive(Clone)]
pub struct AppState {
    pub db: sqlx::PgPool,
    pub jwt_secret: Arc<Vec<u8>>,
    pub hub: Arc<hub::Hub>,
    pub limiter: Arc<ratelimit::Limiter>,
    /// Header chứa IP thật của client khi chạy sau proxy tin cậy (vd CF-Connecting-IP); xem ratelimit::client_ip.
    pub ip_header: Option<axum::http::HeaderName>,
    /// Băm giả để đồng đều thời gian phản hồi đăng nhập khi email không tồn tại.
    pub dummy_hash: Arc<String>,
    /// Thông báo đẩy FCM; None nếu chưa cấu hình FCM_SERVICE_ACCOUNT_FILE.
    pub push: Arc<Option<push::Fcm>>,
    /// Google HomeGraph (Report State + Request Sync); None nếu chưa cấu hình GOOGLE_HOMEGRAPH_SA_FILE.
    pub homegraph: Arc<Option<homegraph::HomeGraph>>,
    /// Đăng nhập bằng Google / Apple (xác minh ID token).
    pub sso: Arc<sso::Sso>,
    /// Sign in with Apple REST API (thu hồi token khi xoá tài khoản); None nếu chưa cấu hình khoá .p8.
    pub apple: Arc<Option<sso::AppleApi>>,
    /// Lần báo gần nhất theo (thiết bị, loại sự kiện) để giới hạn tần suất cảnh báo.
    pub alert_seen: Arc<dashmap::DashMap<(uuid::Uuid, alerts::Event), std::time::Instant>>,
    /// Lệnh gần nhất do luật thiết bị phát theo (thiết bị, gang) → (trạng thái, lúc gửi): để phân biệt bản tin phản hồi, không nối chuỗi luật `link`.
    pub rule_cmds: Arc<dashmap::DashMap<(uuid::Uuid, String), (String, std::time::Instant)>>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        // Giờ trong log theo múi giờ của container (TZ, mặc định Asia/Ho_Chi_Minh trong docker-compose), có kèm độ lệch (+07:00).
        .with_timer(tracing_subscriber::fmt::time::ChronoLocal::rfc_3339())
        .init();

    let database_url = std::env::var("DATABASE_URL")?;
    let jwt_secret = std::env::var("JWT_SECRET")?;
    anyhow::ensure!(jwt_secret.len() >= 32, "JWT_SECRET must be at least 32 bytes");
    let bind = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());

    let db = PgPoolOptions::new().max_connections(10).connect(&database_url).await?;
    sqlx::migrate!("./migrations").run(&db).await?;

    let ip_header = match std::env::var("TRUSTED_IP_HEADER") {
        Ok(h) if !h.trim().is_empty() => Some(axum::http::HeaderName::from_bytes(h.trim().as_bytes())?),
        _ => None,
    };
    match &ip_header {
        Some(h) => tracing::info!("client IP taken from header {h} (backend must only be reachable via the trusted proxy)"),
        None => tracing::info!("client IP taken from the TCP peer address (TRUSTED_IP_HEADER not set)"),
    }

    let state = AppState {
        db,
        jwt_secret: Arc::new(jwt_secret.into_bytes()),
        hub: Arc::new(hub::Hub::default()),
        limiter: Arc::new(ratelimit::Limiter::default()),
        ip_header,
        dummy_hash: Arc::new(auth::dummy_hash().await),
        push: Arc::new(push::Fcm::from_env()),
        homegraph: Arc::new(homegraph::HomeGraph::from_env()),
        sso: Arc::new(sso::Sso::from_env()),
        apple: Arc::new(sso::AppleApi::from_env()),
        alert_seen: Arc::new(dashmap::DashMap::new()),
        rule_cmds: Arc::new(dashmap::DashMap::new()),
    };
    if state.push.is_none() {
        tracing::info!("push: FCM chưa cấu hình (đặt FCM_SERVICE_ACCOUNT_FILE để bật); cảnh báo vẫn lưu và đẩy realtime tới app đang mở");
    }

    // Dọn nền: bộ đếm giới hạn tốc độ (5 phút) và refresh token hết hạn (1 giờ).
    {
        let st = state.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(300));
            let mut n = 0u32;
            loop {
                tick.tick().await;
                st.limiter.gc();
                if n % 12 == 0 {
                    auth::purge_expired(&st).await;
                    alerts::purge_old(&st).await;
                    oauth::purge(&st).await;
                }
                n = n.wrapping_add(1);
            }
        });
    }

    tokio::spawn(automation::scheduler(state.clone()));
    tokio::spawn(rules::runner(state.clone()));

    let app = routes::router(state).layer(tower_http::trace::TraceLayer::new_for_http());

    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!("listening on {bind}");
    axum::serve(listener, app.into_make_service_with_connect_info::<std::net::SocketAddr>()).await?;
    Ok(())
}
