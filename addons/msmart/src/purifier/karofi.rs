//! Giao thức Bluetooth LE của máy lọc nước Karofi (bộ điều khiển Makipos, tên quảng bá `TCM-*`).
//!
//! Viết lại từ tích hợp Home Assistant mã nguồn mở <https://github.com/luuquangvu/karofi> (giao thức do cộng đồng
//! tìm hiểu, Karofi không công bố). Phần này chỉ giải mã dữ liệu — không đụng tới Bluetooth — để kiểm thử được.
//!
//! Máy gửi các khung JSON (có khi bị cắt ra nhiều gói notify, có khi nhiều khung nối nhau), hai dạng:
//!   `{"iro_tds": 12, "iro_lTime": [..], "iro_hsd": [..], ...}`  hoặc  `{"pc": "iro_tds", "d": 12}`.
//! Thời gian lõi lọc tính bằng GIỜ: `iro_lTime` còn lại / `iro_hsd` định mức theo lịch,
//! `iro_rtr` còn lại / `iro_rtt` định mức theo giờ chạy bơm.
use serde_json::{json, Map, Value};

/// Dịch vụ dữ liệu, đặc tính notify (ac02) và lệnh (ab02 trong dịch vụ 12ab).
pub const SERVICE: u16 = 0x12ac;
pub const CMD_SERVICE: u16 = 0x12ab;
pub const NOTIFY: u16 = 0xac02;
pub const COMMAND: u16 = 0xab02;
pub const WIFI_PROV: u16 = 0xab01;

/// Yêu cầu máy gửi số liệu (không đóng khung SOH/EOT, ghi thành từng mẩu ≤ 19 byte).
pub const READ_REQUEST: &[u8] = br#"{"et":"NP"}"#;
pub const CHUNK: usize = 19;

/// Lệnh đặt lại lõi lọc thứ `index` (đếm từ 0), đóng khung SOH … EOT, ghi một lần.
pub fn reset_command(index: usize) -> Vec<u8> {
    let mut v = vec![0x01];
    v.extend_from_slice(format!(r#"{{"et":"CP","pc":"iro_rsft","d":{index}}}"#).as_bytes());
    v.push(0x04);
    v
}

pub fn is_karofi_name(name: &str) -> bool {
    name.trim().trim_matches('\0').to_ascii_lowercase().starts_with("tcm")
}

const MAX_TDS: i64 = 2000;
const TDS_SENTINEL: i64 = 0xFFFF;
const MAX_FILTER_HOURS: i64 = 24 * 365 * 50;
pub const MAX_FILTERS: usize = 16;
const MAX_HYDROGEN_PPB: i64 = 100_000;
const MAX_ALKALINE_LEVEL: i64 = 11;
/// Định mức mặc định (ngày) khi máy chưa báo `iro_hsd`.
const DEFAULT_LIFE_DAYS: [i64; 4] = [180, 270, 270, 730];

const TDS_KEYS: [&str; 4] = ["iro_tds", "tds", "pure_index", "pi"];
const H2_KEYS: [&str; 5] = ["hydrogenPpb", "iro_h2", "iro_hydrogen", "iro_h2Ppb", "hydrogen"];
const ALK_KEYS: [&str; 2] = ["iro_alk", "alkalineLevel"];
const MODE_KEYS: [&str; 4] = ["iro_mode", "iro_waterMode", "water_mode", "waterMode"];
const NAME_KEYS: [&str; 3] = ["iro_names", "filter_names", "names"];

/// Mọi object JSON trong một chuỗi byte (một khung, mảng khung, hoặc nhiều khung nối nhau lẫn byte rác).
pub fn json_dicts(bytes: &[u8]) -> Vec<Map<String, Value>> {
    let text = String::from_utf8_lossy(bytes);
    let s = text.as_ref();
    let mut out = Vec::new();
    let mut i = 0;
    while i < s.len() {
        let Some(rel) = s[i..].find(['{', '[']) else { break };
        let start = i + rel;
        let mut it = serde_json::Deserializer::from_str(&s[start..]).into_iter::<Value>();
        match it.next() {
            Some(Ok(v)) => {
                match v {
                    Value::Object(m) => out.push(m),
                    Value::Array(a) => out.extend(a.into_iter().filter_map(|x| if let Value::Object(m) = x { Some(m) } else { None })),
                    _ => {}
                }
                i = start + it.byte_offset().max(1);
            }
            _ => i = start + 1,
        }
    }
    out
}

/// Giá trị của thuộc tính: dạng `{"pc": key, "d": v}` hoặc khoá trực tiếp.
fn prop<'a>(m: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    if let (Some(pc), Some(d)) = (m.get("pc").and_then(Value::as_str), m.get("d")) {
        if keys.contains(&pc) {
            return Some(d);
        }
    }
    keys.iter().find_map(|k| m.get(*k))
}

fn scalar(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().filter(|f| f.is_finite()).map(|f| f as i64)),
        Value::String(s) => s.trim().parse::<f64>().ok().filter(|f| f.is_finite()).map(|f| f as i64),
        _ => None,
    }
}

/// Số nguyên đúng (không nhận số lẻ như 0.5, tránh làm tròn dữ liệu hỏng thành 0).
fn integral(v: &Value) -> Option<i64> {
    let v = match v {
        Value::Array(a) => a.first()?,
        x => x,
    };
    match v {
        Value::Bool(_) => None,
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && f.is_finite()).map(|f| f as i64)),
        Value::String(s) => {
            let f: f64 = s.split(',').next()?.trim().parse().ok()?;
            (f.fract() == 0.0 && f.is_finite()).then_some(f as i64)
        }
        _ => None,
    }
}

/// Danh sách số (mảng hoặc chuỗi "a,b,c"); phần tử hỏng giữ chỗ bằng None để khớp thứ tự lõi lọc.
fn int_list(v: &Value) -> Option<Vec<Option<i64>>> {
    let items: Vec<Option<i64>> = match v {
        Value::Array(a) => a.iter().map(scalar).collect(),
        Value::String(s) if s.contains(',') => s.split(',').map(|p| p.trim().parse::<f64>().ok().map(|f| f as i64)).collect(),
        _ => return None,
    };
    items.iter().any(Option::is_some).then_some(items)
}

fn hours_list(m: &Map<String, Value>, key: &str) -> Option<Vec<Option<i64>>> {
    let l = int_list(prop(m, &[key])?)?;
    let l: Vec<Option<i64>> = l.into_iter().map(|x| x.filter(|h| h.abs() <= MAX_FILTER_HOURS)).collect();
    l.iter().any(Option::is_some).then_some(l)
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Filter {
    pub name: Option<String>,
    /// Giờ còn lại / định mức theo lịch.
    pub remain_h: Option<i64>,
    pub life_h: Option<i64>,
    /// Giờ chạy còn lại / định mức giờ chạy.
    pub run_remain_h: Option<i64>,
    pub run_total_h: Option<i64>,
}

impl Filter {
    fn merge(&mut self, o: Filter) {
        self.name = o.name.or(self.name.take());
        self.remain_h = o.remain_h.or(self.remain_h);
        self.life_h = o.life_h.or(self.life_h);
        self.run_remain_h = o.run_remain_h.or(self.run_remain_h);
        self.run_total_h = o.run_total_h.or(self.run_total_h);
    }

    fn life_hours(&self, index: usize) -> i64 {
        self.life_h.filter(|h| *h > 0).unwrap_or_else(|| DEFAULT_LIFE_DAYS.get(index).copied().unwrap_or(365) * 24)
    }

    /// % còn lại = mức thấp hơn giữa theo lịch và theo giờ chạy (dùng nhiều thì hết sớm dù còn hạn).
    pub fn percent(&self, index: usize) -> Option<i64> {
        let cal = self.remain_h.map(|r| pct(r, self.life_hours(index)));
        let run = match (self.run_remain_h, self.run_total_h) {
            (Some(r), Some(t)) if t > 0 => Some(pct(r, t)),
            _ => None,
        };
        match (cal, run) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }
}

fn pct(remain: i64, total: i64) -> i64 {
    ((remain as f64 / total as f64) * 100.0).round().clamp(0.0, 100.0) as i64
}

/// Trạng thái đã biết của một máy (ghép dần từ nhiều khung).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Status {
    pub tds: Option<i64>,
    pub filters: Vec<Filter>,
    pub errors: Option<Vec<i64>>,
    pub hydrogen_ppb: Option<i64>,
    pub alkaline_level: Option<i64>,
    pub water_mode: Option<&'static str>,
}

impl Status {
    /// Cập nhật từ dữ liệu thô (đọc đặc tính hoặc notify). Trả về true nếu có thông tin hữu ích.
    pub fn apply(&mut self, bytes: &[u8]) -> bool {
        let mut any = false;
        for m in json_dicts(bytes) {
            any |= self.apply_dict(&m);
        }
        any
    }

    fn apply_dict(&mut self, m: &Map<String, Value>) -> bool {
        let mut any = false;
        // TDS: `pc=iro_tds`, khoá trực tiếp, hoặc khung chỉ có {"d": .., "id": ..}.
        let raw = prop(m, &TDS_KEYS).or_else(|| {
            (m.contains_key("d") && !m.contains_key("et") && !m.contains_key("pc") && m.keys().all(|k| k == "d" || k == "id")).then(|| &m["d"])
        });
        if let Some(t) = raw.and_then(|v| match v {
            Value::Array(a) => a.first().and_then(scalar),
            Value::String(s) => s.split(',').next().and_then(|p| p.trim().parse::<f64>().ok()).map(|f| f as i64),
            x => scalar(x),
        }) {
            any = true;
            self.tds = ((0..=MAX_TDS).contains(&t) && t != TDS_SENTINEL).then_some(t);
        }

        let (lt, hsd, rtr, rtt) = (hours_list(m, "iro_lTime"), hours_list(m, "iro_hsd"), hours_list(m, "iro_rtr"), hours_list(m, "iro_rtt"));
        let names: Option<Vec<Option<String>>> = NAME_KEYS.iter().find_map(|k| m.get(*k)?.as_array()).map(|a| {
            a.iter().map(|x| x.as_str().map(str::trim).filter(|s| !s.is_empty()).map(|s| s.chars().take(40).collect())).collect()
        });
        let n = [lt.as_ref().map(Vec::len), hsd.as_ref().map(Vec::len), rtr.as_ref().map(Vec::len), rtt.as_ref().map(Vec::len), names.as_ref().map(Vec::len)]
            .into_iter()
            .flatten()
            .max()
            .unwrap_or(0)
            .min(MAX_FILTERS);
        if n > 0 {
            any = true;
            if self.filters.len() < n {
                self.filters.resize(n, Filter::default());
            }
            let at = |l: &Option<Vec<Option<i64>>>, i: usize| l.as_ref().and_then(|l| l.get(i).copied().flatten());
            for i in 0..n {
                self.filters[i].merge(Filter {
                    name: names.as_ref().and_then(|l| l.get(i).cloned().flatten()),
                    remain_h: at(&lt, i).map(|h| h.max(0)),
                    life_h: at(&hsd, i).filter(|h| *h > 0),
                    run_remain_h: at(&rtr, i).map(|h| h.max(0)),
                    run_total_h: at(&rtt, i).map(|h| h.max(0)),
                });
            }
        }

        if let Some(v) = prop(m, &["iro_errs"]) {
            let errs = match v {
                Value::Array(a) if a.is_empty() => Some(vec![]),
                _ => int_list(v).map(|l| l.into_iter().flatten().filter(|c| *c > 0).collect()).or_else(|| integral(v).map(|c| if c > 0 { vec![c] } else { vec![] })),
            };
            if let Some(e) = errs {
                any = true;
                self.errors = Some(e);
            }
        }

        if let Some(h) = prop(m, &H2_KEYS).and_then(integral).filter(|h| (0..=MAX_HYDROGEN_PPB).contains(h)) {
            any = true;
            self.hydrogen_ppb = Some(h);
        }
        let level = prop(m, &ALK_KEYS).and_then(water_mode);
        let mode = prop(m, &MODE_KEYS).and_then(water_mode);
        if let Some((l, md)) = level {
            any = true;
            if l.is_some() {
                self.alkaline_level = l;
            }
            if mode.is_none() {
                self.water_mode = Some(md);
            }
        }
        if let Some((l, md)) = mode {
            any = true;
            if level.is_none() && l.is_some() {
                self.alkaline_level = l;
            }
            self.water_mode = Some(md);
        }
        any
    }

    /// Chất lượng nước theo TDS sau màng RO: tốt < 50 ppm, khá ≤ 150, kém > 150.
    pub fn quality(&self) -> &'static str {
        match self.tds {
            None => "unknown",
            Some(t) if t < 50 => "good",
            Some(t) if t <= 150 => "fair",
            _ => "poor",
        }
    }

    /// Trạng thái gửi lên cloud (lưu vào `devices.state`).
    pub fn to_json(&self) -> Value {
        let filters: Vec<Value> = self
            .filters
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let mut o = json!({ "no": i + 1, "percent": f.percent(i) });
                if let Some(n) = &f.name {
                    o["name"] = json!(n);
                }
                if let Some(r) = f.remain_h {
                    o["days_left"] = json!((r as f64 / 24.0).round() as i64);
                    o["life_days"] = json!(((f.life_hours(i) as f64) / 24.0).round().max(1.0) as i64);
                }
                if let (Some(r), Some(t)) = (f.run_remain_h, f.run_total_h) {
                    o["hours_left"] = json!(r);
                    o["hours_total"] = json!(t);
                }
                o
            })
            .collect();
        let min = self.filters.iter().enumerate().filter_map(|(i, f)| f.percent(i)).min();
        let mut s = json!({ "tds": self.tds, "quality": self.quality(), "filters": filters, "filter_min": min });
        if let Some(e) = &self.errors {
            s["errors"] = json!(e);
        }
        if let Some(h) = self.hydrogen_ppb {
            s["hydrogen"] = json!(h);
        }
        if let Some(m) = self.water_mode {
            s["water_mode"] = json!(m);
        }
        if let Some(l) = self.alkaline_level {
            s["alkaline_level"] = json!(l);
        }
        s
    }
}

/// (mức kiềm, chế độ nước): số 0 = tinh khiết, 1..5 = kiềm, lớn hơn = chế độ khác; hoặc tên chế độ.
fn water_mode(v: &Value) -> Option<(Option<i64>, &'static str)> {
    if let Some(s) = v.as_str() {
        let k = s.trim().to_lowercase().replace(['-', ' '], "_");
        let m = match k.as_str() {
            "pure" | "pure_water" => Some("pure"),
            "alkaline" | "alkaline_water" => Some("alkaline"),
            "hydrogen" | "alkaline_hydro_ion" | "alkaline_hydro_ions695" => Some("hydrogen"),
            "skin_care" | "skin_lotion" => Some("skin_care"),
            "hot" | "hot_water" => Some("hot"),
            "cold" | "cool_water" => Some("cold"),
            "cold_water" => Some("ambient"),
            "soda_water" => Some("soda"),
            _ => None,
        };
        if let Some(m) = m {
            return Some((if m == "pure" { Some(0) } else { None }, m));
        }
    }
    let l = integral(v).filter(|l| (0..=MAX_ALKALINE_LEVEL).contains(l))?;
    Some((Some(l), if l == 0 { "pure" } else if l <= 5 { "alkaline" } else { "other" }))
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_split_and_concatenated() {
        let mut s = Status::default();
        // một khung bị cắt thành hai gói notify, ghép lại mới đọc được
        let a = br#"{"iro_tds":[12],"iro_lTime":[2160,4320],"#;
        let b = br#""iro_hsd":[4320,6480],"iro_errs":[]}{"pc":"iro_rtr","d":"100,50"}"#;
        assert!(s.apply(&[&a[..], &b[..]].concat()));
        assert_eq!(s.tds, Some(12));
        assert_eq!(s.quality(), "good");
        assert_eq!(s.filters.len(), 2);
        assert_eq!(s.filters[0].percent(0), Some(50));
        assert_eq!(s.errors, Some(vec![]));
        assert_eq!(s.filters[1].run_remain_h, Some(50));
        // giờ chạy: chỉ tính khi có định mức
        assert!(s.apply(br#"{"iro_rtt":[1000,100]}"#));
        assert_eq!(s.filters[1].percent(1), Some(50)); // min(4320/6480=67%, 50/100=50%)
        let j = s.to_json();
        assert_eq!(j["filter_min"], 10); // lõi 1: min(50%, 100/1000=10%)
        assert_eq!(j["filters"][0]["days_left"], 90);
        assert_eq!(j["filters"][0]["life_days"], 180);
    }

    #[test]
    fn pc_form_errors_and_sentinels() {
        let mut s = Status::default();
        assert!(s.apply(b"\x01{\"pc\":\"iro_tds\",\"d\":65535}\x04"));
        assert_eq!(s.tds, None);
        assert!(s.apply(br#"{"d":180,"id":"12ac"}"#));
        assert_eq!((s.tds, s.quality()), (Some(180), "poor"));
        assert!(s.apply(br#"{"pc":"iro_errs","d":[2,0,5]}"#));
        assert_eq!(s.errors, Some(vec![2, 5]));
        assert!(s.apply(br#"{"iro_errs":0}"#));
        assert_eq!(s.errors, Some(vec![]));
        assert!(!s.apply(br#"{"et":"NP"}"#)); // khung bắt tay, không có số liệu
        assert!(s.apply(br#"{"iro_alk":3,"hydrogenPpb":450}"#));
        assert_eq!((s.alkaline_level, s.water_mode, s.hydrogen_ppb), (Some(3), Some("alkaline"), Some(450)));
        assert!(s.apply(br#"{"water_mode":"hot water"}"#));
        assert_eq!(s.water_mode, Some("hot"));
    }

    #[test]
    fn reset_frame() {
        assert_eq!(reset_command(2), b"\x01{\"et\":\"CP\",\"pc\":\"iro_rsft\",\"d\":2}\x04".to_vec());
        assert!(is_karofi_name("TCM-112233") && !is_karofi_name("Mi Band"));
    }
}
