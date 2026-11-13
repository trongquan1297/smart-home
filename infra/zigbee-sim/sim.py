"""Giả lập Zigbee2MQTT (MQTT + frontend web) — thay thế Pi + dongle khi phát triển.

KHÔNG phải Zigbee2MQTT thật: chỉ giả lập hành vi ở mức giao thức MQTT và một giao diện web đơn giản
(permit join, ghép thiết bị ảo, đổi tên, xoá, điều khiển). Thiết bị theo tài liệu zigbee2mqtt.io:
HS-SW100/200/300/400ZB-VNM, HS-SEDR00ZB-VNM, HS-SEOC00ZB-VNM.

MQTT (giống Z2M): bridge/devices, bridge/state, bridge/info, bridge/event (retain tuỳ loại),
<name> (retain), <name>/availability (retain), <name>/set, bridge/request/permit_join.
Web: http://localhost:8081
"""
import json
import os
import random
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paho.mqtt.client as mqtt

BASE = os.getenv("Z2M_BASE", "zigbee2mqtt")
HOST = os.getenv("MQTT_HOST", "localhost")
PORT = int(os.getenv("MQTT_PORT", "1883"))
HTTP_PORT = int(os.getenv("HTTP_PORT", "8080"))
SENSOR_PERIOD = float(os.getenv("SENSOR_PERIOD", "20"))
PERMIT_SECONDS = int(os.getenv("PERMIT_JOIN_SECONDS", "120"))
INTERVIEW_SECONDS = float(os.getenv("INTERVIEW_SECONDS", "2"))
STATE_FILE = os.getenv("SIM_STATE_FILE", "/data/sim_state.json")  # volume: thiết bị ghép trong sim sống qua lần khởi động lại
NAME_RE = re.compile(r"^[A-Za-z0-9 _.\-]{1,64}$")  # không cho / # + (an toàn cho MQTT topic)

LOCK = threading.RLock()


def binary(prop, access=1, on=True, off=False):
    return {"type": "binary", "name": prop, "property": prop, "value_on": on, "value_off": off, "access": access}


def switch_expose(prop):
    """Z2M gắn `endpoint` vào expose của công tắc nhiều gang (state_1 -> endpoint "1"); 1 gang thì không có."""
    ep = prop.split("_", 1)[1] if "_" in prop else None
    feat = {"type": "binary", "name": "state", "property": prop,
            "value_on": "ON", "value_off": "OFF", "value_toggle": "TOGGLE", "access": 7}
    out = {"type": "switch", "features": [feat]}
    if ep:
        feat["endpoint"] = ep
        out["endpoint"] = ep
    return out


def gang_props(n):
    return ["state"] if n == 1 else [f"state_{i}" for i in range(1, n + 1)]


def make_catalog():
    cat = {}
    for n in (1, 2, 3, 4):
        cat[f"HS-SW{n}00ZB-VNM"] = {
            "desc": f"Wall switch {n} gang", "type": "Router",
            "exposes": [switch_expose(p) for p in gang_props(n)], "init": {p: "OFF" for p in gang_props(n)}}
    cat["HS-SEDR00ZB-VNM"] = {
        "desc": "Door/window sensor", "type": "EndDevice",
        "exposes": [binary("contact", on=False, off=True), binary("battery_low"), binary("tamper")],
        "init": {"contact": True, "battery_low": False, "tamper": False}}
    cat["HS-SEOC00ZB-VNM"] = {
        "desc": "Occupancy sensor", "type": "EndDevice",
        "exposes": [{"type": "numeric", "name": "battery", "property": "battery", "access": 1, "unit": "%",
                     "value_min": 0, "value_max": 100}, binary("occupancy")],
        "init": {"occupancy": False, "battery": 100}}
    return cat


CATALOG = make_catalog()
DEVICES = {}   # friendly_name -> {ieee, model, state}
PENDING = {}   # ieee -> model (đang interview)
PERMIT = {"until": 0.0}
CLIENT = None


def add_device(name, ieee, model):
    st = dict(CATALOG[model]["init"])
    st["linkquality"] = random.randint(80, 200)
    DEVICES[name] = {"ieee": ieee, "model": model, "state": st}


for _n, _i, _m in [("sw_1_gang", "0x00124b0000000011", "HS-SW100ZB-VNM"),
                   ("sw_2_gang", "0x00124b0000000012", "HS-SW200ZB-VNM"),
                   ("sw_3_gang", "0x00124b0000000013", "HS-SW300ZB-VNM"),
                   ("door_sensor", "0x00124b0000000021", "HS-SEDR00ZB-VNM"),
                   ("occupancy_sensor", "0x00124b0000000022", "HS-SEOC00ZB-VNM")]:
    add_device(_n, _i, _m)


# ---------- lưu trạng thái ----------
def save_state():
    """Ghi danh sách thiết bị ra volume (nguyên tử). Lỗi ghi không được làm hỏng simulator."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(DEVICES, f)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        print("cannot save state:", e, flush=True)


def load_state():
    try:
        with open(STATE_FILE) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return
    ok = {n: d for n, d in saved.items() if isinstance(d, dict) and d.get("model") in CATALOG and d.get("ieee") and isinstance(d.get("state"), dict)}
    if ok:
        DEVICES.clear()
        DEVICES.update(ok)
        print(f"loaded {len(ok)} devices from {STATE_FILE}", flush=True)


load_state()


# ---------- MQTT helpers ----------
def pub(topic, payload, retain=True):
    CLIENT.publish(f"{BASE}/{topic}", json.dumps(payload), qos=1, retain=retain)


def clear_retained(topic):
    CLIENT.publish(f"{BASE}/{topic}", None, qos=1, retain=True)


def bridge_devices():
    out = [{"ieee_address": "0x0000000000000000", "type": "Coordinator", "network_address": 0,
            "friendly_name": "Coordinator", "supported": True, "disabled": False, "interview_completed": True,
            "interviewing": False, "definition": None, "power_source": "Mains (single phase)",
            "model_id": "ZBDongle-E", "manufacturer": "SONOFF", "endpoints": {}}]
    for i, (name, d) in enumerate(DEVICES.items(), start=1):
        c = CATALOG[d["model"]]
        battery = c["type"] == "EndDevice"
        out.append({
            "ieee_address": d["ieee"], "type": c["type"], "network_address": 0x1000 + i,
            "friendly_name": name, "supported": True, "disabled": False,
            "interview_completed": True, "interviewing": False,
            # Giá trị giả lập: Z2M thật báo chuỗi model Zigbee của thiết bị, không phải mã sản phẩm.
            "model_id": d["model"].replace("ZB-VNM", "ZB"), "manufacturer": "VSmart (sim)",
            "power_source": "Battery" if battery else "Mains (single phase)",
            "software_build_id": "sim-1.0", "date_code": "20260101",
            "endpoints": {},
            "definition": {"model": d["model"], "vendor": "VSmart", "description": c["desc"],
                           "supports_ota": False, "exposes": c["exposes"], "options": []},
        })
    return out


def publish_info():
    """bridge/info giống Zigbee2MQTT thật (các client như matterbridge-zigbee2mqtt đọc config.* và version)."""
    left = max(0, int(PERMIT["until"] - time.time()))
    pub("bridge/info", {
        "version": "2.0.0-sim",
        "commit": "simulator",
        "zigbee_herdsman": {"version": "0.0.0-sim"},
        "zigbee_herdsman_converters": {"version": "0.0.0-sim"},
        "coordinator": {"type": "EmberZNet", "meta": {"revision": "EmberZNet 8.0.2"}},
        "network": {"channel": 11, "pan_id": 6754, "extended_pan_id": "0xdddddddddddddddd"},
        "log_level": "info",
        "permit_join": left > 0,
        "permit_join_timeout": left,
        "permit_join_end": int(PERMIT["until"] * 1000) if left else None,
        "config": {
            "availability": {"enabled": True},
            "advanced": {"output": "json", "legacy_api": False, "legacy_availability_payload": False},
            "homeassistant": {"enabled": False},
            "mqtt": {"base_topic": BASE},
        },
        "config_schema": {},
    })


def publish_all():
    pub("bridge/state", {"state": "online"})
    pub("bridge/devices", bridge_devices())
    pub("bridge/groups", [])
    pub("bridge/extensions", [])
    publish_info()
    for name, d in DEVICES.items():
        pub(f"{name}/availability", {"state": "online"})
        pub(name, d["state"])


# ---------- thao tác (dùng chung cho MQTT và web) ----------
def apply_set(name, cmd):
    with LOCK:
        d = DEVICES.get(name)
        if not d:
            raise KeyError("unknown device")
        for k, v in cmd.items():
            if k.startswith("state") and k in d["state"]:
                cur = d["state"][k]
                d["state"][k] = ("OFF" if cur == "ON" else "ON") if v == "TOGGLE" else ("ON" if v == "ON" else "OFF")
        print("SET", name, cmd, "->", d["state"], flush=True)
        pub(name, d["state"])
        save_state()


def set_permit(enable):
    with LOCK:
        PERMIT["until"] = time.time() + PERMIT_SECONDS if enable else 0.0
        publish_info()
    print("permit_join", enable, flush=True)


def finish_pairing(ieee):
    with LOCK:
        model = PENDING.pop(ieee, None)
        if model is None:
            return
        add_device(ieee, ieee, model)  # giống Z2M: friendly_name mặc định = địa chỉ IEEE
        pub("bridge/event", {"type": "device_interview",
                             "data": {"friendly_name": ieee, "ieee_address": ieee, "status": "successful"}}, retain=False)
        pub("bridge/devices", bridge_devices())
        pub(f"{ieee}/availability", {"state": "online"})
        pub(ieee, DEVICES[ieee]["state"])
        save_state()
    print("paired", ieee, model, flush=True)


def pair(model):
    with LOCK:
        if model not in CATALOG:
            raise ValueError("unknown model")
        if time.time() >= PERMIT["until"]:
            raise ValueError("permit join is disabled — bật Permit join trước")
        ieee = "0x00124b" + "".join(random.choice("0123456789abcdef") for _ in range(10))
        PENDING[ieee] = model
        pub("bridge/event", {"type": "device_joined", "data": {"friendly_name": ieee, "ieee_address": ieee}}, retain=False)
    threading.Timer(INTERVIEW_SECONDS, finish_pairing, args=(ieee,)).start()
    return ieee


def rename(old, new):
    new = new.strip()
    with LOCK:
        if old not in DEVICES:
            raise KeyError("unknown device")
        if not NAME_RE.match(new):
            raise ValueError("tên chỉ gồm chữ, số, khoảng trắng, _ - . (tối đa 64)")
        if new in DEVICES or new == "bridge":
            raise ValueError("tên đã tồn tại")
        DEVICES[new] = DEVICES.pop(old)
        clear_retained(old)
        clear_retained(f"{old}/availability")
        pub("bridge/devices", bridge_devices())
        pub(f"{new}/availability", {"state": "online"})
        pub(new, DEVICES[new]["state"])
        save_state()


def remove(name):
    with LOCK:
        if name not in DEVICES:
            raise KeyError("unknown device")
        DEVICES.pop(name)
        clear_retained(name)
        clear_retained(f"{name}/availability")
        pub("bridge/devices", bridge_devices())
        save_state()


def trigger(name):
    """Mô phỏng sự kiện cảm biến: mở/đóng cửa hoặc có/không người."""
    with LOCK:
        d = DEVICES.get(name)
        if not d:
            raise KeyError("unknown device")
        s = d["state"]
        if "contact" in s:
            s["contact"] = not s["contact"]
        elif "occupancy" in s:
            s["occupancy"] = not s["occupancy"]
        else:
            raise ValueError("không phải cảm biến")
        pub(name, s)
        save_state()


def snapshot():
    with LOCK:
        return {
            "permit_join_left": max(0, int(PERMIT["until"] - time.time())),
            "pending": len(PENDING),
            "models": [{"model": m, "desc": c["desc"]} for m, c in CATALOG.items()],
            "devices": [{"name": n, "ieee": d["ieee"], "model": d["model"], "vendor": "VSmart",
                         "desc": CATALOG[d["model"]]["desc"], "type": CATALOG[d["model"]]["type"], "state": d["state"]}
                        for n, d in sorted(DEVICES.items())],
        }


# ---------- MQTT callbacks ----------
def on_connect(c, _u, _f, rc, _p=None):
    print("connected to MQTT", rc, flush=True)
    c.subscribe(f"{BASE}/+/set", qos=1)
    c.subscribe(f"{BASE}/bridge/request/permit_join", qos=1)
    publish_all()


def on_message(c, _u, msg):
    parts = msg.topic.split("/")
    try:
        body = json.loads(msg.payload or b"{}")
    except ValueError:
        return
    if msg.topic == f"{BASE}/bridge/request/permit_join":
        set_permit(bool(body.get("time", body.get("value", 0))))
    elif len(parts) == 3 and parts[2] == "set" and isinstance(body, dict):
        try:
            apply_set(parts[1], body)
        except KeyError:
            pass


def sensor_loop():
    """Cảm biến tự thay đổi để thử realtime (đặt SENSOR_PERIOD=0 để tắt)."""
    while SENSOR_PERIOD > 0:
        time.sleep(SENSOR_PERIOD)
        if not CLIENT.is_connected():
            continue
        with LOCK:
            for name, d in DEVICES.items():
                s = d["state"]
                if "contact" in s:
                    s["contact"] = not s["contact"]
                    pub(name, s)
                elif "occupancy" in s:
                    s["occupancy"] = random.random() < 0.5
                    s["battery"] = max(1, s.get("battery", 100) - random.choice([0, 0, 1]))
                    pub(name, s)
            save_state()


# ---------- web frontend ----------
INDEX = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"), "rb").read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/state":
            return self._json(200, snapshot())
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(INDEX)))
            self.end_headers()
            self.wfile.write(INDEX)
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        try:
            n = int(self.headers.get("content-length", 0))
            b = json.loads(self.rfile.read(n) or b"{}")
            p = self.path
            if p == "/api/permit_join":
                set_permit(bool(b.get("enable")))
            elif p == "/api/pair":
                return self._json(200, {"ieee": pair(b["model"])})
            elif p == "/api/set":
                apply_set(b["name"], b["payload"])
            elif p == "/api/rename":
                rename(b["from"], b["to"])
            elif p == "/api/remove":
                remove(b["name"])
            elif p == "/api/trigger":
                trigger(b["name"])
            else:
                return self._json(404, {"error": "not found"})
            self._json(200, {"ok": True})
        except (KeyError, ValueError, TypeError, AttributeError) as e:
            self._json(400, {"error": str(e).strip("'")})


def main():
    global CLIENT
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1)
    CLIENT = c
    if os.getenv("MQTT_USER"):
        c.username_pw_set(os.environ["MQTT_USER"], os.getenv("MQTT_PASSWORD", ""))
    c.on_connect = on_connect
    c.on_message = on_message
    c.will_set(f"{BASE}/bridge/state", json.dumps({"state": "offline"}), retain=True)
    threading.Thread(target=sensor_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"frontend on :{HTTP_PORT}", flush=True)
    while True:
        try:
            c.connect(HOST, PORT, 30)
            c.loop_forever()
        except OSError as e:
            print("mqtt not ready:", e, flush=True)
            time.sleep(2)


main()
