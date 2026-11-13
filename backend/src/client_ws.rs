//! WebSocket realtime cho app: đẩy trạng thái thiết bị của một home.
//! Token lấy từ header Authorization hoặc ?token= (client WebSocket trên một số nền tảng không set được header).
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
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

#[derive(Deserialize)]
pub struct WsQuery {
    token: Option<String>,
}

pub async fn handler(
    State(st): State<AppState>,
    Path(hid): Path<Uuid>,
    Query(q): Query<WsQuery>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> ApiResult<Response> {
    let token = auth::bearer(&headers).or(q.token).ok_or(ApiError::Unauthorized)?;
    let (uid, exp) = auth::verify_claims(&st.jwt_secret, &token)?;
    access::require(&st.db, uid, hid, Role::Guest).await?;
    // Kết nối WebSocket không sống lâu hơn access token: hết hạn thì đóng, client làm mới token rồi nối lại.
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let ttl = std::time::Duration::from_secs(exp.saturating_sub(now));
    Ok(ws.on_upgrade(move |socket| session(st, hid, socket, ttl)))
}

async fn session(st: AppState, hid: Uuid, socket: WebSocket, ttl: std::time::Duration) {
    let mut rx = st.hub.subscribe(hid);
    let (mut sink, mut stream) = socket.split();
    let hello = json!({"type": "gateway", "online": st.hub.gateway_online(hid)}).to_string();
    if sink.send(Message::Text(hello)).await.is_err() {
        return;
    }
    let mut ping = tokio::time::interval(std::time::Duration::from_secs(30));
    let expiry = tokio::time::sleep(ttl);
    tokio::pin!(expiry);
    loop {
        tokio::select! {
            _ = &mut expiry => break,
            m = rx.recv() => match m {
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
