#!/bin/bash
# Build bản Release của app (sandbox, không quyền mạng, ký ad-hoc) và đóng thành DMG để dùng thử / phát hành.
#
#   tools/make_dmg.sh            -> dist/FaceFinder-<phiên bản>.dmg (+ .sha256)
#
# Cần: Xcode, models/*.mlpackage (tools/convert_models.py).
#
# Mặc định ký ad-hoc (chưa có tài khoản Apple Developer, PLAN.md Giai đoạn 4). Khi có tài khoản, đặt thêm biến môi
# trường, không phải sửa code:
#   SIGN_IDENTITY="Developer ID Application: Tên (TEAMID)"  TEAM_ID=TEAMID   -> ký Developer ID (+ dấu thời gian)
#   NOTARY_KEY_PATH=AuthKey_XXXX.p8  NOTARY_KEY_ID=XXXX  NOTARY_ISSUER=<uuid>  -> notarize DMG rồi staple
set -euo pipefail
SIGN_IDENTITY=${SIGN_IDENTITY:--}
TEAM_ID=${TEAM_ID:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
for m in YuNet ArcFaceR50; do
  [ -d "models/$m.mlpackage" ] || { echo "Thiếu models/$m.mlpackage: chạy tools/convert_models.py trước." >&2; exit 1; }
done

DERIVED="$ROOT/.build-app-release"
if [ "$SIGN_IDENTITY" = "-" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
  echo "Có NOTARY_KEY_PATH nhưng thiếu SIGN_IDENTITY: không notarize được bản ký ad-hoc" >&2; exit 1
fi
SIGN_ARGS=()
if [ "$SIGN_IDENTITY" != "-" ]; then
  [ -n "$TEAM_ID" ] || { echo "Ký Developer ID cần cả TEAM_ID" >&2; exit 1; }
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" OTHER_CODE_SIGN_FLAGS=--timestamp)
fi
xcodebuild -project FaceFinder/FaceFinder.xcodeproj -scheme FaceFinder -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/Face Finder.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Kiểm tra lần cuối: sandbox bật, không có quyền mạng, không có quyền gỡ lỗi
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
grep -q "com.apple.security.app-sandbox" <<<"$ENT" || { echo "LỖI: bản build không bật App Sandbox" >&2; exit 1; }
if grep -qE "network\.(client|server)|get-task-allow" <<<"$ENT"; then
  echo "LỖI: bản build có quyền mạng hoặc quyền gỡ lỗi" >&2; exit 1
fi
codesign --verify --deep --strict "$APP"
tools/check_no_network.sh "$APP"
echo "Kiến trúc: $(lipo -archs "$APP/Contents/MacOS/Face Finder")"
# Tên kiểu SelfTest chỉ có trong bản build có cờ SELFTEST/DEBUG. Đọc hết danh sách chuỗi trước rồi mới tìm: với pipefail,
# `strings | grep -q` có thể "qua" đúng lúc chuỗi có mặt (grep thoát sớm, strings nhận SIGPIPE).
SYMBOLS=$(strings "$APP/Contents/MacOS/Face Finder")
if grep -q "SelfTest" <<<"$SYMBOLS"; then
  echo "LỖI: bản phát hành còn chế độ tự kiểm tra" >&2; exit 1
fi

mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/FaceFinder-$VERSION.dmg"
rm -f "$DMG"
# hdiutil thỉnh thoảng báo "Resource busy" trên máy CI: thử lại vài lần.
for i in 1 2 3 4 5; do
  hdiutil create -quiet -volname "Face Finder $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" && break
  [ "$i" -eq 5 ] && exit 1
  sleep 3
done
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign -s "$SIGN_IDENTITY" --timestamp "$DMG"
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
  fi
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Đã tạo $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
