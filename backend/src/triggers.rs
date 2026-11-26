//! Điều kiện tự kích hoạt ngữ cảnh: hẹn giờ, rời nhà, về nhà, cảm biến — kết hợp HOẶC (`any`) hoặc VÀ (`all`).
//!
//! Mỗi điều kiện vừa là một **sự kiện** (đến giờ, người cuối cùng rời nhà, người đầu tiên về nhà, cảm biến chuyển trạng thái)
//! vừa có **trạng thái hiện tại** (đang trong khung giờ, không còn ai ở nhà, có người ở nhà, cảm biến đang ở trạng thái đó).
//! - `any`: sự kiện của bất kỳ điều kiện nào xảy ra thì chạy.
//! - `all`: sự kiện của một điều kiện xảy ra VÀ mọi điều kiện còn lại đang đúng thì chạy.
//!
//! Một ngữ cảnh tự chạy tối đa một lần mỗi `COOLDOWN_SECS` (cảm biến hiện diện nhấp nháy, nhiều điều kiện cùng xảy ra một lúc).
use chrono::{DateTime, Datelike, NaiveTime, TimeZone, Utc};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    alerts::{self, AutoRun},
    automation,
    error::ApiResult,
    presence, AppState,
};

pub const SENSOR_EVENTS: [&str; 4] = ["occupied", "vacant", "open", "closed"];
pub const MAX_SENSORS: usize = 10;
const COOLDOWN_SECS: i64 = 60;
/// Hẹn giờ không có giờ kết thúc được coi là "đang đúng" trong khoảng này sau mốc giờ (khi kết hợp VÀ).
const POINT_WINDOW_SECS: i64 = 300;
const DEFAULT_TZ: &str = "Asia/Ho_Chi_Minh";

/// Thuộc tính Zigbee2MQTT và giá trị ứng với từng loại sự kiện cảm biến.
/// Quy ước Z2M: `occupancy = true` là có người; `contact = true` là cửa đóng.
pub fn sensor_prop(event: &str) -> Option<(&'static str, bool)> {
    match event {
        "occupied" => Some(("occupancy", true)),
        "vacant" => Some(("occupancy", false)),
        "open" => Some(("contact", false)),
        "closed" => Some(("contact", true)),
        _ => None,
    }
}

pub fn sensor_label(event: &str) -> &'static str {
    match event {
        "occupied" => "phát hiện có người",
        "vacant" => "không còn người",
        "open" => "cửa vừa mở",
        "closed" => "cửa vừa đóng",
        _ => "kích hoạt",
    }
}

/// Cảm biến đang ở trạng thái của sự kiện.
pub fn sensor_state(event: &str, state: &Value) -> bool {
    sensor_prop(event).is_some_and(|(k, v)| state.get(k).and_then(Value::as_bool) == Some(v))
}

/// Cảm biến vừa CHUYỂN sang trạng thái của sự kiện (trạng thái cũ phải đã biết và ngược lại — phát lại/ghép mới không tính).
pub fn sensor_event(event: &str, old: &Value, new: &Value) -> bool {
    sensor_prop(event).is_some_and(|(k, v)| old.get(k).and_then(Value::as_bool) == Some(!v) && new.get(k).and_then(Value::as_bool) == Some(v))
}

/// `now` có nằm trong khung giờ của hẹn giờ không (theo múi giờ căn hộ). Khung bắt đầu vào một ngày nằm trong `days`;
/// `end <= start` là khung qua nửa đêm (kết thúc ngày hôm sau). Không có `end`: khung dài `POINT_WINDOW_SECS` từ mốc giờ.
pub fn in_window(tz: &str, start: NaiveTime, end: Option<NaiveTime>, days: &[i16], now: DateTime<Utc>) -> bool {
    let tz: chrono_tz::Tz = tz.parse().unwrap_or_else(|_| DEFAULT_TZ.parse().expect("valid default tz"));
    let today = now.with_timezone(&tz).date_naive();
    for back in 0..2 {
        let date = today - chrono::Days::new(back);
        if !days.contains(&(date.weekday().number_from_monday() as i16)) {
            continue;
        }
        let Some(from) = tz.from_local_datetime(&date.and_time(start)).earliest() else { continue };
        let until = match end {
            Some(e) => {
                let d = if e <= start { date + chrono::Days::new(1) } else { date };
                match tz.from_local_datetime(&d.and_time(e)).earliest() {
                    Some(t) => t,
                    None => continue,
                }
            }
            None => from + chrono::Duration::seconds(POINT_WINDOW_SECS),
        };
        if from <= now && now < until {
            return true;
        }
    }
    false
}

/// Điều kiện nào vừa xảy ra (để không kiểm tra lại chính nó khi kết hợp VÀ). `Sensor(i)` là vị trí trong `trigger_sensors`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fired {
    Time,
    Leave,
    Arrive,
    Sensor(usize),
}

/// Một ngữ cảnh cùng mọi điều kiện tự kích hoạt của nó.
#[derive(FromRow)]
pub struct Cond {
    pub id: Uuid,
    pub home_id: Uuid,
    pub actions: Value,
    pub step_delay_ms: i32,
    pub trigger_logic: String,
    pub auto_enabled: bool,
    pub auto_time: Option<NaiveTime>,
    pub auto_time_end: Option<NaiveTime>,
    pub auto_days: Vec<i16>,
    pub auto_leave: bool,
    pub auto_arrive: bool,
    pub trigger_sensors: Value,
    pub timezone: String,
    pub last_run_at: Option<DateTime<Utc>>,
}

pub const COND_SELECT: &str = "SELECT s.id, s.home_id, s.actions, s.step_delay_ms, s.trigger_logic, s.auto_enabled, s.auto_time, s.auto_time_end,
        s.auto_days, s.auto_leave, s.auto_arrive, s.trigger_sensors, h.timezone, s.last_run_at
   FROM scenes s JOIN homes h ON h.id = s.home_id";

impl Cond {
    pub fn sensors(&self) -> Vec<(Uuid, String)> {
        self.trigger_sensors
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|s| {
                let d = s.get("device_id").and_then(Value::as_str).and_then(|x| Uuid::parse_str(x).ok())?;
                let e = s.get("event").and_then(Value::as_str)?;
                Some((d, e.to_owned()))
            })
            .collect()
    }
}

/// Khi kết hợp VÀ: mọi điều kiện khác `fired` đang đúng. Kết hợp HOẶC luôn đúng.
pub async fn others_hold(st: &AppState, c: &Cond, fired: Fired, now: DateTime<Utc>) -> ApiResult<bool> {
    if c.trigger_logic != "all" {
        return Ok(true);
    }
    if fired != Fired::Time && c.auto_enabled {
        if let Some(start) = c.auto_time {
            if !in_window(&c.timezone, start, c.auto_time_end, &c.auto_days, now) {
                return Ok(false);
            }
        }
    }
    let need_leave = c.auto_leave && fired != Fired::Leave;
    let need_arrive = c.auto_arrive && fired != Fired::Arrive;
    if need_leave || need_arrive {
        // None = chưa ai báo trạng thái: không biết có ai ở nhà không → điều kiện chưa đúng.
        let home = presence::home_presence(st, c.home_id).await?;
        if (need_leave && home != Some(false)) || (need_arrive && home != Some(true)) {
            return Ok(false);
        }
    }
    for (i, (dev, ev)) in c.sensors().iter().enumerate() {
        if fired == Fired::Sensor(i) {
            continue;
        }
        let state: Option<Value> = sqlx::query_scalar("SELECT state FROM devices WHERE id = $1 AND home_id = $2").bind(dev).bind(c.home_id).fetch_optional(&st.db).await?;
        if !state.is_some_and(|s| sensor_state(ev, &s)) {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Chạy ngữ cảnh do một sự kiện (không phải hẹn giờ — hẹn giờ có bộ lập lịch riêng trong automation.rs).
/// Giành lượt bằng UPDATE có điều kiện để không chạy quá một lần mỗi `COOLDOWN_SECS`. Chỉ tính những lần đã thật sự chạy:
/// tạo/sửa ngữ cảnh cũng đặt `last_run_at = now()` (để lịch không chạy bù) nhưng `last_status` NULL, còn lịch bị bỏ lỡ /
/// bỏ qua (`missed`, `skipped`) không gửi lệnh nào — các trường hợp đó không chặn sự kiện.
async fn fire(st: &AppState, c: &Cond, why: AutoRun) -> ApiResult<()> {
    let claimed = sqlx::query(
        "UPDATE scenes SET last_run_at = now(), last_status = 'running'
          WHERE id = $1 AND (last_run_at IS NULL OR last_status IS NULL OR last_status IN ('missed', 'skipped')
                             OR last_run_at < now() - make_interval(secs => $2))",
    )
    .bind(c.id)
    .bind(COOLDOWN_SECS as f64)
    .execute(&st.db)
    .await?
    .rows_affected()
        == 1;
    if !claimed {
        return Ok(());
    }
    let outcome = automation::run_scene_actions(st, c.home_id, &c.actions, None, c.step_delay_ms).await.unwrap_or_default();
    let status = automation::status_of(&outcome);
    tracing::info!(scene = %c.id, sent = outcome.sent, total = outcome.total, status, "scene auto-ran on event");
    if outcome.sent > 0 {
        automation::activate_scene(st, c.home_id, c.id).await;
    }
    sqlx::query("UPDATE scenes SET last_status = $2 WHERE id = $1").bind(c.id).bind(status).execute(&st.db).await?;
    alerts::scene_auto_ran(st, c.home_id, c.id, why, outcome.sent > 0).await;
    Ok(())
}

fn spawn_fire(st: &AppState, c: Cond, why: AutoRun) {
    let st = st.clone();
    tokio::spawn(async move {
        if let Err(e) = fire(&st, &c, why).await {
            tracing::warn!(scene = %c.id, "scene trigger: {e:?}");
        }
    });
}

/// Người cuối cùng rời nhà (`Fired::Leave`) hoặc người đầu tiên về nhà (`Fired::Arrive`).
pub async fn on_presence(st: &AppState, hid: Uuid, fired: Fired) {
    let (col, why) = match fired {
        Fired::Leave => ("auto_leave", AutoRun::Leave),
        Fired::Arrive => ("auto_arrive", AutoRun::Arrive),
        _ => return,
    };
    let rows: Vec<Cond> = match sqlx::query_as(&format!("{COND_SELECT} WHERE s.home_id = $1 AND s.{col}")).bind(hid).fetch_all(&st.db).await {
        Ok(r) => r,
        Err(e) => return tracing::warn!(%hid, "presence triggers: {e}"),
    };
    let now = Utc::now();
    for c in rows {
        match others_hold(st, &c, fired, now).await {
            Ok(true) => spawn_fire(st, c, why.clone()),
            Ok(false) => tracing::info!(scene = %c.id, ?fired, "presence trigger: other conditions not met"),
            Err(e) => tracing::warn!(scene = %c.id, "presence trigger: {e:?}"),
        }
    }
}

/// Gọi mỗi khi một thiết bị báo trạng thái mới (sau alerts/rules). Lỗi chỉ ghi log.
pub async fn on_state(st: &AppState, home: Uuid, device: Uuid, old: &Value, new: &Value) {
    // Nhanh: thiết bị không phải cảm biến cửa/hiện diện thì bỏ qua, không truy vấn.
    if !SENSOR_EVENTS.iter().any(|e| sensor_event(e, old, new)) {
        return;
    }
    let rows: Vec<Cond> = match sqlx::query_as(&format!("{COND_SELECT} WHERE s.home_id = $1 AND s.trigger_sensors @> $2"))
        .bind(home)
        .bind(json!([{ "device_id": device }]))
        .fetch_all(&st.db)
        .await
    {
        Ok(r) => r,
        Err(e) => return tracing::warn!(%home, "sensor triggers: {e}"),
    };
    if rows.is_empty() {
        return;
    }
    let name: String = sqlx::query_scalar("SELECT name FROM devices WHERE id = $1").bind(device).fetch_optional(&st.db).await.ok().flatten().unwrap_or_default();
    let now = Utc::now();
    for c in rows {
        let hit = c.sensors().iter().enumerate().find(|(_, (d, ev))| *d == device && sensor_event(ev, old, new)).map(|(i, (_, ev))| (i, ev.clone()));
        let Some((i, ev)) = hit else { continue };
        match others_hold(st, &c, Fired::Sensor(i), now).await {
            Ok(true) => spawn_fire(st, c, AutoRun::Sensor(name.clone(), sensor_label(&ev))),
            Ok(false) => tracing::debug!(scene = %c.id, "sensor trigger: other conditions not met"),
            Err(e) => tracing::warn!(scene = %c.id, "sensor trigger: {e:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(h: u32, m: u32) -> NaiveTime {
        NaiveTime::from_hms_opt(h, m, 0).unwrap()
    }
    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }
    const ALL: [i16; 7] = [1, 2, 3, 4, 5, 6, 7];
    const VN: &str = "Asia/Ho_Chi_Minh";

    #[test]
    fn sensor_events_need_a_real_transition() {
        assert!(sensor_event("occupied", &json!({"occupancy": false}), &json!({"occupancy": true})));
        assert!(!sensor_event("occupied", &json!({}), &json!({"occupancy": true})), "trạng thái cũ chưa biết");
        assert!(!sensor_event("occupied", &json!({"occupancy": true}), &json!({"occupancy": true})), "phát lại");
        assert!(sensor_event("vacant", &json!({"occupancy": true}), &json!({"occupancy": false})));
        assert!(sensor_event("open", &json!({"contact": true}), &json!({"contact": false})));
        assert!(sensor_event("closed", &json!({"contact": false}), &json!({"contact": true})));
        assert!(!sensor_event("open", &json!({"contact": false}), &json!({"contact": true})));
        assert!(!sensor_event("bogus", &json!({"contact": true}), &json!({"contact": false})));
    }

    #[test]
    fn sensor_states() {
        assert!(sensor_state("open", &json!({"contact": false, "battery": 80})));
        assert!(!sensor_state("open", &json!({"contact": true})));
        assert!(sensor_state("occupied", &json!({"occupancy": true})));
        assert!(!sensor_state("occupied", &json!({})), "chưa có dữ liệu → không đúng");
    }

    #[test]
    fn time_window_same_day() {
        // 18:00–23:00 giờ VN = 11:00–16:00 UTC; 2026-11-13 là thứ Sáu.
        assert!(in_window(VN, t(18, 0), Some(t(23, 0)), &ALL, utc("2026-11-13T12:00:00Z")));
        assert!(!in_window(VN, t(18, 0), Some(t(23, 0)), &ALL, utc("2026-11-13T16:00:00Z")), "đúng 23:00 là hết khung");
        assert!(!in_window(VN, t(18, 0), Some(t(23, 0)), &ALL, utc("2026-11-13T10:59:00Z")));
        // chỉ thứ Hai → thứ Sáu không đúng
        assert!(!in_window(VN, t(18, 0), Some(t(23, 0)), &[1], utc("2026-11-13T12:00:00Z")));
    }

    #[test]
    fn time_window_across_midnight() {
        // 22:00–06:00, chỉ thứ Sáu (5). 02:00 sáng thứ Bảy (VN) = 19:00 UTC thứ Sáu → thuộc khung bắt đầu tối thứ Sáu.
        assert!(in_window(VN, t(22, 0), Some(t(6, 0)), &[5], utc("2026-11-13T19:00:00Z")));
        // 07:00 sáng thứ Bảy → đã hết khung
        assert!(!in_window(VN, t(22, 0), Some(t(6, 0)), &[5], utc("2026-11-14T00:00:00Z")));
        // 02:00 sáng thứ Sáu thuộc khung tối thứ Năm (4), không nằm trong [5]
        assert!(!in_window(VN, t(22, 0), Some(t(6, 0)), &[5], utc("2026-11-12T19:00:00Z")));
    }

    #[test]
    fn point_in_time_has_short_window() {
        assert!(in_window(VN, t(18, 0), None, &ALL, utc("2026-11-13T11:04:00Z")));
        assert!(!in_window(VN, t(18, 0), None, &ALL, utc("2026-11-13T11:06:00Z")));
    }
}
