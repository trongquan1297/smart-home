"""Camera ONVIF giả lập (thay camera Wi‑Fi thật khi phát triển addon camera).

- ONVIF (HTTP :8000): GetSystemDateAndTime, GetCapabilities, GetDeviceInformation, GetProfiles, GetStreamUri,
  PTZ ContinuousMove/Stop, Events CreatePullPointSubscription/PullMessages/Renew/Unsubscribe.
  Mọi lệnh (trừ đọc giờ) kiểm tra WS-Security UsernameToken PasswordDigest như camera thật.
- WS-Discovery (UDP 3702 multicast): trả lời Probe để addon tìm thấy camera.
- RTSP :8554: chuyển tiếp TCP tới nguồn video thử (container camera-video chạy go2rtc + ffmpeg testsrc).
- Web :8090: xem vị trí PTZ, bấm "Mô phỏng chuyển động" để camera gửi sự kiện.
"""
import asyncio
import base64
import datetime as dt
import hashlib
import json
import os
import socket
import struct
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USER = os.getenv("CAM_USER", "admin")
PASSWORD = os.getenv("CAM_PASSWORD", "camera-sim-pass")
VIDEO = (os.getenv("VIDEO_HOST", "camera-video"), int(os.getenv("VIDEO_PORT", "8554")))
RTSP_PATH = os.getenv("RTSP_PATH", "/cam")

LOCK = threading.Condition()
STATE = {"pan": 0.0, "tilt": 0.0, "zoom": 0.0, "moving": {"pan": 0.0, "tilt": 0.0, "zoom": 0.0}, "last_cmd": None}
EVENTS = []          # hàng đợi sự kiện chuyển động chung (mỗi subscription có con trỏ riêng)
SUBS = {}            # id -> {"cursor": int, "until": float}


def env(body):
    return ('<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" '
            'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" '
            'xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2" '
            'xmlns:wsa="http://www.w3.org/2005/08/addressing">'
            f"<s:Body>{body}</s:Body></s:Envelope>")


def fault(reason):
    return env('<s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code>'
               f'<s:Reason><s:Text xml:lang="en">{reason}</s:Text></s:Reason></s:Fault>')


def local(tag):
    return tag.rsplit("}", 1)[-1]


def check_auth(root):
    tok = next((e for e in root.iter() if local(e.tag) == "UsernameToken"), None)
    if tok is None:
        return False
    vals = {local(e.tag): (e.text or "") for e in tok}
    if vals.get("Username") != USER:
        return False
    try:
        nonce = base64.b64decode(vals.get("Nonce", ""))
        created = vals.get("Created", "")
        when = dt.datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return False
    if abs(when - time.time()) > 300:  # camera thật cũng từ chối khi lệch giờ quá nhiều
        return False
    digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + PASSWORD.encode()).digest()).decode()
    return digest == vals.get("Password")


def motion_msg(active):
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return ('<wsnt:NotificationMessage><wsnt:Topic Dialect="http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet">'
            'tns1:RuleEngine/CellMotionDetector/Motion</wsnt:Topic><wsnt:Message>'
            f'<tt:Message UtcTime="{now}"><tt:Source><tt:SimpleItem Name="VideoSourceConfigurationToken" Value="vsc"/></tt:Source>'
            f'<tt:Data><tt:SimpleItem Name="IsMotion" Value="{"true" if active else "false"}"/></tt:Data></tt:Message>'
            '</wsnt:Message></wsnt:NotificationMessage>')


def trigger_motion():
    with LOCK:
        EVENTS.append(True)
        LOCK.notify_all()
    print("motion -> true", flush=True)

    def stop():
        with LOCK:
            EVENTS.append(False)
            LOCK.notify_all()
    threading.Timer(5, stop).start()


class Onvif(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_xml(self, code, xml):
        b = xml.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/soap+xml; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            root = ET.fromstring(raw)
        except ET.ParseError:
            return self.send_xml(400, fault("bad xml"))
        body = next((e for e in root.iter() if local(e.tag) == "Body"), None)
        op = local(body[0].tag) if body is not None and len(body) else ""
        base = f"http://{self.headers.get('Host', 'camera-sim:8000')}"
        host = self.headers.get("Host", "camera-sim:8000").rsplit(":", 1)[0]
        if op == "GetSystemDateAndTime":
            n = dt.datetime.now(dt.timezone.utc)
            return self.send_xml(200, env(
                "<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType><tt:UTCDateTime>"
                f"<tt:Time><tt:Hour>{n.hour}</tt:Hour><tt:Minute>{n.minute}</tt:Minute><tt:Second>{n.second}</tt:Second></tt:Time>"
                f"<tt:Date><tt:Year>{n.year}</tt:Year><tt:Month>{n.month}</tt:Month><tt:Day>{n.day}</tt:Day></tt:Date>"
                "</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>"))
        if not check_auth(root):
            print("auth failed for", op, flush=True)
            return self.send_xml(400, fault("Sender not Authorized"))
        print("onvif", op, flush=True)
        if op == "GetCapabilities":
            return self.send_xml(200, env(
                "<tds:GetCapabilitiesResponse><tds:Capabilities>"
                f"<tt:Device><tt:XAddr>{base}/onvif/device_service</tt:XAddr></tt:Device>"
                f"<tt:Events><tt:XAddr>{base}/onvif/events</tt:XAddr><tt:WSPullPointSupport>true</tt:WSPullPointSupport></tt:Events>"
                f"<tt:Media><tt:XAddr>{base}/onvif/media</tt:XAddr></tt:Media>"
                f"<tt:PTZ><tt:XAddr>{base}/onvif/ptz</tt:XAddr></tt:PTZ>"
                "</tds:Capabilities></tds:GetCapabilitiesResponse>"))
        if op == "GetDeviceInformation":
            return self.send_xml(200, env(
                "<tds:GetDeviceInformationResponse><tds:Manufacturer>MSmart Sim</tds:Manufacturer><tds:Model>PTZ-CAM-1</tds:Model>"
                "<tds:FirmwareVersion>1.0</tds:FirmwareVersion><tds:SerialNumber>SIM0001</tds:SerialNumber><tds:HardwareId>sim</tds:HardwareId>"
                "</tds:GetDeviceInformationResponse>"))
        if op == "GetProfiles":
            return self.send_xml(200, env(
                '<trt:GetProfilesResponse><trt:Profiles token="profile_1" fixed="true"><tt:Name>main</tt:Name>'
                '<tt:PTZConfiguration token="ptz_1"><tt:Name>ptz</tt:Name><tt:NodeToken>node_1</tt:NodeToken></tt:PTZConfiguration>'
                "</trt:Profiles></trt:GetProfilesResponse>"))
        if op == "GetStreamUri":
            return self.send_xml(200, env(
                f"<trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>rtsp://{host}:8554{RTSP_PATH}</tt:Uri>"
                "<tt:InvalidAfterConnect>false</tt:InvalidAfterConnect><tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>"
                "<tt:Timeout>PT0S</tt:Timeout></trt:MediaUri></trt:GetStreamUriResponse>"))
        if op in ("ContinuousMove", "Stop"):
            with LOCK:
                if op == "Stop":
                    STATE["moving"] = {"pan": 0.0, "tilt": 0.0, "zoom": 0.0}
                else:
                    pt = next((e for e in body.iter() if local(e.tag) == "PanTilt"), None)
                    zm = next((e for e in body.iter() if local(e.tag) == "Zoom"), None)
                    STATE["moving"] = {
                        "pan": float(pt.get("x", 0)) if pt is not None else 0.0,
                        "tilt": float(pt.get("y", 0)) if pt is not None else 0.0,
                        "zoom": float(zm.get("x", 0)) if zm is not None else 0.0,
                    }
                STATE["last_cmd"] = {"op": op, **STATE["moving"], "at": time.time()}
            print("ptz", op, STATE["moving"], flush=True)
            return self.send_xml(200, env(f"<tptz:{op}Response/>"))
        if op == "CreatePullPointSubscription":
            sid = uuid.uuid4().hex[:12]
            with LOCK:
                SUBS[sid] = {"cursor": len(EVENTS), "until": time.time() + 600}
            now = dt.datetime.now(dt.timezone.utc)
            return self.send_xml(200, env(
                f"<tev:CreatePullPointSubscriptionResponse><tev:SubscriptionReference><wsa:Address>{base}/onvif/sub/{sid}</wsa:Address>"
                f"</tev:SubscriptionReference><wsnt:CurrentTime>{now:%Y-%m-%dT%H:%M:%SZ}</wsnt:CurrentTime>"
                f"<wsnt:TerminationTime>{now + dt.timedelta(seconds=600):%Y-%m-%dT%H:%M:%SZ}</wsnt:TerminationTime>"
                "</tev:CreatePullPointSubscriptionResponse>"))
        sid = self.path.rsplit("/", 1)[-1]
        if op in ("PullMessages", "Renew", "Unsubscribe"):
            with LOCK:
                sub = SUBS.get(sid)
                if sub is None:
                    return self.send_xml(400, fault("unknown subscription"))
                if op == "Unsubscribe":
                    SUBS.pop(sid, None)
                    return self.send_xml(200, env("<wsnt:UnsubscribeResponse/>"))
                if op == "Renew":
                    sub["until"] = time.time() + 600
                    return self.send_xml(200, env("<wsnt:RenewResponse><wsnt:TerminationTime>PT600S</wsnt:TerminationTime></wsnt:RenewResponse>"))
                LOCK.wait_for(lambda: len(EVENTS) > sub["cursor"], timeout=15)
                msgs = EVENTS[sub["cursor"]:]
                sub["cursor"] = len(EVENTS)
            now = dt.datetime.now(dt.timezone.utc)
            return self.send_xml(200, env(
                f"<tev:PullMessagesResponse><tev:CurrentTime>{now:%Y-%m-%dT%H:%M:%SZ}</tev:CurrentTime>"
                f"<tev:TerminationTime>{now + dt.timedelta(seconds=600):%Y-%m-%dT%H:%M:%SZ}</tev:TerminationTime>"
                + "".join(motion_msg(a) for a in msgs) + "</tev:PullMessagesResponse>"))
        return self.send_xml(400, fault(f"unsupported {op}"))


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width"><title>Camera giả lập</title>
<style>body{font-family:system-ui;margin:24px;max-width:520px}button{font-size:16px;padding:10px 16px;border-radius:10px;border:0;background:#0ea5e9;color:#fff}
pre{background:#f1f5f9;padding:12px;border-radius:10px}</style>
<h2>Camera ONVIF giả lập</h2><p>Tài khoản camera: <b>%USER%</b> / <b>%PASS%</b> · ONVIF cổng 8000 · RTSP cổng 8554</p>
<button onclick="fetch('/api/motion',{method:'POST'}).then(load)">Mô phỏng chuyển động</button>
<h3>Trạng thái</h3><pre id=s></pre>
<script>function load(){fetch('/api/state').then(r=>r.json()).then(j=>s.textContent=JSON.stringify(j,null,2))}load();setInterval(load,1000)</script>"""


class Web(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, body, ctype):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/api/state":
            with LOCK:
                return self.reply(200, json.dumps({"ptz": STATE, "subscriptions": len(SUBS), "events": len(EVENTS)}), "application/json")
        self.reply(200, PAGE.replace("%USER%", USER).replace("%PASS%", PASSWORD), "text/html; charset=utf-8")

    def do_POST(self):
        if self.path == "/api/motion":
            trigger_motion()
            return self.reply(200, '{"ok":true}', "application/json")
        self.reply(404, '{"error":"not found"}', "application/json")


def ptz_loop():
    """Tích phân vận tốc → vị trí (chỉ để hiển thị)."""
    while True:
        time.sleep(0.2)
        with LOCK:
            for k in ("pan", "tilt", "zoom"):
                STATE[k] = round(max(-1.0, min(1.0, STATE[k] + STATE["moving"][k] * 0.05)), 3)


def discovery():
    ip = socket.gethostbyname(socket.gethostname())
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", 3702))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4sl", socket.inet_aton("239.255.255.250"), socket.INADDR_ANY))
    while True:
        data, addr = s.recvfrom(65535)
        if b"Probe" not in data or b"ProbeMatches" in data:
            continue
        try:
            rel = next((e.text for e in ET.fromstring(data).iter() if local(e.tag) == "MessageID"), "")
        except ET.ParseError:
            continue
        resp = ('<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
                'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
                'xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header>'
                f"<w:MessageID>uuid:{uuid.uuid4()}</w:MessageID><w:RelatesTo>{rel}</w:RelatesTo>"
                "<w:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</w:To>"
                "<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</w:Action></e:Header><e:Body>"
                "<d:ProbeMatches><d:ProbeMatch><w:EndpointReference><w:Address>urn:uuid:5f5a69c2-e0ae-504f-829b-00000000sim1</w:Address></w:EndpointReference>"
                "<d:Types>dn:NetworkVideoTransmitter</d:Types>"
                "<d:Scopes>onvif://www.onvif.org/name/MSmart_Sim_Camera onvif://www.onvif.org/hardware/PTZ-CAM-1 onvif://www.onvif.org/type/video_encoder</d:Scopes>"
                f"<d:XAddrs>http://{ip}:8000/onvif/device_service</d:XAddrs><d:MetadataVersion>1</d:MetadataVersion>"
                "</d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>")
        s.sendto(resp.encode(), addr)
        print("discovery probe from", addr[0], flush=True)


async def rtsp_proxy():
    async def pipe(r, w):
        try:
            while data := await r.read(65536):
                w.write(data)
                await w.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            w.close()

    async def client(r, w):
        try:
            ur, uw = await asyncio.open_connection(*VIDEO)
        except OSError as e:
            print("video source unavailable:", e, flush=True)
            w.close()
            return
        await asyncio.gather(pipe(r, uw), pipe(ur, w))

    server = await asyncio.start_server(client, "0.0.0.0", 8554)
    async with server:
        await server.serve_forever()


def main():
    threading.Thread(target=ptz_loop, daemon=True).start()
    threading.Thread(target=discovery, daemon=True).start()
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", 8000), Onvif).serve_forever, daemon=True).start()
    threading.Thread(target=ThreadingHTTPServer(("0.0.0.0", 8090), Web).serve_forever, daemon=True).start()
    print(f"camera sim ready: ONVIF :8000, RTSP :8554 -> {VIDEO[0]}:{VIDEO[1]}, web :8090", flush=True)
    asyncio.run(rtsp_proxy())


if __name__ == "__main__":
    main()
