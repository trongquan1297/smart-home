#!/bin/sh
# Xcode Cloud chạy script này ngay sau khi clone repo, trước khi xcodebuild archive.
# Nó cài Flutter rồi `flutter build ios --config-only`: sinh Generated.xcconfig (dart-define, số build) và
# Swift Package của plugin, để Xcode Cloud tự build/ký/archive như một dự án iOS bình thường.
#
# Biến môi trường (đặt trong workflow Xcode Cloud nếu cần đổi):
#   FLUTTER_VERSION      tag Flutter, khớp bản dùng trên máy dev (mặc định 3.50.0)
#   API_URL              máy chủ app gọi tới (mặc định production)
#   BUILD_NUMBER_OFFSET  cộng vào CI_BUILD_NUMBER để số build luôn lớn hơn các bản đã tải tay lên (mặc định 100)
#   RUN_TESTS            "true" để chạy flutter test trước khi build
set -eu

FLUTTER_VERSION="${FLUTTER_VERSION:-3.50.0}"
API_URL="${API_URL:-https://msmart-api.newmoon.cloud}"
BUILD_NUMBER_OFFSET="${BUILD_NUMBER_OFFSET:-100}"
REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../../.." && pwd)}"
APP_DIR="$REPO/app"

if [ "${CI:-}" = "TRUE" ] || [ "${CI:-}" = "true" ]; then
  if [ ! -x "$HOME/flutter/bin/flutter" ]; then
    git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$HOME/flutter"
  fi
  export PATH="$HOME/flutter/bin:$PATH"
  flutter config --no-analytics >/dev/null
fi

flutter --version
flutter precache --ios

cd "$APP_DIR"
flutter pub get

if [ "${RUN_TESTS:-false}" = "true" ]; then
  flutter test
fi

BUILD_NUMBER=$(( ${CI_BUILD_NUMBER:-0} + BUILD_NUMBER_OFFSET ))
echo "Build number: $BUILD_NUMBER, API_URL: $API_URL"
flutter build ios --config-only --release \
  --build-number="$BUILD_NUMBER" \
  --dart-define=API_URL="$API_URL"
