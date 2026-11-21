//! Kênh WebSocket giữa gateway (Pi) và cloud. Gateway chủ động kết nối ra ngoài (outbound) nên
//! Pi không cần public IP / mở port, đi xuyên NAT và qua được Cloudflare.
use axum::{
    extract::{
        ws::{rejection::WebSocketUpgradeRejection, Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::HeaderMap,
    response::Response,
};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use tokio::sync::{mpsc, Notify};
use uuid::Uuid;

use crate::{
    auth,
    error::{ApiError, ApiResult},
    AppState,
};

#[derive(Clone)]
struct Gw {
    id: Uuid,
    tenant_id: Uuid,
    home_id: Uuid,
    token_hash: String,
}

#[derive(Deserialize)]
struct CamState {
    camera_id: Uuid,
    online: bool,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum GwMsg {
    /// payload của zigbee2mqtt/bridge/devices
    Devices { devices: Vec<Value> },
    /// payload của zigbee2mqtt/<friendly_name>
    State { friendly_name: String, payload: Value },
    /// payload của zigbee2mqtt/<friendly_name>/availability, đã đổi thành bool
    Availability { friendly_name: String, online: bool },
    /// Trả lời yêu cầu matter_* của cloud (xem routes::matter_request)
    MatterReply { id: Uuid, info: Option<Value>, error: Option<String> },
    /// Gateway khai báo khả năng ngay sau khi kết nối (`z2m`, `cast`)
    Hello { caps: Vec<String> },
    /// Trả lời yêu cầu cast_scan (speak::scan)
    CastReply { id: Uuid, devices: Option<Value>, error: Option<String> },
    /// Trạng thái cho phép ghép thiết bị Zigbee mới (từ bridge/info)
    Permit { open: bool, seconds: u64 },
    /// Sự kiện ghép nối từ bridge/event: device_joined | device_interview | device_leave
    PairEvent { event: String, ieee: String, friendly_name: Option<String>, status: Option<String> },
    /// Addon camera trả lời yêu cầu cam_* (xem camera.rs). Chỉ các trường đã biết được chuyển tiếp.
    CamReply { id: Uuid, error: Option<String>, info: Option<Value>, devices: Option<Value>, sdp: Option<String>, jpeg: Option<String> },
    /// Addon camera vừa kết nối: các camera nó đang giữ.
    CamList { cameras: Vec<CamState> },
    CamStatus { camera_id: Uuid, online: bool },
    /// Addon trả lời yêu cầu pur_* (máy lọc nước Bluetooth, xem purifier.rs).
    PurReply { id: Uuid, error: Option<String>, info: Option<Value>, devices: Option<Value>, ok: Option<bool> },
    /// Sự kiện từ camera (hiện chỉ có "motion").
    CamEvent { camera_id: Uuid, kind: String },
    Ping,
}

pub async fn handler(State(st): State<AppState>, headers: HeaderMap, ws: Result<WebSocketUpgrade, WebSocketUpgradeRejection>) -> ApiResult<Response> {
    let token = auth::bearer(&headers).ok_or(ApiError::Unauthorized)?;
    let token_hash = auth::hash_token(&token);
    let row: Option<(Uuid, Uuid, Uuid)> =
        sqlx::query_as("SELECT id, tenant_id, home_id FROM gateways WHERE token_hash = $1")
            .bind(&token_hash)
            .fetch_optional(&st.db)
            .await?;
    let (id, tenant_id, home_id) = row.ok_or(ApiError::Unauthorized)?;
    let gw = Gw { id, tenant_id, home_id, token_hash };
    // IP nguồn (qua Cloudflare): phân biệt khi hai máy dùng chung một token gateway (đá nhau liên tục).
    let ip = headers.get("cf-connecting-ip").and_then(|v| v.to_str().ok()).unwrap_or("-").chars().take(45).collect::<String>();
    tracing::info!(gateway = %id, %ip, "gateway ws upgrade");
    let ws = crate::client_ws::upgrade_or_log("gateway", &headers, ws)?;
    Ok(ws.on_upgrade(move |socket| session(st, gw, socket)))
}

async fn session(st: AppState, gw: Gw, socket: WebSocket) {
    tracing::info!(gateway = %gw.id, home = %gw.home_id, "gateway connected");
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::channel::<String>(64);
    let kill = Arc::new(Notify::new());
    st.hub.register_gateway(gw.id, gw.home_id, tx.clone(), kill.clone());
    // Token có thể vừa bị thu hồi giữa lúc xác thực và lúc đăng ký → kiểm tra lại.
    let still_valid: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM gateways WHERE id = $1 AND token_hash = $2)")
        .bind(gw.id)
        .bind(&gw.token_hash)
        .fetch_one(&st.db)
        .await
        .unwrap_or(false);
    if !still_valid {
        st.hub.unregister_gateway(gw.id, &tx);
        return;
    }
    st.hub.publish(gw.home_id, json!({"type": "gateway", "online": true}).to_string());
    touch(&st, &gw).await;

    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            if sink.send(Message::Text(m)).await.is_err() {
                break;
            }
        }
    });

    loop {
        tokio::select! {
            _ = kill.notified() => {
                tracing::info!(gateway = %gw.id, "gateway kicked (token revoked or gateway removed)");
                break;
            }
            msg = stream.next() => match msg {
                Some(Ok(Message::Text(t))) => match serde_json::from_str::<GwMsg>(&t) {
                    Ok(m) => {
                        if let Err(e) = handle(&st, &gw, m).await {
                            tracing::warn!(gateway = %gw.id, "handle error: {e:?}");
                        }
                    }
                    Err(e) => tracing::warn!(gateway = %gw.id, "bad message: {e}"),
                },
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                _ => {}
            },
        }
    }

    writer.abort();
    st.hub.unregister_gateway(gw.id, &tx);
    if !st.hub.gateway_connected(gw.id) {
        crate::camera::on_gateway_gone(&st, gw.id, gw.home_id).await;
    }
    if !st.hub.gateway_online(gw.home_id) {
        st.hub.publish(gw.home_id, json!({"type": "gateway", "online": false}).to_string());
    }
    tracing::info!(gateway = %gw.id, "gateway disconnected");
}

async fn touch(st: &AppState, gw: &Gw) {
    let _ = sqlx::query("UPDATE gateways SET last_seen_at = now() WHERE id = $1")
        .bind(gw.id)
        .execute(&st.db)
        .await;
}

/// Phân loại thiết bị từ `exposes` của Zigbee2MQTT: light | switch | cover | sensor | purifier | other.
/// `purifier` = máy lọc nước Bluetooth do addon báo (có `filters`).
/// Dựa vào cấu trúc exposes chứ không dựa vào hãng, nên Aqara/Tuya/VSmart… dùng chung một đường xử lý.
fn kind_of(exposes: &[Value]) -> &'static str {
    let has_type = |t: &str| exposes.iter().any(|e| e.get("type").and_then(Value::as_str) == Some(t));
    let has_prop = |ps: &[&str]| {
        exposes.iter().any(|e| e.get("property").and_then(Value::as_str).is_some_and(|p| ps.contains(&p)))
    };
    if has_prop(&["filters"]) {
        "purifier"
    } else if has_type("light") {
        "light"
    } else if has_type("switch") {
        "switch"
    } else if has_type("cover") {
        "cover"
    } else if has_prop(&[
        "contact", "occupancy", "motion", "water_leak", "smoke", "temperature", "humidity", "pressure", "illuminance",
        "illuminance_lux", "vibration", "co2", "pm25", "soil_moisture", "gas",
    ]) {
        "sensor"
    } else {
        "other"
    }
}

async fn handle(st: &AppState, gw: &Gw, msg: GwMsg) -> ApiResult<()> {
    match msg {
        GwMsg::Ping => touch(st, gw).await,
        GwMsg::Hello { caps } => st.hub.set_caps(gw.id, caps.into_iter().filter(|c| c.len() <= 16).take(8).collect()),
        GwMsg::CastReply { id, devices, error } => st.hub.resolve(gw.id, id, json!({ "devices": devices, "error": error })),
        GwMsg::MatterReply { id, info, error } => st.hub.resolve(gw.id, id, json!({ "info": info, "error": error })),
        GwMsg::CamReply { id, error, info, devices, sdp, jpeg } => {
            st.hub.resolve(gw.id, id, json!({ "error": error, "info": info, "devices": devices, "sdp": sdp, "jpeg": jpeg }))
        }
        GwMsg::PurReply { id, error, info, devices, ok } => st.hub.resolve(gw.id, id, json!({ "error": error, "info": info, "devices": devices, "ok": ok })),
        GwMsg::CamList { cameras } => {
            let v: Vec<(Uuid, bool)> = cameras.iter().take(256).map(|c| (c.camera_id, c.online)).collect();
            crate::camera::on_list(st, gw.id, gw.home_id, &v).await?
        }
        GwMsg::CamStatus { camera_id, online } => crate::camera::on_status(st, gw.id, camera_id, online).await?,
        GwMsg::CamEvent { camera_id, kind } => {
            if kind == "motion" {
                crate::camera::on_motion(st, gw.id, camera_id).await?
            }
        }
        GwMsg::Permit { open, seconds } => {
            st.hub.publish(gw.home_id, json!({"type": "permit_join", "open": open, "seconds": seconds.min(254)}).to_string());
        }
        GwMsg::PairEvent { event, ieee, friendly_name, status } => {
            // Không tin dữ liệu gateway: chỉ chuyển tiếp các loại/độ dài đã biết.
            let short = |s: Option<String>| s.filter(|s| s.len() <= 64);
            if matches!(event.as_str(), "device_joined" | "device_interview" | "device_leave") && ieee.len() <= 64 {
                st.hub.publish(
                    gw.home_id,
                    json!({"type": "pair_event", "event": event, "ieee": ieee, "friendly_name": short(friendly_name), "status": short(status)}).to_string(),
                );
            }
        }
        GwMsg::Devices { devices } => {
            let mut keep: Vec<String> = Vec::new();
            for d in devices {
                if d.get("type").and_then(Value::as_str) == Some("Coordinator") {
                    continue;
                }
                let Some(ieee) = d.get("ieee_address").and_then(Value::as_str) else { continue };
                // Có trong danh sách = vẫn thuộc mạng Zigbee, kể cả khi Z2M chưa nạp xong `definition` (vừa khởi động,
                // đang interview): giữ lại, chỉ không cập nhật. Trước đây thiết bị như vậy bị xoá → mất tên/phòng/quy tắc.
                keep.push(ieee.to_owned());
                let (Some(fname), Some(def)) = (
                    d.get("friendly_name").and_then(Value::as_str),
                    d.get("definition").filter(|v| v.is_object()),
                ) else {
                    continue; // thiết bị chưa được interview xong / không hỗ trợ
                };
                let exposes = def.get("exposes").cloned().unwrap_or_else(|| json!([]));
                let kind = kind_of(exposes.as_array().map(Vec::as_slice).unwrap_or(&[]));
                sqlx::query(
                    "INSERT INTO devices (tenant_id, home_id, gateway_id, ieee_address, friendly_name, name, vendor, model, kind, exposes, description)
                     VALUES ($1,$2,$3,$4,$5,$5,$6,$7,$8,$9,$10)
                     ON CONFLICT (gateway_id, ieee_address) DO UPDATE SET
                       -- tên hiển thị đi theo tên Z2M, trừ khi người dùng đã tự đặt tên khác trong app
                       name = CASE WHEN devices.name = devices.friendly_name THEN EXCLUDED.friendly_name ELSE devices.name END,
                       friendly_name = EXCLUDED.friendly_name, vendor = EXCLUDED.vendor, model = EXCLUDED.model,
                       kind = EXCLUDED.kind, exposes = EXCLUDED.exposes, description = EXCLUDED.description",
                )
                .bind(gw.tenant_id)
                .bind(gw.home_id)
                .bind(gw.id)
                .bind(ieee)
                .bind(fname)
                .bind(def.get("vendor").and_then(Value::as_str))
                .bind(def.get("model").and_then(Value::as_str))
                .bind(kind)
                .bind(&exposes)
                .bind(def.get("description").and_then(Value::as_str))
                .execute(&st.db)
                .await?;
            }
            // Thiết bị đã bị gỡ khỏi Zigbee2MQTT thì gỡ khỏi hệ thống. Danh sách RỖNG thì không xoá gì: Z2M vừa khởi động lại
            // / mất dongle có thể phát danh sách trống, xoá theo đó là mất tên, phòng, quy tắc của cả căn hộ (gỡ thiết bị thật
            // thì Z2M gửi danh sách còn lại, không rỗng; máy lọc Bluetooth gỡ qua purifier::remove).
            if keep.is_empty() {
                let n: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE gateway_id = $1").bind(gw.id).fetch_one(&st.db).await?;
                if n > 0 {
                    tracing::warn!(gateway = %gw.id, existing = n, "empty device list ignored (not deleting)");
                }
            } else {
                let r = sqlx::query("DELETE FROM devices WHERE gateway_id = $1 AND NOT (ieee_address = ANY($2))")
                    .bind(gw.id)
                    .bind(&keep)
                    .execute(&st.db)
                    .await?;
                if r.rows_affected() > 0 {
                    tracing::warn!(gateway = %gw.id, removed = r.rows_affected(), "devices removed (no longer in device list)");
                }
            }
            st.hub.publish(gw.home_id, json!({"type": "devices_changed"}).to_string());
            crate::homegraph::home_changed(st, gw.home_id);
        }
        GwMsg::State { friendly_name, payload } => {
            if !payload.is_object() {
                return Ok(());
            }
            // Lấy cả trạng thái CŨ để phát hiện chuyển trạng thái của cảm biến (cảnh báo theo ngữ cảnh).
            let row: Option<(Uuid, Value, Value)> = sqlx::query_as(
                "WITH old AS (SELECT id, state FROM devices WHERE gateway_id = $1 AND friendly_name = $2 FOR UPDATE)
                 UPDATE devices d SET state = d.state || $3, last_seen_at = now()
                   FROM old WHERE d.id = old.id RETURNING d.id, d.state, old.state",
            )
            .bind(gw.id)
            .bind(&friendly_name)
            .bind(&payload)
            .fetch_optional(&st.db)
            .await?;
            if let Some((id, state, old_state)) = row {
                st.hub.publish(gw.home_id, json!({"type": "device_state", "device_id": id, "state": state}).to_string());
                crate::alerts::on_state(st, gw.home_id, id, &old_state, &state).await;
                crate::rules::on_state(st, gw.home_id, id, &old_state, &state).await;
                crate::purifier::on_state(st, gw.home_id, id, &old_state, &state).await;
                crate::homegraph::device_changed(st, gw.home_id, id);
            }
        }
        GwMsg::Availability { friendly_name, online } => {
            let id: Option<Uuid> = sqlx::query_scalar(
                "UPDATE devices SET online = $3 WHERE gateway_id = $1 AND friendly_name = $2 RETURNING id",
            )
            .bind(gw.id)
            .bind(&friendly_name)
            .bind(online)
            .fetch_optional(&st.db)
            .await?;
            if let Some(id) = id {
                st.hub.publish(gw.home_id, json!({"type": "device_online", "device_id": id, "online": online}).to_string());
                crate::homegraph::device_changed(st, gw.home_id, id);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(exposes: Value) -> &'static str {
        kind_of(exposes.as_array().unwrap())
    }

    #[test]
    fn vendor_neutral_classification() {
        // Aqara QBKG03LM: hai gang left/right (kiểu switch)
        assert_eq!(kinds(json!([{"type":"switch","endpoint":"left","features":[{"type":"binary","property":"state_left"}]}])), "switch");
        // Tuya TS130F: rèm
        assert_eq!(kinds(json!([{"type":"cover","features":[{"type":"enum","property":"state"},{"type":"numeric","property":"position"}]}])), "cover");
        // Aqara WSDCGQ11LM: nhiệt độ/độ ẩm/áp suất
        assert_eq!(kinds(json!([{"type":"numeric","property":"battery"},{"type":"numeric","property":"temperature"}])), "sensor");
        assert_eq!(kinds(json!([{"type":"numeric","property":"illuminance"},{"type":"binary","property":"occupancy"}])), "sensor");
        assert_eq!(kinds(json!([{"type":"binary","property":"water_leak"}])), "sensor");
        // ổ cắm đo điện (switch + power) vẫn là switch, không bị nhầm thành cảm biến
        assert_eq!(kinds(json!([{"type":"switch","features":[{"type":"binary","property":"state"}]},{"type":"numeric","property":"power"}])), "switch");
        assert_eq!(kinds(json!([{"type":"light","features":[]}])), "light");
        assert_eq!(kinds(json!([{"type":"numeric","property":"battery"}])), "other");
        // máy lọc nước Bluetooth (addon)
        assert_eq!(kinds(json!([{"type":"numeric","property":"tds"},{"type":"composite","property":"filters"}])), "purifier");
    }
}
