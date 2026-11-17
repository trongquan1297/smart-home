"""Loa Google Cast GIẢ LẬP để thử tính năng thông báo giọng nói mà không cần loa thật.

- Quảng bá mDNS `_googlecast._tcp` và nói CASTV2 qua TLS cổng 8009 (đủ cho "Default Media Receiver": CONNECT, LAUNCH, LOAD, STOP, PING).
- Giao diện web (cổng 8082): danh sách các thông báo đã "phát" kèm nút nghe lại ngay trên trình duyệt, và nhật ký phiên Cast.
- Cổng 8099 (nội bộ) là máy chủ TTS trung gian cho gateway: gọi Google Translate TTS thật (tiếng Việt); nếu không gọi được
  (bị chặn IP máy chủ, không có Internet…) thì trả tiếng "bíp" để vẫn thử trọn luồng. Nhờ đó giao diện biết câu đã đọc.
Không phải loa thật: chỉ kiểm tra backend → gateway → Cast → loa; KHÔNG chứng minh tương thích với Google Home/Nest Mini thật.
"""
import datetime, io, json, math, os, socket, ssl, struct, threading, time, urllib.parse, urllib.request, wave
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from zeroconf import ServiceInfo, Zeroconf

NAME = os.environ.get("CAST_NAME", "Loa giả lập (MSmart)")
CAST_ID = os.environ.get("CAST_ID", "msmartsim0001")
MODEL = os.environ.get("CAST_MODEL", "MSmart Cast Simulator")
TTS_UPSTREAM = os.environ.get("TTS_UPSTREAM", "https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=vi&q={text}")

LOCK = threading.Lock()
EVENTS = []   # thông báo đã phát (mới nhất cuối)
LOGS = []     # nhật ký phiên Cast
AUDIO = {}    # id -> (bytes, content-type)
LAST_TTS = {"text": None, "at": 0.0, "real": False}
SEQ = [0]


def log(msg):
    line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with LOCK:
        LOGS.append(line)
        del LOGS[:-150]


# ───────────────────────── CASTV2 tối thiểu ─────────────────────────
def rv(b, i):
    n = s = 0
    while True:
        c = b[i]; i += 1; n |= (c & 0x7F) << s; s += 7
        if not c & 0x80:
            return n, i

def parse(b):
    i, d = 0, {}
    while i < len(b):
        k, i = rv(b, i); f, w = k >> 3, k & 7
        if w == 0:
            v, i = rv(b, i)
        elif w == 2:
            l, i = rv(b, i); v = b[i:i + l]; i += l
        else:
            raise ValueError(w)
        d[f] = v
    return d

def vi(n):
    o = bytearray()
    while True:
        c = n & 0x7F; n >>= 7
        if n:
            o.append(c | 0x80)
        else:
            o.append(c); return bytes(o)

def fld_s(f, s):
    s = s.encode(); return vi(f << 3 | 2) + vi(len(s)) + s

def enc(src, dst, ns, payload):
    body = vi(1 << 3) + vi(0) + fld_s(2, src) + fld_s(3, dst) + fld_s(4, ns) + vi(5 << 3) + vi(0) + fld_s(6, json.dumps(payload))
    return struct.pack(">I", len(body)) + body


def handle(conn, peer):
    try:
        buf = b""
        def rd(n):
            nonlocal buf
            while len(buf) < n:
                c = conn.recv(65536)
                if not c:
                    raise EOFError
                buf += c
            r, buf = buf[:n], buf[n:]
            return r
        transport, session = "web-1", "sess-1"
        log(f"[cast] {peer[0]} kết nối")
        while True:
            n = struct.unpack(">I", rd(4))[0]
            m = parse(rd(n))
            ns, src, dst, p = m[4].decode(), m[2].decode(), m[3].decode(), json.loads(m[6].decode())
            t = p.get("type")
            if ns.endswith("heartbeat"):
                if t == "PING":
                    conn.sendall(enc("receiver-0", src, ns, {"type": "PONG"}))
            elif ns.endswith("receiver") and t == "LAUNCH":
                log(f"[cast] LAUNCH {p.get('appId')}")
                conn.sendall(enc("receiver-0", src, ns, {"type": "RECEIVER_STATUS", "requestId": p["requestId"], "status": {"applications": [{"appId": p["appId"], "transportId": transport, "sessionId": session, "displayName": "Default Media Receiver"}]}}))
            elif ns.endswith("receiver") and t == "STOP":
                log("[cast] STOP (loa về trạng thái rảnh)")
                conn.sendall(enc("receiver-0", src, ns, {"type": "RECEIVER_STATUS", "requestId": p["requestId"], "status": {}}))
            elif ns.endswith("media") and t == "LOAD":
                media = p["media"]; url = media["contentId"]
                log(f"[cast] LOAD {url} ({media.get('contentType')})")
                try:
                    with urllib.request.urlopen(url, timeout=8) as r:
                        data = r.read(); ctype = r.headers.get("Content-Type", media.get("contentType", "audio/mpeg"))
                except Exception as e:
                    log(f"[cast] không tải được âm thanh: {e}")
                    conn.sendall(enc(transport, src, ns, {"type": "LOAD_FAILED", "requestId": p["requestId"]}))
                    continue
                with LOCK:
                    SEQ[0] += 1; eid = SEQ[0]
                    fresh = time.time() - LAST_TTS["at"] < 60
                    AUDIO[eid] = (data, ctype)
                    EVENTS.append({"id": eid, "at": datetime.datetime.now().strftime("%H:%M:%S %d/%m"), "text": LAST_TTS["text"] if fresh else "(không rõ câu)", "bytes": len(data), "real_tts": LAST_TTS["real"] if fresh else False})
                    for old in EVENTS[:-30]:
                        AUDIO.pop(old["id"], None)
                    del EVENTS[:-30]
                log(f"[cast] PHÁT {len(data)} byte — {EVENTS[-1]['text']}")
                conn.sendall(enc(transport, src, ns, {"type": "MEDIA_STATUS", "requestId": p["requestId"], "status": [{"playerState": "PLAYING"}]}))
                time.sleep(max(0.6, min(8.0, len(data) / 16000)))  # giả vờ đang phát
                conn.sendall(enc(transport, src, ns, {"type": "MEDIA_STATUS", "requestId": 0, "status": [{"playerState": "IDLE", "idleReason": "FINISHED"}]}))
    except Exception as e:
        if not isinstance(e, (EOFError, ssl.SSLError, ConnectionError)):
            log(f"[cast] lỗi kết nối: {e!r}")
    finally:
        conn.close()


# ───────────────────────── TTS trung gian (8099) ─────────────────────────
def beep():
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(b"".join(struct.pack("<h", int(9000 * math.sin(2 * math.pi * 880 * i / 16000))) for i in range(6400)))
    return b.getvalue()

class TTS(BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("q", [""])[0]
        real = True
        try:
            req = urllib.request.Request(TTS_UPSTREAM.replace("{text}", urllib.parse.quote(q)), headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"})
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read()
            if len(body) < 200:
                raise ValueError("TTS quá ngắn")
            ctype = "audio/mpeg"
        except Exception as e:
            log(f"[tts] Google Translate TTS không dùng được ({e}); dùng tiếng bíp")
            body, ctype, real = beep(), "audio/wav", False
        with LOCK:
            LAST_TTS.update(text=q, at=time.time(), real=real)
        log(f"[tts] \"{q}\" → {len(body)} byte ({'giọng thật' if real else 'bíp'})")
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass


# ───────────────────────── giao diện web (8082) ─────────────────────────
PAGE = """<!doctype html><html lang="vi"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Loa Cast giả lập</title>
<style>body{font:16px system-ui;margin:0;background:#f3f6f5;color:#16302b}header{background:#00695c;color:#fff;padding:16px 20px}h1{margin:0;font-size:20px}
main{max-width:760px;margin:0 auto;padding:16px}.card{background:#fff;border-radius:14px;padding:14px 16px;margin:10px 0;box-shadow:0 1px 3px #0002}
.t{font-weight:700;font-size:17px}.m{color:#5a6f6a;font-size:13px;margin-top:4px}audio{width:100%;margin-top:8px}pre{background:#102a26;color:#cfe;padding:12px;border-radius:10px;overflow:auto;max-height:260px;font-size:12px}
.pill{display:inline-block;background:#e0f2f1;border-radius:99px;padding:2px 10px;font-size:12px;margin-left:6px}label{display:block;margin:8px 0}</style>
<header><h1>🔊 __NAME__</h1><div>Loa Cast giả lập · id __ID__ · chờ lệnh từ gateway (mDNS + CASTV2)</div></header>
<main><label><input type="checkbox" id="auto"> Tự phát âm thanh trên trình duyệt khi có thông báo mới (bật mục này để trình duyệt cho phép phát)</label>
<div id="list"><div class="card">Chưa có thông báo nào. Trong app: Loa thông báo → Thêm loa → ▶ Phát thử.</div></div>
<h3>Nhật ký phiên Cast</h3><pre id="log"></pre></main>
<script>let seen=0;async function tick(){try{const r=await (await fetch('api/events')).json();const L=document.getElementById('list');
if(r.events.length){L.innerHTML=r.events.slice().reverse().map(e=>`<div class="card"><div class="t">${e.text.replace(/</g,'&lt;')}<span class="pill">${e.real_tts?'giọng Google':'bíp (TTS thật không dùng được)'}</span></div><div class="m">${e.at} · ${e.bytes} byte</div><audio controls preload="none" src="audio/${e.id}"></audio></div>`).join('');}
const last=r.events.length?r.events[r.events.length-1].id:0;if(last>seen){if(seen&&document.getElementById('auto').checked){const a=document.querySelector('audio');a&&a.play().catch(()=>{});}seen=last;}
document.getElementById('log').textContent=r.logs.join('\\n');}catch(e){}}tick();setInterval(tick,1500);</script></html>"""

class Web(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/audio/"):
            with LOCK:
                item = AUDIO.get(int(path.rsplit("/", 1)[-1]) if path.rsplit("/", 1)[-1].isdigit() else -1)
            if not item:
                self.send_response(404); self.end_headers(); return
            data, ctype = item
            self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if path == "/api/events":
            with LOCK:
                body = json.dumps({"events": EVENTS, "logs": LOGS[-80:]}, ensure_ascii=False).encode()
            ctype = "application/json; charset=utf-8"
        elif path in ("/", "/index.html"):
            body = PAGE.replace("__NAME__", NAME).replace("__ID__", CAST_ID).encode(); ctype = "text/html; charset=utf-8"
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

class Threaded(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nm = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "msmart-cast-sim")])
    cert = (x509.CertificateBuilder().subject_name(nm).issuer_name(nm).public_key(key.public_key()).serial_number(1)
            .not_valid_before(datetime.datetime(2020, 1, 1)).not_valid_after(datetime.datetime(2040, 1, 1)).sign(key, hashes.SHA256()))
    open("/tmp/c.pem", "wb").write(cert.public_bytes(serialization.Encoding.PEM))
    open("/tmp/k.pem", "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("/tmp/c.pem", "/tmp/k.pem")
    threading.Thread(target=lambda: Threaded(("0.0.0.0", 8099), TTS).serve_forever(), daemon=True).start()
    threading.Thread(target=lambda: Threaded(("0.0.0.0", 8082), Web).serve_forever(), daemon=True).start()
    ip = socket.gethostbyname(socket.gethostname())
    zc = Zeroconf()
    zc.register_service(ServiceInfo("_googlecast._tcp.local.", f"{CAST_ID}._googlecast._tcp.local.", addresses=[socket.inet_aton(ip)], port=8009,
                                    properties={"id": CAST_ID, "fn": NAME, "md": MODEL}, server=f"{CAST_ID}.local."))
    log(f"Loa giả lập sẵn sàng: {NAME} ({ip}:8009), giao diện web cổng 8082")
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("0.0.0.0", 8009)); srv.listen(5)
    while True:
        c, peer = srv.accept()
        try:
            c = ctx.wrap_socket(c, server_side=True)
        except Exception as e:
            log(f"[cast] TLS lỗi: {e}"); continue
        threading.Thread(target=handle, args=(c, peer), daemon=True).start()


if __name__ == "__main__":
    main()
