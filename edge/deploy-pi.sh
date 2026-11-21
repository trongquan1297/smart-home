#!/usr/bin/env bash
# Triển khai edge lên Raspberry Pi mà KHÔNG build trên Pi: build image linux/arm64 trên máy dev (Mac Apple Silicon/Linux có
# buildx), chép image qua SSH (docker save | docker load), đồng bộ file cấu hình, rồi `docker compose up -d --no-build` trên Pi.
#
#   edge/deploy-pi.sh pi@10.0.0.20                 # Zigbee2MQTT + Mosquitto + Matterbridge + gateway
#   edge/deploy-pi.sh pi@10.0.0.20 --addon         # thêm addon trong nhà (camera, máy lọc nước…; --camera là tên cũ)
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
ADDON=0
UP=1
for a in "$@"; do
  case $a in
    --addon | --camera) ADDON=1 ;;
    --no-up) UP=0 ;;
    *) echo "tham số lạ: $a" >&2; exit 2 ;;
  esac
done
REMOTE_DIR=${REMOTE_DIR:-msmart} # tương đối = trong thư mục home của user SSH
PLATFORM=linux/arm64

IMAGES=("smarthome-gateway:local|gateway" "smarthome-matterbridge:local|infra/matterbridge")
[ "$ADDON" = 1 ] && IMAGES+=("smarthome-addon:local|addons/msmart")

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
"${SSH[@]}" "mkdir -p '$REMOTE_DIR/edge' '$REMOTE_DIR/infra/mosquitto' '$REMOTE_DIR/infra/zigbee2mqtt' '$REMOTE_DIR/infra/matterbridge' '$REMOTE_DIR/addons/msmart' '$REMOTE_DIR/gateway'"
# Thư mục build context phải tồn tại để compose đọc file (dù --no-build): chỉ chép Dockerfile, không chép mã nguồn.
tar --no-xattrs -C "$ROOT" -cf - \
  edge/docker-compose.yml edge/docker-compose.addon.yml edge/docker-compose.cast.yml edge/.env.example \
  edge/gen-secrets.sh edge/pi-reduce-writes.sh \
  infra/mosquitto/mosquitto.conf infra/mosquitto/acl.conf infra/mosquitto/entrypoint.sh \
  infra/matterbridge/Dockerfile gateway/Dockerfile addons/msmart/Dockerfile addons/msmart/go2rtc.yaml \
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
if [ "$ADDON" = 1 ]; then
  # Addon dùng token gateway RIÊNG: edge/.env.addon trên Pi (CLOUD_WS_URL, GATEWAY_TOKEN, chmod 600).
  # Chuyển từ bản cũ "smarthome-camera" (một lần): đổi tên .env.camera, chép dữ liệu volume cũ, gỡ project cũ.
  "${SSH[@]}" "cd '$REMOTE_DIR/edge' && set -e
    if [ ! -f .env.addon ] && [ -f .env.camera ]; then mv .env.camera .env.addon; chmod 600 .env.addon; echo '   .env.camera -> .env.addon'; fi
    [ -f .env.addon ] || { echo 'thiếu edge/.env.addon (CLOUD_WS_URL, GATEWAY_TOKEN của addon) — bỏ qua addon'; exit 0; }
    if docker volume inspect smarthome-camera_camera-data >/dev/null 2>&1 && ! docker volume inspect msmart-addon_addon-data >/dev/null 2>&1; then
      docker compose -p smarthome-camera down
      docker volume create --label com.docker.compose.project=msmart-addon --label com.docker.compose.volume=addon-data msmart-addon_addon-data >/dev/null
      docker run --rm --user 0 -v smarthome-camera_camera-data:/from:ro -v msmart-addon_addon-data:/to smarthome-addon:local sh -c 'cp -a /from/. /to/ && chown -R 65534:65534 /to'
      echo '   đã chép dữ liệu addon cũ sang msmart-addon_addon-data (volume cũ vẫn giữ để dự phòng)'
    fi
    docker compose -p smarthome-camera down 2>/dev/null || true
    docker compose --env-file .env.addon -f docker-compose.addon.yml up -d --no-build --remove-orphans && docker compose -f docker-compose.addon.yml ps"
fi
