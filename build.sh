#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Glitter.app"
IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Version.xcconfig | tr -d '[:space:]')
BUILD_NUMBER=$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' Config/Version.xcconfig | tr -d '[:space:]')
if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Failed to read version metadata from Config/Version.xcconfig" >&2
  exit 1
fi
DEMO=false
SWIFT_FLAGS=()
if [[ $# -gt 1 ]]; then
  echo "Usage: ./build.sh [--demo]" >&2
  exit 1
elif [[ "${1:-}" == "--demo" ]]; then
  APP="build/Glitter-Demo.app"
  IDENTIFIER="${IDENTIFIER}.demo"
  DEMO=true
  SWIFT_FLAGS+=(-D DEMO)
elif [[ $# -gt 0 ]]; then
  echo "Usage: ./build.sh [--demo]" >&2
  exit 1
fi
BIN="$APP/Contents/MacOS/Glitter"
CACHE="$PWD/.build/modcache"

mkdir -p "$CACHE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
swiftc \
  -O \
  -swift-version 5 \
  -nonlib-dependency-scanner \
  -module-cache-path "$CACHE" \
  -target arm64-apple-macosx14.0 \
  ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
  -framework AppKit -framework SwiftUI -framework EventKit -framework ServiceManagement \
  Sources/*.swift \
  -o "$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
if $DEMO; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $IDENTIFIER" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Glitter Demo" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Glitter Demo" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :GlitterDemoMode bool true" "$APP/Contents/Info.plist"
fi

echo "==> 签名"
IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "    ad-hoc 签名（本地构建，未经过 Apple 公证）"
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "==> 完成: $APP"
