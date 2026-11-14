#!/bin/bash
# Build bản Release của app (sandbox, không quyền mạng, ký ad-hoc) và đóng thành DMG để dùng thử / phát hành.
#
#   tools/make_dmg.sh            -> dist/FaceFinder-<phiên bản>.dmg (+ .sha256)
#
# Cần: Xcode, models/*.mlpackage (tools/convert_models.py). Chưa notarize (PLAN.md Giai đoạn 4).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
for m in YuNet ArcFaceR50; do
  [ -d "models/$m.mlpackage" ] || { echo "Thiếu models/$m.mlpackage: chạy tools/convert_models.py trước." >&2; exit 1; }
done

DERIVED="$ROOT/.build-app-release"
xcodebuild -project FaceFinder/FaceFinder.xcodeproj -scheme FaceFinder -configuration Release \
  -derivedDataPath "$DERIVED" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/Face Finder.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Kiểm tra lần cuối: sandbox bật, không có quyền mạng, không có quyền gỡ lỗi
ENT=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
echo "$ENT" | grep -q "com.apple.security.app-sandbox" || { echo "LỖI: bản build không bật App Sandbox" >&2; exit 1; }
if echo "$ENT" | grep -qE "network\.(client|server)|get-task-allow"; then
  echo "LỖI: bản build có quyền mạng hoặc quyền gỡ lỗi" >&2; exit 1
fi
codesign --verify --deep --strict "$APP"
echo "Kiến trúc: $(lipo -archs "$APP/Contents/MacOS/Face Finder")"
if strings "$APP/Contents/MacOS/Face Finder" | grep -q "FF_SELFTEST"; then
  echo "LỖI: bản phát hành còn chế độ tự kiểm tra" >&2; exit 1
fi

mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/FaceFinder-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Face Finder $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Đã tạo $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
