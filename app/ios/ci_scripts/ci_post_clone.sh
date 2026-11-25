#!/bin/sh
# Xcode Cloud chạy script này ngay sau khi clone repo, trước khi xcodebuild archive.
# Nó cài Flutter rồi `flutter build ios --config-only`: sinh Generated.xcconfig (dart-define, số build) và
# Swift Package của plugin, để Xcode Cloud tự build/ký/archive như một dự án iOS bình thường.
#
# Biến môi trường (đặt trong workflow Xcode Cloud nếu cần đổi):
#   FLUTTER_VERSION      tag Flutter, khớp bản dùng trên máy dev (mặc định 3.50.0)
#   API_URL              máy chủ app gọi tới (mặc định production)
#   BUILD_NUMBER         ép số build khi build ngoài Xcode Cloud (mặc định: lấy từ pubspec.yaml)
#   RUN_TESTS            "true" để chạy flutter test trước khi build
set -eu

FLUTTER_VERSION="${FLUTTER_VERSION:-3.50.0}"
API_URL="${API_URL:-https://msmart-api.newmoon.cloud}"
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

# Phiên bản (X.Y.Z) lấy từ dòng `version: X.Y.Z+N` trong pubspec.yaml.
# Số build: khi archive để phân phối, Xcode Cloud GHI ĐÈ N bằng bộ đếm build của chính nó
# (đặt số tiếp theo ở App Store Connect → Xcode Cloud → Settings → Build Number). N trong pubspec chỉ có tác dụng khi build tay.
VERSION_LINE=$(grep -E '^version:' pubspec.yaml | head -1)
echo "pubspec $VERSION_LINE, API_URL: $API_URL"
if [ -n "${BUILD_NUMBER:-}" ]; then
  echo "Ép số build: $BUILD_NUMBER"
  flutter build ios --config-only --release --build-number="$BUILD_NUMBER" --dart-define=API_URL="$API_URL"
else
  flutter build ios --config-only --release --dart-define=API_URL="$API_URL"
fi
