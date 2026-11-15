#!/bin/bash
# Kiểm tra bản build không có đường ra mạng (PLAN.md mục 3): lấy đúng entitlements đã ký vào app, ký chúng cho một
# chương trình thử (tools/netprobe.c) rồi cho nó kết nối tới một cổng mở trên chính máy này. Trong sandbox của app,
# kết nối phải bị hệ điều hành từ chối; bản đối chứng không sandbox phải kết nối được (để test không "qua" chỉ vì máy
# không có mạng).
#
#   tools/check_no_network.sh "path/to/Face Finder.app"
#
# Không gửi gì ra ngoài máy: chỉ dùng 127.0.0.1.
set -euo pipefail
APP=${1:?"dùng: tools/check_no_network.sh <đường dẫn tới Face Finder.app>"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
LISTENER=""
cleanup() { [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

codesign -d --entitlements :- "$APP" > "$WORK/app.entitlements" 2>/dev/null
grep -q "com.apple.security.app-sandbox" "$WORK/app.entitlements" || { echo "LỖI: app không bật App Sandbox" >&2; exit 1; }

# Chương trình dòng lệnh chạy sandbox cần Info.plist nhúng sẵn (có bundle id), nếu không macOS dừng nó ngay lúc khởi động.
cat > "$WORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.facefinder.netprobe</string>
  <key>CFBundleName</key><string>netprobe</string>
</dict></plist>
PLIST
clang -O1 -o "$WORK/netprobe" "$ROOT/tools/netprobe.c" -sectcreate __TEXT __info_plist "$WORK/Info.plist"
cp "$WORK/netprobe" "$WORK/netprobe-open"
cp "$WORK/netprobe" "$WORK/netprobe-sandboxed"
codesign -s - -f "$WORK/netprobe-open" 2>/dev/null
codesign -s - -f --options runtime --identifier io.github.facefinder.netprobe \
  --entitlements "$WORK/app.entitlements" "$WORK/netprobe-sandboxed" 2>/dev/null

"$WORK/netprobe-open" listen > "$WORK/port" &
LISTENER=$!
disown "$LISTENER"
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT=$(head -1 "$WORK/port")
[ -n "$PORT" ] || { echo "LỖI: không mở được cổng thử" >&2; exit 1; }

echo "Đối chứng (không sandbox):"
set +e
"$WORK/netprobe-open" connect "$PORT" | sed 's/^/  /'
OPEN=${PIPESTATUS[0]}
echo "Với entitlements của app:"
"$WORK/netprobe-sandboxed" connect "$PORT" | sed 's/^/  /'
BOXED=${PIPESTATUS[0]}
set -e

[ "$OPEN" -eq 0 ] || { echo "LỖI: bản đối chứng không kết nối được, test không có ý nghĩa (mã $OPEN)" >&2; exit 1; }
[ "$BOXED" -eq 3 ] || { echo "LỖI: sandbox của app KHÔNG chặn kết nối mạng (mã $BOXED)" >&2; exit 1; }
echo "OK: sandbox của app chặn kết nối mạng."
