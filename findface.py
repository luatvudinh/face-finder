#!/usr/bin/env python3
"""
findface — lọc ra những ảnh có mặt một người cụ thể.

Đưa vào một hoặc nhiều ảnh mẫu của người cần tìm; công cụ quét các thư mục / file zip
và gom những ảnh có người đó vào thư mục kết quả.

Nhận diện: YuNet (phát hiện khuôn mặt) + ArcFace w600k_r50 của InsightFace (so khớp).
"""
import argparse
import csv
import io
import os
import pickle
import shutil
import sys
import time
import zipfile
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timedelta

os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")
# ONNX Runtime (Microsoft) bản macOS mặc định gửi telemetry (thông tin máy, mã thiết bị) về
# mobile.events.data.microsoft.com. Tắt ngay từ đầu, trước khi thư viện được nạp ở bất kỳ tiến trình nào.
os.environ["ORT_DISABLE_TELEMETRY"] = "1"

import cv2
import numpy as np
from PIL import Image, ImageOps

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:
    pass

Image.MAX_IMAGE_PIXELS = None
cv2.setNumThreads(1)

HERE = os.path.dirname(os.path.realpath(__file__))
DET_MODEL = os.path.join(HERE, "models", "yunet.onnx")
REC_MODEL = os.path.join(HERE, "models", "w600k_r50.onnx")
DEFAULT_CACHE = os.path.expanduser("~/.cache/findface/faces.pkl")
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif"}
CACHE_VERSION = 1
REVIEW_DIR = "Cần kiểm tra"
REPORT_DIR = "_báo cáo"

# Vị trí chuẩn của 5 điểm mốc (mắt trái, mắt phải, mũi, khoé miệng trái, phải) cho ArcFace 112x112.
ARC_TEMPLATE = np.array(
    [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]],
    np.float32,
)


def log(msg=""):
    print(msg, file=sys.stderr, flush=True)


def die(msg):
    log(f"Lỗi: {msg}")
    sys.exit(1)


# ---------------------------------------------------------------- nguồn ảnh

def file_item(path):
    st = os.stat(path)
    return {"key": path, "zip": None, "member": None, "name": os.path.basename(path),
            "size": st.st_size, "mtime": st.st_mtime, "stamp": (st.st_size, st.st_mtime_ns)}


def zip_items(path):
    items = []
    try:
        with zipfile.ZipFile(path) as z:
            for zi in z.infolist():
                name = os.path.basename(zi.filename)
                if zi.is_dir() or name.startswith("._") or "__MACOSX" in zi.filename:
                    continue
                if os.path.splitext(name)[1].lower() not in IMAGE_EXTS:
                    continue
                items.append({"key": f"{path}::{zi.filename}", "zip": path, "member": zi.filename, "name": name,
                              "size": zi.file_size, "mtime": time.mktime(zi.date_time + (0, 0, -1)),
                              "stamp": (zi.file_size, zi.CRC)})
    except zipfile.BadZipFile:
        log(f"  Bỏ qua file zip hỏng: {path}")
    return items


def collect(paths, since=None, exclude_dirs=()):
    """Gom danh sách ảnh từ các file / thư mục / zip. Thư mục được quét đệ quy."""
    exclude = {os.path.realpath(d) for d in exclude_dirs}
    items = []

    def add(path):
        name = os.path.basename(path)
        ext = os.path.splitext(name)[1].lower()
        if name.startswith("."):
            return
        if since and os.path.getmtime(path) < since:
            return
        if ext == ".zip":
            items.extend(zip_items(path))
        elif ext in IMAGE_EXTS:
            items.append(file_item(path))

    for p in paths:
        p = os.path.abspath(os.path.expanduser(p))
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith(".")
                                 and os.path.realpath(os.path.join(root, d)) not in exclude)
                for f in sorted(files):
                    add(os.path.join(root, f))
        elif os.path.isfile(p):
            add(p)
        else:
            log(f"  Không tìm thấy: {p}")
    return items


def dedupe(items):
    """Bỏ ảnh trùng (cùng tên và dung lượng), ví dụ vừa có trong zip vừa có bản đã giải nén."""
    seen, out = set(), []
    for it in items:
        k = (it["name"].lower(), it["size"])
        if k not in seen:
            seen.add(k)
            out.append(it)
    return out


_zips = {}


def read_bytes(item):
    if item["zip"] is None:
        with open(item["key"], "rb") as f:
            return f.read()
    z = _zips.get(item["zip"])
    if z is None:
        z = _zips[item["zip"]] = zipfile.ZipFile(item["zip"])
    return z.read(item["member"])


def extract_zip_items(items, dest_root):
    """Giải nén những ảnh nằm trong zip ra dest_root (giữ cấu trúc thư mục, không ghi đè)."""
    out, todo = [], [it for it in items if it["zip"]]
    prog = Progress(len(todo), "Giải nén")
    for it in items:
        if not it["zip"]:
            out.append(it)
            continue
        # bỏ "/", ".." trong tên file zip để không ghi ra ngoài thư mục đích (zip slip)
        parts = [x for x in it["member"].replace("\\", "/").split("/") if x not in ("", ".", "..")]
        dest = os.path.join(dest_root, *parts)
        if not (os.path.exists(dest) and os.path.getsize(dest) == it["size"]):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(read_bytes(it))
            os.utime(dest, (it["mtime"], it["mtime"]))
        out.append(file_item(dest))
        prog.update()
    prog.done()
    return out


# ---------------------------------------------------------------- nhận diện

def load_image(data, max_side):
    """Đọc ảnh (xoay đúng theo EXIF), thu nhỏ để cạnh dài <= max_side. Trả về (ảnh BGR, tỉ lệ thu nhỏ)."""
    im = Image.open(io.BytesIO(data))
    w, h = im.size
    long0 = max(w, h)
    s = min(1.0, max_side / long0)
    if s < 1 and im.format == "JPEG":
        im.draft("RGB", (max(1, int(w * s)), max(1, int(h * s))))  # giải mã JPEG ở độ phân giải thấp, nhanh hơn nhiều
    im = ImageOps.exif_transpose(im).convert("RGB")
    if max(im.size) > max_side:
        im.thumbnail((max_side, max_side), Image.BILINEAR)
    return np.asarray(im)[:, :, ::-1].copy(), max(im.size) / long0


_det = _rec = None
_cfg = {}


def init_models(max_side, min_face, det_thresh, device="cpu"):
    global _det, _rec
    import onnxruntime as ort
    ort.disable_telemetry_events()

    _cfg.update(max_side=max_side, min_face=min_face)
    _det = cv2.FaceDetectorYN.create(DET_MODEL, "", (320, 320), det_thresh, 0.3, 5000)
    opt = ort.SessionOptions()
    opt.intra_op_num_threads = 1
    opt.inter_op_num_threads = 1
    opt.log_severity_level = 3
    _rec = None
    if device == "gpu":  # Apple GPU qua CoreML: nhanh hơn ~10 lần, kết quả như CPU
        # Không dùng ModelCacheDirectory của CoreML: nhiều tiến trình cùng ghi một thư mục cache sẽ làm hỏng
        # nhau (lỗi "A valid manifest does not exist"). Biên dịch trong bộ nhớ chỉ tốn ~1 giây mỗi tiến trình.
        try:
            _rec = ort.InferenceSession(REC_MODEL, opt, providers=[
                ("CoreMLExecutionProvider", {"MLComputeUnits": "CPUAndGPU", "ModelFormat": "MLProgram"}),
                "CPUExecutionProvider"])
        except Exception as e:
            sys.stderr.write(f"\n  ! Không dùng được GPU ({type(e).__name__}: {str(e)[:120]}), chuyển sang CPU.\n")
    if _rec is None:
        _rec = ort.InferenceSession(REC_MODEL, opt, providers=["CPUExecutionProvider"])


def analyze(data):
    """Trả về danh sách khuôn mặt [(box theo toạ độ ảnh gốc, embedding float16)]."""
    img, scale = load_image(data, _cfg["max_side"])
    h, w = img.shape[:2]
    _det.setInputSize((w, h))
    _, dets = _det.detect(img)
    if dets is None:
        return []
    boxes, crops = [], []
    for d in dets:
        if min(d[2], d[3]) < _cfg["min_face"]:
            continue
        lm = d[4:14].reshape(5, 2).astype(np.float32)
        if lm[0, 0] > lm[1, 0]:
            lm[[0, 1]] = lm[[1, 0]]
        if lm[3, 0] > lm[4, 0]:
            lm[[3, 4]] = lm[[4, 3]]
        M, _ = cv2.estimateAffinePartial2D(lm, ARC_TEMPLATE, method=cv2.LMEDS)
        if M is None:
            continue
        crops.append(cv2.warpAffine(img, M, (112, 112)))
        boxes.append((d[:4] / scale).astype(np.float32))
    if not crops:
        return []
    x = ((np.stack(crops)[:, :, :, ::-1].astype(np.float32) - 127.5) / 127.5).transpose(0, 3, 1, 2)
    feats = _rec.run(None, {_rec.get_inputs()[0].name: x})[0]
    feats /= np.linalg.norm(feats, axis=1, keepdims=True)
    return [(b, f.astype(np.float16)) for b, f in zip(boxes, feats)]


def _work(item):
    try:
        return item["key"], analyze(read_bytes(item)), None
    except Exception as e:
        return item["key"], [], f"{type(e).__name__}: {e}"


class FaceCache:
    """Lưu embedding đã tính để chạy lại (đổi ảnh mẫu, đổi ngưỡng) gần như tức thì."""

    def __init__(self, path):
        self.path, self.data, self.dirty = (os.path.abspath(os.path.expanduser(path)) if path else None), {}, 0
        if path and os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    obj = pickle.load(f)
                if obj.get("version") == CACHE_VERSION:
                    self.data = obj["entries"]
            except Exception:
                log("  Cache hỏng, sẽ tính lại.")

    def get(self, item, sig):
        e = self.data.get(item["key"])
        if e and e[0] == item["stamp"] and e[1] == sig:
            return e[2]
        return None

    def put(self, item, sig, faces):
        self.data[item["key"]] = (item["stamp"], sig, faces)
        self.dirty += 1

    def save(self):
        if not self.path or not self.dirty:
            return
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        tmp = self.path + ".tmp"
        # cache chứa "vân mặt" (dữ liệu sinh trắc học) nên chỉ chủ máy được đọc/ghi
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            pickle.dump({"version": CACHE_VERSION, "entries": self.data}, f, protocol=pickle.HIGHEST_PROTOCOL)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)
        self.dirty = 0


class Progress:
    def __init__(self, total, label):
        self.total, self.label, self.n, self.t0, self.last = total, label, 0, time.time(), 0

    def update(self, n=1):
        self.n += n
        now = time.time()
        if now - self.last < 0.5 and self.n < self.total:
            return
        self.last = now
        el = now - self.t0
        eta = el / self.n * (self.total - self.n) if self.n else 0
        sys.stderr.write(f"\r  {self.label}: {self.n}/{self.total} ({self.n * 100 // max(1, self.total)}%)"
                         f"  còn ~{int(eta // 60)}m{int(eta % 60):02d}s   ")
        sys.stderr.flush()

    def done(self):
        if self.total:
            sys.stderr.write("\n")


def analyze_items(items, pool, cache, sig, label):
    faces, errors, todo = {}, {}, []
    for it in items:
        hit = cache.get(it, sig) if cache else None
        if hit is None:
            todo.append(it)
        else:
            faces[it["key"]] = hit
    if len(items) - len(todo):
        log(f"  {label}: {len(items) - len(todo)} ảnh lấy từ cache")
    by_key = {it["key"]: it for it in todo}
    prog = Progress(len(todo), label)
    for key, fs, err in (pool().map(_work, todo, chunksize=2) if todo else []):
        faces[key] = fs
        if err:
            errors[key] = err
        elif cache:
            cache.put(by_key[key], sig, fs)
            if cache.dirty >= 300:
                cache.save()
        prog.update()
    prog.done()
    return faces, errors


# ---------------------------------------------------------------- so khớp

MIN_REF_SIM = 0.35  # mặt trong ảnh mẫu phải giống "người cần tìm" ít nhất mức này
PROMINENCE = 0.3    # ưu tiên người có mặt to (nổi bật) trong ảnh mẫu


def _refine(imgs, target, iters=3):
    """Lặp: chọn mặt giống nhất trong mỗi ảnh mẫu, lấy tâm các mặt đó làm chuẩn mới."""
    for _ in range(iters):
        good = []
        for _, _, F, _ in imgs:
            sims = F @ target
            if sims.max() >= MIN_REF_SIM:
                good.append(F[int(np.argmax(sims))])
        if not good:
            break
        c = np.mean(good, axis=0)
        target = c / np.linalg.norm(c)
    members = []
    for it, boxes, F, _ in imgs:
        sims = F @ target
        j = int(np.argmax(sims))
        members.append({"item": it, "box": boxes[j], "feat": F[j], "sim": float(sims[j]), "j": j})
    return members


def find_identities(ref_items, ref_faces, anchor=None, max_ids=None):
    """Tìm những người có thể là "người cần tìm" trong các ảnh mẫu, xếp theo độ tin cậy.

    Điểm của một ứng viên = mức độ xuất hiện nhất quán qua các ảnh mẫu + độ nổi bật (mặt to).
    Trả về (danh sách người, ảnh mẫu không có mặt nào, ảnh mẫu dùng được).
    """
    imgs, noface = [], []
    for it in ref_items:
        fs = ref_faces.get(it["key"]) or []
        if not fs:
            noface.append(it)
            continue
        area = np.array([b[2] * b[3] for b, _ in fs], np.float32)
        imgs.append((it, [b for b, _ in fs], np.stack([f.astype(np.float32) for _, f in fs]), area / area.max()))
    if not imgs:
        return [], noface, imgs
    n = len(imgs)
    max_ids = max_ids or (12 if n == 1 else 8)

    if anchor:
        idx = [i for i, (it, _, _, _) in enumerate(imgs) if anchor in (it["name"], it["key"])]
        if not idx:
            die(f"--anchor '{anchor}' không phải ảnh mẫu nào có khuôn mặt")
        i = idx[0]
        cands = [(1.0, i, int(np.argmax(imgs[i][3])))]
    else:
        cands = []
        for i, (_, _, F, prom) in enumerate(imgs):
            for j in range(len(F)):
                if n == 1:
                    score = float(prom[j])
                else:
                    cons, pr = 0.0, float(prom[j])
                    for k, (_, _, G, gprom) in enumerate(imgs):
                        if k == i:
                            continue
                        sims = G @ F[j]
                        m = int(np.argmax(sims))
                        cons += float(sims[m])
                        if sims[m] >= MIN_REF_SIM:
                            pr += float(gprom[m])
                    score = cons / (n - 1) + PROMINENCE * pr / n
                cands.append((score, i, j))
        cands.sort(reverse=True)

    ids = []
    for score, i, j in cands:
        if n == 1 and ids and imgs[i][3][j] < 0.4:
            break  # 1 ảnh mẫu: chỉ xét thêm những mặt to gần bằng mặt lớn nhất
        members = _refine(imgs, imgs[i][2][j])
        cover = {(m["item"]["key"], m["j"]) for m in members if m["sim"] >= MIN_REF_SIM}
        if any(len(cover & ex["cover"]) * 2 >= max(len(cover), 1) for ex in ids):
            continue  # trùng với một người đã có
        ids.append({"members": members, "cover": cover, "score": score})
        if len(ids) >= max_ids or anchor:
            break
    return ids, noface, imgs


def is_ambiguous(ids, nimgs, margin=0.15):
    """Mơ hồ khi người thứ hai gần như ngang người thứ nhất: cùng xuất hiện trong phần lớn ảnh mẫu
    và điểm chỉ kém một chút (vd. ảnh nhóm chụp liên tiếp), hoặc 1 ảnh mẫu có 2 mặt to gần bằng nhau."""
    if len(ids) < 2:
        return False
    a, b = ids[0], ids[1]
    if nimgs == 1:
        return b["score"] >= 0.5  # mặt thứ hai có diện tích ≥ 50% mặt lớn nhất
    need = max(2, int(np.ceil(0.6 * nimgs)))
    return len(b["cover"]) >= need and b["score"] >= a["score"] - margin


def centroid(feats):
    c = np.mean(feats, axis=0)
    return c / np.linalg.norm(c)


def score_items(items, faces_by_key, target, all_scores=None):
    """Điểm khuôn mặt = độ giống (cosine) với "tâm" các khuôn mặt mẫu; điểm ảnh = khuôn mặt cao nhất."""
    res = []
    for it in items:
        fs = faces_by_key.get(it["key"]) or []
        if not fs:
            res.append({"item": it, "score": -1.0, "box": None, "feat": None, "nfaces": 0})
            continue
        F = np.stack([f for _, f in fs]).astype(np.float32)
        s = F @ target
        if all_scores is not None:
            all_scores.append(s)
        j = int(np.argmax(s))
        res.append({"item": it, "score": float(s[j]), "box": fs[j][0], "feat": F[j], "nfaces": len(fs)})
    return res


def auto_review_threshold(face_scores, threshold):
    """Cận dưới vùng "Cần kiểm tra", tự điều chỉnh theo mức giống của *người khác* trong chính bộ ảnh này.

    Gần như mọi khuôn mặt trong bộ ảnh là người khác, nên trung bình + 3 độ lệch chuẩn ước lượng
    mức điểm cao nhất mà người lạ thường đạt. Trẻ em cùng lớp trông giống nhau → cận dưới cao (ít ảnh rác);
    người lớn → cận dưới thấp (giữ lại ảnh khó). Đo trên 8 người: giảm ảnh rác ~5 lần, không mất ảnh đúng.
    """
    if len(face_scores) < 300:
        return min(0.40, threshold)
    return float(min(threshold, max(0.40, face_scores.mean() + 3.0 * face_scores.std())))


# ---------------------------------------------------------------- kết quả

def place(item, dest_dir, mode):
    os.makedirs(dest_dir, exist_ok=True)
    base, ext = os.path.splitext(item["name"])
    dest, n = os.path.join(dest_dir, item["name"]), 1
    while os.path.lexists(dest):
        if os.path.getsize(dest) == item["size"]:
            return False  # đã có sẵn
        dest, n = os.path.join(dest_dir, f"{base}_{n}{ext}"), n + 1
    if item["zip"]:
        with open(dest, "wb") as f:
            f.write(read_bytes(item))
        os.utime(dest, (item["mtime"], item["mtime"]))
    elif mode == "move":
        shutil.move(item["key"], dest)
    elif mode == "link":
        os.symlink(item["key"], dest)
    else:
        shutil.copy2(item["key"], dest)
    return True


def _tile(args):
    item, box, label, max_side, size = args
    t = np.zeros((size, size, 3), np.uint8)
    if item is None:
        cv2.putText(t, label, (4, size - 7), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1, cv2.LINE_AA)
        return t
    try:
        img, scale = load_image(read_bytes(item), max_side)
        x, y, w, h = [float(v) * scale for v in box]
        m = 0.6 * max(w, h)
        x0, y0 = int(max(0, x - m)), int(max(0, y - m))
        x1, y1 = int(min(img.shape[1], x + w + m)), int(min(img.shape[0], y + h + m))
        crop = img[y0:y1, x0:x1]
        r = size / max(crop.shape[:2])
        crop = cv2.resize(crop, (max(1, int(crop.shape[1] * r)), max(1, int(crop.shape[0] * r))))
        oy, ox = (size - crop.shape[0]) // 2, (size - crop.shape[1]) // 2
        t[oy:oy + crop.shape[0], ox:ox + crop.shape[1]] = crop
    except Exception:
        pass
    cv2.rectangle(t, (0, size - 22), (size, size), (0, 0, 0), -1)
    cv2.putText(t, label.encode("ascii", "replace").decode(), (4, size - 7),
                cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1, cv2.LINE_AA)
    return t


def contact_sheet(entries, path, pool, max_side, cols=8, size=180, limit=480):
    """Ghép mặt các ảnh thành 1 ảnh tổng hợp để rà soát nhanh. entries: [(item, box, nhãn)]."""
    entries = entries[:limit]
    if not entries:
        return
    tiles = list(pool().map(_tile, [(it, b, lb, max_side, size) for it, b, lb in entries], chunksize=2))
    while len(tiles) % cols:
        tiles.append(np.zeros((size, size, 3), np.uint8))
    sheet = np.vstack([np.hstack(tiles[i:i + cols]) for i in range(0, len(tiles), cols)])
    cv2.imwrite(path, sheet, [cv2.IMWRITE_JPEG_QUALITY, 85])


def parse_since(s):
    if not s:
        return None
    s = s.strip().lower()
    now = datetime.now()
    if s in ("today", "homnay", "hôm nay"):
        d = now.replace(hour=0, minute=0, second=0, microsecond=0)
    elif s[:-1].isdigit() and s[-1] in "dh":
        d = now - (timedelta(days=int(s[:-1])) if s[-1] == "d" else timedelta(hours=int(s[:-1])))
    else:
        try:
            d = datetime.strptime(s, "%Y-%m-%d")
        except ValueError:
            die(f"--since không hợp lệ: {s} (dùng today, 3d, 12h hoặc YYYY-MM-DD)")
    return d.timestamp()


def stem(item):
    return os.path.splitext(item["name"])[0]


def main():
    ap = argparse.ArgumentParser(
        prog="findface",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Lọc ra những ảnh có mặt người cần tìm, dựa trên một hoặc nhiều ảnh mẫu.",
        epilog="""Ví dụ:
  # Dùng cả thư mục ảnh mẫu, quét các file zip tải hôm nay trong Downloads
  findface -r ~/Desktop/AnhMau -i ~/Downloads --since today -o ~/Desktop/"Kết quả"

  # Vài ảnh mẫu cụ thể, quét một thư mục ảnh
  findface -r a.jpg b.jpg c.jpg -i ~/Pictures/SuKien -o ~/Desktop/KetQua

  # Giải nén zip ra thư mục rồi lọc
  findface -r mau/ -i ~/Downloads/*.zip --extract-to ~/Downloads/AnhGoc -o KetQua
""")
    ap.add_argument("-r", "--ref", nargs="+", required=True, metavar="ẢNH_MẪU",
                    help="ảnh mẫu của người cần tìm (file, thư mục hoặc zip). Càng nhiều ảnh, càng nhiều góc mặt thì càng chính xác")
    ap.add_argument("-i", "--input", nargs="+", required=True, metavar="NGUỒN",
                    help="thư mục / file ảnh / file zip cần quét (thư mục được quét đệ quy, kể cả zip bên trong)")
    ap.add_argument("-o", "--output", required=True, metavar="THƯ_MỤC", help="thư mục chứa kết quả")
    ap.add_argument("-t", "--threshold", type=float, default=0.475,
                    help="điểm tối thiểu để coi là khớp (mặc định 0.475). Tăng để chặt hơn, giảm để tìm được nhiều hơn")
    ap.add_argument("--review", type=float,
                    help=f"ảnh có điểm từ mức này tới --threshold được đưa vào '{REVIEW_DIR}' "
                         "(mặc định: tự điều chỉnh trong khoảng 0.40–threshold theo bộ ảnh; đặt = threshold để tắt)")
    ap.add_argument("--since", metavar="THỜI_GIAN",
                    help="chỉ quét file sửa/tải từ thời điểm này: today, 3d, 12h hoặc YYYY-MM-DD")
    ap.add_argument("--no-expand", action="store_true",
                    help="tắt bước tự mở rộng (mặc định: dùng thêm ảnh khớp chắc chắn làm ảnh mẫu rồi chấm lại)")
    ap.add_argument("--expand-threshold", type=float, default=0.60, help="điểm tối thiểu để thành ảnh mẫu bổ sung (mặc định 0.60)")
    ap.add_argument("--pick", type=int, metavar="N",
                    help=f"khi ảnh mẫu có nhiều người: chọn người số N trong {REPORT_DIR}/chon_nguoi.jpg (không hỏi)")
    ap.add_argument("--anchor", metavar="TÊN_FILE",
                    help="ảnh mẫu dùng làm chuẩn (lấy khuôn mặt lớn nhất trong ảnh đó)")
    ap.add_argument("-y", "--yes", action="store_true", help="không hỏi lại; khi ảnh mẫu mơ hồ thì chọn người số 1")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--move", action="store_true", help="di chuyển ảnh thay vì sao chép")
    g.add_argument("--link", action="store_true", help="tạo symlink thay vì sao chép")
    ap.add_argument("--extract-to", metavar="THƯ_MỤC", help="giải nén toàn bộ ảnh trong các file zip ra thư mục này trước khi lọc")
    ap.add_argument("--dry-run", action="store_true", help="chỉ chấm điểm và tạo báo cáo, không chép ảnh")
    ap.add_argument("--workers", type=int, help="số tiến trình chạy song song (mặc định: số nhân CPU, hoặc một nửa + 1 khi dùng GPU)")
    ap.add_argument("--device", choices=["auto", "cpu", "gpu"], default="auto",
                    help="chạy nhận diện trên CPU hay GPU (Apple, qua CoreML). auto = GPU nếu có")
    ap.add_argument("--max-size", type=int, default=2400, help="thu nhỏ ảnh về cạnh dài này trước khi nhận diện (mặc định 2400)")
    ap.add_argument("--min-face", type=int, default=20, help="bỏ khuôn mặt nhỏ hơn số pixel này sau khi thu nhỏ (mặc định 20)")
    ap.add_argument("--det-threshold", type=float, default=0.7, help="độ tin cậy phát hiện khuôn mặt (mặc định 0.7)")
    ap.add_argument("--cache", default=DEFAULT_CACHE, help=f"file cache embedding (mặc định {DEFAULT_CACHE})")
    ap.add_argument("--no-cache", action="store_true", help="không dùng cache")
    args = ap.parse_args()

    for m in (DET_MODEL, REC_MODEL):
        if not os.path.exists(m):
            die(f"thiếu model {m}. Chạy {os.path.join(HERE, 'setup.sh')} trước.")
    if args.review is not None and args.review > args.threshold:
        args.review = args.threshold

    out = os.path.abspath(os.path.expanduser(args.output))
    since = parse_since(args.since)
    sig = (CACHE_VERSION, args.max_size, args.min_face, args.det_threshold)
    cache = None if args.no_cache else FaceCache(args.cache)

    log("Đang liệt kê ảnh...")
    ref_items = dedupe(collect(args.ref))
    if not ref_items:
        die("không tìm thấy ảnh mẫu nào")
    input_items = dedupe(collect(args.input, since, exclude_dirs=[out]))
    if not input_items:
        die("không tìm thấy ảnh nào để quét" + (" (kiểm tra lại --since)" if since else ""))
    nzip = len({it["zip"] for it in input_items if it["zip"]})
    log(f"  {len(ref_items)} ảnh mẫu, {len(input_items)} ảnh cần quét" + (f" (trong đó {nzip} file zip)" if nzip else ""))
    if args.extract_to:
        input_items = extract_zip_items(input_items, os.path.abspath(os.path.expanduser(args.extract_to)))

    device = args.device
    if device == "auto":
        import onnxruntime as ort
        ort.disable_telemetry_events()
        device = "gpu" if "CoreMLExecutionProvider" in ort.get_available_providers() else "cpu"
    if not args.workers:
        ncpu = os.cpu_count() or 4
        args.workers = min(6, ncpu // 2 + 1) if device == "gpu" else ncpu

    executor = None

    def pool():
        nonlocal executor
        if executor is None:
            executor = ProcessPoolExecutor(args.workers, initializer=init_models,
                                           initargs=(args.max_size, args.min_face, args.det_threshold, device))
        return executor

    t0 = time.time()
    try:
        # 1. Ảnh mẫu: xác định người cần tìm
        rep = os.path.join(out, REPORT_DIR)
        os.makedirs(rep, exist_ok=True)
        ref_faces, _ = analyze_items(ref_items, pool, cache, sig, "Ảnh mẫu")
        ids, noface, ref_imgs = find_identities(ref_items, ref_faces, args.anchor)
        for it in noface:
            log(f"  ! Bỏ ảnh mẫu {it['name']}: không thấy khuôn mặt")
        if not ids:
            die("không lấy được khuôn mặt nào từ ảnh mẫu")
        choice = 0
        if args.pick:
            if not 1 <= args.pick <= len(ids):
                die(f"--pick phải từ 1 đến {len(ids)}")
            choice = args.pick - 1
        elif is_ambiguous(ids, len(ref_imgs)):
            sheet = os.path.join(rep, "chon_nguoi.jpg")
            cols = min(len(ref_imgs), 7)
            entries = []
            for k, p in enumerate(ids):
                row = [(m["item"], m["box"], f"#{k + 1} {stem(m['item'])}") if m["sim"] >= MIN_REF_SIM else (None, None, f"#{k + 1}")
                       for m in p["members"][:cols]]
                entries += row
            contact_sheet(entries, sheet, pool, args.max_size, cols=cols)
            log(f"  ! Ảnh mẫu có {len(ids)} người cùng xuất hiện — không chắc ai là người cần tìm.")
            log(f"    Mỗi hàng trong {sheet} là một người (#1 = khả năng cao nhất).")
            if args.yes:
                log("    Đã chọn người #1 (do dùng -y). Nếu sai, chạy lại với --pick N.")
            elif sys.stdin.isatty():
                if sys.platform == "darwin":
                    os.system(f'open "{sheet}"')
                ans = input(f"    Nhập số người cần tìm [1-{len(ids)}, mặc định 1]: ").strip()
                if ans:
                    if not ans.isdigit() or not 1 <= int(ans) <= len(ids):
                        die("lựa chọn không hợp lệ")
                    choice = int(ans) - 1
            else:
                die(f"xem {sheet} rồi chạy lại với --pick N (N = số thứ tự người cần tìm), hoặc -y để chọn người #1")
        members = ids[choice]["members"]
        refs = [m for m in members if m["sim"] >= MIN_REF_SIM]
        for m in members:
            if m["sim"] < MIN_REF_SIM:
                log(f"  ! Bỏ ảnh mẫu {m['item']['name']}: không thấy người cần tìm (giống nhất {m['sim']:.2f})")
        log(f"  Dùng {len(refs)} khuôn mặt mẫu" + ("  (nên dùng ≥ 3 ảnh mẫu, nhiều góc mặt để chính xác hơn)" if len(refs) < 3 else ""))
        R = np.stack([p["feat"] for p in refs])
        if len(refs) >= 2 and (R @ R.T)[~np.eye(len(refs), dtype=bool)].mean() >= 0.85:
            log("  ! Các ảnh mẫu gần như giống hệt nhau (cùng một loạt chụp?). Thêm ảnh ở cảnh/góc/ánh sáng khác"
                " để tìm được nhiều ảnh hơn.")

        # 2. Quét
        faces, errors = analyze_items(input_items, pool, cache, sig, "Quét ảnh")
        if cache:
            cache.save()
        face_scores = []
        results = score_items(input_items, faces, centroid(R), face_scores)

        if not args.no_expand:
            conf = sorted((r for r in results if r["score"] >= args.expand_threshold), key=lambda r: -r["score"])[:200]
            if conf:
                face_scores = []
                results = score_items(input_items, faces, centroid(np.vstack([R] + [r["feat"][None] for r in conf])), face_scores)
                log(f"  Mở rộng: thêm {len(conf)} khuôn mặt mẫu từ những ảnh khớp chắc chắn")
        if args.review is None:
            args.review = auto_review_threshold(np.concatenate(face_scores) if face_scores else np.zeros(0), args.threshold)

        results.sort(key=lambda r: -r["score"])
        matched = [r for r in results if r["score"] >= args.threshold]
        review = [r for r in results if args.review <= r["score"] < args.threshold]

        # 3. Xuất kết quả
        mode = "move" if args.move else "link" if args.link else "copy"
        if not args.dry_run:
            todo = [(r, out) for r in matched] + [(r, os.path.join(out, REVIEW_DIR)) for r in review]
            prog = Progress(len(todo), "Chép ảnh")
            for r, d in todo:
                place(r["item"], d, mode)
                prog.update()
            prog.done()

        with open(os.path.join(rep, "ket_qua.csv"), "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(["tên file", "điểm", "kết quả", "số khuôn mặt", "nguồn", "lỗi"])
            for r in results:
                key = r["item"]["key"]
                status = ("Lỗi đọc ảnh" if key in errors else "Khớp" if r["score"] >= args.threshold
                          else "Cần kiểm tra" if r["score"] >= args.review else "Không")
                w.writerow([r["item"]["name"], f"{r['score']:.3f}", status, r["nfaces"], key, errors.get(key, "")])
        log("Đang tạo ảnh tổng hợp để rà soát...")
        contact_sheet([(p["item"], p["box"], f"{stem(p['item'])} {p['sim']:.2f}") for p in refs],
                      os.path.join(rep, "anh_mau.jpg"), pool, args.max_size)
        contact_sheet([(r["item"], r["box"], f"{stem(r['item'])} {r['score']:.2f}") for r in matched],
                      os.path.join(rep, "khop.jpg"), pool, args.max_size)
        contact_sheet([(r["item"], r["box"], f"{stem(r['item'])} {r['score']:.2f}") for r in review],
                      os.path.join(rep, "can_kiem_tra.jpg"), pool, args.max_size)
    finally:
        if cache:
            cache.save()
        if executor:
            executor.shutdown()

    el = time.time() - t0
    log("")
    log(f"Xong sau {int(el // 60)}m{int(el % 60):02d}s. Đã quét {len(input_items)} ảnh.")
    log(f"  Khớp:          {len(matched)} ảnh  (điểm ≥ {args.threshold})")
    if args.review < args.threshold:
        log(f"  Cần kiểm tra:  {len(review)} ảnh  (điểm {args.review:.3f}–{args.threshold})")
    if errors:
        log(f"  Lỗi đọc:       {len(errors)} ảnh (xem ket_qua.csv)")
    log(f"  Kết quả:  {out}" + ("  [dry-run: chưa chép ảnh]" if args.dry_run else ""))
    log(f"  Báo cáo:  {rep}  (anh_mau.jpg: kiểm tra đã chọn đúng người trong ảnh mẫu)")


if __name__ == "__main__":
    main()
