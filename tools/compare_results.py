#!/usr/bin/env python3
"""
So hai file ket_qua.csv (CLI Python là chuẩn, bản Swift là bản cần kiểm) theo tiêu chí Giai đoạn 1 của PLAN.md:
tập ảnh "Khớp" trùng >= 99%, chênh lệch điểm từng ảnh < 0.01.

    python3 tools/compare_results.py <chuẩn>/_báo\\ cáo/ket_qua.csv <swift>/_báo\\ cáo/ket_qua.csv
"""
import csv
import sys


def load(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return {r["nguồn"]: r for r in csv.DictReader(f)}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    common = sorted(set(a) & set(b))
    print(f"Chuẩn: {len(a)} ảnh, bản so: {len(b)} ảnh, chung: {len(common)}")
    if len(common) != len(a) or len(common) != len(b):
        print(f"  ! chỉ có ở chuẩn: {len(set(a) - set(b))}, chỉ có ở bản so: {len(set(b) - set(a))}")

    if not common:
        sys.exit("Không có ảnh nào chung: hai lần chạy phải quét cùng nguồn (cột 'nguồn' phải trùng nhau).")

    diffs = sorted(((abs(float(a[k]["điểm"]) - float(b[k]["điểm"])), k) for k in common), reverse=True)
    d = [x for x, _ in diffs]
    n = len(d)
    print(f"Chênh lệch điểm: lớn nhất {d[0]:.3f}, p99 {d[n // 100]:.3f}, trung bình {sum(d) / n:.4f}; "
          f">= 0.01: {sum(x >= 0.01 for x in d)} ảnh ({100 * sum(x >= 0.01 for x in d) / n:.2f}%)")
    faces = sum(a[k]["số khuôn mặt"] != b[k]["số khuôn mặt"] for k in common)
    print(f"Khác số khuôn mặt: {faces} ảnh")

    for status in ("Khớp", "Cần kiểm tra"):
        sa = {k for k in common if a[k]["kết quả"] == status}
        sb = {k for k in common if b[k]["kết quả"] == status}
        union = sa | sb
        same = 100 * len(sa & sb) / len(union) if union else 100.0
        print(f"{status}: chuẩn {len(sa)}, bản so {len(sb)}, chung {len(sa & sb)}  (trùng {same:.1f}%)")
        for k in sorted(sa ^ sb):
            side = "chỉ chuẩn" if k in sa else "chỉ bản so"
            print(f"    {side}: {a[k]['tên file']}  chuẩn {a[k]['điểm']} ({a[k]['kết quả']})  bản so {b[k]['điểm']} ({b[k]['kết quả']})")

    print("Ảnh lệch điểm nhiều nhất:")
    for x, k in diffs[:8]:
        print(f"    {x:.3f}  {a[k]['tên file']}  chuẩn {a[k]['điểm']} / {a[k]['số khuôn mặt']} mặt   bản so {b[k]['điểm']} / {b[k]['số khuôn mặt']} mặt")


if __name__ == "__main__":
    main()
