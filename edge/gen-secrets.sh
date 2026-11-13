#!/bin/sh
# Sinh mật khẩu MQTT ngẫu nhiên (256-bit, hex) vào edge/.env. Biến nào đã có thì giữ nguyên (không xoay vòng ngoài ý muốn).
# Muốn đổi mật khẩu: xoá dòng tương ứng trong .env rồi chạy lại script + `docker compose up -d --force-recreate`.
set -eu
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env; echo "đã tạo .env từ .env.example — nhớ điền CLOUD_WS_URL, GATEWAY_TOKEN, ZIGBEE_DEVICE"; }
chmod 600 .env
for v in MQTT_PASSWORD_Z2M MQTT_PASSWORD_GATEWAY MQTT_PASSWORD_MATTERBRIDGE; do
  if grep -q "^$v=." .env; then
    echo "giữ nguyên $v"
  else
    sed -i.bak "/^$v=/d" .env && rm -f .env.bak
    printf '%s=%s\n' "$v" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
    echo "đã tạo $v"
  fi
done
