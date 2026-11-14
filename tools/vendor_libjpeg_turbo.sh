#!/bin/bash
# Chép phần giải mã của libjpeg-turbo vào FaceFinderKit/Sources/CJPEGTurbo/upstream và sinh các header cấu hình.
#
#   tools/vendor_libjpeg_turbo.sh [tag]        # mặc định 3.1.4.1 = bản đi kèm Pillow 12.3 mà CLI dùng
#
# Vì sao cần: app phải giải mã JPEG ra đúng từng pixel như CLI Python (PLAN.md mục 5.1). ImageIO của Apple cho
# pixel khác, làm điểm số lệch. Chỉ chạy lại script này khi nâng phiên bản; mã nguồn đã chép được commit vào repo.
# Không sửa file nào của upstream: chọn file để biên dịch trong Package.swift, cấu hình nằm ở config/.
set -euo pipefail
TAG=${1:-3.1.4.1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/FaceFinderKit/Sources/CJPEGTurbo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone -q --depth 1 --branch "$TAG" https://github.com/libjpeg-turbo/libjpeg-turbo.git "$TMP/src" 2>/dev/null
COMMIT=$(git -C "$TMP/src" rev-parse HEAD)
VERSION=$(sed -n 's/^set(VERSION \(.*\))$/\1/p' "$TMP/src/CMakeLists.txt")
YEAR=$(sed -n 's/^set(COPYRIGHT_YEAR "\(.*\)")$/\1/p' "$TMP/src/CMakeLists.txt")
IFS=. read -r MAJOR MINOR REV _ <<<"$VERSION"
NUMBER=$((MAJOR * 1000000 + MINOR * 1000 + REV))

rm -rf "$DEST/upstream" "$DEST/config" "$DEST/neon"
mkdir -p "$DEST/upstream/src/wrapper" "$DEST/upstream/simd/arm/aarch64" "$DEST/config" "$DEST/neon"

# Mã nguồn thư viện (bỏ các chương trình dòng lệnh và test), giấy phép.
cp "$TMP"/src/src/j*.c "$TMP"/src/src/j*.h "$DEST/upstream/src/"
rm -f "$DEST/upstream/src/jpegtran.c" "$DEST/upstream/src/jcstest.c"
cp "$TMP"/src/src/wrapper/j*.c "$DEST/upstream/src/wrapper/"
cp "$TMP/src/simd/jsimd.h" "$DEST/upstream/simd/"
cp "$TMP"/src/simd/arm/*.c "$TMP"/src/simd/arm/*.h "$DEST/upstream/simd/arm/"
cp "$TMP"/src/simd/arm/aarch64/*.c "$DEST/upstream/simd/arm/aarch64/"
cp "$TMP/src/LICENSE.md" "$TMP/src/README.ijg" "$DEST/upstream/"

# Phần NEON chỉ biên dịch trên Apple Silicon; máy Intel dùng bản C thuần (kết quả giống hệt, chậm hơn).
for f in jccolor jcgray jcphuff jcsample jdcolor jdmerge jdsample jfdctfst jfdctint jidctfst jidctint jidctred jquanti \
         aarch64/jchuff aarch64/jsimd; do
  src="$f-neon.c"; [ "$f" = aarch64/jsimd ] && src="$f.c"
  printf '// Sinh bởi tools/vendor_libjpeg_turbo.sh\n#if defined(__aarch64__)\n#include "../upstream/simd/arm/%s"\n#endif\n' "$src" \
    > "$DEST/neon/$(basename "$src")"
done

cat > "$DEST/config/jconfig.h" <<EOF
/* Sinh bởi tools/vendor_libjpeg_turbo.sh từ src/jconfig.h.in của libjpeg-turbo $VERSION. */
#define JPEG_LIB_VERSION  62
#define LIBJPEG_TURBO_VERSION  $VERSION
#define LIBJPEG_TURBO_VERSION_NUMBER  $NUMBER
#define D_ARITH_CODING_SUPPORTED  1
#define MEM_SRCDST_SUPPORTED  1
#if defined(__aarch64__)
#define WITH_SIMD  1
#endif
#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8
#endif
EOF

cat > "$DEST/config/jconfigint.h" <<EOF
/* Sinh bởi tools/vendor_libjpeg_turbo.sh từ src/jconfigint.h.in của libjpeg-turbo $VERSION. */
#define BUILD  "facefinder"
#define HIDDEN  __attribute__((visibility("hidden")))
#undef inline
#define INLINE  __inline__ __attribute__((always_inline))
#define THREAD_LOCAL  __thread
#define PACKAGE_NAME  "libjpeg-turbo"
#define VERSION  "$VERSION"
#define SIZEOF_SIZE_T  8
#define HAVE_BUILTIN_CTZL

#if defined(__has_attribute)
#if __has_attribute(fallthrough)
#define FALLTHROUGH  __attribute__((fallthrough));
#else
#define FALLTHROUGH
#endif
#else
#define FALLTHROUGH
#endif

#ifndef BITS_IN_JSAMPLE
#define BITS_IN_JSAMPLE  8
#endif

#undef C_ARITH_CODING_SUPPORTED
#undef D_ARITH_CODING_SUPPORTED
#undef WITH_SIMD

#if BITS_IN_JSAMPLE == 8
#define D_ARITH_CODING_SUPPORTED  1
#if defined(__aarch64__)
#define WITH_SIMD  1
#endif
#endif
EOF

sed "s/@COPYRIGHT_YEAR@/$YEAR/" "$TMP/src/src/jversion.h.in" > "$DEST/config/jversion.h"
sed -e 's/#cmakedefine \(HAVE_VLD1[A-Z0-9_]*\)/#define \1/' "$TMP/src/simd/arm/neon-compat.h.in" > "$DEST/config/neon-compat.h"

cat > "$DEST/upstream/VENDORED.md" <<EOF
libjpeg-turbo $VERSION, commit $COMMIT
Nguồn: https://github.com/libjpeg-turbo/libjpeg-turbo (tag $TAG)

Chép nguyên văn bằng tools/vendor_libjpeg_turbo.sh, không sửa file nào. Đã bỏ: chương trình dòng lệnh, TurboJPEG API,
test, phần SIMD cho x86/MIPS/PowerPC và bản hợp ngữ. Chỉ phần giải mã được biên dịch (xem Package.swift).
Giấy phép: LICENSE.md và README.ijg trong thư mục này (IJG + BSD 3 điều khoản + zlib).
EOF
echo "Đã chép libjpeg-turbo $VERSION ($COMMIT) vào $DEST"
