#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Mac 音频枢纽.app"
CONTENTS="$APP/Contents"
export MACOSX_DEPLOYMENT_TARGET=14.0
INSTALL=0
if [[ "${1:-}" == "--install" ]]; then
  INSTALL=1
fi

echo "▸ 清理构建目录"
rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$BUILD/icon.iconset"

echo "▸ 编译 Swift"
xcrun swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework Network \
  -framework Security \
  -framework CoreImage \
  -framework CryptoKit \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  "$ROOT"/Sources/*.swift \
  "$ROOT"/Sources/MacSpeaker/*.swift \
  -o "$CONTENTS/MacOS/AirMic"

echo "▸ 复制手机网页资源"
cp "$ROOT/Resources/phone.html" "$CONTENTS/Resources/phone.html"
cp "$ROOT/Resources/pcm-worklet.js" "$CONTENTS/Resources/pcm-worklet.js"
cp "$ROOT/Resources/manifest.webmanifest" "$CONTENTS/Resources/manifest.webmanifest"
cp "$ROOT/Resources/favicon.svg" "$CONTENTS/Resources/favicon.svg"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "▸ 编译系统正在播放辅助程序"
xcrun clang -O2 -fobjc-arc -framework Foundation -framework AppKit \
  "$ROOT/Resources/NowPlayingHelper.m" \
  -o "$CONTENTS/Resources/nowplaying-cli"
chmod 755 "$CONTENTS/Resources/nowplaying-cli"
codesign --force --sign - "$CONTENTS/Resources/nowplaying-cli" >/dev/null
chmod 644 "$CONTENTS/Resources/phone.html" "$CONTENTS/Resources/pcm-worklet.js" \
  "$CONTENTS/Resources/manifest.webmanifest" "$CONTENTS/Resources/favicon.svg"

echo "▸ 生成应用图标"
xcrun swift "$ROOT/Resources/make_icon.swift" "$BUILD/icon-1024.png" >/dev/null
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$BUILD/icon-1024.png" --out "$BUILD/icon.iconset/$2.png" >/dev/null
done
iconutil -c icns "$BUILD/icon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$BUILD/icon.iconset" "$BUILD/icon-1024.png"

echo "▸ 签名"
codesign --force --deep --sign - "$APP" >/dev/null
plutil -lint "$CONTENTS/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP"

echo "✓ 构建完成：$APP"

if [[ "$INSTALL" -eq 1 ]]; then
  TARGET="$HOME/Desktop/Mac 音频枢纽.app"
  echo "▸ 安装到桌面：$TARGET"
  rm -rf "$TARGET"
  ditto "$APP" "$TARGET"
  xattr -cr "$TARGET"
  echo "✓ 已放到桌面"
fi
