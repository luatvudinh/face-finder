#!/bin/bash
# Báo lỗi nếu git đang theo dõi (hoặc sắp commit) file có thể chứa dữ liệu cá nhân: ảnh/video, chỉ mục, kết quả, model,
# dữ liệu đối chiếu với CLI. Kiểm tra theo đuôi và đường dẫn file, cộng thêm kiểu nội dung (để bắt ảnh bị đổi đuôi);
# dữ liệu test trong Tests/**/Fixtures/ là ảnh nhiễu ngẫu nhiên do tools/make_test_fixtures.py tạo nên được bỏ qua.
#
#   tools/check_repo_privacy.sh            # file đã commit + file đã `git add`
set -euo pipefail
cd "$(dirname "$0")/.."

NAME_RE='^(golden|models|dist|face-finder/models|face-finder/venv)/|\.(mlpackage|mlmodelc)/|(^|/)Face Finder - [^/]*/|(^|/)_báo cáo/'
EXT_RE='\.(jpe?g|jpe|jfif|png|gif|heic|heif|avif|webp|tiff?|bmp|arw|srf|sr2|cr2|cr3|crw|nef|nrw|dng|raf|orf|rw2|raw|rwl|pef|srw|3fr|iiq|x3f|erf|mrw|mos|mov|mp4|m4v|zip|7z|rar|sqlite|sqlite3|db|pkl|npy|npz|csv|onnx|mlmodel)$'
FIXTURES_RE='^FaceFinderKit/Tests/FaceFinderKitTests/Fixtures/'

FILES=$( { git ls-files -z; git diff --cached --name-only -z; } | tr '\0' '\n' | sort -u)
BAD=$(grep -iE -e "$NAME_RE" -e "$EXT_RE" <<<"$FILES" || true)

# Nội dung là ảnh/video dù đuôi file là gì (ngoài thư mục Fixtures)
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -qE "$FIXTURES_RE" <<<"$f" && continue
  case $(file -b --mime-type "$f") in
    image/svg+xml) ;;
    image/* | video/* | application/zip | application/x-sqlite3) BAD+=$'\n'"$f" ;;
  esac
done <<<"$FILES"

BAD=$(grep -v '^$' <<<"$BAD" || true)
if [ -n "$BAD" ]; then
  echo "LỖI: repo có file có thể chứa dữ liệu cá nhân (ảnh, chỉ mục, kết quả, model):" >&2
  echo "$BAD" | sed 's/^/  /' >&2
  exit 1
fi
echo "OK: $(wc -l <<<"$FILES" | tr -d ' ') file, không có ảnh, chỉ mục, kết quả hay model."
