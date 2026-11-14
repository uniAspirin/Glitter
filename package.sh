#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ $# -gt 0 ]]; then
  echo "Usage: ./package.sh" >&2
  exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" && "${SIGNING_IDENTITY:--}" == "-" ]]; then
  echo "NOTARY_PROFILE requires a Developer ID Application SIGNING_IDENTITY." >&2
  exit 1
fi

./build.sh
APP="build/Glitter.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
FILENAME="Glitter-$VERSION.dmg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glitter-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/staging" dist
ditto "$APP" "$WORK/staging/Glitter.app"
ln -s /Applications "$WORK/staging/Applications"

echo "==> 创建磁盘映像"
hdiutil create -volname Glitter -srcfolder "$WORK/staging" -fs HFS+ -format UDZO "$WORK/$FILENAME"
if [[ "${SIGNING_IDENTITY:--}" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$WORK/$FILENAME"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> 提交 Apple 公证"
  xcrun notarytool submit "$WORK/$FILENAME" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$WORK/notary.plist"
  STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK/notary.plist")
  if [[ "$STATUS" != "Accepted" ]]; then
    cat "$WORK/notary.plist" >&2
    echo "Apple notarization did not accept this package." >&2
    exit 1
  fi
  xcrun stapler staple "$WORK/$FILENAME"
  xcrun stapler validate "$WORK/$FILENAME"
fi

hdiutil verify "$WORK/$FILENAME"
mv -f "$WORK/$FILENAME" "dist/$FILENAME"
(
  cd dist
  shasum -a 256 "$FILENAME" > "$FILENAME.sha256"
)
echo "==> 完成: dist/$FILENAME"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "    此 DMG 尚未经过 Apple 公证。"
fi
