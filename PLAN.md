# Kế hoạch: app macOS "Face Finder"

Mục tiêu: biến công cụ dòng lệnh `face-finder/` (findface) thành một app macOS có giao diện, giữ nguyên độ
chính xác đã kiểm chứng (~99% / ~97% với ≥3 ảnh mẫu), **chạy hoàn toàn trên máy** và nhanh bằng hoặc hơn CLI.

Trạng thái (14/11/2026): **Giai đoạn 0 và 1 xong, đạt mọi tiêu chí** (mục 5.0, 5.1). **Giai đoạn 2 có bản dùng thử**
(`dist/FaceFinder-0.2.0.dmg`, mục 5.2): toàn luồng chạy đúng và nhanh như CLI; còn chờ thử bằng tay các bước xin quyền
trong sandbox. Từ Giai đoạn 4 đã có: DMG, README hướng dẫn cài, kiểm tra entitlements khi đóng gói.

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

### 5.2 Kết quả Giai đoạn 2 (14/11/2026, Apple M1) — có bản dùng thử, còn chờ thử bằng tay trong sandbox

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

**Chưa làm:** hỗ trợ Mac Intel (bộ máy dùng `Float16`, không có trên x86_64; bản build hiện chỉ có arm64).

### Giai đoạn 3 — Trải nghiệm hoàn chỉnh (3–5 ngày)
- Đánh dấu ✓/✗ và chấm lại tức thì; Quick Look; nhiều người đã lưu; lịch sử tìm kiếm.
- Tự nhận ra file mới trong nguồn đã thêm (quét bổ sung).
- Hỗ trợ ảnh RAW/HEIC đầy đủ, xử lý ảnh hỏng, zip có mật khẩu (báo lỗi rõ ràng).
- Giao diện tiếng Việt (mặc định) + tiếng Anh.

### Giai đoạn 4 — Phát hành trên GitHub (1–2 ngày)
- Đóng DMG, đưa lên GitHub Releases; README hướng dẫn cài; GitHub Actions build và chạy test ở mỗi commit.
- **Chưa notarize:** bản build chỉ được ký ad-hoc, macOS sẽ chặn ở lần mở đầu tiên. README phải hướng dẫn rõ:
  mở System Settings → Privacy & Security → "Open Anyway" (từ macOS 15 không còn cách chuột phải → Open).
  Kèm mã SHA-256 của DMG để người dùng kiểm tra file tải về, và hướng dẫn tự build từ mã nguồn bằng Xcode.
- **Khi có tài khoản Apple Developer:** ký bằng Developer ID, notarize, staple; thêm bước này vào GitHub Actions.
  Không phải sửa gì trong code.
- Kiểm tra lần cuối: entitlements không có mạng, test chặn mạng, đo hiệu năng ghi vào README.

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
