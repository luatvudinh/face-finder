#!/bin/bash
# Tự kiểm tra toàn luồng của app (bản Debug, KHÔNG sandbox, dữ liệu riêng): thêm nguồn → lập chỉ mục → thêm người
# → tìm → ghi thư mục kết quả → kéo ngưỡng. Chụp cửa sổ app ở từng bước. Xem FaceFinder/App/SelfTest.swift.
#
#   tools/app_selftest.sh THƯ_MỤC_LÀM_VIỆC TÊN THƯ_MỤC_ẢNH_MẪU NGUỒN...
#
# Build Release (tốc độ như bản phát hành) có bật thêm SelfTest bằng cờ SELFTEST; bản phát hành thật không có cờ này.
# Ghi vào THƯ_MỤC_LÀM_VIỆC: data/ (chỉ mục), out/ (thư mục kết quả), shots/ (ảnh chụp), selftest.log.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(cd "$1" && pwd); NAME=$2; REFS=$3; shift 3
mkdir -p "$WORK/data" "$WORK/out" "$WORK/shots"
xcodebuild -project "$ROOT/FaceFinder/FaceFinder.xcodeproj" -scheme FaceFinder -configuration Release \
  -derivedDataPath "$ROOT/.build-app-selftest" CODE_SIGN_ENTITLEMENTS=App/FaceFinder-NoSandbox.entitlements \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=SELFTEST build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
python3 - "$WORK" "$NAME" "$REFS" "$@" <<'PY'
import json, sys
work, name, refs, *sources = sys.argv[1:]
json.dump({"sources": sources, "references": [refs], "name": name, "outputBase": f"{work}/out",
           "snapshots": f"{work}/shots", "threshold2": 0.55}, open(f"{work}/selftest.json", "w"), ensure_ascii=False)
PY
FF_DATA_DIR="$WORK/data" FF_SELFTEST="$WORK/selftest.json" \
  "$ROOT/.build-app-selftest/Build/Products/Release/Face Finder.app/Contents/MacOS/Face Finder" 2>&1 | tee "$WORK/selftest.log" | grep --line-buffered "\[selftest\]"
