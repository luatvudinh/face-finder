#!/usr/bin/env python3
"""
Xuất "đáp án mẫu" (golden data) từ CLI Python để so với bộ máy Swift/Core ML.

    face-finder/venv/bin/python tools/export_golden.py -i ~/Downloads/*.zip -n 200

Chạy bằng venv của CLI (cần cv2, onnxruntime). Dùng lại đúng các hàm của findface.py nên kết quả là
kết quả của CLI. Ghi vào golden/ ở gốc dự án (KHÔNG commit: chứa ảnh cá nhân và "vân mặt"):

    manifest.json   cấu hình + từng ảnh: kích thước, tổng kiểm, các khuôn mặt (khung, 5 điểm, điểm tin cậy,
                    ma trận căn mặt, số thứ tự ảnh mặt đã căn)
    images/*.png    ảnh sau khi CLI giải mã + thu nhỏ (đúng từng pixel mà YuNet của CLI nhìn thấy)
    crops.rgb       ảnh mặt đã căn, uint8 [N, 112, 112, 3] RGB
    emb_cpu.f32     vân mặt float32 [N, 512] đã chuẩn hoá, ONNX Runtime trên CPU (chuẩn đối chiếu)
    emb_gpu.f32     như trên nhưng qua CoreML EP của ONNX Runtime (cách CLI chạy mặc định trên máy Apple)
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "face-finder"))

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import findface as ff  # noqa: E402


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    ap = argparse.ArgumentParser(description="Xuất golden data từ CLI findface")
    ap.add_argument("-i", "--input", nargs="+", required=True, help="thư mục / ảnh / zip (như -i của findface)")
    ap.add_argument("-n", "--count", type=int, default=200, help="số ảnh lấy mẫu, rải đều (mặc định 200)")
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "golden"))
    ap.add_argument("--max-size", type=int, default=2400)
    ap.add_argument("--min-face", type=int, default=20)
    ap.add_argument("--det-threshold", type=float, default=0.7)
    args = ap.parse_args()

    import onnxruntime as ort
    ort.disable_telemetry_events()

    items = ff.dedupe(ff.collect(args.input))
    if not items:
        sys.exit("không tìm thấy ảnh nào")
    step = max(1, len(items) // args.count)
    items = items[::step][:args.count]
    log(f"Lấy {len(items)} ảnh")

    os.makedirs(os.path.join(args.output, "images"), exist_ok=True)
    det = cv2.FaceDetectorYN.create(ff.DET_MODEL, "", (320, 320), args.det_threshold, 0.3, 5000)
    opt = ort.SessionOptions()
    opt.intra_op_num_threads = 4
    opt.log_severity_level = 3
    cpu = ort.InferenceSession(ff.REC_MODEL, opt, providers=["CPUExecutionProvider"])
    gpu = None
    if "CoreMLExecutionProvider" in ort.get_available_providers():
        gpu = ort.InferenceSession(ff.REC_MODEL, opt, providers=[
            ("CoreMLExecutionProvider", {"MLComputeUnits": "CPUAndGPU", "ModelFormat": "MLProgram"}),
            "CPUExecutionProvider"])
    inp = cpu.get_inputs()[0].name

    images, ncrops = [], 0
    f_crops = open(os.path.join(args.output, "crops.rgb"), "wb")
    f_cpu = open(os.path.join(args.output, "emb_cpu.f32"), "wb")
    f_gpu = open(os.path.join(args.output, "emb_gpu.f32"), "wb") if gpu else None
    prog = ff.Progress(len(items), "Xuất")
    for n, it in enumerate(items):
        try:
            img, scale = ff.load_image(ff.read_bytes(it), args.max_size)
        except Exception as e:
            log(f"\n  bỏ {it['name']}: {e}")
            prog.update()
            continue
        h, w = img.shape[:2]
        det.setInputSize((w, h))
        _, dets = det.detect(img)
        fname = f"images/{n:05d}.png"
        cv2.imwrite(os.path.join(args.output, fname), img, [cv2.IMWRITE_PNG_COMPRESSION, 3])
        faces, crops = [], []
        for d in (dets if dets is not None else []):
            face = {"box": [float(v) for v in d[:4]], "lm": [float(v) for v in d[4:14]], "score": float(d[14]),
                    "crop": -1, "M": None}
            faces.append(face)
            if min(d[2], d[3]) < args.min_face:
                continue
            # y hệt findface.analyze()
            lm = d[4:14].reshape(5, 2).astype(np.float32)
            if lm[0, 0] > lm[1, 0]:
                lm[[0, 1]] = lm[[1, 0]]
            if lm[3, 0] > lm[4, 0]:
                lm[[3, 4]] = lm[[4, 3]]
            M, _ = cv2.estimateAffinePartial2D(lm, ff.ARC_TEMPLATE, method=cv2.LMEDS)
            if M is None:
                continue
            crops.append(cv2.warpAffine(img, M, (112, 112)))
            face["crop"], face["M"] = ncrops + len(crops) - 1, [float(v) for v in M.ravel()]
        if crops:
            rgb = np.stack(crops)[:, :, :, ::-1]
            x = ((rgb.astype(np.float32) - 127.5) / 127.5).transpose(0, 3, 1, 2)
            f_crops.write(np.ascontiguousarray(rgb).tobytes())
            for sess, f in ((cpu, f_cpu), (gpu, f_gpu)):
                if sess is None:
                    continue
                feats = sess.run(None, {inp: x})[0]
                feats /= np.linalg.norm(feats, axis=1, keepdims=True)
                f.write(feats.astype(np.float32).tobytes())
            ncrops += len(crops)
        images.append({"file": fname, "name": it["name"], "width": w, "height": h, "scale": float(scale),
                       "sha1": hashlib.sha1(img.tobytes()).hexdigest(),  # trên dữ liệu BGR, hàng-trước
                       "faces": faces})
        prog.update()
    prog.done()
    for f in (f_crops, f_cpu, f_gpu):
        if f:
            f.close()

    with open(os.path.join(args.output, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"version": 1, "max_size": args.max_size, "min_face": args.min_face,
                   "det_threshold": args.det_threshold, "nms_threshold": 0.3, "top_k": 5000,
                   "opencv": cv2.__version__, "onnxruntime": ort.__version__,
                   "crops": ncrops, "has_gpu": gpu is not None, "images": images}, f, ensure_ascii=False)
    nfaces = sum(len(i["faces"]) for i in images)
    log(f"Xong: {len(images)} ảnh, {nfaces} khuôn mặt phát hiện, {ncrops} ảnh mặt đã căn -> {args.output}")
    if gpu and ncrops:
        a = np.fromfile(os.path.join(args.output, "emb_cpu.f32"), np.float32).reshape(-1, 512)
        b = np.fromfile(os.path.join(args.output, "emb_gpu.f32"), np.float32).reshape(-1, 512)
        cos = np.sum(a * b, 1)
        log(f"Tham khảo: cosine giữa CPU và GPU của chính CLI: min={cos.min():.6f} trung bình={cos.mean():.6f}")


if __name__ == "__main__":
    main()
