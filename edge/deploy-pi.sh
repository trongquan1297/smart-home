#!/usr/bin/env bash
# Triển khai edge lên Raspberry Pi mà KHÔNG build trên Pi: build image linux/arm64 trên máy dev (Mac Apple Silicon/Linux có
# buildx), chép image qua SSH (docker save | docker load), đồng bộ file cấu hình, rồi `docker compose up -d --no-build` trên Pi.
#
#   edge/deploy-pi.sh pi@10.0.0.20                 # Zigbee2MQTT + Mosquitto + Matterbridge + gateway
#   edge/deploy-pi.sh pi@10.0.0.20 --camera        # thêm addon camera (go2rtc + camera-addon)
#   edge/deploy-pi.sh pi@10.0.0.20 --no-up         # chỉ chép image + file, không khởi động
#   BUILD_ONLY=1 edge/deploy-pi.sh                 # chỉ build image trên máy này
#
# Cần: SSH vào Pi bằng khoá (ssh-copy-id), Docker + compose plugin trên Pi (OS 64-bit), REMOTE_DIR (mặc định ~/msmart).
# Không bao giờ ghi đè trên Pi: edge/.env (token, mật khẩu) và infra/zigbee2mqtt/configuration.yaml (Z2M ghi network key vào đó).
set -euo pipefail
export COPYFILE_DISABLE=1 # tar trên macOS: không đóng gói xattr/metadata của Mac (tar trên Pi báo cảnh báo)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-}
shift || true
CAMERA=0
UP=1
for a in "$@"; do
  case $a in
    --camera) CAMERA=1 ;;
    --no-up) UP=0 ;;
    *) echo "tham số lạ: $a" >&2; exit 2 ;;
  esac
done
REMOTE_DIR=${REMOTE_DIR:-msmart} # tương đối = trong thư mục home của user SSH
PLATFORM=linux/arm64

IMAGES=("smarthome-gateway:local|gateway" "smarthome-matterbridge:local|infra/matterbridge")
[ "$CAMERA" = 1 ] && IMAGES+=("smarthome-camera-addon:local|addons/camera")

for item in "${IMAGES[@]}"; do
  tag=${item%%|*}
  ctx=${item#*|}
  echo "== build $tag ($PLATFORM) từ $ctx"
  docker buildx build --platform "$PLATFORM" -t "$tag" --load "$ROOT/$ctx"
done
[ "${BUILD_ONLY:-0}" = 1 ] && exit 0
[ -n "$TARGET" ] || { echo "thiếu đích, vd: $0 pi@10.0.0.20" >&2; exit 2; }

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")
echo "== kiểm tra Pi"
"${SSH[@]}" 'set -e; arch=$(uname -m); [ "$arch" = aarch64 ] || { echo "Pi chạy $arch: cần Raspberry Pi OS 64-bit (aarch64)" >&2; exit 1; }
  docker compose version >/dev/null || { echo "Pi chưa có docker compose plugin" >&2; exit 1; }'

echo "== chép image (nén gzip qua SSH)"
tags=()
for item in "${IMAGES[@]}"; do tags+=("${item%%|*}"); done
docker save "${tags[@]}" | gzip -1 | "${SSH[@]}" 'gunzip | docker load'

echo "== đồng bộ cấu hình vào ~/$REMOTE_DIR"
"${SSH[@]}" "mkdir -p '$REMOTE_DIR/edge' '$REMOTE_DIR/infra/mosquitto' '$REMOTE_DIR/infra/zigbee2mqtt' '$REMOTE_DIR/infra/matterbridge' '$REMOTE_DIR/addons/camera' '$REMOTE_DIR/gateway'"
# Thư mục build context phải tồn tại để compose đọc file (dù --no-build): chỉ chép Dockerfile, không chép mã nguồn.
tar --no-xattrs -C "$ROOT" -cf - \
  edge/docker-compose.yml edge/docker-compose.camera.yml edge/docker-compose.cast.yml edge/.env.example \
  edge/gen-secrets.sh edge/pi-reduce-writes.sh \
  infra/mosquitto/mosquitto.conf infra/mosquitto/acl.conf infra/mosquitto/entrypoint.sh \
  infra/matterbridge/Dockerfile gateway/Dockerfile addons/camera/Dockerfile addons/camera/go2rtc.yaml \
  | "${SSH[@]}" "tar -C '$REMOTE_DIR' -xf -"
# Cấu hình Z2M: chỉ chép lần đầu.
if "${SSH[@]}" "test -f '$REMOTE_DIR/infra/zigbee2mqtt/configuration.yaml'"; then
  echo "   giữ nguyên configuration.yaml của Z2M trên Pi"
else
  tar --no-xattrs -C "$ROOT" -cf - infra/zigbee2mqtt/configuration.yaml | "${SSH[@]}" "tar -C '$REMOTE_DIR' -xf -"
  echo "   đã chép configuration.yaml của Z2M (lần đầu)"
fi

if ! "${SSH[@]}" "test -f '$REMOTE_DIR/edge/.env'"; then
  echo "Pi chưa có $REMOTE_DIR/edge/.env. Trên Pi: cd $REMOTE_DIR/edge && ./gen-secrets.sh → điền CLOUD_WS_URL, GATEWAY_TOKEN, ZIGBEE_DEVICE; rồi chạy lại script này."
  exit 0
fi
[ "$UP" = 1 ] || exit 0

echo "== khởi động"
"${SSH[@]}" "cd '$REMOTE_DIR/edge' && docker compose up -d --no-build --remove-orphans && docker compose ps"
if [ "$CAMERA" = 1 ]; then
  # Addon camera dùng token gateway RIÊNG: đặt trong edge/.env.camera trên Pi (CLOUD_WS_URL, GATEWAY_TOKEN).
  "${SSH[@]}" "cd '$REMOTE_DIR/edge' && if [ -f .env.camera ]; then docker compose --env-file .env.camera -f docker-compose.camera.yml up -d --no-build && docker compose -f docker-compose.camera.yml ps; else echo 'thiếu edge/.env.camera (CLOUD_WS_URL, GATEWAY_TOKEN của addon camera) — bỏ qua camera'; fi"
fi
