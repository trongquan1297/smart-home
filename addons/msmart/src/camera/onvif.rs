//! Client ONVIF tối thiểu: tìm camera (WS-Discovery), đọc luồng RTSP, điều khiển PTZ và nhận sự kiện chuyển động (PullPoint).
//! go2rtc không có PTZ/sự kiện nên addon tự nói chuyện ONVIF với camera.
//! Xác thực bằng WS-Security UsernameToken (PasswordDigest), có bù lệch đồng hồ camera.
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rand::RngCore;
use sha1::{Digest, Sha1};

const SOAP12: &str = "http://www.w3.org/2003/05/soap-envelope";

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    pub device_url: String,
    user: String,
    pass: String,
    /// Đồng hồ camera − đồng hồ máy này (giây). WS-Security từ chối nếu thời điểm tạo lệch quá xa giờ camera.
    clock_offset: i64,
}

/// Thông tin đọc được khi thêm camera.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Probe {
    pub rtsp_url: String,
    pub profile: String,
    pub ptz_url: Option<String>,
    pub events_url: Option<String>,
    pub manufacturer: Option<String>,
    pub model: Option<String>,
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// PasswordDigest = Base64(SHA1(nonce + created + password)).
pub fn password_digest(nonce: &[u8], created: &str, password: &str) -> String {
    let mut h = Sha1::new();
    h.update(nonce);
    h.update(created.as_bytes());
    h.update(password.as_bytes());
    B64.encode(h.finalize())
}

/// Tìm phần tử con (theo tên cục bộ, bỏ namespace) ở mọi cấp.
fn find<'a>(n: roxmltree::Node<'a, 'a>, name: &str) -> Option<roxmltree::Node<'a, 'a>> {
    n.descendants().find(|d| d.is_element() && d.tag_name().name() == name)
}

fn text_of(n: roxmltree::Node, name: &str) -> Option<String> {
    find(n, name).and_then(|x| x.text()).map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

/// XAddr của một dịch vụ trong GetCapabilities (vd "Media", "PTZ", "Events").
fn xaddr(doc: &roxmltree::Document, service: &str) -> Option<String> {
    let root = doc.root();
    let svc = root.descendants().find(|d| d.is_element() && d.tag_name().name() == service)?;
    text_of(svc, "XAddr")
}

/// Camera thường báo XAddr bằng IP nội bộ của nó; nếu camera nằm sau NAT/docker thì địa chỉ đó sai — giữ đường dẫn, thay host:port
/// bằng địa chỉ người dùng đã nhập.
pub fn rebase(url: &str, device_url: &str) -> String {
    let host_of = |u: &str| u.split("://").nth(1).and_then(|r| r.split('/').next()).map(str::to_string);
    match (host_of(url), host_of(device_url)) {
        (Some(h), Some(d)) if h != d => url.replacen(&h, &d, 1),
        _ => url.to_string(),
    }
}

/// Như `rebase` nhưng chỉ thay host, giữ cổng (RTSP chạy cổng khác cổng ONVIF).
pub fn rebase_host(url: &str, host: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else { return url.to_string() };
    let (auth_host, path) = rest.split_once('/').map(|(a, p)| (a, format!("/{p}"))).unwrap_or((rest, String::new()));
    let (auth, hp) = auth_host.rsplit_once('@').map(|(a, h)| (format!("{a}@"), h)).unwrap_or((String::new(), auth_host));
    let port = hp.rsplit_once(':').map(|(_, p)| format!(":{p}")).unwrap_or_default();
    format!("{scheme}://{auth}{host}{port}{path}")
}

/// Chèn user:pass vào URL RTSP (go2rtc cần URL đầy đủ). Ký tự đặc biệt được mã hoá phần trăm.
pub fn with_credentials(rtsp: &str, user: &str, pass: &str) -> String {
    if user.is_empty() || rtsp.contains('@') {
        return rtsp.to_string();
    }
    let enc = |s: &str| {
        s.bytes()
            .map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
            .collect::<String>()
    };
    match rtsp.split_once("://") {
        Some((scheme, rest)) => format!("{scheme}://{}:{}@{rest}", enc(user), enc(pass)),
        None => rtsp.to_string(),
    }
}

impl Client {
    pub fn new(host: &str, port: u16, user: &str, pass: &str) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(8)).build().expect("http client");
        Client { http, device_url: format!("http://{host}:{port}/onvif/device_service"), user: user.into(), pass: pass.into(), clock_offset: 0 }
    }

    fn host(&self) -> String {
        let hp = self.device_url.trim_start_matches("http://").split('/').next().unwrap_or_default();
        hp.rsplit_once(':').map(|(h, _)| h).unwrap_or(hp).to_string()
    }

    fn security(&self) -> String {
        if self.user.is_empty() {
            return String::new();
        }
        let mut nonce = [0u8; 16];
        rand::thread_rng().fill_bytes(&mut nonce);
        let created = (chrono::Utc::now() + chrono::Duration::seconds(self.clock_offset)).format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string();
        format!(
            r#"<Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"><UsernameToken><Username>{}</Username><Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{}</Password><Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">{}</Nonce><Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">{}</Created></UsernameToken></Security>"#,
            esc(&self.user),
            password_digest(&nonce, &created, &self.pass),
            B64.encode(nonce),
            created
        )
    }

    /// Gửi một yêu cầu SOAP 1.2; trả về toàn bộ XML phản hồi. `to` thêm header WS-Addressing (PullPoint cần).
    async fn call(&self, url: &str, body: &str, auth: bool, to: Option<&str>) -> Result<String> {
        self.call_t(url, body, auth, to, Duration::from_secs(8)).await
    }

    async fn call_t(&self, url: &str, body: &str, auth: bool, to: Option<&str>, timeout: Duration) -> Result<String> {
        let addressing = to.map(|t| format!(r#"<a:To xmlns:a="http://www.w3.org/2005/08/addressing">{}</a:To>"#, esc(t))).unwrap_or_default();
        let header = if auth { self.security() } else { String::new() };
        let env = format!(r#"<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="{SOAP12}"><s:Header>{header}{addressing}</s:Header><s:Body>{body}</s:Body></s:Envelope>"#);
        let r = self.http.post(url).header("Content-Type", "application/soap+xml; charset=utf-8").body(env).timeout(timeout).send().await.with_context(|| format!("connect {url}"))?;
        let status = r.status();
        let text = r.text().await?;
        if !status.is_success() {
            let reason = roxmltree::Document::parse(&text).ok().and_then(|d| text_of(d.root(), "Text")).unwrap_or_default();
            if status.as_u16() == 401 || reason.to_lowercase().contains("not authorized") || reason.to_lowercase().contains("authority") {
                bail!("unauthorized");
            }
            bail!("onvif {status}: {reason}");
        }
        Ok(text)
    }

    /// Lấy giờ camera (không cần đăng nhập) để bù lệch đồng hồ cho WS-Security.
    pub async fn sync_clock(&mut self) -> Result<()> {
        let xml = self.call(&self.device_url.clone(), r#"<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>"#, false, None).await?;
        let doc = roxmltree::Document::parse(&xml)?;
        let utc = find(doc.root(), "UTCDateTime").ok_or_else(|| anyhow!("no UTCDateTime"))?;
        let num = |n: &str| text_of(utc, n).and_then(|v| v.parse::<u32>().ok());
        let (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s)) = (num("Year"), num("Month"), num("Day"), num("Hour"), num("Minute"), num("Second")) else {
            return Ok(());
        };
        let cam = chrono::NaiveDate::from_ymd_opt(y as i32, mo, d).and_then(|x| x.and_hms_opt(h, mi, s)).map(|x| x.and_utc().timestamp());
        if let Some(cam) = cam {
            self.clock_offset = cam - chrono::Utc::now().timestamp();
        }
        Ok(())
    }

    /// Đọc khả năng, hồ sơ đầu tiên và URL RTSP. Lỗi "unauthorized" = sai tài khoản camera.
    pub async fn probe(&mut self) -> Result<Probe> {
        let _ = self.sync_clock().await; // camera không trả giờ thì vẫn thử với giờ máy này
        let dev = self.device_url.clone();
        let caps = self.call(&dev, r#"<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>All</Category></GetCapabilities>"#, true, None).await?;
        let doc = roxmltree::Document::parse(&caps)?;
        let media = xaddr(&doc, "Media").map(|u| rebase(&u, &dev)).ok_or_else(|| anyhow!("camera has no ONVIF media service"))?;
        let ptz_url = xaddr(&doc, "PTZ").map(|u| rebase(&u, &dev));
        let events_url = xaddr(&doc, "Events").map(|u| rebase(&u, &dev));

        let profiles = self.call(&media, r#"<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>"#, true, None).await?;
        let pdoc = roxmltree::Document::parse(&profiles)?;
        let first = pdoc.root().descendants().find(|d| d.is_element() && d.tag_name().name() == "Profiles").ok_or_else(|| anyhow!("camera has no media profile"))?;
        let profile = first.attribute("token").ok_or_else(|| anyhow!("profile without token"))?.to_string();
        let has_ptz_cfg = find(first, "PTZConfiguration").is_some();

        let body = format!(
            r#"<GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup><Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream><Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport></StreamSetup><ProfileToken>{}</ProfileToken></GetStreamUri>"#,
            esc(&profile)
        );
        let su = self.call(&media, &body, true, None).await?;
        let sdoc = roxmltree::Document::parse(&su)?;
        let uri = text_of(sdoc.root(), "Uri").ok_or_else(|| anyhow!("camera returned no stream URI"))?;
        let rtsp_url = with_credentials(&rebase_host(&uri, &self.host()), &self.user, &self.pass);

        // Hãng/model chỉ để hiển thị, lỗi thì bỏ qua.
        let (mut manufacturer, mut model) = (None, None);
        if let Ok(info) = self.call(&dev, r#"<GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>"#, true, None).await {
            if let Ok(d) = roxmltree::Document::parse(&info) {
                manufacturer = text_of(d.root(), "Manufacturer");
                model = text_of(d.root(), "Model");
            }
        }
        Ok(Probe { rtsp_url, profile, ptz_url: ptz_url.filter(|_| has_ptz_cfg), events_url, manufacturer, model })
    }

    /// Quay liên tục theo vận tốc (-1..1). Gửi cả 0 = dừng.
    pub async fn ptz_move(&self, ptz_url: &str, profile: &str, pan: f32, tilt: f32, zoom: f32) -> Result<()> {
        let c = |v: f32| v.clamp(-1.0, 1.0);
        let body = if pan == 0.0 && tilt == 0.0 && zoom == 0.0 {
            format!(r#"<Stop xmlns="http://www.onvif.org/ver20/ptz/wsdl"><ProfileToken>{}</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>"#, esc(profile))
        } else {
            // Timeout: camera tự dừng nếu lệnh dừng bị lạc (mất mạng giữa chừng).
            format!(
                r#"<ContinuousMove xmlns="http://www.onvif.org/ver20/ptz/wsdl"><ProfileToken>{}</ProfileToken><Velocity><PanTilt xmlns="http://www.onvif.org/ver10/schema" x="{}" y="{}"/><Zoom xmlns="http://www.onvif.org/ver10/schema" x="{}"/></Velocity><Timeout>PT2S</Timeout></ContinuousMove>"#,
                esc(profile),
                c(pan),
                c(tilt),
                c(zoom)
            )
        };
        self.call(ptz_url, &body, true, None).await.map(|_| ())
    }

    /// Tạo PullPoint; trả về địa chỉ subscription.
    pub async fn subscribe(&self, events_url: &str) -> Result<String> {
        let xml = self
            .call(events_url, r#"<CreatePullPointSubscription xmlns="http://www.onvif.org/ver10/events/wsdl"><InitialTerminationTime>PT600S</InitialTerminationTime></CreatePullPointSubscription>"#, true, None)
            .await?;
        let doc = roxmltree::Document::parse(&xml)?;
        let sref = find(doc.root(), "SubscriptionReference").ok_or_else(|| anyhow!("no SubscriptionReference"))?;
        let addr = text_of(sref, "Address").ok_or_else(|| anyhow!("no subscription address"))?;
        Ok(rebase(&addr, &self.device_url))
    }

    pub async fn renew(&self, sub: &str) -> Result<()> {
        self.call(sub, r#"<Renew xmlns="http://docs.oasis-open.org/wsn/b-2"><TerminationTime>PT600S</TerminationTime></Renew>"#, true, Some(sub)).await.map(|_| ())
    }

    pub async fn unsubscribe(&self, sub: &str) {
        let _ = self.call(sub, r#"<Unsubscribe xmlns="http://docs.oasis-open.org/wsn/b-2"/>"#, true, Some(sub)).await;
    }

    /// Chờ tối đa ~20 giây; trả về các trạng thái chuyển động (true = đang có chuyển động) theo thứ tự.
    pub async fn pull(&self, sub: &str) -> Result<Vec<bool>> {
        // Camera giữ yêu cầu tới khi có sự kiện hoặc hết Timeout (20 giây) → HTTP phải chờ lâu hơn thế.
        let body = r#"<PullMessages xmlns="http://www.onvif.org/ver10/events/wsdl"><Timeout>PT20S</Timeout><MessageLimit>20</MessageLimit></PullMessages>"#;
        let xml = self.call_t(sub, body, true, Some(sub), Duration::from_secs(35)).await?;
        Ok(parse_motion(&xml))
    }
}

/// Lấy các sự kiện chuyển động trong PullMessagesResponse. Hãng khác nhau đặt tên khác nhau: chủ đề chứa "Motion"
/// (RuleEngine/CellMotionDetector/Motion, VideoSource/MotionAlarm…), giá trị ở SimpleItem `IsMotion` hoặc `State`.
pub fn parse_motion(xml: &str) -> Vec<bool> {
    let Ok(doc) = roxmltree::Document::parse(xml) else { return vec![] };
    let mut out = Vec::new();
    for msg in doc.root().descendants().filter(|d| d.is_element() && d.tag_name().name() == "NotificationMessage") {
        let topic = text_of(msg, "Topic").unwrap_or_default();
        if !topic.contains("Motion") {
            continue;
        }
        let Some(data) = find(msg, "Data") else { continue };
        for item in data.descendants().filter(|d| d.is_element() && d.tag_name().name() == "SimpleItem") {
            if matches!(item.attribute("Name"), Some("IsMotion") | Some("State") | Some("Motion")) {
                if let Some(v) = item.attribute("Value") {
                    out.push(v.eq_ignore_ascii_case("true") || v == "1");
                }
            }
        }
    }
    out
}

/// Camera tìm thấy trong mạng LAN.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Found {
    pub host: String,
    pub port: u16,
    pub name: Option<String>,
    pub hardware: Option<String>,
}

/// Tách các trường cần thiết từ một ProbeMatch (XAddrs + Scopes).
pub fn parse_probe_match(xml: &str) -> Vec<Found> {
    let Ok(doc) = roxmltree::Document::parse(xml) else { return vec![] };
    let mut out = Vec::new();
    for m in doc.root().descendants().filter(|d| d.is_element() && d.tag_name().name() == "ProbeMatch") {
        let scopes = text_of(m, "Scopes").unwrap_or_default();
        let scope = |key: &str| {
            scopes
                .split_whitespace()
                .find_map(|s| s.strip_prefix(&format!("onvif://www.onvif.org/{key}/")))
                .map(|v| v.replace("%20", " ").replace('_', " "))
        };
        let Some(addr) = text_of(m, "XAddrs").and_then(|x| x.split_whitespace().find(|u| u.starts_with("http://")).map(str::to_string)) else { continue };
        let hostport = addr.trim_start_matches("http://").split('/').next().unwrap_or_default().to_string();
        let (host, port) = match hostport.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.parse().unwrap_or(80)),
            None => (hostport, 80),
        };
        if host.parse::<std::net::IpAddr>().is_ok() {
            out.push(Found { host, port, name: scope("name"), hardware: scope("hardware") });
        }
    }
    out
}

/// WS-Discovery: gửi Probe tới 239.255.255.250:3702 và gom phản hồi trong `wait`. Cần chạy cùng mạng LAN với camera
/// (Docker: network_mode host).
pub async fn discover(wait: Duration) -> Result<Vec<Found>> {
    let sock = tokio::net::UdpSocket::bind("0.0.0.0:0").await?;
    let id = format!("uuid:{:032x}", rand::random::<u128>());
    let probe = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="{SOAP12}" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>{id}</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>"#
    );
    // Gửi hai lần: UDP multicast hay rơi gói.
    for _ in 0..2 {
        sock.send_to(probe.as_bytes(), "239.255.255.250:3702").await?;
    }
    let mut found: Vec<Found> = Vec::new();
    let deadline = tokio::time::Instant::now() + wait;
    let mut buf = vec![0u8; 65535];
    while let Ok(Ok((n, _))) = tokio::time::timeout_at(deadline, sock.recv_from(&mut buf)).await {
        for f in parse_probe_match(&String::from_utf8_lossy(&buf[..n])) {
            if !found.iter().any(|x| x.host == f.host && x.port == f.port) {
                found.push(f);
            }
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_matches_onvif_spec_example() {
        // Ví dụ trong ONVIF Application Programmer's Guide (§6.1.1.3).
        let nonce = B64.decode("LKqI6G/AikKCQrN0zqZFlg==").unwrap();
        assert_eq!(password_digest(&nonce, "2010-09-16T07:50:45Z", "userpassword"), "tuOSpGlFlIXsozq4HFNeeGeFLEI=");
    }

    #[test]
    fn rebase_and_credentials() {
        assert_eq!(rebase("http://192.168.1.64/onvif/ptz", "http://10.0.0.5:8080/onvif/device_service"), "http://10.0.0.5:8080/onvif/ptz");
        assert_eq!(rebase_host("rtsp://192.168.1.64:554/stream1?x=1", "10.0.0.5"), "rtsp://10.0.0.5:554/stream1?x=1");
        assert_eq!(rebase_host("rtsp://cam/live", "10.0.0.5"), "rtsp://10.0.0.5/live");
        assert_eq!(with_credentials("rtsp://1.2.3.4:554/s0", "admin", "p@ss:1"), "rtsp://admin:p%40ss%3A1@1.2.3.4:554/s0");
        assert_eq!(with_credentials("rtsp://u:p@1.2.3.4/s0", "admin", "x"), "rtsp://u:p@1.2.3.4/s0");
    }

    #[test]
    fn motion_events_from_several_vendors() {
        let xml = r#"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><PullMessagesResponse>
          <wsnt:NotificationMessage><wsnt:Topic>tns1:RuleEngine/CellMotionDetector/Motion</wsnt:Topic><wsnt:Message><tt:Message><tt:Data><tt:SimpleItem Name="IsMotion" Value="true"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>
          <wsnt:NotificationMessage><wsnt:Topic>tns1:VideoSource/MotionAlarm</wsnt:Topic><wsnt:Message><tt:Message><tt:Data><tt:SimpleItem Name="State" Value="false"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>
          <wsnt:NotificationMessage><wsnt:Topic>tns1:Device/Trigger/DigitalInput</wsnt:Topic><wsnt:Message><tt:Message><tt:Data><tt:SimpleItem Name="LogicalState" Value="true"/></tt:Data></tt:Message></wsnt:Message></wsnt:NotificationMessage>
        </PullMessagesResponse></s:Body></s:Envelope>"#;
        assert_eq!(parse_motion(xml), vec![true, false]);
    }

    #[test]
    fn probe_match_parsing() {
        let xml = r#"<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><e:Body><d:ProbeMatches><d:ProbeMatch>
          <d:Scopes>onvif://www.onvif.org/name/Tapo_C200 onvif://www.onvif.org/hardware/C200</d:Scopes>
          <d:XAddrs>http://192.168.1.20:2020/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>"#;
        let f = parse_probe_match(xml);
        assert_eq!(f.len(), 1);
        assert_eq!((f[0].host.as_str(), f[0].port), ("192.168.1.20", 2020));
        assert_eq!(f[0].name.as_deref(), Some("Tapo C200"));
    }
}
