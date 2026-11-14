#!/usr/bin/env python3
"""
Tạo dữ liệu kiểm thử cho bước đọc ảnh, từ ảnh nhiễu ngẫu nhiên (không phải ảnh thật):
  - resample_*: ảnh + kết quả Pillow thu nhỏ nó              -> test `PILResampleTests`
  - load_*:     file JPEG/MPO + kết quả `findface.load_image` -> test `ImageLoaderTests`
Bản Swift phải cho ra đúng từng byte.

    face-finder/venv/bin/python tools/make_test_fixtures.py

Định dạng file *_in.bin / *_out_*.bin: rộng, cao (2 số uint32 little-endian) rồi dữ liệu R, G, B từng pixel.
File load_*_file.bin là nguyên file ảnh (đặt đuôi .bin vì .gitignore chặn mọi file ảnh).
"""
import io
import os
import struct
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "face-finder"))
import findface  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
                   "FaceFinderKit", "Tests", "FaceFinderKitTests", "Fixtures")


def save(name, im):
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(struct.pack("<II", *im.size) + im.tobytes())


def noise(rng, w, h):
    # nhiễu mịn + nhiễu hạt để có cả vùng chuyển màu lẫn chi tiết sắc
    base = rng.integers(0, 256, (h // 8 + 2, w // 8 + 2, 3)).astype(np.uint8)
    im = Image.fromarray(base).resize((w, h), Image.BICUBIC)
    return Image.fromarray(np.clip(np.asarray(im).astype(int) + rng.integers(-40, 41, (h, w, 3)), 0, 255).astype(np.uint8))


def load_fixtures(rng):
    exif = Image.Exif()
    exif[274] = 6  # Orientation: xoay 90 độ theo chiều kim đồng hồ
    im = noise(rng, 520, 392)
    cases = {
        # JPEG thường, thu nhỏ 4,3 lần: findface dùng draft() -> giải mã ở 1/4 rồi thu nhỏ tiếp
        "draft": (dict(format="JPEG", quality=90, subsampling="4:2:2"), 120),
        # như trên nhưng có thẻ xoay EXIF và lấy mẫu màu 4:2:0
        "rotated": (dict(format="JPEG", quality=85, subsampling="4:2:0", exif=exif), 150),
        # MPO (JPEG nhiều ảnh, như máy Sony): Pillow báo format "MPO" nên findface KHÔNG dùng draft()
        "mpo": (dict(format="MPO", quality=90, save_all=True, append_images=[im.resize((64, 48))]), 120),
        # ảnh nhỏ hơn giới hạn: không thu nhỏ
        "asis": (dict(format="JPEG", quality=92, subsampling="4:4:4"), 2400),
    }
    for name, (options, side) in cases.items():
        buf = io.BytesIO()
        im.save(buf, **options)
        data = buf.getvalue()
        with open(os.path.join(OUT, f"load_{name}_file.bin"), "wb") as f:
            f.write(data)
        bgr, _ = findface.load_image(data, side)
        save(f"load_{name}_out_{side}.bin", Image.fromarray(bgr[:, :, ::-1]))
        print("load", name, Image.open(io.BytesIO(data)).format, im.size, "->", bgr.shape[1::-1], f"{len(data) // 1024} KB")


def main():
    rng = np.random.default_rng(2026)
    # (tên, rộng, cao, cạnh dài sau thu nhỏ): thu nhỏ ít (<2 lần), thu nhỏ nhiều (có bước gộp khối), ảnh dọc
    for name, w, h, side in (("small", 301, 203, 208), ("large", 517, 389, 96), ("tall", 199, 331, 200)):
        im = noise(rng, w, h)
        save(f"resample_{name}_in.bin", im)
        im.thumbnail((side, side), Image.BILINEAR)
        save(f"resample_{name}_out_{side}.bin", im)
        print("resample", name, (w, h), "->", im.size)
    load_fixtures(rng)


if __name__ == "__main__":
    main()
