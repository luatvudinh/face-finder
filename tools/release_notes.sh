#!/bin/bash
# In ghi chú phát hành cho GitHub Releases (Markdown) ra stdout.
#
#   tools/release_notes.sh dist/FaceFinder-0.4.0.dmg [notarized]
set -euo pipefail
DMG=${1:?"dùng: tools/release_notes.sh <file .dmg> [notarized]"}
NOTARIZED=${2:-}
NAME=$(basename "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

cat <<EOF
Ứng dụng macOS tìm ảnh có một người trong thư mục hoặc file zip ảnh. Chạy hoàn toàn trên máy: App Sandbox không có
quyền mạng, model nhận diện đóng gói sẵn trong app.

**Yêu cầu:** macOS 15 trở lên. Bản universal: Apple Silicon và Intel (Intel chậm hơn nhiều, chưa được thử trên máy
thật).

### Cài đặt

1. Tải \`$NAME\`, mở ra và kéo **Face Finder** vào **Applications**.
EOF

if [ "$NOTARIZED" = "notarized" ]; then
  echo "2. Mở app như mọi app khác (bản này đã được Apple notarize)."
else
  cat <<'EOF'
2. Bản này **chưa được Apple notarize** (ký ad-hoc), nên lần mở đầu macOS sẽ chặn. Mở app một lần, bấm **Done**, rồi
   vào **System Settings → Privacy & Security**, kéo xuống và bấm **Open Anyway** cạnh dòng "Face Finder", xác nhận
   bằng mật khẩu máy. Chỉ phải làm một lần.
EOF
fi

cat <<EOF
3. Kiểm tra file tải về không bị sửa:

   \`\`\`
   shasum -a 256 $NAME
   \`\`\`

   phải ra đúng: \`$SHA\`

Tự kiểm tra app không có quyền mạng: \`codesign -d --entitlements - "/Applications/Face Finder.app"\` (không có dòng
\`network\`).

### Giấy phép

Mã nguồn: MIT. Model nhận diện ArcFace (InsightFace) **chỉ được dùng cho mục đích phi thương mại**, nên bản build này
cũng chỉ dùng phi thương mại. Chi tiết trong \`NOTICE\`.

---

*English:* Face Finder finds photos of a person in a photo folder or zip file, fully on-device (sandboxed, no network
access). macOS 15+. Not notarized unless stated above: after the first launch is blocked, open System Settings →
Privacy & Security → **Open Anyway**. Non-commercial use only (InsightFace ArcFace model license). The interface
language can be switched to English in Settings.
EOF
