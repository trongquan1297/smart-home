//! Gọi API HTTP của go2rtc (chỉ nghe 127.0.0.1 / mạng nội bộ của addon): khai báo luồng, WebRTC, ảnh chụp.
use std::time::Duration;

use anyhow::{bail, Result};
use serde_json::{json, Value};

#[derive(Clone)]
pub struct Go2rtc {
    base: String,
    http: reqwest::Client,
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

impl Go2rtc {
    pub fn new(base: &str) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().expect("http client");
        Go2rtc { base: base.trim_end_matches('/').to_string(), http }
    }

    async fn exists(&self, name: &str) -> Result<bool> {
        let v: Value = self.http.get(format!("{}/api/streams", self.base)).send().await?.json().await?;
        Ok(v.get(name).is_some())
    }

    /// Tạo hoặc thay luồng `name` lấy từ `src` (URL RTSP có mật khẩu — không ghi log).
    /// go2rtc cố lưu thay đổi vào file cấu hình; file gắn chỉ-đọc (cố ý, để mật khẩu không nằm trong cấu hình go2rtc) nên API
    /// trả 400 dù luồng đã tạo trong bộ nhớ — vì vậy xác nhận bằng danh sách luồng chứ không dựa vào mã trả về.
    pub async fn upsert(&self, name: &str, src: &str) -> Result<()> {
        self.remove(name).await;
        let _ = self.http.put(format!("{}/api/streams?name={}&src={}", self.base, enc(name), enc(src))).send().await?;
        if !self.exists(name).await? {
            bail!("go2rtc did not create stream {name}");
        }
        Ok(())
    }

    pub async fn remove(&self, name: &str) {
        let _ = self.http.delete(format!("{}/api/streams?src={}", self.base, enc(name))).send().await;
    }

    /// Đưa SDP offer của app cho go2rtc, nhận SDP answer.
    pub async fn webrtc(&self, name: &str, offer: &str) -> Result<String> {
        let r = self.http.post(format!("{}/api/webrtc?src={}", self.base, enc(name))).json(&json!({"type": "offer", "sdp": offer})).send().await?;
        if !r.status().is_success() {
            bail!("go2rtc webrtc: {}", r.status());
        }
        let v: Value = r.json().await?;
        match v.get("sdp").and_then(Value::as_str) {
            Some(s) => Ok(s.to_string()),
            None => bail!("go2rtc webrtc: no answer"),
        }
    }

    /// Ảnh JPEG hiện tại, thu nhỏ theo chiều rộng.
    pub async fn frame(&self, name: &str, width: u32) -> Result<Vec<u8>> {
        let r = self.http.get(format!("{}/api/frame.jpeg?src={}&w={width}", self.base, enc(name))).send().await?;
        if !r.status().is_success() {
            bail!("go2rtc frame: {}", r.status());
        }
        Ok(r.bytes().await?.to_vec())
    }
}
