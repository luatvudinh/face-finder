#!/bin/bash
# Tải hai model ONNX gốc (YuNet của OpenCV Zoo, ArcFace w600k_r50 của InsightFace) và kiểm tra SHA-256, để
# tools/convert_models.py chuyển sang Core ML. Dùng khi không có sẵn repo CLI face-finder/ (ví dụ trên GitHub Actions).
#
#   tools/fetch_models.sh            -> models/onnx/yunet.onnx, models/onnx/w600k_r50.onnx
#   tools/fetch_models.sh <thư mục>
#
# Mã SHA-256 là của đúng hai file mà CLI đã dùng để kiểm chứng độ chính xác (PLAN.md mục 5.0).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/models/onnx"}
mkdir -p "$OUT"

YUNET_URL=https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
YUNET_SHA=8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
BUFFALO_URL=https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
ARCFACE_SHA=4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43

ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }
check() { ok "$1" "$2" || { echo "LỖI: $1 sai mã SHA-256 (mong đợi $2)" >&2; rm -f "$1"; exit 1; }; }

if ok "$OUT/yunet.onnx" "$YUNET_SHA"; then
  echo "Đã có yunet.onnx"
else
  curl -fsSL --retry 5 -o "$OUT/yunet.onnx" "$YUNET_URL"
  check "$OUT/yunet.onnx" "$YUNET_SHA"
  echo "Đã tải yunet.onnx"
fi

if ok "$OUT/w600k_r50.onnx" "$ARCFACE_SHA"; then
  echo "Đã có w600k_r50.onnx"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 5 -o "$TMP/buffalo_l.zip" "$BUFFALO_URL"
  unzip -q -o -j "$TMP/buffalo_l.zip" w600k_r50.onnx -d "$OUT"
  check "$OUT/w600k_r50.onnx" "$ARCFACE_SHA"
  echo "Đã tải w600k_r50.onnx"
fi
