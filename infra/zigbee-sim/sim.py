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
NAME_RE = re.compile(r"^[\w .\-()]{1,64}$")  # chữ Unicode (có dấu), số, khoảng trắng, _ . - ( ); KHÔNG cho / # + (an toàn cho MQTT topic)

LOCK = threading.RLock()


def binary(prop, access=1, on=True, off=False):
    return {"type": "binary", "name": prop, "property": prop, "value_on": on, "value_off": off, "access": access}


def numeric(prop, unit=None, access=1, lo=None, hi=None, category=None):
    e = {"type": "numeric", "name": prop, "property": prop, "access": access}
    if unit:
        e["unit"] = unit
    if lo is not None:
        e["value_min"], e["value_max"] = lo, hi
    if category:
        e["category"] = category
    return e


def cover_expose():
    """Rèm/cửa cuốn kiểu Zigbee2MQTT: state (OPEN/CLOSE/STOP, chỉ ghi) + position 0..100 (cover.features)."""
    return {"type": "cover", "features": [
        {"type": "enum", "name": "state", "property": "state", "values": ["OPEN", "CLOSE", "STOP"], "access": 2},
        {"type": "numeric", "name": "position", "property": "position", "unit": "%", "value_min": 0, "value_max": 100, "access": 7}]}


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
    for m, c in make_vendor_catalog().items():
        cat[m] = c
    return cat


def make_vendor_catalog():
    """Mẫu Aqara và Tuya (Zigbee). Thuộc tính lấy theo trang thiết bị trên zigbee2mqtt.io; simulator KHÔNG phải
    Zigbee2MQTT thật nên giá trị khởi tạo/đơn vị chỉ để thử giao diện. `endpoint` left/right → state_left/state_right."""
    diag = "diagnostic"
    v = {}
    v["WSDCGQ11LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Temperature and humidity sensor", "type": "EndDevice",
        "exposes": [numeric("battery", "%", 1, 0, 100, diag), numeric("temperature", "°C"), numeric("humidity", "%"),
                    numeric("pressure", "hPa"), numeric("voltage", "mV", 1, None, None, diag)],
        "init": {"battery": 100, "temperature": 26.4, "humidity": 62.0, "pressure": 1009.0, "voltage": 3025}}
    v["RTCGQ11LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Motion sensor", "type": "EndDevice",
        "exposes": [numeric("battery", "%", 1, 0, 100, diag), binary("occupancy"), numeric("illuminance", "lx"),
                    numeric("device_temperature", "°C", 1, None, None, diag), numeric("voltage", "mV", 1, None, None, diag)],
        "init": {"battery": 100, "occupancy": False, "illuminance": 120, "device_temperature": 27, "voltage": 3010}}
    v["SJCGQ11LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Water leak sensor", "type": "EndDevice",
        "exposes": [numeric("battery", "%", 1, 0, 100, diag), binary("water_leak"), binary("battery_low", 1, True, False),
                    numeric("voltage", "mV", 1, None, None, diag)],
        "init": {"battery": 100, "water_leak": False, "battery_low": False, "voltage": 3000}}
    v["MCCGQ11LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Door and window sensor", "type": "EndDevice",
        "exposes": [numeric("battery", "%", 1, 0, 100, diag), binary("contact", on=False, off=True),
                    numeric("voltage", "mV", 1, None, None, diag)],
        "init": {"battery": 100, "contact": True, "voltage": 3000}}
    v["QBKG03LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Smart wall switch (no neutral, double rocker)", "type": "EndDevice", "mains": True,
        "exposes": [switch_expose("state_left"), switch_expose("state_right"),
                    numeric("device_temperature", "°C", 1, None, None, diag)],
        "init": {"state_left": "OFF", "state_right": "OFF", "device_temperature": 30}}
    v["ZNCZ12LM"] = {"vendor": "Aqara", "mfr": "LUMI", "desc": "Smart plug US", "type": "Router",
        "exposes": [switch_expose("state"), numeric("power", "W", 5), numeric("energy", "kWh"), numeric("voltage", "V"),
                    numeric("current", "A"), numeric("device_temperature", "°C", 1, None, None, diag)],
        "init": {"state": "OFF", "power": 0.0, "energy": 12.34, "voltage": 220.0, "current": 0.0, "device_temperature": 32}}
    # Bóng đèn chỉnh độ sáng: expose kiểu `light` của Z2M (state + brightness 0..254) → backend xếp loại "light",
    # Google nhận LIGHT + OnOff + Brightness mà không cần đặt loại tải trong app.
    v["LED1623G12"] = {"vendor": "IKEA", "mfr": "IKEA of Sweden", "desc": "TRADFRI LED bulb E27 dimmable", "type": "Router",
        "exposes": [{"type": "light", "features": [
            {"type": "binary", "name": "state", "property": "state", "value_on": "ON", "value_off": "OFF", "value_toggle": "TOGGLE", "access": 7},
            {"type": "numeric", "name": "brightness", "property": "brightness", "value_min": 0, "value_max": 254, "access": 7}]}],
        "init": {"state": "OFF", "brightness": 254}}
    v["TS0012"] = {"vendor": "Tuya", "mfr": "_TZ3000_sim", "desc": "Smart light switch - 2 gang", "type": "Router",
        "exposes": [switch_expose("state_left"), switch_expose("state_right")],
        "init": {"state_left": "OFF", "state_right": "OFF"}}
    v["TS0201"] = {"vendor": "Tuya", "mfr": "_TZ3000_sim", "desc": "Temperature & humidity sensor with display", "type": "EndDevice",
        "exposes": [numeric("battery", "%", 1, 0, 100, diag), numeric("temperature", "°C"), numeric("humidity", "%"),
                    numeric("voltage", "mV", 1, None, None, diag)],
        "init": {"battery": 100, "temperature": 27.1, "humidity": 58.0, "voltage": 3000}}
    v["TS011F_plug_1"] = {"vendor": "Tuya", "mfr": "_TZ3000_sim", "desc": "Smart plug (with power monitoring)", "type": "Router",
        "exposes": [switch_expose("state"), numeric("power", "W"), numeric("current", "A"), numeric("voltage", "V"), numeric("energy", "kWh")],
        "init": {"state": "OFF", "power": 0.0, "current": 0.0, "voltage": 221.0, "energy": 3.2}}
    v["TS130F"] = {"vendor": "Tuya", "mfr": "_TZ3000_sim", "desc": "Curtain/blind switch", "type": "Router",
        "exposes": [cover_expose()],
        "init": {"position": 100, "moving": "STOP"}}
    return v


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
        battery = c["type"] == "EndDevice" and not c.get("mains")
        out.append({
            "ieee_address": d["ieee"], "type": c["type"], "network_address": 0x1000 + i,
            "friendly_name": name, "supported": True, "disabled": False,
            "interview_completed": True, "interviewing": False,
            # Giá trị giả lập: Z2M thật báo chuỗi model Zigbee của thiết bị, không phải mã sản phẩm.
            "model_id": d["model"].replace("ZB-VNM", "ZB"), "manufacturer": c.get("mfr", "VSmart (sim)"),
            "power_source": "Battery" if battery else "Mains (single phase)",
            "software_build_id": "sim-1.0", "date_code": "20260101",
            "endpoints": {},
            "definition": {"model": d["model"], "vendor": c.get("vendor", "VSmart"), "description": c["desc"],
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


# Thiết bị đang giả lập mất kết nối (chỉ trong RAM: khởi động lại simulator thì tất cả online lại).
OFFLINE = set()


def avail(name):
    return {"state": "offline" if name in OFFLINE else "online"}


def set_availability(name, online):
    """Giả lập thiết bị mất kết nối / có lại kết nối, như Zigbee2MQTT báo qua <name>/availability (retain)."""
    with LOCK:
        if name not in DEVICES:
            raise KeyError("unknown device")
        (OFFLINE.discard if online else OFFLINE.add)(name)
        pub(f"{name}/availability", avail(name))
        if online:
            pub(name, DEVICES[name]["state"])  # Z2M thường gửi lại trạng thái khi thiết bị quay lại
    print("availability", name, "online" if online else "offline", flush=True)


def publish_all():
    pub("bridge/state", {"state": "online"})
    pub("bridge/devices", bridge_devices())
    pub("bridge/groups", [])
    pub("bridge/extensions", [])
    publish_info()
    for name, d in DEVICES.items():
        pub(f"{name}/availability", avail(name))
        pub(name, d["state"])


# ---------- thao tác (dùng chung cho MQTT và web) ----------
def apply_set(name, cmd):
    with LOCK:
        d = DEVICES.get(name)
        if not d:
            raise KeyError("unknown device")
        if name in OFFLINE:  # thiết bị mất kết nối không nhận lệnh, trạng thái giữ nguyên
            raise ValueError("device offline")
        st = d["state"]
        if "position" in st:  # rèm: state OPEN/CLOSE/STOP hoặc position 0..100 (tức thời, không mô phỏng chuyển động)
            if cmd.get("state") == "OPEN":
                st["position"] = 100
            elif cmd.get("state") == "CLOSE":
                st["position"] = 0
            if isinstance(cmd.get("position"), (int, float)):
                st["position"] = max(0, min(100, int(cmd["position"])))
            st["moving"] = "STOP"
        for k, v in cmd.items():
            if k.startswith("state") and k in st and st[k] in ("ON", "OFF"):
                st[k] = ("OFF" if st[k] == "ON" else "ON") if v == "TOGGLE" else ("ON" if v == "ON" else "OFF")
        if "brightness" in st and isinstance(cmd.get("brightness"), (int, float)):
            st["brightness"] = max(0, min(254, int(cmd["brightness"])))
            if "state" in st and "state" not in cmd:
                st["state"] = "ON" if st["brightness"] > 0 else "OFF"  # như Z2M: đặt độ sáng là bật đèn
        if "power" in st:  # ổ cắm đo điện: công suất giả lập theo trạng thái
            on = st.get("state") == "ON"
            st["power"] = round(random.uniform(40, 90), 1) if on else 0.0
            st["current"] = round(st["power"] / max(st.get("voltage", 220), 1), 3)
        print("SET", name, cmd, "->", st, flush=True)
        pub(name, st)
        save_state()


def set_permit(enable, seconds=None):
    with LOCK:
        PERMIT["until"] = time.time() + (seconds or PERMIT_SECONDS) if enable else 0.0
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
            raise ValueError("tên chỉ gồm chữ (có dấu), số, khoảng trắng và _ - . ( ) (tối đa 64)")
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
        if name in OFFLINE:
            raise ValueError("device offline")
        s = d["state"]
        if "contact" in s:
            s["contact"] = not s["contact"]
        elif "occupancy" in s:
            s["occupancy"] = not s["occupancy"]
        elif "water_leak" in s:
            s["water_leak"] = not s["water_leak"]
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
            "devices": [{"name": n, "ieee": d["ieee"], "model": d["model"], "vendor": CATALOG[d["model"]].get("vendor", "VSmart"),
                         "desc": CATALOG[d["model"]]["desc"], "type": CATALOG[d["model"]]["type"], "state": d["state"],
                          "online": n not in OFFLINE}
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
        t = body.get("time")  # Z2M 2.x: {"time": giây}, 0 = đóng; 1.x: {"value": bool}
        if isinstance(t, (int, float)):
            set_permit(t > 0, min(int(t), 254))
        else:
            set_permit(bool(body.get("value", 0)))
    elif len(parts) == 3 and parts[2] == "set" and isinstance(body, dict):
        try:
            apply_set(parts[1], body)
        except (KeyError, ValueError) as e:
            print("SET ignored", parts[1], e, flush=True)


def sensor_loop():
    """Cảm biến tự thay đổi để thử realtime (đặt SENSOR_PERIOD=0 để tắt)."""
    while SENSOR_PERIOD > 0:
        time.sleep(SENSOR_PERIOD)
        if not CLIENT.is_connected():
            continue
        with LOCK:
            for name, d in DEVICES.items():
                if name in OFFLINE:
                    continue
                s = d["state"]
                if "contact" in s:
                    s["contact"] = not s["contact"]
                    pub(name, s)
                elif "occupancy" in s:
                    s["occupancy"] = random.random() < 0.5
                    s["battery"] = max(1, s.get("battery", 100) - random.choice([0, 0, 1]))
                    if "illuminance" in s:
                        s["illuminance"] = max(0, int(s["illuminance"] + random.randint(-30, 30)))
                    pub(name, s)
                elif "temperature" in s:
                    s["temperature"] = round(s["temperature"] + random.uniform(-0.4, 0.4), 1)
                    if "humidity" in s:
                        s["humidity"] = round(max(20, min(95, s["humidity"] + random.uniform(-1.5, 1.5))), 1)
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
            elif p == "/api/availability":  # {"name": "...", "online": false}
                set_availability(b["name"], bool(b["online"]))
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
