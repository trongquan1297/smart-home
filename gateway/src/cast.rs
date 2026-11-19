//! Thông báo giọng nói qua Google Cast (Google Home / Nest Mini…), chạy trên gateway vì loa nằm cùng mạng LAN với Pi.
//!
//!   backend --{"type":"speak"}--> gateway --TTS (Google Translate)--> mp3 --HTTP LAN--> loa <--CASTV2/TLS 8009-- gateway
//!
//! - Tìm loa: mDNS `_googlecast._tcp` (cần mạng host trên Pi, xem edge/docker-compose.yml).
//! - Phát: kết nối TLS tới cổng 8009, chạy "Default Media Receiver" (CC1AD845), LOAD URL mp3 do gateway phục vụ.
//! - TTS: endpoint `translate.google.com/translate_tts` KHÔNG chính thức (không có tài liệu, có thể đổi/chặn bất cứ lúc nào);
//!   đổi nguồn bằng `TTS_URL_TEMPLATE` (đặt `{text}` là chỗ chèn câu đã mã hoá URL).
//! Mỗi loa chỉ phát từng câu một (hàng đợi theo cast_id). Phát xong gửi STOP để loa quay về trạng thái rảnh.
use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use prost::Message;
use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use tokio_rustls::{
    rustls::{
        self,
        client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        pki_types::{CertificateDer, ServerName, UnixTime},
        DigitallySignedStruct, SignatureScheme,
    },
    TlsConnector,
};
use tracing::{info, warn};

const DEFAULT_MEDIA_RECEIVER: &str = "CC1AD845";
const NS_CONN: &str = "urn:x-cast:com.google.cast.tp.connection";
const NS_HEART: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
const NS_RECV: &str = "urn:x-cast:com.google.cast.receiver";
const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";
const SENDER: &str = "sender-0";
/// Câu dài hơn mức này bị cắt (Google Translate TTS nhận ~200 ký tự).
const MAX_CHARS: usize = 200;
const FILE_TTL: Duration = Duration::from_secs(300);

#[derive(Clone, Debug)]
pub struct Found {
    pub cast_id: String,
    pub name: String,
    pub model: String,
    pub host: IpAddr,
    pub port: u16,
}

pub struct Cast {
    found: Arc<Mutex<HashMap<String, Found>>>,
    files: Arc<Mutex<HashMap<String, (Vec<u8>, Instant)>>>,
    locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    http_port: u16,
    advertise_host: Option<String>,
    tts_template: String,
    http: reqwest::Client,
    mdns_ok: bool,
}

static CAST: OnceLock<Arc<Cast>> = OnceLock::new();

/// Khởi động mDNS + máy chủ HTTP phục vụ âm thanh. Gọi một lần ở `main`.
pub fn start() -> Arc<Cast> {
    let http_port: u16 = std::env::var("CAST_HTTP_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8765);
    let found: Arc<Mutex<HashMap<String, Found>>> = Arc::default();
    let files: Arc<Mutex<HashMap<String, (Vec<u8>, Instant)>>> = Arc::default();
    let mdns_ok = match spawn_mdns(found.clone()) {
        Ok(()) => true,
        Err(e) => {
            warn!("cast: mDNS không khởi động được ({e:#}); chỉ phát được tới loa có địa chỉ IP đã lưu");
            false
        }
    };
    let cast = Arc::new(Cast {
        found,
        files: files.clone(),
        locks: Mutex::default(),
        http_port,
        advertise_host: std::env::var("CAST_ADVERTISE_HOST").ok().filter(|h| !h.is_empty()),
        tts_template: std::env::var("TTS_URL_TEMPLATE").unwrap_or_else(|_| "https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=vi&q={text}".into()),
        http: reqwest::Client::builder().timeout(Duration::from_secs(15)).user_agent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36").build().expect("http client"),
        mdns_ok,
    });
    tokio::spawn(serve_files(files, http_port));
    let _ = CAST.set(cast.clone());
    cast
}

impl Cast {
    pub fn mdns_ok(&self) -> bool {
        self.mdns_ok
    }
}

pub fn get() -> Option<Arc<Cast>> {
    CAST.get().cloned()
}

fn spawn_mdns(found: Arc<Mutex<HashMap<String, Found>>>) -> Result<()> {
    let daemon = ServiceDaemon::new()?;
    let rx = daemon.browse("_googlecast._tcp.local.")?;
    std::thread::spawn(move || {
        let _keep = daemon; // giữ daemon sống cùng luồng
        let mut by_full: HashMap<String, String> = HashMap::new();
        while let Ok(ev) = rx.recv() {
            match ev {
                ServiceEvent::ServiceResolved(info) => {
                    let Some(cast_id) = info.get_property_val_str("id").map(str::to_string) else { continue };
                    let addrs = info.get_addresses();
                    let Some(host) = addrs.iter().find(|a| a.is_ipv4()).or_else(|| addrs.iter().next()).copied() else { continue };
                    let f = Found {
                        name: info.get_property_val_str("fn").unwrap_or("Loa Cast").to_string(),
                        model: info.get_property_val_str("md").unwrap_or("").to_string(),
                        cast_id: cast_id.clone(),
                        host,
                        port: info.get_port(),
                    };
                    info!("cast: thấy {} ({}) {}:{}", f.name, f.model, f.host, f.port);
                    by_full.insert(info.get_fullname().to_string(), cast_id.clone());
                    found.lock().unwrap().insert(cast_id, f);
                }
                ServiceEvent::ServiceRemoved(_, full) => {
                    if let Some(id) = by_full.remove(&full) {
                        found.lock().unwrap().remove(&id);
                    }
                }
                _ => {}
            }
        }
    });
    Ok(())
}

impl Cast {
    /// Trả lời `cast_scan` của backend: danh sách loa đang thấy trên LAN.
    pub async fn scan(&self) -> Value {
        if !self.mdns_ok {
            return json!({"error": "mdns unavailable", "devices": []});
        }
        let empty = self.found.lock().unwrap().is_empty();
        tokio::time::sleep(Duration::from_secs(if empty { 5 } else { 1 })).await;
        let mut v: Vec<Found> = self.found.lock().unwrap().values().cloned().collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        json!({"devices": v.into_iter().map(|f| json!({"cast_id": f.cast_id, "name": f.name, "model": f.model, "host": f.host.to_string(), "port": f.port})).collect::<Vec<_>>()})
    }

    /// Xử lý `{"type":"speak","text","speakers":[{cast_id,name,host,port}]}`: tải TTS một lần rồi phát ở từng loa (song song, mỗi loa xếp hàng riêng).
    pub async fn speak(self: &Arc<Self>, msg: &Value) {
        let Some(text) = msg.get("text").and_then(Value::as_str).map(|t| t.chars().take(MAX_CHARS).collect::<String>()).filter(|t| !t.trim().is_empty()) else { return };
        let Some(speakers) = msg.get("speakers").and_then(Value::as_array) else { return };
        let audio = match self.tts(&text).await {
            Ok(a) => Arc::new(a),
            Err(e) => return warn!("cast: lấy TTS lỗi: {e:#}"),
        };
        for s in speakers {
            let Some(cast_id) = s.get("cast_id").and_then(Value::as_str).map(str::to_string) else { continue };
            let name = s.get("name").and_then(Value::as_str).unwrap_or("loa").to_string();
            let fallback = s.get("host").and_then(Value::as_str).and_then(|h| h.parse::<IpAddr>().ok()).map(|h| (h, s.get("port").and_then(Value::as_u64).unwrap_or(8009) as u16));
            let (me, audio) = (self.clone(), audio.clone());
            tokio::spawn(async move {
                let lock = me.locks.lock().unwrap().entry(cast_id.clone()).or_default().clone();
                let _turn = lock.lock().await;
                let target = me.found.lock().unwrap().get(&cast_id).map(|f| (f.host, f.port)).or(fallback);
                let Some((host, port)) = target else { return warn!("cast: không biết địa chỉ của {name} (chưa thấy qua mDNS, chưa có IP)") };
                match me.play(host, port, &audio).await {
                    Ok(()) => info!("cast: đã phát trên {name} ({host})"),
                    Err(e) => warn!("cast: phát trên {name} ({host}) lỗi: {e:#}"),
                }
            });
        }
    }

    async fn tts(&self, text: &str) -> Result<Vec<u8>> {
        let url = self.tts_template.replace("{text}", &urlencode(text));
        let res = self.http.get(&url).send().await?.error_for_status().context("TTS trả lỗi")?;
        let bytes = res.bytes().await?.to_vec();
        if bytes.len() < 200 {
            bail!("TTS trả về quá ngắn ({} byte)", bytes.len());
        }
        Ok(bytes)
    }

    fn local_host(&self, speaker: IpAddr) -> Result<String> {
        if let Some(h) = &self.advertise_host {
            return Ok(h.clone());
        }
        let sock = std::net::UdpSocket::bind(if speaker.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" })?;
        sock.connect((speaker, 8009))?;
        let ip = sock.local_addr()?.ip();
        Ok(if ip.is_ipv6() { format!("[{ip}]") } else { ip.to_string() })
    }

    async fn play(&self, host: IpAddr, port: u16, audio: &[u8]) -> Result<()> {
        // Đăng ký tệp âm thanh với tên ngẫu nhiên khó đoán, tự xoá sau 5 phút.
        let name = format!("{:032x}", rand_u128());
        {
            let mut f = self.files.lock().unwrap();
            f.retain(|_, (_, t)| t.elapsed() < FILE_TTL);
            f.insert(name.clone(), (audio.to_vec(), Instant::now()));
        }
        let url = format!("http://{}:{}/tts/{name}.mp3", self.local_host(host)?, self.http_port);
        let res = tokio::time::timeout(Duration::from_secs(60), cast_url(host, port, &url)).await.map_err(|_| anyhow!("quá thời gian chờ loa"))?;
        self.files.lock().unwrap().remove(&name);
        res
    }
}

// ───────────────────────── CASTV2 ─────────────────────────

#[derive(Clone, PartialEq, prost::Message)]
struct CastMessage {
    #[prost(int32, required, tag = "1")]
    protocol_version: i32,
    #[prost(string, required, tag = "2")]
    source_id: String,
    #[prost(string, required, tag = "3")]
    destination_id: String,
    #[prost(string, required, tag = "4")]
    namespace: String,
    #[prost(int32, required, tag = "5")]
    payload_type: i32,
    #[prost(string, optional, tag = "6")]
    payload_utf8: Option<String>,
    #[prost(bytes = "vec", optional, tag = "7")]
    payload_binary: Option<Vec<u8>>,
}

/// Loa Cast dùng chứng chỉ tự ký nên không kiểm tra chuỗi tin cậy (mạng LAN nội bộ; chỉ phát âm thanh công khai).
#[derive(Debug)]
struct AcceptAny(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for AcceptAny {
    fn verify_server_cert(&self, _: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(m, c, d, &self.0.signature_verification_algorithms)
    }
    fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(m, c, d, &self.0.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

struct Chan<S> {
    io: S,
}

impl<S: AsyncReadExt + AsyncWriteExt + Unpin> Chan<S> {
    async fn send(&mut self, ns: &str, dest: &str, payload: Value) -> Result<()> {
        let m = CastMessage { protocol_version: 0, source_id: SENDER.into(), destination_id: dest.into(), namespace: ns.into(), payload_type: 0, payload_utf8: Some(payload.to_string()), payload_binary: None };
        let body = m.encode_to_vec();
        let mut buf = (body.len() as u32).to_be_bytes().to_vec();
        buf.extend(body);
        self.io.write_all(&buf).await?;
        Ok(())
    }

    async fn recv(&mut self) -> Result<(String, Value)> {
        let mut len = [0u8; 4];
        self.io.read_exact(&mut len).await?;
        let n = u32::from_be_bytes(len) as usize;
        if n == 0 || n > 64 * 1024 {
            bail!("khung CASTV2 bất thường ({n} byte)");
        }
        let mut body = vec![0u8; n];
        self.io.read_exact(&mut body).await?;
        let m = CastMessage::decode(&body[..])?;
        let v = m.payload_utf8.as_deref().and_then(|s| serde_json::from_str(s).ok()).unwrap_or(Value::Null);
        Ok((m.namespace, v))
    }

    /// Nhận tới khi `pick` trả Some; tự trả lời PING, gửi PING định kỳ để loa không đóng kết nối.
    async fn until<T>(&mut self, limit: Duration, mut pick: impl FnMut(&str, &Value) -> Result<Option<T>>) -> Result<T> {
        let end = Instant::now() + limit;
        let mut last_ping = Instant::now();
        loop {
            let left = end.checked_duration_since(Instant::now()).ok_or_else(|| anyhow!("hết thời gian chờ phản hồi của loa"))?;
            if last_ping.elapsed() > Duration::from_secs(5) {
                self.send(NS_HEART, "receiver-0", json!({"type": "PING"})).await?;
                last_ping = Instant::now();
            }
            let step = left.min(Duration::from_secs(5));
            let Ok(r) = tokio::time::timeout(step, self.recv()).await else { continue };
            let (ns, v) = r?;
            if ns == NS_HEART && v["type"] == "PING" {
                self.send(NS_HEART, "receiver-0", json!({"type": "PONG"})).await?;
                continue;
            }
            if ns == NS_CONN && v["type"] == "CLOSE" {
                bail!("loa đóng kết nối");
            }
            if let Some(t) = pick(&ns, &v)? {
                return Ok(t);
            }
        }
    }
}

async fn cast_url(host: IpAddr, port: u16, url: &str) -> Result<()> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAny(provider)))
        .with_no_client_auth();
    let tcp = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect((host, port))).await.map_err(|_| anyhow!("không kết nối được tới loa"))??;
    let tls = TlsConnector::from(Arc::new(cfg)).connect(ServerName::IpAddress(host.into()), tcp).await?;
    let mut ch = Chan { io: tls };

    ch.send(NS_CONN, "receiver-0", json!({"type": "CONNECT"})).await?;
    ch.send(NS_RECV, "receiver-0", json!({"type": "LAUNCH", "appId": DEFAULT_MEDIA_RECEIVER, "requestId": 1})).await?;
    let (transport, session) = ch
        .until(Duration::from_secs(15), |ns, v| {
            if ns != NS_RECV || v["type"] != "RECEIVER_STATUS" {
                return Ok(None);
            }
            let app = v["status"]["applications"].as_array().and_then(|a| a.iter().find(|x| x["appId"] == DEFAULT_MEDIA_RECEIVER));
            Ok(app.and_then(|a| Some((a["transportId"].as_str()?.to_string(), a["sessionId"].as_str()?.to_string()))))
        })
        .await?;
    ch.send(NS_CONN, &transport, json!({"type": "CONNECT"})).await?;
    ch.send(NS_MEDIA, &transport, json!({"type": "LOAD", "requestId": 2, "autoplay": true, "currentTime": 0, "media": {"contentId": url, "contentType": "audio/mpeg", "streamType": "BUFFERED"}})).await?;
    let outcome = ch
        .until(Duration::from_secs(45), |ns, v| {
            if ns != NS_MEDIA {
                return Ok(None);
            }
            match v["type"].as_str() {
                Some("LOAD_FAILED") | Some("INVALID_REQUEST") | Some("LOAD_CANCELLED") => bail!("loa không tải được âm thanh ({})", v["type"]),
                Some("MEDIA_STATUS") => {
                    let st = &v["status"][0];
                    if st["playerState"] == "IDLE" {
                        return match st["idleReason"].as_str() {
                            Some("FINISHED") => Ok(Some(())),
                            Some(r) => bail!("loa dừng phát: {r}"),
                            None => Ok(None),
                        };
                    }
                    Ok(None)
                }
                _ => Ok(None),
            }
        })
        .await;
    // Trả loa về trạng thái rảnh (kể cả khi lỗi); bỏ qua lỗi gửi.
    let _ = ch.send(NS_RECV, "receiver-0", json!({"type": "STOP", "sessionId": session, "requestId": 3})).await;
    outcome
}

// ───────────────────────── HTTP phục vụ âm thanh ─────────────────────────

async fn serve_files(files: Arc<Mutex<HashMap<String, (Vec<u8>, Instant)>>>, port: u16) {
    let listener = match TcpListener::bind(("0.0.0.0", port)).await {
        Ok(l) => l,
        Err(e) => return warn!("cast: không mở được cổng HTTP {port}: {e}"),
    };
    info!("cast: phục vụ âm thanh TTS ở cổng {port}");
    loop {
        let Ok((mut sock, _)) = listener.accept().await else { continue };
        let files = files.clone();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 4096];
            let n = match tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf)).await {
                Ok(Ok(n)) if n > 0 => n,
                _ => return,
            };
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            let _ = sock.write_all(&respond(&req, &files)).await;
        });
    }
}

/// GET/HEAD /tts/<tên>.mp3, có hỗ trợ `Range: bytes=a-b` (trình phát của loa hay hỏi theo đoạn).
fn respond(req: &str, files: &Mutex<HashMap<String, (Vec<u8>, Instant)>>) -> Vec<u8> {
    let mut lines = req.lines();
    let first = lines.next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let (method, path) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let name = path.strip_prefix("/tts/").and_then(|p| p.strip_suffix(".mp3")).filter(|n| n.len() == 32 && n.chars().all(|c| c.is_ascii_hexdigit()));
    let data = name.and_then(|n| files.lock().unwrap().get(n).filter(|(_, t)| t.elapsed() < FILE_TTL).map(|(d, _)| d.clone()));
    let (Some(data), true) = (data, matches!(method, "GET" | "HEAD")) else {
        return b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec();
    };
    let total = data.len();
    let range = lines.find_map(|l| l.to_ascii_lowercase().strip_prefix("range: bytes=").map(str::to_string)).and_then(|r| {
        let (a, b) = r.trim().split_once('-')?;
        let start: usize = a.parse().ok()?;
        let end: usize = if b.is_empty() { total - 1 } else { b.parse().ok()? };
        (start <= end && start < total).then_some((start, end.min(total - 1)))
    });
    let (status, body, extra) = match range {
        Some((s, e)) => ("206 Partial Content", &data[s..=e], format!("Content-Range: bytes {s}-{e}/{total}\r\n")),
        None => ("200 OK", &data[..], String::new()),
    };
    let mut out = format!("HTTP/1.1 {status}\r\nContent-Type: audio/mpeg\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n", body.len()).into_bytes();
    if method == "GET" {
        out.extend_from_slice(body);
    }
    out
}

fn urlencode(s: &str) -> String {
    let mut o = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

fn rand_u128() -> u128 {
    // Tên tệp khó đoán: trộn thời gian ns, bộ đếm và địa chỉ ngăn xếp qua RandomState (SipHash khoá ngẫu nhiên theo tiến trình).
    use std::hash::{BuildHasher, Hasher};
    let mut out = 0u128;
    for i in 0..2u64 {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
        h.write_u64(i);
        out = (out << 64) | h.finish() as u128;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_encoding_handles_vietnamese() {
        assert_eq!(urlencode("Đã tắt"), "%C4%90%C3%A3%20t%E1%BA%AFt");
        assert_eq!(urlencode("a-b_c.d~"), "a-b_c.d~");
    }

    #[test]
    fn castmessage_roundtrip() {
        let m = CastMessage { protocol_version: 0, source_id: "sender-0".into(), destination_id: "receiver-0".into(), namespace: NS_CONN.into(), payload_type: 0, payload_utf8: Some("{}".into()), payload_binary: None };
        assert_eq!(CastMessage::decode(&m.encode_to_vec()[..]).unwrap(), m);
    }

    #[test]
    fn http_serves_ranges_and_hides_unknown_files() {
        let files = Mutex::new(HashMap::new());
        let name = "0123456789abcdef0123456789abcdef";
        files.lock().unwrap().insert(name.to_string(), (vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10], Instant::now()));
        let full = respond(&format!("GET /tts/{name}.mp3 HTTP/1.1\r\nHost: x\r\n\r\n"), &files);
        assert!(full.starts_with(b"HTTP/1.1 200 OK") && full.ends_with(&[10]));
        let part = respond(&format!("GET /tts/{name}.mp3 HTTP/1.1\r\nRange: bytes=2-4\r\n\r\n"), &files);
        assert!(String::from_utf8_lossy(&part).contains("206 Partial Content") && part.ends_with(&[3, 4, 5]));
        let head = respond(&format!("HEAD /tts/{name}.mp3 HTTP/1.1\r\n\r\n"), &files);
        assert!(head.ends_with(b"\r\n\r\n"));
        assert!(respond("GET /tts/ffffffffffffffffffffffffffffffff.mp3 HTTP/1.1\r\n\r\n", &files).starts_with(b"HTTP/1.1 404"));
        assert!(respond("GET /etc/passwd HTTP/1.1\r\n\r\n", &files).starts_with(b"HTTP/1.1 404"));
    }
}
