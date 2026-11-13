#!/bin/sh
# Tạo file mật khẩu Mosquitto từ biến môi trường rồi chạy broker. Thiếu hoặc quá ngắn (<16 ký tự) -> từ chối chạy.
#   MQTT_PASSWORD_Z2M, MQTT_PASSWORD_GATEWAY, MQTT_PASSWORD_MATTERBRIDGE
set -eu
PW=/tmp/mosquitto-passwd
: > "$PW"
for pair in z2m:MQTT_PASSWORD_Z2M gateway:MQTT_PASSWORD_GATEWAY matterbridge:MQTT_PASSWORD_MATTERBRIDGE; do
  user=${pair%%:*}
  var=${pair#*:}
  val=$(printenv "$var" || true)
  if [ "${#val}" -lt 16 ]; then
    echo "mosquitto: $var chưa đặt hoặc ngắn hơn 16 ký tự — chạy edge/gen-secrets.sh để tạo" >&2
    exit 1
  fi
  mosquitto_passwd -b "$PW" "$user" "$val" >/dev/null
done
chown mosquitto:mosquitto "$PW"
chmod 600 "$PW"
exec /docker-entrypoint.sh mosquitto -c /mosquitto/config/mosquitto.conf
