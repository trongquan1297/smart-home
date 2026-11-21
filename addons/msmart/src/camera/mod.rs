//! Camera Wi‑Fi (RTSP/ONVIF) trong addon:
//!
//!   Camera ⇄ go2rtc (cùng máy) ⇄ [addon] ⇄ WebSocket (outbound) ⇄ Cloud backend ⇄ App
//!
//! - Thêm camera: đọc luồng RTSP/PTZ/sự kiện qua ONVIF, lưu mật khẩu TẠI CHỖ (`$DATA_DIR/cameras.json`), khai báo luồng cho go2rtc.
//! - Xem trực tiếp: chuyển SDP offer/answer giữa app và go2rtc (WebRTC đi thẳng điện thoại ↔ máy này); ảnh chụp làm dự phòng.
//! - PTZ (ONVIF ContinuousMove/Stop) và cảnh báo chuyển động (ONVIF PullPoint) — go2rtc không có hai phần này.
//! - Bản tin cloud → addon: `cam_*`; addon → cloud: `cam_list`, `cam_status`, `cam_event`, `cam_reply`.
mod go2rtc;
mod onvif;
mod store;

use std::{
    collections::HashMap,
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use tokio::task::JoinHandle;
use tracing::{info, warn};

use self::{go2rtc::Go2rtc, store::Camera, store::Store};
use crate::Up;

pub struct Cameras {
    store: Mutex<Store>,
    go2rtc: Go2rtc,
    up: Up,
    watchers: Mutex<HashMap<String, JoinHandle<()>>>,
    online: Mutex<HashMap<String, bool>>,
}

/// Id camera do cloud cấp (UUID) — cũng là tên luồng trong go2rtc, nên chỉ nhận đúng định dạng.
fn valid_id(id: &str) -> bool {
    id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

/// Lỗi trả về app: chỉ dùng mã ngắn, không lộ URL/mật khẩu.
fn short_err(e: &anyhow::Error) -> &'static str {
    let s = format!("{e:#}");
    if s.contains("unauthorized") {
        "unauthorized"
    } else if s.contains("connect") || s.contains("timed out") || s.contains("error sending request") {
        "unreachable"
    } else if s.contains("no ONVIF media") || s.contains("onvif") {
        "onvif_error"
    } else {
        "failed"
    }
}

impl Cameras {
    pub fn load(data: &Path, go2rtc_url: &str, up: Up) -> Arc<Self> {
        Arc::new(Cameras {
            store: Mutex::new(Store::load(data.join("cameras.json"))),
            go2rtc: Go2rtc::new(go2rtc_url),
            up,
            watchers: Mutex::new(HashMap::new()),
            online: Mutex::new(HashMap::new()),
        })
    }

    pub fn count(&self) -> usize {
        self.store.lock().unwrap().cameras.len()
    }

    /// Chạy nền: khai báo lại luồng cho go2rtc (go2rtc không nhớ luồng thêm qua API sau khi khởi động lại),
    /// bật theo dõi chuyển động, và mỗi phút kiểm tra camera còn với tới được không.
    pub async fn run(self: Arc<Self>) {
        let cams: Vec<(String, Camera)> = self.store.lock().unwrap().cameras.clone().into_iter().collect();
        for (id, cam) in cams {
            while let Err(e) = self.go2rtc.upsert(&id, &cam.rtsp_url).await {
                warn!("go2rtc not ready ({e}); retry in 3s");
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
            self.start_watcher(&id, &cam);
        }
        self.status_loop().await;
    }

    /// Khi vừa kết nối cloud: báo danh sách camera đang giữ + trạng thái online để cloud đồng bộ.
    pub fn on_connect(&self) {
        let cams: Vec<Value> = {
            let online = self.online.lock().unwrap();
            self.store.lock().unwrap().cameras.keys().map(|id| json!({"camera_id": id, "online": online.get(id).copied().unwrap_or(false)})).collect()
        };
        let _ = self.up.try_send(json!({"type": "cam_list", "cameras": cams}).to_string());
    }

    pub async fn handle(self: Arc<Self>, v: &Value) {
        let id = v.get("id").cloned().unwrap_or(Value::Null);
        let cam_id = v.get("camera_id").and_then(Value::as_str).filter(|c| valid_id(c)).map(str::to_string);
        let reply = |body: Value| {
            // Lệnh gửi kiểu "không chờ" (vd cam_remove từ API xoá) không có id → không trả lời.
            if id.is_null() {
                return;
            }
            let mut r = body;
            r["type"] = json!("cam_reply");
            r["id"] = id.clone();
            let _ = self.up.try_send(r.to_string());
        };
        match v.get("type").and_then(Value::as_str) {
            Some("cam_scan") => match onvif::discover(Duration::from_secs(3)).await {
                Ok(found) => reply(json!({ "devices": found })),
                Err(e) => {
                    warn!("discovery failed: {e:#}");
                    reply(json!({ "error": "discovery_unavailable" }))
                }
            },
            Some("cam_add") => {
                let Some(cid) = cam_id else { return reply(json!({"error": "bad_request"})) };
                match self.add(&cid, v).await {
                    Ok(info) => reply(json!({ "info": info })),
                    Err(e) => {
                        warn!(camera = cid, "add failed: {e:#}");
                        reply(json!({ "error": short_err(&e) }))
                    }
                }
            }
            Some("cam_remove") => {
                if let Some(cid) = cam_id {
                    if let Some(h) = self.watchers.lock().unwrap().remove(&cid) {
                        h.abort();
                    }
                    self.go2rtc.remove(&cid).await;
                    let mut s = self.store.lock().unwrap();
                    s.cameras.remove(&cid);
                    let _ = s.save();
                    info!(camera = cid, "camera removed");
                }
                reply(json!({ "ok": true }))
            }
            Some("cam_webrtc") => {
                let (Some(cid), Some(sdp)) = (cam_id, v.get("sdp").and_then(Value::as_str)) else { return reply(json!({"error": "bad_request"})) };
                if !self.store.lock().unwrap().cameras.contains_key(&cid) {
                    return reply(json!({"error": "unknown_camera"}));
                }
                match self.go2rtc.webrtc(&cid, sdp).await {
                    Ok(answer) => reply(json!({ "sdp": answer })),
                    Err(e) => {
                        warn!(camera = cid, "webrtc failed: {e:#}");
                        reply(json!({ "error": "stream_unavailable" }))
                    }
                }
            }
            Some("cam_snapshot") => {
                let Some(cid) = cam_id else { return reply(json!({"error": "bad_request"})) };
                if !self.store.lock().unwrap().cameras.contains_key(&cid) {
                    return reply(json!({"error": "unknown_camera"}));
                }
                let w = v.get("width").and_then(Value::as_u64).unwrap_or(640).clamp(160, 1280) as u32;
                match self.go2rtc.frame(&cid, w).await {
                    Ok(jpeg) => reply(json!({ "jpeg": B64.encode(jpeg) })),
                    Err(e) => {
                        warn!(camera = cid, "snapshot failed: {e:#}");
                        reply(json!({ "error": "stream_unavailable" }))
                    }
                }
            }
            Some("cam_ptz") => {
                let Some(cid) = cam_id else { return };
                let f = |k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0) as f32;
                let cam = self.store.lock().unwrap().cameras.get(&cid).cloned();
                let Some(cam) = cam else { return };
                let Some(p) = cam.onvif.as_ref().filter(|p| p.ptz_url.is_some()) else { return };
                let mut c = onvif::Client::new(&cam.host, cam.port, &cam.username, &cam.password);
                let _ = c.sync_clock().await;
                if let Err(e) = c.ptz_move(p.ptz_url.as_deref().unwrap_or_default(), &p.profile, f("pan"), f("tilt"), f("zoom")).await {
                    warn!(camera = cid, "ptz failed: {e:#}");
                }
            }
            _ => {}
        }
    }

    /// Thêm/cập nhật camera: kiểm tra kết nối thật (ONVIF hoặc RTSP), lưu tại chỗ, khai báo go2rtc, bật theo dõi chuyển động.
    async fn add(self: &Arc<Self>, cid: &str, v: &Value) -> anyhow::Result<Value> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().trim().to_string();
        let host = s("host");
        let port = v.get("port").and_then(Value::as_u64).unwrap_or(80) as u16;
        let (user, pass, manual) = (s("username"), v.get("password").and_then(Value::as_str).unwrap_or_default().to_string(), s("rtsp_url"));
        let cam = if !manual.is_empty() {
            anyhow::ensure!(manual.starts_with("rtsp://") || manual.starts_with("rtsps://"), "bad rtsp url");
            let host = manual.split("://").nth(1).and_then(|r| r.rsplit('@').next()).and_then(|r| r.split(['/', ':']).next()).unwrap_or_default().to_string();
            Camera { host, port: 554, username: user.clone(), password: pass.clone(), onvif: None, rtsp_url: onvif::with_credentials(&manual, &user, &pass) }
        } else {
            anyhow::ensure!(host.parse::<std::net::IpAddr>().is_ok() || host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-'), "bad host");
            let mut c = onvif::Client::new(&host, port, &user, &pass);
            let probe = c.probe().await?;
            Camera { host, port, username: user, password: pass, rtsp_url: probe.rtsp_url.clone(), onvif: Some(probe) }
        };
        self.go2rtc.upsert(cid, &cam.rtsp_url).await?;
        {
            let mut st = self.store.lock().unwrap();
            st.cameras.insert(cid.to_string(), cam.clone());
            st.save()?;
        }
        self.online.lock().unwrap().insert(cid.to_string(), true);
        self.start_watcher(cid, &cam);
        let p = cam.onvif.as_ref();
        info!(camera = cid, ptz = p.is_some_and(|p| p.ptz_url.is_some()), events = p.is_some_and(|p| p.events_url.is_some()), "camera added");
        Ok(json!({
            "ptz": p.is_some_and(|p| p.ptz_url.is_some()),
            "events": p.is_some_and(|p| p.events_url.is_some()),
            "manufacturer": p.and_then(|p| p.manufacturer.clone()),
            "model": p.and_then(|p| p.model.clone()),
            "host": cam.host,
        }))
    }

    /// Theo dõi sự kiện chuyển động ONVIF của một camera (chạy nền tới khi camera bị xoá).
    fn start_watcher(self: &Arc<Self>, cid: &str, cam: &Camera) {
        if let Some(h) = self.watchers.lock().unwrap().remove(cid) {
            h.abort();
        }
        let Some(events_url) = cam.onvif.as_ref().and_then(|p| p.events_url.clone()) else { return };
        let (up, cid2, cam) = (self.up.clone(), cid.to_string(), cam.clone());
        let h = tokio::spawn(async move {
            loop {
                let mut c = onvif::Client::new(&cam.host, cam.port, &cam.username, &cam.password);
                let _ = c.sync_clock().await;
                match c.subscribe(&events_url).await {
                    Ok(sub) => {
                        info!(camera = cid2, "motion events subscribed");
                        let mut renew = tokio::time::Instant::now() + Duration::from_secs(300);
                        let mut moving = false;
                        loop {
                            if tokio::time::Instant::now() >= renew {
                                if c.renew(&sub).await.is_err() {
                                    break;
                                }
                                renew = tokio::time::Instant::now() + Duration::from_secs(300);
                            }
                            match c.pull(&sub).await {
                                Ok(states) => {
                                    for s in states {
                                        // Chỉ báo khi chuyển từ không → có chuyển động.
                                        if s && !moving {
                                            let _ = up.try_send(json!({"type": "cam_event", "camera_id": cid2, "kind": "motion"}).to_string());
                                        }
                                        moving = s;
                                    }
                                }
                                Err(e) => {
                                    warn!(camera = cid2, "pull failed: {e:#}");
                                    break;
                                }
                            }
                        }
                        c.unsubscribe(&sub).await;
                    }
                    Err(e) => warn!(camera = cid2, "events subscribe failed: {e:#}"),
                }
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        });
        self.watchers.lock().unwrap().insert(cid.to_string(), h);
    }

    /// Mỗi phút kiểm tra camera còn với tới được không (mở TCP tới cổng camera) và báo cloud khi đổi trạng thái.
    async fn status_loop(&self) {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            let cams: Vec<(String, String, u16)> = self
                .store
                .lock()
                .unwrap()
                .cameras
                .iter()
                .map(|(id, c)| {
                    let rtsp_port = c.rtsp_url.split("://").nth(1).and_then(|r| r.rsplit('@').next()).and_then(|r| r.split('/').next()).and_then(|hp| hp.rsplit_once(':')).and_then(|(_, p)| p.parse().ok()).unwrap_or(554);
                    (id.clone(), c.host.clone(), if c.onvif.is_some() { c.port } else { rtsp_port })
                })
                .collect();
            for (id, host, port) in cams {
                let ok = matches!(tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect((host.as_str(), port))).await, Ok(Ok(_)));
                let changed = self.online.lock().unwrap().insert(id.clone(), ok) != Some(ok);
                if changed {
                    let _ = self.up.try_send(json!({"type": "cam_status", "camera_id": id, "online": ok}).to_string());
                }
            }
        }
    }
}
