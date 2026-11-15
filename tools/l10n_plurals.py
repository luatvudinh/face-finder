#!/usr/bin/env python3
"""
Hoàn thiện String Catalog sau khi nhập bản dịch (xcodebuild -importLocalizations):
  - thêm dạng số ít/số nhiều tiếng Anh (xliff không mang được biến thể số nhiều);
  - ghi rõ bản tiếng Việt (= câu gốc) cho mọi chuỗi. Không có thì bundle chỉ có en.lproj, macOS coi app chỉ có
    tiếng Anh và hiện tiếng Anh cả cho người dùng tiếng Việt.
Chạy lại sau mỗi lần nhập bản dịch: python3 tools/l10n_plurals.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
APP = os.path.join(ROOT, "FaceFinder/App/Localizable.xcstrings")
KIT = os.path.join(ROOT, "FaceFinderKit/Sources/FaceFinderKit/Localizable.xcstrings")


def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}


def plural(one, other):
    return {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}


def sub(arg, spec, one, other):
    """Một biến thay thế: `%arg` là chỗ số đếm."""
    return {"argNum": arg, "formatSpecifier": spec, "variations": {"plural": {"one": unit(one), "other": unit(other)}}}


# chuỗi chỉ có một số đếm: biến thể số nhiều ở cấp trên cùng
SIMPLE = {
    "%lld ảnh không đọc được…": ("%lld unreadable photo…", "%lld unreadable photos…"),
    "%lld ảnh mẫu. App đề xuất người #1; bấm vào hàng khác nếu chọn sai.": (
        "%lld reference photo. The app suggests person #1; click another row if that’s the wrong person.",
        "%lld reference photos. The app suggests person #1; click another row if that’s the wrong person."),
    "%lld ảnh mẫu. Đã chọn sẵn người #1. Nên thêm ảnh (ít nhất 3) để tìm chính xác hơn.": (
        "%lld reference photo. Person #1 is already selected. Add more photos (at least 3) for more accurate results.",
        "%lld reference photos. Person #1 is already selected. Add more photos (at least 3) for more accurate results."),
    "%lld giây": ("%lld second", "%lld seconds"),
    "%lld khuôn mặt mẫu": ("%lld reference face", "%lld reference faces"),
    "Đã chọn %lld ảnh": ("%lld photo selected", "%lld photos selected"),
    "Bỏ đánh dấu %lld ảnh": ("Clear mark on %lld photo", "Clear marks on %lld photos"),
    "Đánh dấu %lld ảnh là đúng (D)": ("Mark %lld photo as them (Y)", "Mark %lld photos as them (Y)"),
    "Đánh dấu %lld ảnh là không phải (S)": ("Mark %lld photo as not them (N)", "Mark %lld photos as not them (N)"),
    "thêm %lld ảnh": ("added %lld photo", "added %lld photos"),
    "chuyển nhóm %lld ảnh": ("moved %lld photo between groups", "moved %lld photos between groups"),
    "bỏ %lld ảnh (vào Thùng rác)": ("moved %lld photo to the Trash", "moved %lld photos to the Trash"),
    "Đã tự dùng thêm %lld ảnh khớp chắc chắn làm mẫu để tìm được nhiều hơn.": (
        "Automatically added %lld confident match as a reference photo to find more.",
        "Automatically added %lld confident matches as reference photos to find more."),
}

# chuỗi nhiều tham số: chỉ phần có số đếm đổi theo số ít/nhiều (substitutions)
SUBS = {
    "%.3f · %d mặt": ("%1$.3f · %#@faces@", {"faces": sub(2, "d", "%arg face", "%arg faces")}),
    "%lld khớp · %lld cần kiểm tra (từ %@)": ("%#@matches@ · %2$lld to review (from %3$@)",
                                             {"matches": sub(1, "lld", "%arg match", "%arg matches")}),
    "%lld nguồn · %@ ảnh · %@ khuôn mặt": ("%#@sources@ · %2$@ photos · %3$@ faces",
                                          {"sources": sub(1, "lld", "%arg source", "%arg sources")}),
    "%lld phút %lld giây": ("%#@minutes@ %#@seconds@", {"minutes": sub(1, "lld", "%arg minute", "%arg minutes"),
                                                      "seconds": sub(2, "lld", "%arg second", "%arg seconds")}),
    "Đã lập chỉ mục %lld ảnh trong %@.": ("Indexed %#@photos@ in %2$@.", {"photos": sub(1, "lld", "%arg photo", "%arg photos")}),
    "Đã lập chỉ mục %lld ảnh trong %@. %lld ảnh không đọc được.": (
        "Indexed %#@photos@ in %2$@. %3$lld couldn’t be read.", {"photos": sub(1, "lld", "%arg photo", "%arg photos")}),
}

# viết lại cho không phụ thuộc số ít/nhiều
NEUTRAL = {
    "%lld ảnh trong %@ được bảo vệ bằng mật khẩu, app chưa đọc được. Giải nén bằng Finder rồi thêm thư mục đã giải nén.":
        "Password-protected photos in %2$@: %1$lld. The app can’t read them yet. Unzip it in Finder, then add the unzipped folder.",
}


def apply(path):
    d = json.load(open(path))
    # chuỗi không còn trong code (Xcode đánh dấu "stale" khi nhập bản dịch): bỏ đi cho catalog gọn
    stale = [k for k, v in d["strings"].items() if v.get("extractionState") == "stale"]
    for k in stale:
        del d["strings"][k]
    done = 0
    for key, entry in d["strings"].items():
        loc = entry.setdefault("localizations", {})
        if entry.get("shouldTranslate") is not False:
            loc["vi"] = unit(loc.get("vi", {}).get("stringUnit", {}).get("value") or key)
        if key in SIMPLE:
            loc["en"] = plural(*SIMPLE[key])
        elif key in SUBS:
            value, subs = SUBS[key]
            loc["en"] = {"stringUnit": {"state": "translated", "value": value}, "substitutions": subs}
        elif key in NEUTRAL:
            loc["en"] = unit(NEUTRAL[key])
        else:
            continue
        done += 1
    with open(path, "w") as f:
        json.dump(d, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    return done


if __name__ == "__main__":
    n = apply(APP) + apply(KIT)
    expected = len(SIMPLE) + len(SUBS) + len(NEUTRAL)
    print(f"Đã cập nhật {n}/{expected} chuỗi")
