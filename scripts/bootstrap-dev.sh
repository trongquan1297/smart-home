#!/usr/bin/env bash
# Tạo dữ liệu mẫu qua API: user chủ nhà + tenant + căn hộ + phòng + gateway token.
# Dùng: ./scripts/bootstrap-dev.sh   (backend phải đang chạy ở API_URL)
# Kết quả: in GATEWAY_TOKEN, ghi vào .env để compose đưa cho service `gateway`.
set -euo pipefail
API_URL="${API_URL:-http://localhost:8080}"
EMAIL="${EMAIL:-owner@example.com}"
PASSWORD="${PASSWORD:-change-me-123}"

j() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }
post() { curl -fsS -X POST "$API_URL$1" -H 'content-type: application/json' ${TOKEN:+-H "authorization: Bearer $TOKEN"} -d "$2"; }

echo "→ đăng ký/đăng nhập $EMAIL"
if RES=$(post /v1/auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"Chủ nhà\"}" 2>/dev/null); then :; else
  RES=$(post /v1/auth/login "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")
fi
TOKEN=$(echo "$RES" | j "['token']")

TENANT=$(post /v1/tenants '{"name":"Khách hàng Demo"}' | j "['id']")
HOME_ID=$(post "/v1/tenants/$TENANT/homes" '{"name":"Căn hộ A-1203","address":"Hà Nội"}' | j "['id']")
post "/v1/homes/$HOME_ID/rooms" '{"name":"Phòng khách"}' >/dev/null
post "/v1/homes/$HOME_ID/rooms" '{"name":"Phòng ngủ"}' >/dev/null
GW_TOKEN=$(post "/v1/homes/$HOME_ID/gateways" '{"name":"Raspberry Pi 3"}' | j "['token']")

echo "tenant=$TENANT"
echo "home=$HOME_ID"
echo "GATEWAY_TOKEN=$GW_TOKEN"
touch .env
grep -v '^GATEWAY_TOKEN=' .env > .env.tmp || true
echo "GATEWAY_TOKEN=$GW_TOKEN" >> .env.tmp && mv .env.tmp .env
echo "→ đã ghi GATEWAY_TOKEN vào .env. Chạy: docker compose up -d gateway"
