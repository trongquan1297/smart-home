//! Fulfillment Google Home cloud-to-cloud: `POST /google/fulfillment` nhận intent SYNC / QUERY / EXECUTE / DISCONNECT
//! (xác thực bằng access token OAuth, xem oauth.rs).
//!
//! Ánh xạ thiết bị:
//!  * mỗi gang công tắc (`state`, `state_left`, `state_l2`…) = một thiết bị Google (id `<uuid>:<khoá>`), loại theo loại tải
//!    người dùng chọn trong app (đèn → LIGHT, quạt → FAN, ổ cắm → OUTLET, còn lại SWITCH), trait OnOff;
//!    bóng đèn có độ sáng thêm trait Brightness;
//!  * rèm (cover) = CURTAIN, trait OpenClose (chỉ mở/đóng nếu rèm không báo vị trí);
//!  * cảm biến nhiệt độ/độ ẩm = SENSOR, TemperatureControl/HumiditySetting chỉ đọc;
//!  * máy lọc nước Bluetooth (addon) = SENSOR, SensorState: FilterLifeTime (% lõi thấp nhất) + WaterLeak (mã lỗi 5).
//! Chỉ thiết bị ở căn hộ mà người dùng là thành viên trở lên (khách thuê/khách xem không đưa sang Google).
use axum::{extract::State, Json};
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::{
    access::{self, Role},
    error::{ApiError, ApiResult},
    oauth::OAuthUser,
    routes::validate_command,
    AppState,
};

/// Một thiết bị (hàng `devices`) cùng căn hộ/phòng của nó.
#[derive(sqlx::FromRow)]
pub(crate) struct Row {
    pub id: Uuid,
    pub home_id: Uuid,
    pub gateway_id: Uuid,
    friendly_name: String,
    name: String,
    kind: String,
    model: Option<String>,
    vendor: Option<String>,
    exposes: Value,
    channels: Value,
    state: Value,
    pub online: bool,
    room: Option<String>,
}

const ROW_SQL: &str = "SELECT d.id, d.home_id, d.gateway_id, d.friendly_name, d.name, d.kind, d.model, d.vendor, d.exposes, d.channels, d.state, d.online, r.name AS room
    FROM devices d LEFT JOIN rooms r ON r.id = d.room_id";

/// Căn hộ người dùng có quyền thành viên trở lên (gồm quản trị tenant).
async fn homes(st: &AppState, user: Uuid) -> ApiResult<Vec<Uuid>> {
    let candidates: Vec<Uuid> = sqlx::query_scalar(
        "SELECT h.id FROM homes h WHERE EXISTS (SELECT 1 FROM home_members m WHERE m.home_id = h.id AND m.user_id = $1)
            OR EXISTS (SELECT 1 FROM tenant_members t WHERE t.tenant_id = h.tenant_id AND t.user_id = $1)",
    )
    .bind(user)
    .fetch_all(&st.db)
    .await?;
    let mut out = Vec::new();
    for h in candidates {
        if access::home_role(&st.db, user, h).await.is_ok_and(|r| r >= Role::Member) {
            out.push(h);
        }
    }
    Ok(out)
}

fn walk<'a>(v: &'a Value, out: &mut Vec<&'a Value>) {
    match v {
        Value::Array(a) => a.iter().for_each(|x| walk(x, out)),
        Value::Object(o) => {
            out.push(v);
            if let Some(f) = o.get("features") {
                walk(f, out);
            }
        }
        _ => {}
    }
}

fn nodes(exposes: &Value) -> Vec<&Value> {
    let mut out = Vec::new();
    walk(exposes, &mut out);
    out
}

/// Các khoá bật/tắt (giống app: thuộc tính binary bắt đầu bằng `state`).
fn switch_keys(exposes: &Value) -> Vec<String> {
    let mut k: Vec<String> = nodes(exposes)
        .into_iter()
        .filter(|n| n.get("type").and_then(Value::as_str) == Some("binary"))
        .filter_map(|n| n.get("property").and_then(Value::as_str))
        .filter(|p| p.starts_with("state"))
        .map(str::to_string)
        .collect();
    k.sort();
    k.dedup();
    k
}

fn has_prop(exposes: &Value, prop: &str) -> bool {
    nodes(exposes).iter().any(|n| n.get("property").and_then(Value::as_str) == Some(prop))
}

/// Tên mặc định của gang (giống app).
fn gang_label(key: &str) -> String {
    let Some(suf) = key.strip_prefix("state_") else { return "Nguồn".into() };
    let s = suf.to_lowercase();
    let digits = s.trim_start_matches('l');
    if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
        return format!("Gang {digits}");
    }
    match s.as_str() {
        "left" => "Gang trái".into(),
        "right" => "Gang phải".into(),
        "center" | "middle" => "Gang giữa".into(),
        "top" => "Gang trên".into(),
        "bottom" => "Gang dưới".into(),
        _ => format!("Gang {s}"),
    }
}

fn split_id(id: &str) -> Option<(Uuid, Option<&str>)> {
    match id.split_once(':') {
        Some((u, k)) => Some((u.parse().ok()?, Some(k))),
        None => Some((id.parse().ok()?, None)),
    }
}

/// Thiết bị Google (SYNC) từ một hàng `devices`. Một công tắc nhiều gang → nhiều thiết bị.
/// `report`: máy chủ có báo trạng thái chủ động qua HomeGraph (willReportState).
pub(crate) fn sync_devices(d: &Row, report: bool) -> Vec<Value> {
    let info = json!({"manufacturer": d.vendor.clone().unwrap_or_else(|| "MSmart".into()), "model": d.model.clone().unwrap_or_default()});
    let base = |id: String, ty: &str, traits: Vec<&str>, name: String, attrs: Value| {
        let mut v = json!({
            "id": id, "type": format!("action.devices.types.{ty}"),
            "traits": traits.iter().map(|t| format!("action.devices.traits.{t}")).collect::<Vec<_>>(),
            "name": {"name": name, "defaultNames": [d.name.clone()]},
            "willReportState": report, "deviceInfo": info.clone(),
            "customData": {"home": d.home_id},
        });
        if let Some(r) = &d.room {
            v["roomHint"] = json!(r);
        }
        if attrs.as_object().is_some_and(|o| !o.is_empty()) {
            v["attributes"] = attrs;
        }
        v
    };
    let mut out = Vec::new();
    if d.kind == "cover" {
        let attrs = if has_prop(&d.exposes, "position") { json!({}) } else { json!({"discreteOnlyOpenClose": true}) };
        out.push(base(d.id.to_string(), "CURTAIN", vec!["OpenClose"], d.name.clone(), attrs));
        return out;
    }
    if d.kind == "purifier" {
        // Google không có TDS; báo tuổi thọ lõi lọc và rò nước qua SensorState (chỉ đọc).
        let attrs = json!({"sensorStatesSupported": [
            {"name": "FilterLifeTime", "descriptiveCapabilities": {"availableStates": ["new", "good", "replace soon", "replace now", "unknown"]},
             "numericCapabilities": {"rawValueUnit": "PERCENTAGE"}},
            {"name": "WaterLeak", "descriptiveCapabilities": {"availableStates": ["leak", "no leak", "unknown"]}}
        ]});
        out.push(base(d.id.to_string(), "SENSOR", vec!["SensorState"], d.name.clone(), attrs));
        return out;
    }
    let keys = switch_keys(&d.exposes);
    for k in &keys {
        let ch = d.channels.get(k);
        let ch_name = ch.and_then(|c| c.get("name")).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
        let ch_type = ch.and_then(|c| c.get("type")).and_then(Value::as_str).unwrap_or("");
        let ty = match ch_type {
            "light" => "LIGHT",
            "fan" => "FAN",
            "outlet" => "OUTLET",
            _ if d.kind == "light" => "LIGHT",
            _ => "SWITCH",
        };
        let name = match (ch_name, keys.len()) {
            (Some(n), _) => n.to_string(),
            (None, 1) => d.name.clone(),
            (None, _) => format!("{} {}", d.name, gang_label(k)),
        };
        let mut traits = vec!["OnOff"];
        if d.kind == "light" && keys.len() == 1 && has_prop(&d.exposes, "brightness") {
            traits.push("Brightness");
        }
        out.push(base(format!("{}:{k}", d.id), ty, traits, name, json!({})));
    }
    if keys.is_empty() && d.kind == "sensor" {
        let (t, h) = (has_prop(&d.exposes, "temperature"), has_prop(&d.exposes, "humidity"));
        let (contact, occupancy) = (has_prop(&d.exposes, "contact"), has_prop(&d.exposes, "occupancy"));
        if t || h || contact || occupancy {
            let mut traits = Vec::new();
            let mut attrs = Map::new();
            // Cảm biến cửa: OpenClose chỉ-đọc (tài liệu SENSOR: "window sensors should use the OpenClose trait with
            // queryOnlyOpenClose set to true").
            if contact {
                traits.push("OpenClose");
                attrs.insert("queryOnlyOpenClose".into(), json!(true));
                attrs.insert("discreteOnlyOpenClose".into(), json!(true));
            }
            // Cảm biến hiện diện: occupancySensorType là trường bắt buộc (PIR | ULTRASONIC | PHYSICAL_CONTACT).
            if occupancy {
                traits.push("OccupancySensing");
                attrs.insert("occupancySensorConfiguration".into(), json!([{"occupancySensorType": "PIR"}]));
            }
            if t {
                traits.push("TemperatureControl");
                attrs.insert("queryOnlyTemperatureControl".into(), json!(true));
                attrs.insert("temperatureUnitForUX".into(), json!("C"));
                attrs.insert("temperatureRange".into(), json!({"minThresholdCelsius": -20, "maxThresholdCelsius": 60}));
            }
            if h {
                traits.push("HumiditySetting");
                attrs.insert("queryOnlyHumiditySetting".into(), json!(true));
            }
            out.push(base(d.id.to_string(), "SENSOR", traits, d.name.clone(), Value::Object(attrs)));
        }
    }
    out
}

/// Trạng thái QUERY của một thiết bị Google.
pub(crate) fn query_state(d: &Row, key: Option<&str>, online: bool) -> Value {
    let mut s = json!({"online": online, "status": "SUCCESS"});
    if !online {
        s["status"] = json!("OFFLINE");
        s["errorCode"] = json!("deviceOffline");
    }
    let st = &d.state;
    match key {
        Some(k) => {
            s["on"] = json!(st.get(k).and_then(Value::as_str) == Some("ON"));
            if let Some(b) = st.get("brightness").and_then(Value::as_u64) {
                s["brightness"] = json!(((b as f64) * 100.0 / 254.0).round() as u64);
            }
        }
        None if d.kind == "cover" => {
            let pct = st.get("position").and_then(Value::as_u64).unwrap_or_else(|| match st.get("state").and_then(Value::as_str) {
                Some("OPEN") => 100,
                _ => 0,
            });
            s["openPercent"] = json!(pct.min(100));
        }
        None if d.kind == "purifier" => {
            let pct = st.get("filter_min").and_then(Value::as_i64);
            let life = match pct {
                None => "unknown",
                Some(p) if p >= 90 => "new",
                Some(p) if p > 20 => "good",
                Some(p) if p > 5 => "replace soon",
                Some(_) => "replace now",
            };
            let mut filter = json!({"name": "FilterLifeTime", "currentSensorState": life});
            if let Some(p) = pct {
                filter["rawValue"] = json!(p.clamp(0, 100));
            }
            let leak = match st.get("errors").and_then(Value::as_array) {
                None => "unknown",
                Some(e) if e.iter().any(|c| c.as_i64() == Some(5)) => "leak",
                Some(_) => "no leak",
            };
            s["currentSensorStateData"] = json!([filter, {"name": "WaterLeak", "currentSensorState": leak}]);
        }
        None => {
            if let Some(t) = st.get("temperature").and_then(Value::as_f64) {
                s["temperatureAmbientCelsius"] = json!(t);
                s["temperatureSetpointCelsius"] = json!(t);
            }
            if let Some(h) = st.get("humidity").and_then(Value::as_f64) {
                s["humidityAmbientPercent"] = json!(h.round() as i64);
            }
            // Zigbee2MQTT: contact = true nghĩa là hai nửa cảm biến chạm nhau = cửa ĐÓNG.
            if has_prop(&d.exposes, "contact") {
                let closed = st.get("contact").and_then(Value::as_bool).unwrap_or(true);
                s["openPercent"] = json!(if closed { 0 } else { 100 });
            }
            if has_prop(&d.exposes, "occupancy") {
                s["occupancy"] = json!(match st.get("occupancy").and_then(Value::as_bool) {
                    Some(true) => "OCCUPIED",
                    Some(false) => "UNOCCUPIED",
                    None => "UNKNOWN_OCCUPANCY_STATE",
                });
            }
        }
    }
    s
}

pub async fn fulfillment(State(st): State<AppState>, user: OAuthUser, Json(req): Json<Value>) -> ApiResult<Json<Value>> {
    let request_id = req.get("requestId").cloned().unwrap_or(json!(""));
    let input = req.get("inputs").and_then(Value::as_array).and_then(|a| a.first()).ok_or_else(|| ApiError::BadRequest("no inputs".into()))?;
    let intent = input.get("intent").and_then(Value::as_str).unwrap_or_default();
    let payload = match intent {
        "action.devices.SYNC" => sync(&st, &user).await?,
        "action.devices.QUERY" => query(&st, &user, input).await?,
        "action.devices.EXECUTE" => execute(&st, &user, input).await?,
        "action.devices.DISCONNECT" => {
            // Người dùng huỷ liên kết trong Google Home: thu hồi luôn refresh/access token của lần liên kết này.
            sqlx::query("UPDATE oauth_grants SET revoked_at = now() WHERE id = $1").bind(user.grant_id).execute(&st.db).await?;
            sqlx::query("DELETE FROM oauth_tokens WHERE grant_id = $1").bind(user.grant_id).execute(&st.db).await?;
            tracing::info!(user = %user.user_id, grant = %user.grant_id, "google home: unlinked");
            return Ok(Json(json!({})));
        }
        _ => return Ok(Json(json!({"requestId": request_id, "payload": {"errorCode": "notSupported"}}))),
    };
    Ok(Json(json!({"requestId": request_id, "payload": payload})))
}

async fn rows_for(st: &AppState, user: &OAuthUser, ids: Option<&[Uuid]>) -> ApiResult<Vec<Row>> {
    rows_in(st, &homes(st, user.user_id).await?, ids).await
}

/// Thiết bị của một căn hộ (HomeGraph dùng khi báo trạng thái).
pub(crate) async fn home_rows(st: &AppState, home: Uuid, ids: Option<&[Uuid]>) -> ApiResult<Vec<Row>> {
    rows_in(st, &[home], ids).await
}

async fn rows_in(st: &AppState, homes: &[Uuid], ids: Option<&[Uuid]>) -> ApiResult<Vec<Row>> {
    let q = match ids {
        Some(_) => format!("{ROW_SQL} WHERE d.home_id = ANY($1) AND d.id = ANY($2) ORDER BY d.name"),
        None => format!("{ROW_SQL} WHERE d.home_id = ANY($1) ORDER BY d.name"),
    };
    let mut query = sqlx::query_as::<_, Row>(&q).bind(homes);
    if let Some(ids) = ids {
        query = query.bind(ids);
    }
    Ok(query.fetch_all(&st.db).await?)
}

/// Danh sách thiết bị Google của người dùng (nội dung SYNC).
pub(crate) async fn sync_payload(st: &AppState, user: Uuid) -> ApiResult<Vec<Value>> {
    let report = st.homegraph.is_some();
    let rows = rows_in(st, &homes(st, user).await?, None).await?;
    Ok(rows.iter().flat_map(|r| sync_devices(r, report)).collect())
}

async fn sync(st: &AppState, user: &OAuthUser) -> ApiResult<Value> {
    let devices = sync_payload(st, user.user_id).await?;
    crate::homegraph::synced(st, user.user_id, &devices);
    tracing::info!(user = %user.user_id, devices = devices.len(), "google home: SYNC");
    Ok(json!({"agentUserId": user.user_id.to_string(), "devices": devices}))
}

fn requested_ids(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array).map(|a| a.iter().filter_map(|d| d.get("id").and_then(Value::as_str).map(str::to_string)).take(200).collect()).unwrap_or_default()
}

async fn query(st: &AppState, user: &OAuthUser, input: &Value) -> ApiResult<Value> {
    let ids = requested_ids(input.pointer("/payload/devices"));
    let uuids: Vec<Uuid> = ids.iter().filter_map(|i| split_id(i).map(|(u, _)| u)).collect();
    let rows = rows_for(st, user, Some(&uuids)).await?;
    let mut out = Map::new();
    for id in ids {
        let Some((uuid, key)) = split_id(&id) else { continue };
        let v = match rows.iter().find(|r| r.id == uuid) {
            Some(d) => query_state(d, key, d.online && st.hub.gateway_connected(d.gateway_id)),
            None => json!({"status": "ERROR", "errorCode": "deviceNotFound"}),
        };
        out.insert(id, v);
    }
    Ok(json!({"devices": out}))
}

/// Đổi một lệnh Google thành payload Zigbee2MQTT cho thiết bị/gang. Err = mã lỗi Google.
fn to_payload(d: &Row, key: Option<&str>, command: &str, params: &Value) -> Result<(Map<String, Value>, Value), &'static str> {
    let mut p = Map::new();
    let mut states = json!({"online": true});
    match (command, key) {
        ("action.devices.commands.OnOff", Some(k)) => {
            let on = params.get("on").and_then(Value::as_bool).ok_or("functionNotSupported")?;
            p.insert(k.to_string(), json!(if on { "ON" } else { "OFF" }));
            states["on"] = json!(on);
        }
        ("action.devices.commands.BrightnessAbsolute", Some(_)) if d.kind == "light" => {
            let b = params.get("brightness").and_then(Value::as_u64).ok_or("functionNotSupported")?.min(100);
            p.insert("brightness".into(), json!(((b as f64) * 254.0 / 100.0).round() as u64));
            states["brightness"] = json!(b);
        }
        ("action.devices.commands.OpenClose", None) if d.kind == "cover" => {
            let pct = params.get("openPercent").and_then(Value::as_f64).ok_or("functionNotSupported")?.clamp(0.0, 100.0).round() as u64;
            if has_prop(&d.exposes, "position") {
                p.insert("position".into(), json!(pct));
            } else {
                p.insert("state".into(), json!(if pct > 0 { "OPEN" } else { "CLOSE" }));
            }
            states["openPercent"] = json!(pct);
        }
        _ => return Err("functionNotSupported"),
    }
    Ok((p, states))
}

async fn execute(st: &AppState, user: &OAuthUser, input: &Value) -> ApiResult<Value> {
    let mut results: Vec<Value> = Vec::new();
    for cmd in input.pointer("/payload/commands").and_then(Value::as_array).cloned().unwrap_or_default().iter().take(20) {
        let ids = requested_ids(cmd.get("devices"));
        let uuids: Vec<Uuid> = ids.iter().filter_map(|i| split_id(i).map(|(u, _)| u)).collect();
        let rows = rows_for(st, user, Some(&uuids)).await?;
        let execs = cmd.get("execution").and_then(Value::as_array).cloned().unwrap_or_default();
        for id in ids {
            let result = execute_one(st, user, &rows, &id, &execs).await;
            results.push(match result {
                Ok(states) => json!({"ids": [id], "status": "SUCCESS", "states": states}),
                Err("deviceOffline") => json!({"ids": [id], "status": "OFFLINE", "errorCode": "deviceOffline"}),
                Err(code) => json!({"ids": [id], "status": "ERROR", "errorCode": code}),
            });
        }
    }
    Ok(json!({"commands": results}))
}

async fn execute_one(st: &AppState, user: &OAuthUser, rows: &[Row], id: &str, execs: &[Value]) -> Result<Value, &'static str> {
    let (uuid, key) = split_id(id).ok_or("deviceNotFound")?;
    let d = rows.iter().find(|r| r.id == uuid).ok_or("deviceNotFound")?;
    if key.is_some_and(|k| !switch_keys(&d.exposes).iter().any(|x| x == k)) {
        return Err("deviceNotFound");
    }
    let mut payload = Map::new();
    let mut states = json!({});
    for e in execs.iter().take(5) {
        let c = e.get("command").and_then(Value::as_str).unwrap_or_default();
        let (p, s) = to_payload(d, key, c, e.get("params").unwrap_or(&Value::Null))?;
        payload.extend(p);
        if let (Some(dst), Some(src)) = (states.as_object_mut(), s.as_object()) {
            dst.extend(src.clone());
        }
    }
    let payload = Value::Object(payload);
    validate_command(&payload).map_err(|_| "functionNotSupported")?;
    let msg = json!({"type": "set", "friendly_name": d.friendly_name, "payload": payload}).to_string();
    if !st.hub.send_gateway(d.gateway_id, msg).await {
        return Err("deviceOffline");
    }
    let _ = sqlx::query("INSERT INTO command_log (device_id, home_id, user_id, payload) VALUES ($1,$2,$3,$4)")
        .bind(d.id)
        .bind(d.home_id)
        .bind(user.user_id)
        .bind(&payload)
        .execute(&st.db)
        .await;
    tracing::info!(user = %user.user_id, device = %d.id, %payload, "google home: EXECUTE");
    Ok(states)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(kind: &str, exposes: Value, channels: Value, state: Value) -> Row {
        Row {
            id: Uuid::nil(),
            home_id: Uuid::nil(),
            gateway_id: Uuid::nil(),
            friendly_name: "0x01".into(),
            name: "Công tắc khách".into(),
            kind: kind.into(),
            model: Some("M".into()),
            vendor: Some("VSmart".into()),
            exposes,
            channels,
            state,
            online: true,
            room: Some("Phòng khách".into()),
        }
    }

    #[test]
    fn purifier_sensor_state() {
        let d = row("purifier", json!([{"type":"composite","property":"filters"}]), json!({}), json!({"tds": 12, "filter_min": 15, "errors": [5]}));
        let devs = sync_devices(&d, true);
        assert_eq!(devs.len(), 1);
        assert_eq!(devs[0]["type"], "action.devices.types.SENSOR");
        assert_eq!(devs[0]["traits"], json!(["action.devices.traits.SensorState"]));
        let q = query_state(&d, None, true);
        assert_eq!(q["currentSensorStateData"][0], json!({"name": "FilterLifeTime", "currentSensorState": "replace soon", "rawValue": 15}));
        assert_eq!(q["currentSensorStateData"][1]["currentSensorState"], "leak");
    }

    #[test]
    fn door_and_occupancy_sensors() {
        let door = row("sensor", json!([{"type":"binary","property":"contact"},{"type":"binary","property":"battery_low"}]), json!({}), json!({"contact": false}));
        let devs = sync_devices(&door, true);
        assert_eq!(devs.len(), 1);
        assert_eq!(devs[0]["type"], "action.devices.types.SENSOR");
        assert_eq!(devs[0]["traits"], json!(["action.devices.traits.OpenClose"]));
        assert_eq!(devs[0]["attributes"]["queryOnlyOpenClose"], true);
        assert!(devs[0].get("otherDeviceIds").is_none(), "otherDeviceIds chỉ dành cho local execution");
        assert_eq!(query_state(&door, None, true)["openPercent"], 100, "contact=false là cửa mở");
        let closed = row("sensor", door.exposes.clone(), json!({}), json!({"contact": true}));
        assert_eq!(query_state(&closed, None, true)["openPercent"], 0);

        let occ = row("sensor", json!([{"type":"binary","property":"occupancy"}]), json!({}), json!({"occupancy": true}));
        let devs = sync_devices(&occ, true);
        assert_eq!(devs[0]["traits"], json!(["action.devices.traits.OccupancySensing"]));
        assert_eq!(devs[0]["attributes"]["occupancySensorConfiguration"][0]["occupancySensorType"], "PIR");
        assert_eq!(query_state(&occ, None, true)["occupancy"], "OCCUPIED");
    }

    #[test]
    fn gangs_become_separate_google_devices() {
        let ex = json!([{"type":"switch","endpoint":"l1","features":[{"type":"binary","property":"state_l1"}]},
                        {"type":"switch","endpoint":"l2","features":[{"type":"binary","property":"state_l2"}]}]);
        let d = row("switch", ex, json!({"state_l1": {"name": "Đèn trần", "type": "light"}}), json!({"state_l1": "ON"}));
        let devs = sync_devices(&d, false);
        assert_eq!(devs.len(), 2);
        assert_eq!(devs[0]["id"], format!("{}:state_l1", Uuid::nil()));
        assert_eq!(devs[0]["type"], "action.devices.types.LIGHT");
        assert_eq!(devs[0]["name"]["name"], "Đèn trần");
        assert_eq!(devs[1]["type"], "action.devices.types.SWITCH");
        assert_eq!(devs[1]["name"]["name"], "Công tắc khách Gang 2");
        assert_eq!(devs[0]["roomHint"], "Phòng khách");
        assert_eq!(query_state(&d, Some("state_l1"), true)["on"], true);
        assert_eq!(query_state(&d, Some("state_l2"), false)["status"], "OFFLINE");
    }

    #[test]
    fn cover_and_commands() {
        let ex = json!([{"type":"cover","features":[{"type":"enum","property":"state"},{"type":"numeric","property":"position"}]}]);
        let d = row("cover", ex, json!({}), json!({"position": 40}));
        let devs = sync_devices(&d, false);
        assert_eq!(devs[0]["type"], "action.devices.types.CURTAIN");
        assert!(devs[0].get("attributes").is_none());
        assert_eq!(query_state(&d, None, true)["openPercent"], 40);
        let (p, s) = to_payload(&d, None, "action.devices.commands.OpenClose", &json!({"openPercent": 75})).unwrap();
        assert_eq!(Value::Object(p), json!({"position": 75}));
        assert_eq!(s["openPercent"], 75);
        assert_eq!(to_payload(&d, None, "action.devices.commands.OnOff", &json!({"on": true})).unwrap_err(), "functionNotSupported");

        let sw = row("switch", json!([{"type":"binary","property":"state"}]), json!({}), json!({}));
        let (p, _) = to_payload(&sw, Some("state"), "action.devices.commands.OnOff", &json!({"on": false})).unwrap();
        assert_eq!(Value::Object(p), json!({"state": "OFF"}));
        assert_eq!(sync_devices(&sw, false)[0]["name"]["name"], "Công tắc khách");
    }

    #[test]
    fn labels_and_ids() {
        assert_eq!(gang_label("state"), "Nguồn");
        assert_eq!(gang_label("state_left"), "Gang trái");
        assert_eq!(gang_label("state_l3"), "Gang 3");
        assert_eq!(gang_label("state_2"), "Gang 2");
        let u = Uuid::new_v4();
        assert_eq!(split_id(&format!("{u}:state_l1")), Some((u, Some("state_l1"))));
        assert_eq!(split_id(&u.to_string()), Some((u, None)));
        assert_eq!(split_id("x"), None);
    }
}
