#!/bin/sh
# Khởi động Matterbridge ở chế độ bridge, tự cấu hình plugin Zigbee2MQTT ở lần chạy đầu.
#
# Biến môi trường:
#   MQTT_URL        mqtt://localhost   (host mạng: broker publish ở 127.0.0.1:1883)
#   MQTT_PORT       1883
#   MQTT_USERNAME / MQTT_PASSWORD   tài khoản Mosquitto (bắt buộc khi broker tắt anonymous); luôn ghi lại vào config plugin
#   Z2M_BASE        zigbee2mqtt
#   MB_FRONTEND_PORT  8283   cổng frontend/API của Matterbridge (KHÔNG có xác thực mặc định -> chỉ bind nội bộ)
#   MB_BIND         127.0.0.1  địa chỉ bind của frontend
#   MATTER_SWITCH_AS  light (mặc định) | outlet | switch: kiểu Matter của công tắc (xem autolist.mjs)
#   MB_EXTRA_ARGS   tham số thêm, vd "--mdnsinterface eth0"
set -e

DIR=/root/.matterbridge
CFG="$DIR/matterbridge-zigbee2mqtt.config.json"
mkdir -p "$DIR"

# Cấu hình plugin chỉ tạo khi chưa có -> không ghi đè chỉnh sửa của người dùng (whitelist/blacklist...).
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<EOF
{
  "name": "matterbridge-zigbee2mqtt",
  "type": "DynamicPlatform",
  "host": "${MQTT_URL:-mqtt://localhost}",
  "port": ${MQTT_PORT:-1883},
  "topic": "${Z2M_BASE:-zigbee2mqtt}",
  "username": "",
  "password": "",
  "whiteList": [],
  "blackList": ["Coordinator"],
  "debug": false,
  "unregisterOnShutdown": false
}
EOF
fi

# Tài khoản MQTT áp dụng MỖI lần khởi động (cả khi config đã tồn tại), để đổi mật khẩu chỉ cần sửa biến môi trường.
node -e '
const fs = require("fs");
const [, cfgPath] = process.argv;
const c = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
c.username = process.env.MQTT_USERNAME || "";
c.password = process.env.MQTT_PASSWORD || "";
fs.writeFileSync(cfgPath, JSON.stringify(c, null, 2), { mode: 0o600 });
' "$CFG"

# Công tắc -> Light/Outlet để Home app điều khiển được như đèn/ổ cắm (bỏ qua nếu MATTER_SWITCH_AS=switch).
# Chỉ thấy thiết bị đã có lúc khởi động; thiết bị ghép sau cần khởi động lại container này.
if [ "${MATTER_SWITCH_AS:-light}" != "switch" ]; then
  node /matterbridge/autolist.mjs "$CFG" "${MQTT_URL:-mqtt://localhost}" "${MQTT_PORT:-1883}" "${Z2M_BASE:-zigbee2mqtt}" "${MATTER_SWITCH_AS:-light}" || true
fi

# Đăng ký plugin (idempotent).
if ! matterbridge --list 2>/dev/null | grep -q "matterbridge-zigbee2mqtt"; then
  matterbridge --add matterbridge-zigbee2mqtt
fi

# shellcheck disable=SC2086
exec matterbridge --docker --bridge \
  --frontend "${MB_FRONTEND_PORT:-8283}" --bind "${MB_BIND:-127.0.0.1}" \
  ${MB_EXTRA_ARGS:-}
