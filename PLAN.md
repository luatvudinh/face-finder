# Kế hoạch: app macOS "Face Finder"

Mục tiêu: biến công cụ dòng lệnh `face-finder/` (findface) thành một app macOS có giao diện, giữ nguyên độ
chính xác đã kiểm chứng (~99% / ~97% với ≥3 ảnh mẫu), **chạy hoàn toàn trên máy** và nhanh bằng hoặc hơn CLI.

Trạng thái (15/11/2026): **Giai đoạn 0–2 xong** (mục 5.0–5.2; bản dùng thử 0.2 đã được thử bằng tay, ổn).
**Giai đoạn 3 xong** (mục 5.3). **Giai đoạn 4: phần trong repo xong** (mục 5.4): CI, quy trình phát hành, chuẩn bị
notarize, sửa lỗi bộ nhớ GPU; bản 0.4.1 `dist/FaceFinder-0.4.1.dmg`. Còn lại: tạo repo GitHub, đẩy code, chạy CI lần đầu,
đẩy tag phát hành; notarize khi có tài khoản Apple Developer.

**Đã chốt (14/11/2026):**
- Phát hành mã nguồn mở và bản build trên GitHub (miễn phí, phi thương mại).
- Chưa notarize; làm khi có tài khoản Apple Developer (xem Giai đoạn 4).
- macOS tối thiểu: 15.
- Kết quả mặc định ghi ngay trong thư mục chứa ảnh nguồn; đổi được thư mục trước hoặc sau khi chạy (mục 4.1).

---

## 1. Hiện trạng và điểm xuất phát

| Có sẵn | Ghi chú |
|---|---|
| `face-finder/findface.py` (753 dòng) | Toàn bộ thuật toán đã tinh chỉnh: YuNet → căn mặt 5 điểm → ArcFace `w600k_r50` → tâm ảnh mẫu, tự bổ sung ảnh mẫu (≥0.60), ngưỡng 0.475, "Cần kiểm tra" tự điều chỉnh, chọn người khi ảnh mẫu mơ hồ |
| `face-finder/models/` | `yunet.onnx` (OpenCV Zoo, MIT), `w600k_r50.onnx` (InsightFace, **chỉ dùng phi thương mại**) |
| Số đo tham chiếu (Apple M1) | 1416 ảnh 33MP: 5m08s (GPU), 17m56s (CPU); ArcFace 14 ms/mặt trên GPU qua CoreML; chạy lại có cache 9 giây |
| Máy phát triển | Apple M1, macOS 27.0.1, Xcode 27.0, Swift 6.4 |

CLI sẽ **được giữ lại** làm "chuẩn đối chiếu" (oracle): mọi thay đổi của app đều phải cho điểm giống CLI trên
cùng bộ ảnh.

---

## 2. Quyết định kiến trúc

### 2.1 Bộ máy nhận diện: viết lại bằng Swift + Core ML (khuyến nghị)

| Phương án | Ưu | Nhược |
|---|---|---|
| **A. Swift thuần + Core ML** (khuyến nghị) | App nhỏ (~180 MB, chủ yếu là model), khởi động nhanh, dùng được Neural Engine, không có ONNX Runtime nên **không có telemetry nào để tắt**, ký và notarize đơn giản | Phải chuyển model ONNX → Core ML và viết lại phần căn mặt/chấm điểm; cần kiểm chứng kết quả trùng CLI |
| B. Swift + ONNX Runtime (gói SPM `onnxruntime-objc`) | Dùng nguyên file `.onnx`, kết quả gần như chắc chắn trùng CLI | Thêm ~30 MB thư viện, vẫn phải tắt telemetry, không dùng được Neural Engine |
| C. Giao diện SwiftUI gọi Python đóng gói kèm | Nhanh có bản đầu tiên, dùng lại 100% code | App ~450 MB, phải ký từng file `.so` của Python, dễ vỡ khi nâng cấp macOS, khó bán/phân phối |

Chọn **A**, giữ **B** làm phương án dự phòng nếu bước chuyển model ở Giai đoạn 0 không đạt độ trùng khớp.

### 2.2 Ánh xạ từng bước từ Python sang Swift

| Bước | Python hiện tại | Swift trong app |
|---|---|---|
| Đọc ảnh + thu nhỏ 2400px | PIL `draft()` + `exif_transpose`, pillow-heif | JPEG: **libjpeg-turbo đóng gói kèm** (cùng bản và thiết lập với Pillow); định dạng khác: ImageIO. Xoay theo EXIF, rồi **thu nhỏ bằng bộ lọc của Pillow viết lại**. Trùng CLI từng pixel (mục 5.1) |
| Đọc thẳng file zip | `zipfile` | Thư viện [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT, Swift thuần) |
| Phát hiện mặt | YuNet qua `cv2.FaceDetectorYN` | YuNet chuyển sang Core ML + tự viết phần giải mã đầu ra và NMS. Dự phòng: Apple Vision `VNDetectFaceLandmarksRequest` (suy ra 5 điểm) — phải đo lại độ chính xác |
| Căn mặt 5 điểm → 112×112 | `estimateAffinePartial2D` (LMEDS) + `warpAffine` | Tự viết lại LMEDS (đúng dãy cặp điểm OpenCV thử) + nội suy song tuyến tính. **Không dùng Umeyama**: lệch ở 11% số mặt (mục 5.0) |
| Trích "vân mặt" 512 chiều | ArcFace qua ONNX Runtime + CoreML EP | ArcFace `.mlpackage` (Core ML, FP16, chạy batch, mặc định CPU+GPU; Neural Engine là tuỳ chọn) |
| Chấm điểm, mở rộng, ngưỡng tự điều chỉnh, chọn người | numpy | Swift + Accelerate (vDSP) — chép 1:1 logic từ `findface.py` |
| Cache | pickle `~/.cache/findface/faces.pkl` | SQLite trong container của app (xem 2.4) |

### 2.3 Cấu trúc dự án

```
face-finder-proj/
  PLAN.md                      ← file này
  face-finder/                 ← CLI Python hiện có (giữ nguyên, làm oracle)
  tools/
    convert_models.py          ← ONNX → Core ML (onnx2torch → coremltools), chạy một lần lúc phát triển
    export_golden.py           ← xuất "đáp án mẫu" từ CLI: vân mặt + điểm từng ảnh, để so với Swift
  FaceFinderKit/               ← Swift Package: toàn bộ bộ máy, không phụ thuộc giao diện
    Sources/FaceFinderKit/     ← ImageLoader, FaceDetector, Aligner, Embedder, Scorer, Index, Exporter
    Sources/ffcli/             ← CLI Swift nhỏ để đo tốc độ và so với Python (`swift run ffcli ...`)
    Tests/                     ← test đơn vị + test trùng khớp với golden data
  FaceFinder/                  ← Xcode project app SwiftUI
    FaceFinder.xcodeproj
    App/, Views/, Models/, Resources/ (2 file .mlpackage)
```

Tách `FaceFinderKit` ra thành package giúp test và đo tốc độ bằng dòng lệnh, không cần mở giao diện.

**Repo GitHub:** app là một repo public mới (đề xuất tên `face-finder-mac`) đặt ở gốc `face-finder-proj/`.
Thư mục `face-finder/` vẫn là repo CLI riêng như hiện nay, được bỏ qua trong `.gitignore` của repo app; các
script trong `tools/` gọi nó theo đường dẫn tương đối. Hai file model **không commit vào git**:
`tools/convert_models.py` tự tải và chuyển đổi, còn bản build phát hành trên GitHub Releases đóng gói sẵn model.
Giữ quy tắc của repo CLI: không commit ảnh, kết quả, chỉ mục, golden data hay thông tin máy cá nhân.

### 2.4 Dữ liệu: "lập chỉ mục một lần, tìm nhiều người"

Khác biệt lớn nhất so với CLI: app quản lý một **thư viện ảnh đã lập chỉ mục**. Quét nguồn (thư mục/zip) một
lần, sau đó tìm bất kỳ người nào trong thư viện chỉ mất vài giây, không quét lại.

- SQLite (qua [GRDB.swift](https://github.com/groue/GRDB.swift), MIT), đặt trong container sandbox của app.
- Bảng chính:
  - `sources`: thư mục/zip đã thêm, kèm *security-scoped bookmark* (để app sandbox được đọc lại sau khi khởi động lại).
  - `images`: đường dẫn hoặc `zip::member`, kích thước, mtime/CRC (cùng cách nhận biết thay đổi như CLI).
  - `faces`: khung mặt, 5 điểm, độ tin cậy, vân mặt 512 số (lưu dạng blob Float16, ~1 KB/mặt).
  - `people`: người đã lưu, kèm danh sách mặt mẫu và mặt bị loại.
  - `searches`: kết quả từng lần tìm (điểm từng ảnh), để mở lại không phải chấm lại.
- Ước lượng: 18.000 mặt ≈ 20–25 MB, tương đương cache hiện tại.
- Nút "Xoá toàn bộ dữ liệu khuôn mặt" trong Cài đặt; chỉ mục bị xoá khi gỡ app.

---

## 3. Riêng tư: chạy local được hệ điều hành bảo đảm

CLI hiện chỉ *tự cam kết* không dùng mạng. App làm chặt hơn:

1. **App Sandbox không có quyền mạng** (không khai báo `com.apple.security.network.client`). macOS sẽ chặn mọi
   kết nối ra ngoài ở cấp hệ điều hành, kể cả từ thư viện bên thứ ba. Ai cũng tự kiểm tra được bằng
   `codesign -d --entitlements - FaceFinder.app`.
2. **Model đóng gói sẵn trong app** → không cần tải gì khi chạy (xem mục 7 về bản quyền model).
3. Không dùng ONNX Runtime (phương án A) → không có telemetry Microsoft. Không gắn analytics hay crash reporter.
4. Quyền truy cập file tối thiểu: chỉ đọc/ghi các thư mục/zip người dùng tự chọn hoặc kéo thả vào
   (`com.apple.security.files.user-selected.read-write`), không xin quyền truy cập toàn bộ ổ đĩa. Quyền ghi
   cần cho việc lưu kết quả vào thư mục nguồn (mục 4.1).
5. Test tự động: một test trong app thử mở kết nối mạng và **phải thất bại**; chạy trong CI ở mỗi bản build.

---

## 4. Giao diện (SwiftUI)

Cửa sổ chính gồm thanh bên và vùng nội dung:

- **Thư viện**: các nguồn đã thêm (kéo thả thư mục/zip vào). Thanh tiến trình khi lập chỉ mục: số ảnh, ảnh/giây,
  thời gian còn lại; tạm dừng/tiếp tục/huỷ. Hỗ trợ "chỉ quét file mới từ hôm nay" (giống `--since`).
- **Người**: tạo người mới bằng cách kéo ảnh mẫu vào. App tách các khuôn mặt, gom theo người và **tự đề xuất**
  người xuất hiện nhất quán (cùng logic `find_identities` hiện tại). Người dùng bấm vào khuôn mặt để xác nhận hoặc
  chọn người khác. Thay thế hoàn toàn `chon_nguoi.jpg`, `--pick`, `--anchor`.
- **Kết quả** của một người:
  - Lưới ảnh thu nhỏ sắp theo điểm, khoanh khuôn mặt khớp; ba nhóm *Khớp* / *Cần kiểm tra* / *Dưới ngưỡng*.
  - **Thanh trượt ngưỡng** (mặc định 0.475): kéo là lọc lại ngay, vì điểm đã có sẵn.
  - Phím Space xem lớn (Quick Look); phím ✓/✗ đánh dấu đúng/sai. Ảnh ✓ được thêm vào ảnh mẫu, ảnh ✗ bị loại,
    rồi chấm lại tức thì ("học thêm" — làm bằng tay việc mà `--expand` đang làm tự động).
- **Xuất**: kết quả được ghi tự động theo mục 4.1; ngoài ra xuất thêm CSV. (Giai đoạn sau: thêm vào album Photos.)
- **Cài đặt**: thiết bị tính (Tự động / GPU / Neural Engine / CPU), số luồng song song, dung lượng chỉ mục,
  xoá dữ liệu khuôn mặt, cách ghi kết quả mặc định (chép / alias / di chuyển).

### 4.1 Thư mục kết quả

**Mặc định: ghi ngay trong thư mục chứa ảnh nguồn**, vào một thư mục con riêng cho từng người:

```
<thư mục nguồn>/
  ...ảnh gốc (không bị đổi)...
  Face Finder - <tên người>/
    *.JPG             ảnh khớp
    Cần kiểm tra/
    _báo cáo/         ket_qua.csv, ảnh ghép khuôn mặt (giống CLI)
    .facefinder       file đánh dấu: thư mục do app tạo
```

- **Nguồn là thư mục:** ghi vào chính thư mục đó.
- **Nguồn là file zip:** ghi vào thư mục chứa file zip. Sandbox chỉ cho app quyền với đúng file zip được chọn,
  nên lần đầu app mở hộp thoại chọn thư mục (đã trỏ sẵn tới thư mục chứa zip) để người dùng bấm "Cho phép";
  quyền này được nhớ lại (bookmark), lần sau không hỏi nữa.
- **Nhiều nguồn ở nhiều nơi:** dùng thư mục của nguồn đầu tiên, hiển thị rõ đường dẫn để người dùng đổi nếu muốn.
- **Đổi trước khi chạy:** màn hình bắt đầu tìm có ô "Lưu kết quả vào", điền sẵn đường dẫn mặc định, kèm nút
  "Chọn…" và "Mở trong Finder".
- **Đổi sau khi chạy:** nút "Chuyển kết quả sang…" di chuyển cả thư mục kết quả sang chỗ mới; nút "Sao chép
  sang…" để giữ thêm một bản. Đổi xong, các lần cập nhật sau ghi vào chỗ mới.
- **Cập nhật khi chỉnh kết quả:** sau khi kéo ngưỡng hoặc đánh dấu ✓/✗, app cập nhật thư mục kết quả (thêm ảnh
  mới khớp, bỏ ảnh không còn khớp).
- **An toàn:**
  - App chỉ thêm, sửa, xoá những file **do chính nó tạo** (ghi trong chỉ mục); file người dùng tự bỏ vào thư mục
    kết quả không bao giờ bị đụng tới. Xoá thì đưa vào Thùng rác, không xoá hẳn.
  - Tìm lại cùng người thì cập nhật đúng thư mục cũ, không tạo thêm bản trùng. Trùng tên với thư mục không phải
    của app thì tạo `Face Finder - <tên> (2)`.
  - Khi lập chỉ mục, app **bỏ qua các thư mục có file `.facefinder`**, để ảnh kết quả nằm trong thư mục nguồn
    không bị quét lại thành ảnh trùng.
  - Mặc định **sao chép**, ảnh gốc giữ nguyên. Ảnh nằm trong zip luôn được giải nén ra bản sao.

---

## 5. Lộ trình

Thời gian là ước lượng cho một người làm cùng Claude Code, tính theo ngày làm việc.

### Giai đoạn 0 — Thử nghiệm bộ máy (2–3 ngày) ⚠️ rủi ro lớn nhất, làm trước
1. `tools/convert_models.py`: chuyển `w600k_r50.onnx` và `yunet.onnx` sang `.mlpackage` (cài `onnx`,
   `onnx2torch`, `torch`, `coremltools` trong venv riêng của `tools/`).
2. `tools/export_golden.py`: từ CLI, xuất ~200 ảnh mẫu kèm khung mặt, 5 điểm, ảnh mặt đã căn 112×112 và vân mặt.
3. Swift: đọc golden data, chạy ArcFace Core ML trên **cùng** ảnh mặt đã căn → so cosine.
4. Swift: chạy YuNet Core ML → so khung mặt và 5 điểm.

**Tiêu chí qua:** cosine vân mặt ≥ 0.999 so với Python; YuNet tìm được ≥ 99% số mặt của CLI, sai lệch điểm
mốc < 1px. Không đạt → chuyển sang phương án B (ONNX Runtime) cho phần không đạt.

### 5.0 Kết quả Giai đoạn 0 (14/11/2026, Apple M1) — ĐẠT

Golden data: 200 ảnh rải đều trong bộ 1416 ảnh + ảnh mẫu, 2886 khuôn mặt, 2625 ảnh mặt đã căn.
Chạy lại: `tools/convert_models.py`, `tools/export_golden.py -i <nguồn>`, `swift run -c release ffcli phase0`.

| Phép đo | Kết quả | Tiêu chí |
|---|---|---|
| YuNet Core ML (FP32) trên cùng pixel | tìm lại 2886/2886 mặt, thừa 0; lệch điểm mốc và khung **0,000 px** | ≥ 99%, < 1 px ✅ |
| ArcFace FP16, GPU | cosine nhỏ nhất **0,99923**, trung bình 0,99999; 9,7 ms/mặt (8,6 ms nếu cố định batch 16) | ≥ 0,999 ✅ |
| ArcFace FP16, CPU | nhỏ nhất 0,9955; 60/2625 mặt dưới 0,999; 10,4 ms/mặt | ❌ |
| ArcFace FP16, Neural Engine (batch cố định 16) | nhỏ nhất 0,988; 24% số mặt dưới 0,999; **3,1 ms/mặt** | ❌ |
| ArcFace FP32, GPU / CPU | cosine 1,00000; 15,2 / 25,8 ms/mặt; file 175 MB thay vì 87 MB | ✅ |
| Căn mặt Swift (LMEDS tự viết) + ArcFace | FP32: nhỏ nhất 0,99999 (trùng CLI); FP16 GPU: như dòng ArcFace FP16 | — |
| Căn mặt bằng Umeyama (không loại điểm) | 284/2625 mặt dưới 0,999, nhỏ nhất 0,41 | ❌ bỏ |
| YuNet FP16 | lệch điểm mốc tới 10 px, chỉ nhanh hơn ~20% | ❌ bỏ |

Quyết định rút ra:
- **Phương án A** (Swift + Core ML) cho cả hai model. Không cần ONNX Runtime.
- Mặc định **ArcFace FP16 trên GPU**, YuNet FP32. Chế độ CPU (máy không có GPU phù hợp) nên dùng bản FP32.
- **Neural Engine** nhanh gấp 3 nhưng lệch nhiều hơn tiêu chí → không bật mặc định; để làm tuỳ chọn "nhanh hơn",
  và chỉ đưa vào sau khi đo ảnh hưởng tới điểm cuối cùng ở Giai đoạn 1.
- LMEDS của OpenCV luôn thử cùng một dãy 13 cặp điểm (bộ sinh số khởi tạo cố định) nên chép lại được chính xác.
- Tốc độ: YuNet trên GPU ~100 ms/ảnh 2400×1600, ArcFace ~125 ms/ảnh (13 mặt). Chạy nối tiếp trên một GPU thì
  1416 ảnh mất ~5m20s, **sát nút mục tiêu 5 phút** → Giai đoạn 1 phải cho phát hiện mặt chạy trên CPU song song
  với GPU, hoặc thử kích thước đầu vào cố định cho YuNet.

### Giai đoạn 1 — FaceFinderKit + CLI Swift (4–6 ngày)
- Viết đủ pipeline: ImageLoader (ImageIO, zip), Detector, Aligner, Embedder (batch), Scorer (tâm, mở rộng,
  ngưỡng tự điều chỉnh, chọn người), Index (SQLite).
- Song song hoá bằng Swift Concurrency: giải mã + phát hiện mặt chạy nhiều tác vụ; trích vân mặt gom batch vào
  một model Core ML dùng chung.
- `ffcli` cho ra `ket_qua.csv` cùng định dạng với CLI Python.

**Tiêu chí qua:**
- Trên bộ 1416 ảnh, với cùng ảnh mẫu: tập ảnh *Khớp* trùng CLI ≥ 99%, chênh lệch điểm từng ảnh < 0.01.
- Tốc độ lập chỉ mục 1416 ảnh ≤ 5 phút trên M1 khi máy rảnh (hiện tại 5m08s); chạy lại ≤ 3 giây.
- RAM ≤ 3 GB (CLI hiện ~5,5 GB vì 5 tiến trình Python).

### 5.1 Kết quả Giai đoạn 1 (14/11/2026, Apple M1) — ĐẠT

Đã có: `ImageSource` (thư mục + zip, bỏ thư mục có `.facefinder`), `ImageLoader` + `PILResample` + `CJPEGTurbo`,
`FaceDetector`, `Aligner`, `Embedder`, `Analyzer`, `Scorer` (chép 1:1 phần so khớp của `findface.py`), `FaceIndex`
(SQLite/GRDB), `Pipeline` (song song), `Report` (CSV), lệnh `ffcli find` / `pixels` / `phase0`, 21 test đơn vị.
So với CLI bằng `tools/compare_results.py` trên bộ 1416 ảnh, 8 ảnh mẫu:

| Tiêu chí | Kết quả | |
|---|---|---|
| Tập "Khớp" trùng CLI ≥ 99% | 58 / 58 ảnh (100%); "Cần kiểm tra" 5 / 5; số khuôn mặt trùng ở mọi ảnh | ✅ |
| Chênh lệch điểm từng ảnh < 0,01 | lớn nhất 0,003; trung bình 0,0002 | ✅ |
| Lập chỉ mục 1416 ảnh ≤ 5 phút | 4m38s (CLI 5m08s) | ✅ |
| Chạy lại ≤ 3 giây | 1,3 giây (CLI 9 giây); chỉ mục 26 MB | ✅ |
| RAM ≤ 3 GB | 1,9 GB (CLI ~5,5 GB) | ✅ |

Ba việc phải làm để ảnh đưa vào nhận diện **trùng CLI từng pixel** (đã kiểm trên 200 ảnh golden: lệch 0):
1. **Giải mã JPEG bằng libjpeg-turbo đóng gói kèm** (đã chốt 14/11/2026), đúng bản 3.1.4.1 mà Pillow 12.3 dùng, cùng
   thiết lập. ImageIO của Apple cho pixel khác ở ~47% số pixel (trung bình 0,45–0,6 mức xám) dù giải mã kiểu nào;
   với nó 9,3% số ảnh lệch điểm ≥ 0,01 và tập "Khớp" lệch 1 ảnh. Mã nguồn nằm trong
   `FaceFinderKit/Sources/CJPEGTurbo/upstream` (chép bằng `tools/vendor_libjpeg_turbo.sh`, không sửa); chỉ biên dịch
   phần giải mã; Apple Silicon dùng NEON, Intel dùng C thuần. Định dạng khác (HEIC, PNG...) và JPEG CMYK vẫn qua ImageIO.
2. **Thu nhỏ bằng bộ lọc của Pillow viết lại** (`PILResample`, trùng từng byte). `CreateThumbnailAtIndex` của ImageIO
   lệch nặng: 21,8% số ảnh lệch điểm ≥ 0,01, 10% số ảnh khác số khuôn mặt.
3. **Nhận biết file MPO như Pillow.** Ảnh từ máy Sony là JPEG có khối MPF (kèm ảnh xem trước); Pillow báo
   `format == "MPO"` nên `findface.load_image` **không** gọi `draft()` mà giải mã đủ 33 MP rồi mới thu nhỏ. App làm
   y như vậy để trùng điểm. (Với CLI đây là chỗ chậm không cố ý: giải mã ở 1/2 sẽ nhanh hơn ~2,5 lần phần đọc ảnh,
   nhưng đổi pixel nên đổi điểm; muốn tối ưu thì phải đo lại độ chính xác bằng bộ nhãn.)

Khi nâng Pillow của CLI hoặc libjpeg-turbo của app: chạy lại `tools/make_test_fixtures.py` + `swift test`, rồi
`ffcli pixels` trên golden data.

Ghi chú tốc độ: GPU trích vân mặt là nút cổ chai (đổi số luồng hay cho YuNet chạy CPU không nhanh hơn, RAM lại gấp
đôi). Còn dư địa: batch cố định 16 (~11%), hoặc Neural Engine (nhanh gấp 3 phần ArcFace, nhưng lệch nhiều hơn).

### Giai đoạn 2 — App tối thiểu dùng được (4–5 ngày)
- Thư viện + lập chỉ mục có tiến trình/huỷ; tạo người từ ảnh mẫu với bước chọn khuôn mặt; lưới kết quả + thanh
  trượt ngưỡng; ghi kết quả vào thư mục nguồn, đổi được trước/sau khi chạy (mục 4.1).
- App Sandbox không quyền mạng, security-scoped bookmark cho nguồn.

**Tiêu chí qua:** làm lại được đúng việc "tìm ảnh có bé trong 7 file zip" từ đầu đến cuối chỉ bằng chuột.

### 5.2 Kết quả Giai đoạn 2 (14/11/2026, Apple M1) — ĐẠT (người dùng đã thử bằng tay trong sandbox, ổn)

Đã có: app SwiftUI `FaceFinder/` (project sinh từ `project.yml` bằng XcodeGen) gồm Thư viện (kéo thả thư mục/zip,
lập chỉ mục có tiến độ, tạm dừng/tiếp tục/huỷ), Thêm người (kéo ảnh mẫu, app gom khuôn mặt theo người, đề xuất #1,
bấm chọn người khác), Kết quả (lưới ảnh khuôn mặt theo nhóm, thanh trượt ngưỡng), thư mục kết quả theo mục 4.1 (ghi
mặc định vào thư mục nguồn / thư mục chứa zip, xin quyền khi cần, tự cập nhật khi kéo ngưỡng, chuyển/sao chép sang
chỗ khác, chỉ đụng file do app tạo, bỏ thì vào Thùng rác), Cài đặt (xoá dữ liệu khuôn mặt). App Sandbox không quyền
mạng, security-scoped bookmark cho nguồn và thư mục được phép ghi. DMG: `tools/make_dmg.sh`.

Tự kiểm tra toàn luồng (`tools/app_selftest.sh`: gọi đúng các hàm mà nút bấm gọi, chụp cửa sổ app ở từng bước) trên
7 file zip, bản Release:

| Kiểm tra | Kết quả |
|---|---|
| Lập chỉ mục 1416 ảnh | 313 giây, gồm ~5 giây thử tạm dừng (CLI Python 5m08s, `ffcli` 4m38s) |
| Kết quả so với CLI | Khớp 58/58, Cần kiểm tra 5/5, lệch điểm lớn nhất 0,003 |
| Ảnh mẫu | đề xuất đúng bé ở #1 (có mặt trong 8/8 ảnh mẫu), không mơ hồ |
| Thư mục kết quả | 58 ảnh + `Cần kiểm tra/` 5 ảnh + `_báo cáo/ket_qua.csv` + `.facefinder` |
| Kéo ngưỡng 0,55 rồi trả lại | thư mục tự cập nhật (chuyển nhóm 1 ảnh mỗi lần) |
| Tạm dừng | không xử lý thêm ảnh nào trong lúc dừng |
| Bản phát hành | chỉ 3 quyền (sandbox, file người dùng chọn, bookmark); không mạng, không quyền gỡ lỗi, không có SelfTest |

Bài học:
- **App Nap** làm lập chỉ mục chậm gần gấp đôi (505 giây) khi cửa sổ app không ở phía trước. Sửa bằng
  `ProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` trong lúc lập chỉ mục (cũng giữ máy không ngủ).
- Bản Debug không tối ưu thì giải mã/thu nhỏ ảnh chậm hàng chục lần: `FaceFinderKit` luôn biên dịch `-O`.
- Xcode tự chèn `get-task-allow` vào bản Release khi ký ad-hoc: tắt `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`;
  `make_dmg.sh` kiểm tra lại trước khi đóng gói.

**Chưa kiểm được (không có công cụ điều khiển chuột trong phiên phát triển):** bấm/kéo thả thật trong bản sandbox —
hộp thoại xin quyền ghi vào thư mục chứa zip, quyền còn nhớ sau khi mở lại app, kéo thả từ Finder. Bài tự kiểm tra
chạy bản không sandbox và coi như người dùng đã bấm "Cho phép". Đây là việc đầu tiên khi dùng thử.

**Chưa làm (lúc đó):** hỗ trợ Mac Intel — đã làm ở Giai đoạn 3.

### Giai đoạn 3 — Trải nghiệm hoàn chỉnh (3–5 ngày)
- Đánh dấu ✓/✗ và chấm lại tức thì; Quick Look; nhiều người đã lưu; lịch sử tìm kiếm.
- Tự nhận ra file mới trong nguồn đã thêm (quét bổ sung).
- Hỗ trợ ảnh RAW/HEIC đầy đủ, xử lý ảnh hỏng, zip có mật khẩu (báo lỗi rõ ràng).
- Giao diện tiếng Việt (mặc định) + tiếng Anh.

### 5.3 Kết quả Giai đoạn 3 (15/11/2026)

| Mục | Đã làm |
|---|---|
| Đánh dấu ✓/✗, chấm lại tức thì | Nút khi rê chuột, menu chuột phải, phím **D/Y** (đúng) **S/N** (sai), **Delete** bỏ đánh dấu. Ảnh ✓ luôn "Khớp" và khuôn mặt khớp của nó thành mẫu bổ sung; ảnh ✗ vào nhóm "Đã loại", không dùng để mở rộng, bị bỏ khỏi thư mục kết quả. Chấm lại trên ảnh chụp thư viện trong bộ nhớ (không đọc lại ổ đĩa). Lưu trong `people.marks` |
| Chọn nhiều, thu gọn nhóm | Cmd+bấm (thêm/bớt), Shift+bấm / Shift+mũi tên (chọn dải), Cmd+A; D/S/Delete, nút ✓/✗ và menu áp dụng cho cả loạt; thanh thao tác ở đáy khi chọn ≥ 2 ảnh. Esc / bấm chỗ trống bỏ chọn. Bấm tiêu đề nhóm để thu gọn/mở rộng (nhớ giữa các lần mở app; phím mũi tên bỏ qua nhóm thu gọn). Ô ảnh làm lại theo phản hồi: thanh ✓/✗ ở mép dưới, vòng chọn mảnh, chấm màu trạng thái, ảnh đã loại mờ nhưng giữ màu |
| Quick Look, bàn phím | **Space** xem ảnh lớn (ảnh trong zip được giải nén ra file tạm), phím mũi tên đi giữa các ảnh theo đúng hàng của lưới, giữ phím thì chạy liên tục |
| Nhiều người, lịch sử tìm | Bảng `searches` (50 lần gần nhất mỗi người), hiện trong màn hình kết quả |
| Quét bổ sung | Theo dõi thư mục nguồn bằng FSEvents (bỏ qua thay đổi trong thư mục kết quả của app), quét lại khi quay lại app (>60 giây) và khi cắm ổ đĩa, nút "Quét lại". Thư viện không đổi thì không tìm lại/ghi lại (so dấu vân của thư viện). Dọn dữ liệu của ảnh đã xoá và nguồn đã bỏ |
| Ảnh RAW/HEIC, ảnh hỏng, zip có mật khẩu | RAW (ARW, CR2/CR3, NEF, DNG, RAF, ORF, RW2…) đọc ảnh xem trước nhúng sẵn qua ImageIO; RAW có JPEG/HEIC cùng tên thì chỉ dùng bản JPEG/HEIC. JPEG cụt/hỏng báo lỗi như Pillow; ảnh hỏng được ghi vào chỉ mục (không thử lại tới khi file đổi) và liệt kê trong Thư viện kèm lý do. Zip có mật khẩu: tự đọc thư mục trung tâm của zip để đếm và báo rõ (ZIPFoundation lặng lẽ bỏ qua) |
| Tiếng Việt + tiếng Anh | String Catalog cho app và bộ máy (177 chuỗi), có biến thể số ít/số nhiều. Mặc định tiếng Việt kể cả khi macOS đặt tiếng Anh trước; đổi trong Cài đặt → Ngôn ngữ giao diện. Tên thư mục/CSV ghi ra đĩa luôn là tiếng Việt (giống CLI) |
| Mac Intel | Bỏ kiểu `Float16` của Swift (không có trên x86_64), dùng vImage — làm tròn giống hệt (kiểm trên 20.000 giá trị). DMG universal. **Chưa chạy thử trên máy Intel** (máy phát triển không có Rosetta) |

Cách làm: tự viết các tính năng, rồi dùng workflow nhiều agent cho phần lặp lại/kiểm tra chéo:
chuyển chuỗi sang dạng dịch được (10 agent + 10 agent kiểm tra lại từng file), dịch (4 agent + 1 agent soát thuật ngữ),
**soát lỗi** (6 agent theo 6 khía cạnh + 2 agent phản biện mỗi phát hiện): 23 phát hiện, 19 được cả hai bên phản biện
xác nhận. Đã sửa hết, đáng kể nhất:
- Huỷ lập chỉ mục không dừng các luồng phân tích (AsyncStream kết thúc lặng lẽ khi bị huỷ).
- Ghi thư mục kết quả lỗi giữa chừng (ảnh gốc mất, ổ mạng không có Thùng rác) làm app quên các file đã chép → lần sau
  chép trùng. Giờ lỗi từng file không dừng cả lượt, danh sách file luôn được lưu.
- Chuyển thư mục kết quả trong lúc đang ghi làm thư mục cũ bị tạo lại (không có file đánh dấu). Giờ khoá thao tác này khi
  đang ghi, và việc ghi tự dừng nếu thư mục biến mất.
- Kết quả tạm thời rỗng (vừa mở app, ổ đĩa rút ra) có thể đưa toàn bộ ảnh kết quả vào Thùng rác — tìm ra khi viết lại,
  trước khi soát: chỉ bỏ file khi ảnh gốc còn trong thư viện và được chấm là không khớp.
- Quyền truy cập ổ đĩa cắm sau khi mở app không được mở lại; bookmark lỗi thời không được làm mới.
- Hai người trùng tên tạo liền nhau dùng chung thư mục kết quả; xoá nguồn dùng `LIKE` sai với tên có `%`, `_`.

Kiểm tra: 42 test của bộ máy; tự kiểm tra toàn luồng bằng bản Release cả tiếng Việt và tiếng Anh (thêm bước ✓/✗, Quick
Look, quét lại khi không đổi): kết quả vẫn 58 khớp / 5 cần kiểm tra như CLI. Chỉ mục cũ (lược đồ v2) nâng cấp lên v3 được.
Tốc độ lập chỉ mục chưa đo lại được (lúc đo có máy ảo khác chiếm ~450% CPU); phần code trên đường xử lý chính chỉ đổi
cách làm tròn Float16 và cách huỷ, số đo tham khảo vẫn là 313 giây ở mục 5.2.

### Giai đoạn 4 — Phát hành trên GitHub (1–2 ngày)
- Đóng DMG, đưa lên GitHub Releases; README hướng dẫn cài; GitHub Actions build và chạy test ở mỗi commit.
- **Chưa notarize:** bản build chỉ được ký ad-hoc, macOS sẽ chặn ở lần mở đầu tiên. README phải hướng dẫn rõ:
  mở System Settings → Privacy & Security → "Open Anyway" (từ macOS 15 không còn cách chuột phải → Open).
  Kèm mã SHA-256 của DMG để người dùng kiểm tra file tải về, và hướng dẫn tự build từ mã nguồn bằng Xcode.
- **Khi có tài khoản Apple Developer:** ký bằng Developer ID, notarize, staple; thêm bước này vào GitHub Actions.
  Không phải sửa gì trong code.
- Kiểm tra lần cuối: entitlements không có mạng, test chặn mạng, đo hiệu năng ghi vào README.

### 5.4 Kết quả Giai đoạn 4 (15/11/2026, Apple M1) — phần trong repo xong, chưa đẩy lên GitHub

| Mục | Đã làm |
|---|---|
| CI (`.github/workflows/ci.yml`) | Mỗi commit lên `main` / pull request: kiểm tra không có dữ liệu cá nhân, phiên bản `project.yml` = `Info.plist`, chuẩn bị model, `swift test`, build Release + mọi bước kiểm tra của `make_dmg.sh`, lưu DMG làm artifact. Hai cấu hình: runner `xcode-27` (bản preview của GitHub, đúng Xcode 27.0 27A266a như máy phát triển; DMG lấy từ đây) và `macos-26` với Xcode 26.6 (bản ổn định) |
| Model trên CI | `tools/fetch_models.sh` tải 2 model ONNX gốc, kiểm SHA-256; `convert_models.py --input` chuyển sang Core ML, **báo lỗi nếu lệch so với ONNX quá ngưỡng** (ArcFace cosine < 0,998; YuNet > 0,001). Cache theo nội dung script. Chuyển lại cho ra cùng trọng số với bản trên máy (chỉ khác ngày tạo trong metadata) |
| Phát hành (`release.yml`) | Đẩy tag `v<phiên bản>` → kiểm tra tag = phiên bản app → build DMG → tạo bản phát hành **nháp** kèm DMG, `.sha256`, hướng dẫn cài (`tools/release_notes.sh`, có đoạn "Open Anyway" khi chưa notarize). Bấm Publish bằng tay |
| Notarize | Có đủ 7 secret (ghi ở đầu `release.yml`) thì tự ký Developer ID + notarize + staple; thiếu một phần thì báo lỗi thay vì lặng lẽ ký ad-hoc. Ghi chú phát hành nói "đã notarize" dựa trên chính file DMG (`stapler validate`). Trên máy: biến môi trường cho `make_dmg.sh`. Không phải sửa code |
| Kiểm tra chặn mạng | `tools/check_no_network.sh`: ký đúng entitlements của app cho chương trình thử `tools/netprobe.c`, kết nối tới 127.0.0.1 phải bị macOS từ chối (EPERM), bản đối chứng không sandbox phải kết nối được. Đã thử ngược: app ký lại có `network.client` thì script báo lỗi. Chạy trong mỗi lần `make_dmg.sh` |
| Dữ liệu cá nhân | `tools/check_repo_privacy.sh`: báo lỗi nếu git theo dõi file ảnh/video/zip/chỉ mục/model theo đuôi, đường dẫn và kiểu nội dung (ảnh đổi đuôi), kể cả tên file tiếng Việt. `.gitignore` thêm RAW, HEIF, WebP, TIFF… |

**Lỗi lớn tìm ra khi đo hiệu năng lần cuối: bộ nhớ GPU tăng không giới hạn.** Lập chỉ mục 1416 ảnh có bộ nhớ đỉnh
**13,7 GB** (RSS chỉ 1,7 GB, phần còn lại là bộ nhớ GPU "IOAccelerator"). Máy 8 GB sẽ phải swap rất nặng. Nguyên nhân, đo
bằng chương trình thử riêng:
- Core ML trên GPU giữ một bản biên dịch + bộ nhớ riêng cho mỗi kích thước đầu vào và chỉ giữ được rất ít kích thước,
  tính chung cho cả tiến trình. Vượt quá thì lần gọi nào cũng biên dịch lại, bộ nhớ cũ chỉ được trả khi GPU rảnh.
- ArcFace được gọi với số mặt đúng bằng số mặt trong ảnh (1, 2, 3… mặt): mỗi số là một kích thước. Chỉ cần ArcFace có
  từ 2 cỡ lô trở lên xen kẽ với YuNet là bộ nhớ tăng ~4,7 MB mỗi lượt (1 luồng). YuNet riêng: ≤ 6 kích thước ảnh thì ổn
  định, 10 kích thước thì 9,4 GB sau 300 ảnh. `reshapeFrequency = .frequent` và `autoreleasepool` không giúp gì.

Sửa (kết quả không đổi):
- ArcFace luôn chạy lô cố định **4 mặt**, lô cuối đệm mặt rỗng. Vân mặt giống hệt khi chạy từng mặt một (kiểm từng bit
  trên GPU; CSV kết quả lô 4 và lô 1 giống hệt từng byte). Lô 4 nhanh hơn lô 1 khoảng 6%.
- YuNet: tối đa 4 kích thước ảnh chạy trên GPU, các kích thước khác chạy trên CPU (lệch so với ONNX cỡ 0,00001 như
  GPU). Chỗ trên GPU theo tần suất (`ShapeBudget`): còn chỗ thì vào ngay; hết chỗ thì một kích thước chỉ thay được kích
  thước ít gặp nhất khi gặp nhiều hơn gấp đôi + 8 lần, để vài ảnh mẫu lạ cỡ phân tích trước không đẩy cả thư viện sang CPU,
  và không đổi chỗ qua lại liên tục (10 kích thước đều nhau, 10.000 ảnh: 0 lần đổi).
- Thử nghiệm: 8 kích thước ảnh, 5 luồng, 500 lượt: ổn định ~2–2,5 GB. Test mới: `ShapeBudgetTests` (không cần model),
  `ModelMemoryTests` (chạy khi có model; CI chạy test sau bước chuẩn bị model).
- Tự kiểm tra toàn luồng của app, lập chỉ mục lại từ đầu: 1416 ảnh trong 300 giây (Giai đoạn 2: 313 giây), 58 khớp /
  5 cần kiểm tra, các bước đánh dấu, Quick Look, quét lại đều đúng.

| Lập chỉ mục 1416 ảnh 33 MP (`ffcli`, M1, 5 luồng) | Thời gian | Bộ nhớ đỉnh | So với CLI |
|---|---|---|---|
| Trước khi sửa | 4m44s | 13,7 GB | khớp 58/58, cần kiểm tra 5/5 |
| Sau khi sửa | 5m23s* | 3,1 GB (bộ nhớ GPU đứng yên ~580 MB) | khớp 58/58, cần kiểm tra 5/5, lệch điểm lớn nhất 0,003 |

\* Đo lúc `mediaanalysisd` của macOS chiếm ~200% CPU (load 8–12), lần đo trước lúc load ~4,5, nên chưa so được tốc độ.
Đo xen kẽ trên cùng một zip (251 ảnh) cùng điều kiện: lô 4 38,6 s / 41,2 s, lô 1 40,6 s / 44,0 s.

Soát lỗi phần CI/phát hành bằng workflow nhiều agent (4 khía cạnh, mỗi phát hiện 2 agent phản biện): 22 phát hiện, 13 được
xác nhận, đã sửa hết. Đáng kể nhất: bước chặn bản phát hành còn chế độ tự kiểm tra **chưa bao giờ hoạt động** (tìm chuỗi
`FF_SELFTEST` vốn không có trong file chạy, và `strings | grep -q` dưới `pipefail` có thể "qua" đúng lúc chuỗi có mặt).
Giờ tìm tên kiểu `SelfTest`, đã thử trên cả bản SELFTEST (báo lỗi) và bản phát hành (qua).

Soát riêng phần sửa bộ nhớ (2 khía cạnh, mỗi phát hiện 2 agent phản biện): 13 phát hiện, 6 được xác nhận, đã sửa: chỗ GPU
từng chia theo "đến trước được trước" (ảnh mẫu lạ cỡ có thể đẩy cả thư viện sang CPU) → theo tần suất; test YuNet không
chứng minh được ảnh có chạy CPU thật → tách phần chọn chỗ ra để test riêng; test dùng số ngẫu nhiên không seed và so theo
thứ tự điểm → có seed, ghép theo IoU; `ffcli phase0` đo "GPU" nhưng lẫn ảnh chạy CPU → không dùng bản CPU dự phòng.

Người dùng thử 0.4.0: nút **+** (Thêm nguồn ảnh) không chọn được thư mục (nút Thêm mờ). Hộp chọn khai báo
`allowedContentTypes = [.zip]`; có danh sách kiểu mà thiếu `.folder` thì macOS không cho chọn thư mục dù đã bật
`canChooseDirectories`. Hộp chọn ảnh mẫu cũng bị như vậy. Sửa ở 0.4.1 (thêm `.folder`); kéo thả thư mục vẫn luôn chạy được.

Đã kiểm trên bản sao sạch của repo (không có repo CLI, không có model): `swift test` → tải model → chuyển model →
`make_dmg.sh` đều qua. **Chưa kiểm được:** chạy thật trên GitHub Actions (repo chưa có trên GitHub), build bằng Xcode 26.6,
đường ký Developer ID / notarize (chưa có tài khoản), chạy trên máy Intel.

Tổng: khoảng **3–4 tuần** làm việc.

---

## 6. Kiểm thử

| Loại | Nội dung |
|---|---|
| Trùng khớp với CLI | Golden data từ `export_golden.py`; test vân mặt, khung mặt, điểm từng ảnh, tập ảnh khớp |
| Đơn vị | Căn mặt (ma trận biến đổi), NMS, tâm + mở rộng, ngưỡng tự điều chỉnh, `is_ambiguous`, đọc zip (kể cả đường dẫn độc hại kiểu `../`) |
| Hiệu năng | `ffcli bench` trên bộ 1416 ảnh và bộ 80 ảnh; so với bảng số đo trong README hiện tại |
| Riêng tư | Test mở kết nối mạng phải thất bại; kiểm tra entitlements trong bản build |
| Thư mục kết quả | Ghi mặc định vào thư mục nguồn và thư mục chứa zip; xin quyền khi nguồn là zip; chuyển/sao chép sau khi chạy; cập nhật khi đổi ngưỡng; **không bao giờ đụng file không do app tạo**; lập chỉ mục bỏ qua thư mục có `.facefinder` |
| Giao diện | XCUITest cho luồng chính: thêm nguồn → tạo người → xem kết quả → xuất |

Bộ ảnh thử nghiệm và golden data **không commit vào git** (ảnh cá nhân); chỉ commit script tạo ra chúng.

---

## 7. Rủi ro và quyết định

1. **Bản quyền (đã chốt: phát hành miễn phí trên GitHub):**
   - Mã nguồn của app: giấy phép MIT.
   - Model ArcFace của InsightFace chỉ cho phép dùng phi thương mại. File `NOTICE` và README ghi rõ nguồn model,
     điều khoản này, và việc **app không được dùng cho mục đích thương mại** khi còn đi kèm model này.
   - Thư viện đi kèm: libjpeg-turbo (IJG + BSD 3 điều khoản), ZIPFoundation (MIT), GRDB (MIT) — ghi trong `NOTICE`.
   - Nếu sau này muốn thương mại: phải mua giấy phép InsightFace hoặc thay model khác. SFace của OpenCV
     (Apache 2.0) đã thử và **không phân biệt được trẻ em**, nên không thay thế được.
2. **Notarize (đã chốt: làm sau):** trong lúc chưa có, người dùng phải bấm "Open Anyway" một lần (Giai đoạn 4).
3. **macOS tối thiểu (đã chốt): 15.** Mac Intel chạy được nhưng chậm, không ưu tiên tối ưu.
4. **Chuyển đổi YuNet sang Core ML có thể lệch:** đã có dự phòng (Vision hoặc ONNX Runtime) và tiêu chí đo ở
   Giai đoạn 0.
5. **Neural Engine có thể làm lệch kết quả nhẹ (FP16):** chỉ bật mặc định nếu vượt tiêu chí trùng khớp; không thì
   dùng GPU như CLI. *Đã đo (mục 5.0): không vượt, mặc định dùng GPU.*

---

## 8. Việc phụ phát sinh do chuyển thư mục

- Dòng alias trong `~/.zprofile` vẫn trỏ về đường dẫn cũ `~/Documents/Tools/face-finder/findface` (không còn tồn
  tại), nên lệnh `findface` sẽ báo lỗi. Cần đổi thành
  `~/Documents/Tools/face-finder-proj/face-finder/findface`. Gọi trực tiếp `./findface` trong thư mục
  mới vẫn chạy bình thường (đã thử).
- Cache `~/.cache/findface/faces.pkl` vẫn dùng được, không bị ảnh hưởng.
