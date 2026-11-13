//! Giới hạn tốc độ trong RAM (cửa sổ trượt) cho các endpoint dễ bị dò mật khẩu / spam.
//! Một tiến trình backend duy nhất: nếu chạy nhiều bản sao phía sau load balancer, mỗi bản có bộ đếm riêng
//! (giới hạn thực tế = N × ngưỡng) — khi đó cần chuyển sang Redis/Postgres hoặc đặt rule ở Cloudflare.
use std::{
    net::{IpAddr, SocketAddr},
    time::{Duration, Instant},
};

use axum::http::{HeaderMap, HeaderName};
use dashmap::DashMap;

use crate::error::{ApiError, ApiResult};

/// Số khoá tối đa: kẻ tấn công đổi email/IP liên tục không làm phình bộ nhớ vô hạn.
const MAX_KEYS: usize = 100_000;
/// Số lần ghi nhận tối đa giữ lại cho mỗi khoá.
const MAX_HITS: usize = 64;
/// Cửa sổ dài nhất đang dùng — dùng để dọn rác.
const GC_WINDOW: Duration = Duration::from_secs(3600);

#[derive(Default)]
pub struct Limiter {
    hits: DashMap<String, Vec<Instant>>,
}

impl Limiter {
    /// Từ chối (429 + Retry-After) nếu khoá đã đạt `max` lần trong `window`. Không ghi nhận lần gọi này.
    pub fn check(&self, key: &str, max: usize, window: Duration) -> ApiResult<()> {
        if let Some(mut e) = self.hits.get_mut(key) {
            let now = Instant::now();
            e.retain(|t| now.duration_since(*t) < window);
            if e.len() >= max {
                let wait = window.saturating_sub(now.duration_since(e[0]));
                return Err(ApiError::TooManyRequests(wait.as_secs() + 1));
            }
        }
        Ok(())
    }

    /// Ghi nhận một lần (thất bại / một lần gọi) cho khoá.
    pub fn record(&self, key: &str) {
        if !self.hits.contains_key(key) && self.hits.len() >= MAX_KEYS {
            return;
        }
        let mut e = self.hits.entry(key.to_owned()).or_default();
        if e.len() >= MAX_HITS {
            e.remove(0);
        }
        e.push(Instant::now());
    }

    pub fn clear(&self, key: &str) {
        self.hits.remove(key);
    }

    /// Dọn các khoá đã hết hạn (gọi định kỳ).
    pub fn gc(&self) {
        let now = Instant::now();
        self.hits.retain(|_, v| {
            v.retain(|t| now.duration_since(*t) < GC_WINDOW);
            !v.is_empty()
        });
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.hits.len()
    }
}

/// IP của client dùng làm khoá giới hạn.
/// - Mặc định: địa chỉ kết nối TCP.
/// - Nếu đặt `TRUSTED_IP_HEADER` (vd `CF-Connecting-IP` khi backend CHỈ truy cập được qua Cloudflare Tunnel):
///   lấy IP từ header đó (phần tử đầu tiên). Không đặt biến này khi backend lộ trực tiếp ra Internet —
///   client sẽ giả mạo header để né giới hạn.
/// IPv6 gộp theo /64 để không đổi địa chỉ trong cùng một dải là né được giới hạn.
pub fn client_ip(headers: &HeaderMap, peer: SocketAddr, trusted: Option<&HeaderName>) -> IpAddr {
    let from_header = trusted
        .and_then(|h| headers.get(h))
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split(',').next())
        .and_then(|v| v.trim().parse::<IpAddr>().ok());
    match from_header.unwrap_or_else(|| peer.ip()) {
        IpAddr::V6(v6) => {
            let mut o = v6.octets();
            o[8..].fill(0);
            IpAddr::V6(o.into())
        }
        v4 => v4,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: Duration = Duration::from_secs(60);

    #[test]
    fn blocks_after_max_and_reports_retry_after() {
        let l = Limiter::default();
        for _ in 0..3 {
            assert!(l.check("k", 3, W).is_ok());
            l.record("k");
        }
        match l.check("k", 3, W) {
            Err(ApiError::TooManyRequests(s)) => assert!((1..=61).contains(&s)),
            _ => panic!("phải bị chặn"),
        }
        assert!(l.check("other", 3, W).is_ok(), "khoá khác không bị ảnh hưởng");
    }

    #[test]
    fn window_expires_and_clear_resets() {
        let l = Limiter::default();
        l.record("k");
        std::thread::sleep(Duration::from_millis(30));
        assert!(l.check("k", 1, Duration::from_millis(10)).is_ok(), "ngoài cửa sổ thì hết bị tính");
        l.record("k");
        assert!(l.check("k", 1, W).is_err());
        l.clear("k");
        assert!(l.check("k", 1, W).is_ok());
    }

    #[test]
    fn key_count_is_bounded() {
        let l = Limiter::default();
        for i in 0..(MAX_KEYS + 50) {
            l.record(&format!("k{i}"));
        }
        assert_eq!(l.len(), MAX_KEYS);
        l.record("k0"); // khoá đã có (1 lần) vẫn ghi nhận thêm được → 2 lần
        assert!(l.check("k0", 3, W).is_ok());
        assert!(l.check("k0", 2, W).is_err());
        l.record("khoá-mới-khi-đã-đầy"); // khoá mới bị bỏ qua khi đã đầy
        assert_eq!(l.len(), MAX_KEYS);
    }

    #[test]
    fn ip_header_only_when_trusted_and_v6_masked() {
        let peer: SocketAddr = "10.0.0.5:1234".parse().unwrap();
        let hn = HeaderName::from_static("cf-connecting-ip");
        let mut h = HeaderMap::new();
        h.insert("cf-connecting-ip", "203.0.113.9, 1.2.3.4".parse().unwrap());
        assert_eq!(client_ip(&h, peer, None).to_string(), "10.0.0.5", "không tin header khi chưa cấu hình");
        assert_eq!(client_ip(&h, peer, Some(&hn)).to_string(), "203.0.113.9");
        h.insert("cf-connecting-ip", "rác".parse().unwrap());
        assert_eq!(client_ip(&h, peer, Some(&hn)).to_string(), "10.0.0.5", "header sai → dùng IP kết nối");
        h.insert("cf-connecting-ip", "2001:db8:1:2:aaaa:bbbb:cccc:dddd".parse().unwrap());
        assert_eq!(client_ip(&h, peer, Some(&hn)).to_string(), "2001:db8:1:2::");
    }
}
