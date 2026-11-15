#!/bin/bash
# In phiên bản app (CFBundleShortVersionString). project.yml là nguồn, FaceFinder/App/Info.plist là bản XcodeGen sinh ra
# và được commit (Xcode build từ file này): báo lỗi nếu hai nơi khác nhau, tức là quên chạy `xcodegen` sau khi đổi.
set -euo pipefail
cd "$(dirname "$0")/.."
YML=$(sed -nE 's/^ *CFBundleShortVersionString: *"?([^"]+)"?$/\1/p' FaceFinder/project.yml)
PLIST=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" FaceFinder/App/Info.plist)
YML_BUILD=$(sed -nE 's/^ *CFBundleVersion: *"?([^"]+)"?$/\1/p' FaceFinder/project.yml)
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" FaceFinder/App/Info.plist)
if [ "$YML" != "$PLIST" ] || [ "$YML_BUILD" != "$PLIST_BUILD" ]; then
  echo "LỖI: project.yml ($YML build $YML_BUILD) khác Info.plist ($PLIST build $PLIST_BUILD): chạy 'cd FaceFinder && xcodegen'" >&2
  exit 1
fi
echo "$PLIST"
