#!/usr/bin/env python3
"""
Chuyển hai model ONNX của CLI sang Core ML (.mlpackage) cho app macOS.

    tools/.venv/bin/python tools/convert_models.py            # chuyển cả hai, có kiểm tra
    tools/.venv/bin/python tools/convert_models.py --only arcface --precision fp32

Chỉ chạy lúc phát triển và lúc build trên GitHub Actions. Đầu vào lấy từ face-finder/models/ (do
face-finder/setup.sh tải về) nếu có, không thì từ models/onnx/ (do tools/fetch_models.sh tải về, có kiểm SHA-256);
đầu ra ghi vào models/ ở gốc dự án. Không thư mục nào được commit vào git.

Hai model sau khi chuyển:

  ArcFaceR50.mlpackage
      vào : "faces"  float32 [N, 3, 112, 112], RGB, giá trị 0..255 (model tự chuẩn hoá (x-127.5)/127.5)
      ra  : "embedding" float32 [N, 512], CHƯA chuẩn hoá độ dài (app tự chia cho norm, bằng FP32)

  YuNet.mlpackage
      vào : "image"  ảnh BGR 8 bit, cao/rộng là bội số của 32 (app tự chèn viền đen bên phải/dưới)
      ra  : "s8", "s16", "s32"  float32 [1, 16, H/s, W/s] cho từng bước lưới s = 8, 16, 32.
            16 kênh = [cls, obj, bbox(4), kps(10)]; cls và obj đã qua sigmoid.
            Phần giải mã + NMS do app làm (chép theo cv2.FaceDetectorYN).
"""
import argparse
import os
import shutil
import sys

import numpy as np
import onnx
import torch
import coremltools as ct
from onnx2torch import convert as onnx_to_torch

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SRC = os.path.join(ROOT, "face-finder", "models")
if not os.path.isdir(SRC):
    SRC = os.path.join(ROOT, "models", "onnx")
DST = os.path.join(ROOT, "models")

# Tên tensor ngay trước các nút Transpose/Reshape/Sigmoid cuối cùng của yunet_2023mar.onnx.
# Cắt ở đây để đầu ra giữ dạng lưới [1, C, H/s, W/s], không cần Reshape với kích thước động.
YUNET_HEADS = {
    "cls": ["258", "260", "262"],
    "obj": ["270", "272", "274"],
    "bbox": ["264", "266", "268"],
    "kps": ["276", "278", "280"],
}
YUNET_MAX_SIDE = 2432  # 2400 làm tròn lên bội số của 32


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class ArcFace(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, faces):
        return self.net((faces - 127.5) / 127.5)


class YuNet(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image):
        o = self.net(image)  # thứ tự: cls×3, obj×3, bbox×3, kps×3
        return tuple(
            torch.cat([torch.sigmoid(o[i]), torch.sigmoid(o[3 + i]), o[6 + i], o[9 + i]], dim=1) for i in range(3)
        )


def save(model, name, author, license_text, desc):
    model.author, model.license, model.short_description = author, license_text, desc
    path = os.path.join(DST, name + ".mlpackage")
    if os.path.exists(path):
        shutil.rmtree(path)
    model.save(path)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)
    log(f"  -> {path}  ({size / 1e6:.1f} MB)")
    return path


# Ngưỡng của bước kiểm tra sau khi chuyển: vượt ngưỡng thì xoá model vừa ghi và báo lỗi (để CI không cache/đóng gói
# một model hỏng khi thư viện chuyển đổi đổi phiên bản).
ARCFACE_MIN_COSINE = 0.998
YUNET_MAX_ERROR = {"fp32": 0.001, "fp16": 0.05}  # fp32 đã kiểm chứng: 0,00001


def reject(path, bad, why):
    if bad:
        shutil.rmtree(path, ignore_errors=True)
        sys.exit(f"LỖI: {why}. Đã xoá {path}.")


def precision_of(name):
    return ct.precision.FLOAT16 if name == "fp16" else ct.precision.FLOAT32


def convert_arcface(precision, max_batch, verify):
    src = os.path.join(SRC, "w600k_r50.onnx")
    log(f"ArcFace: {src}  ({precision})")
    net = ArcFace(onnx_to_torch(onnx.load(src))).eval()
    example = torch.rand(2, 3, 112, 112) * 255
    traced = torch.jit.trace(net, example, check_trace=False)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="faces", shape=(ct.RangeDim(1, max_batch, default=1), 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision_of(precision),
        minimum_deployment_target=ct.target.macOS15,
    )
    path = save(model, "ArcFaceR50", "InsightFace (buffalo_l / w600k_r50), chuyển sang Core ML",
                "Chỉ dùng cho mục đích phi thương mại (điều khoản của InsightFace)",
                "ArcFace ResNet-50: ảnh mặt đã căn 112x112 RGB (0..255) -> vector 512 chiều")
    if verify:
        import onnxruntime as ort
        ort.disable_telemetry_events()
        sess = ort.InferenceSession(src, providers=["CPUExecutionProvider"])
        x = np.random.default_rng(0).integers(0, 256, (4, 3, 112, 112)).astype(np.float32)
        ref = sess.run(None, {sess.get_inputs()[0].name: (x - 127.5) / 127.5})[0]
        for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_AND_NE):
            got = ct.models.MLModel(path, compute_units=units).predict({"faces": x})["embedding"]
            cos = np.sum(ref * got, 1) / (np.linalg.norm(ref, axis=1) * np.linalg.norm(got, axis=1))
            log(f"  kiểm tra {units.name:12s}: cosine so với ONNX min={cos.min():.6f}  (đầu vào ngẫu nhiên)")
            # Bản FP16 đã kiểm chứng cho min ≈ 0,9995 (CPU, NE) và 0,999996 (GPU).
            reject(path, cos.min() < ARCFACE_MIN_COSINE, f"ArcFace trên {units.name}: cosine {cos.min():.6f} < {ARCFACE_MIN_COSINE}")


def cut_yunet(src):
    """Bỏ các nút Transpose/Reshape/Sigmoid cuối, lấy thẳng 12 lưới đặc trưng làm đầu ra."""
    m = onnx.load(src)
    heads = [t for k in ("cls", "obj", "bbox", "kps") for t in YUNET_HEADS[k]]
    produced = {o for n in m.graph.node for o in n.output}
    missing = [t for t in heads if t not in produced]
    if missing:
        sys.exit(f"yunet.onnx không có các tensor {missing}: file khác bản 2023mar, cần cập nhật YUNET_HEADS")
    keep = [n for n in m.graph.node if n.op_type not in ("Transpose", "Reshape", "Sigmoid")]
    del m.graph.node[:]
    m.graph.node.extend(keep)
    del m.graph.output[:]
    for t in heads:
        m.graph.output.append(onnx.helper.make_tensor_value_info(t, onnx.TensorProto.FLOAT, None))
    del m.graph.value_info[:]
    return m


def convert_yunet(precision, verify):
    src = os.path.join(SRC, "yunet.onnx")
    log(f"YuNet: {src}  ({precision})")
    net = YuNet(onnx_to_torch(cut_yunet(src))).eval()
    traced = torch.jit.trace(net, torch.rand(1, 3, 320, 480) * 255, check_trace=False)
    side = ct.RangeDim(32, YUNET_MAX_SIDE, default=640)
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, side, side), color_layout=ct.colorlayout.BGR,
                             scale=1.0, bias=[0.0, 0.0, 0.0])],
        outputs=[ct.TensorType(name=n, dtype=np.float32) for n in ("s8", "s16", "s32")],
        convert_to="mlprogram",
        compute_precision=precision_of(precision),
        minimum_deployment_target=ct.target.macOS15,
    )
    path = save(model, "YuNet", "OpenCV Zoo (face_detection_yunet_2023mar), chuyển sang Core ML", "MIT",
                "YuNet: phát hiện khuôn mặt + 5 điểm mốc. Đầu ra là lưới thô, app tự giải mã và NMS")
    if verify:
        import onnxruntime as ort
        from PIL import Image
        ort.disable_telemetry_events()
        sess = ort.InferenceSession(src, providers=["CPUExecutionProvider"])
        rgb = np.random.default_rng(0).integers(0, 256, (640, 640, 3)).astype(np.uint8)
        bgr = rgb[:, :, ::-1].astype(np.float32).transpose(2, 0, 1)[None]
        ref = dict(zip([o.name for o in sess.get_outputs()], sess.run(None, {"input": bgr})))
        for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU):
            got = ct.models.MLModel(path, compute_units=units).predict({"image": Image.fromarray(rgb)})
            worst = 0.0
            for s in (8, 16, 32):
                g = got[f"s{s}"][0].reshape(16, -1).T  # [HW, 16], cùng thứ tự hàng-trước như ONNX
                r = np.concatenate([ref[f"cls_{s}"][0], ref[f"obj_{s}"][0], ref[f"bbox_{s}"][0], ref[f"kps_{s}"][0]], 1)
                worst = max(worst, float(np.abs(g - r).max()))
            log(f"  kiểm tra {units.name:12s}: sai lệch lớn nhất so với ONNX = {worst:.5f}  (ảnh ngẫu nhiên 640x640)")
            limit = YUNET_MAX_ERROR[precision]
            reject(path, worst > limit, f"YuNet trên {units.name}: sai lệch {worst:.5f} > {limit}")


def main():
    ap = argparse.ArgumentParser(description="Chuyển model ONNX của findface sang Core ML")
    ap.add_argument("--only", choices=["arcface", "yunet"], help="chỉ chuyển một model")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16", help="độ chính xác của ArcFace (mặc định fp16)")
    ap.add_argument("--yunet-precision", choices=["fp16", "fp32"], default="fp32",
                    help="độ chính xác của YuNet (mặc định fp32: model chỉ 0,2 MB, không cần nén)")
    ap.add_argument("--max-batch", type=int, default=64, help="số mặt tối đa mỗi lần gọi ArcFace")
    ap.add_argument("--no-verify", action="store_true", help="bỏ bước so với ONNX Runtime")
    ap.add_argument("--input", help="thư mục chứa yunet.onnx và w600k_r50.onnx (mặc định face-finder/models/, "
                                    "không có thì models/onnx/)")
    ap.add_argument("--output", help="thư mục ghi model (mặc định models/ ở gốc dự án)")
    args = ap.parse_args()
    global DST, SRC
    if args.input:
        SRC = os.path.abspath(os.path.expanduser(args.input))
    if args.output:
        DST = os.path.abspath(os.path.expanduser(args.output))
    os.makedirs(DST, exist_ok=True)
    if args.only != "yunet":
        convert_arcface(args.precision, args.max_batch, not args.no_verify)
    if args.only != "arcface":
        convert_yunet(args.yunet_precision, not args.no_verify)


if __name__ == "__main__":
    main()
