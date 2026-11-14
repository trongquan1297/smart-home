//! WebSocket realtime cho app: đẩy trạng thái thiết bị của một home.
//! Token lấy từ header Authorization hoặc ?token= (client WebSocket trên một số nền tảng không set được header).
use axum::{
    extract::{
        ws::{rejection::WebSocketUpgradeRejection, Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::HeaderMap,
    response::Response,
};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::broadcast::error::RecvError;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    auth,
    error::{ApiError, ApiResult},
    AppState,
};

/// Tín hiệu nội bộ (không gửi cho app): quyền của căn hộ này vừa đổi, mọi phiên WebSocket kiểm tra lại ngay.
pub const ACCESS_CHECK: &str = "{\"type\":\"access_check\"}";
/// Kiểm tra định kỳ để bắt kịp khách thuê hết hạn theo thời gian.
const RECHECK_EVERY: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Deserialize)]
pub struct WsQuery {
    token: Option<String>,
}

/// Yêu cầu nâng cấp WebSocket của client ĐÃ XÁC THỰC bị từ chối → ghi log nêu rõ header nhận được (không ghi token).
/// Nguyên nhân thường gặp: reverse proxy / load balancer không chuyển tiếp `Upgrade: websocket` + `Connection: Upgrade`,
/// hoặc đang dùng HTTP/2 tới backend. Không có log này, phía app chỉ thấy "mất kết nối" mà không biết vì sao.
pub fn upgrade_or_log(kind: &str, headers: &HeaderMap, ws: Result<WebSocketUpgrade, WebSocketUpgradeRejection>) -> ApiResult<WebSocketUpgrade> {
    ws.map_err(|e| {
        let h = |n: &str| headers.get(n).and_then(|v| v.to_str().ok()).unwrap_or("(thiếu)").to_owned();
        tracing::warn!(
            kind,
            reason = %e,
            connection = %h("connection"),
            upgrade = %h("upgrade"),
            sec_websocket_version = %h("sec-websocket-version"),
            sec_websocket_key_present = headers.contains_key("sec-websocket-key"),
            x_forwarded_for = %h("x-forwarded-for"),
            via = %h("via"),
            "WebSocket upgrade bị từ chối: proxy/LB có thể đã bỏ header Upgrade/Connection"
        );
        ApiError::BadRequest("websocket upgrade required".into())
    })
}

pub async fn handler(
    State(st): State<AppState>,
    Path(hid): Path<Uuid>,
    Query(q): Query<WsQuery>,
    headers: HeaderMap,
    ws: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> ApiResult<Response> {
    let token = auth::bearer(&headers).or(q.token).ok_or(ApiError::Unauthorized)?;
    let (uid, exp) = auth::verify_claims(&st.jwt_secret, &token)?;
    let role = access::require(&st.db, uid, hid, Role::Guest).await?;
    let ws = upgrade_or_log("app", &headers, ws)?;
    tracing::info!(home = %hid, user = %uid, "app WebSocket connected");
    // Kết nối WebSocket không sống lâu hơn access token: hết hạn thì đóng, client làm mới token rồi nối lại.
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let ttl = std::time::Duration::from_secs(exp.saturating_sub(now));
    Ok(ws.on_upgrade(move |socket| session(st, uid, hid, role, socket, ttl)))
}

async fn session(st: AppState, uid: Uuid, hid: Uuid, mut role: Role, socket: WebSocket, ttl: std::time::Duration) {
    let mut rx = st.hub.subscribe(hid);
    let (mut sink, mut stream) = socket.split();
    let hello = json!({"type": "gateway", "online": st.hub.gateway_online(hid)}).to_string();
    if sink.send(Message::Text(hello)).await.is_err() {
        return;
    }
    let mut ping = tokio::time::interval(std::time::Duration::from_secs(30));
    let expiry = tokio::time::sleep(ttl);
    tokio::pin!(expiry);
    let mut recheck = tokio::time::interval(RECHECK_EVERY);
    recheck.tick().await; // lần đầu trả về ngay
    loop {
        tokio::select! {
            _ = &mut expiry => break,
            _ = recheck.tick() => {
                match access::require(&st.db, uid, hid, Role::Guest).await {
                    Ok(r) => role = r,
                    Err(_) => {
                        let _ = sink.send(Message::Text(json!({"type": "access_revoked"}).to_string())).await;
                        break;
                    }
                }
            }
            m = rx.recv() => match m {
                Ok(text) if text == ACCESS_CHECK => {
                    match access::require(&st.db, uid, hid, Role::Guest).await {
                        Ok(r) => role = r,
                        Err(_) => {
                            let _ = sink.send(Message::Text(json!({"type": "access_revoked"}).to_string())).await;
                            break;
                        }
                    }
                }
                // Cảnh báo cảm biến là thông tin an ninh của gia đình: khách thuê và khách xem không nhận.
                Ok(text) if role < Role::Member && text.contains(r#""type":"alert""#) => {}
                Ok(text) => if sink.send(Message::Text(text)).await.is_err() { break },
                Err(RecvError::Lagged(_)) => {
                    // client chậm: báo refetch thay vì gửi bù
                    if sink.send(Message::Text(json!({"type": "devices_changed"}).to_string())).await.is_err() { break }
                }
                Err(RecvError::Closed) => break,
            },
            _ = ping.tick() => if sink.send(Message::Ping(Vec::new())).await.is_err() { break },
            inbound = stream.next() => match inbound {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                _ => {}
            },
        }
    }
}
