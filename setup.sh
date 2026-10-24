#!/bin/bash
# Cài đặt findface: tạo môi trường Python riêng và tải model nhận diện khuôn mặt.
set -e
cd "$(dirname "$0")"
PY=${PYTHON:-python3}

[ -d venv ] || "$PY" -m venv venv
ok=0
for i in 1 2 3; do ./venv/bin/pip install -q --disable-pip-version-check -r requirements.txt && ok=1 && break; sleep 3; done
if [ $ok = 0 ]; then
  echo "Không cài được đúng phiên bản đã ghim, cài bản mới nhất..."
  ./venv/bin/pip install -q --disable-pip-version-check numpy opencv-python onnxruntime pillow pillow-heif
fi

mkdir -p models
if [ ! -f models/yunet.onnx ]; then
  echo "Tải model phát hiện khuôn mặt (YuNet)..."
  curl -#fL --retry 5 -o models/yunet.onnx \
    https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
fi
if [ ! -f models/w600k_r50.onnx ]; then
  echo "Tải model nhận diện khuôn mặt (InsightFace buffalo_l, ~280MB)..."
  for i in 1 2 3 4 5 6 7 8; do
    curl -#fL -C - -o models/buffalo_l.zip \
      https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip && break
    sleep 2
  done
  unzip -o -j models/buffalo_l.zip w600k_r50.onnx -d models
  rm -f models/buffalo_l.zip
fi
chmod +x findface
echo "Cài đặt xong. Chạy: $(pwd)/findface -h"
