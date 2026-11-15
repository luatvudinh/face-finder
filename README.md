# Face Finder (macOS)

Tìm những ảnh có mặt một người cụ thể trong hàng nghìn ảnh: kéo thư mục ảnh hoặc file zip vào, đưa vài ảnh mẫu
của người cần tìm, app gom ảnh khớp ra một thư mục riêng.

- **Chạy hoàn toàn trên máy.** App chạy trong App Sandbox của macOS **không có quyền truy cập mạng**: hệ điều hành
  chặn mọi kết nối ra ngoài. Tự kiểm tra: `codesign -d --entitlements - "/Applications/Face Finder.app"` (không có
  `network.client`). App chỉ đọc/ghi được thư mục bạn tự chọn hoặc kéo thả vào.
- **Lập chỉ mục một lần, tìm nhiều người.** Quét một lần (~5 phút và ~3 GB bộ nhớ cho 1.400 ảnh 33 MP trên Apple M1),
  sau đó tìm bất kỳ ai chỉ mất vài giây.
- **Cùng độ chính xác với công cụ dòng lệnh `findface`** (~99% ảnh chọn ra là đúng người, tìm được ~97% số ảnh có
  người đó khi có từ 3 ảnh mẫu). Bộ máy của app cho điểm trùng `findface` trên bộ ảnh thử 1.416 ảnh.

Trạng thái: **bản dùng thử** (0.4). Kế hoạch và số đo: [PLAN.md](PLAN.md).

## Cài đặt (bản dùng thử)

Yêu cầu: macOS 15 trở lên. Nên dùng máy Apple Silicon (M1 trở lên); bản build có cả Mac Intel nhưng chưa được thử trên máy Intel và sẽ chậm hơn nhiều.

1. Tải `FaceFinder-<phiên bản>.dmg` ở trang **Releases** của repo, mở ra, kéo **Face Finder** vào thư mục
   **Applications**.
2. Mở app lần đầu: app chưa được Apple công chứng (notarize) nên macOS sẽ chặn với thông báo không xác minh được
   nhà phát triển. Bấm **Xong**, rồi mở **System Settings → Privacy & Security**, kéo xuống mục Security, bấm
   **Open Anyway** cạnh dòng “Face Finder”, xác nhận bằng mật khẩu máy. Chỉ phải làm một lần.
   (Từ macOS 15 không còn cách chuột phải → Open.)
3. Nên kiểm tra file tải về không bị sửa: `shasum -a 256 FaceFinder-*.dmg` phải ra đúng mã ghi trong trang phát hành
   (và trong file `.sha256` đi kèm).

## Cách dùng

1. **Thư viện ảnh:** kéo thả thư mục ảnh hoặc file zip vào cửa sổ (hoặc bấm **+**). Thư mục được quét cả thư mục
   con; ảnh trong zip được đọc thẳng, không cần giải nén. Đọc được JPEG, HEIC, PNG, TIFF, WebP và ảnh RAW của máy
   ảnh (RAW có bản JPEG cùng tên thì chỉ dùng bản JPEG). App lập chỉ mục khuôn mặt, có thể tạm dừng hoặc huỷ; khi có
   ảnh mới trong thư mục nguồn, app tự quét thêm. Ảnh hỏng và zip có mật khẩu được liệt kê kèm lý do.
2. **Thêm người…:** đặt tên, kéo vào vài ảnh rõ mặt của người cần tìm (nên ≥ 3 ảnh, nhiều góc mặt). Ảnh có nhiều
   người cũng được: app tự tìm người xuất hiện nhất quán và đánh số #1, #2…; bấm vào hàng của người cần tìm nếu
   app đoán sai.
3. **Kết quả:** ảnh được chia thành *Khớp* / *Cần kiểm tra* / *Dưới ngưỡng*, kèm ảnh khuôn mặt để rà nhanh. Kéo
   **thanh ngưỡng** sang phải để chặt hơn, sang trái để tìm được nhiều hơn; kết quả đổi ngay.
   **Dạy thêm cho app:** bấm chọn ảnh rồi nhấn **D** (đúng người) hoặc **S** (không phải), hoặc bấm ✓/✗ khi rê chuột lên
   ảnh. Ảnh ✓ luôn được tính là khớp và giúp tìm thêm ảnh giống nó; ảnh ✗ bị loại. **Space** xem ảnh lớn, phím mũi tên
   để chuyển ảnh, **Delete** bỏ đánh dấu, **Esc** hoặc bấm chỗ trống để bỏ chọn.
   **Chọn nhiều:** giữ **Cmd** khi bấm để thêm/bớt từng ảnh, **Shift** để chọn cả dải (hoặc Shift + phím mũi tên),
   **Cmd+A** chọn tất cả; rồi nhấn D/S hoặc dùng thanh thao tác ở dưới để đánh dấu cả loạt.
   Bấm vào tiêu đề nhóm (Khớp, Cần kiểm tra…) để thu gọn hoặc mở rộng nhóm đó.
4. **Thư mục kết quả:** mặc định nằm ngay trong thư mục ảnh nguồn (nguồn là zip thì nằm cạnh file zip; lần đầu app
   xin phép ghi vào thư mục đó):

   ```
   Face Finder - <tên>/
     *.JPG              ảnh khớp (bản sao, ảnh gốc giữ nguyên)
     Cần kiểm tra/      ảnh nên xem lại
     _báo cáo/          ket_qua.csv: điểm từng ảnh
   ```

   Thư mục này tự cập nhật khi bạn kéo ngưỡng hoặc đánh dấu ✓/✗. App chỉ thêm/bỏ những file do chính nó tạo (bỏ thì đưa vào Thùng
   rác); ảnh bạn tự bỏ vào không bao giờ bị đụng tới. **Khác → Chuyển kết quả sang…** để đổi chỗ lưu.

Ngôn ngữ giao diện (Tiếng Việt / English): **Face Finder → Settings…**. Mặc định tiếng Việt.

Xoá dữ liệu: **Face Finder → Settings… → Xoá toàn bộ dữ liệu khuôn mặt** (chỉ mục và người đã lưu chỉ nằm trên máy,
trong thư mục riêng của app).

## Tự build từ mã nguồn

Cần Xcode (phát triển bằng Xcode 27.0; CI build thêm bằng Xcode 26.6), Python 3.13 (chỉ để chuyển model một lần).

```bash
python3.13 -m venv tools/.venv && tools/.venv/bin/pip install -r tools/requirements.txt
```

Tải hai model gốc (YuNet của OpenCV Zoo, ArcFace `w600k_r50` của InsightFace; script kiểm mã SHA-256) vào
`models/onnx/`, rồi chuyển sang Core ML vào `models/`:

```bash
tools/fetch_models.sh
```

```bash
tools/.venv/bin/python tools/convert_models.py
```

Build bản Release, kiểm tra (sandbox bật, không quyền mạng, không quyền gỡ lỗi, sandbox thật sự chặn kết nối) và đóng
DMG vào `dist/`:

```bash
tools/make_dmg.sh
```

Hoặc mở `FaceFinder/FaceFinder.xcodeproj` bằng Xcode (project sinh từ `FaceFinder/project.yml` bằng XcodeGen).

Kiểm tra riêng việc chặn mạng của một bản build bất kỳ: `tools/check_no_network.sh "/Applications/Face Finder.app"`.
Script ký các entitlements lấy từ chính app đó cho một chương trình thử nhỏ (`tools/netprobe.c`), cho nó kết nối tới
một cổng trên chính máy (127.0.0.1) và yêu cầu kết nối bị macOS từ chối; bản đối chứng không sandbox phải kết nối được.

### CI và phát hành

- `.github/workflows/ci.yml`: mỗi commit lên `main` và mỗi pull request chạy test của `FaceFinderKit`, build app bằng
  Xcode 27.0 và 26.6, chạy các bước kiểm tra của `make_dmg.sh` và lưu DMG làm artifact (14 ngày). Model được chuyển trên
  máy CI rồi cache lại. Repo không chứa model, ảnh hay dữ liệu khuôn mặt: `tools/check_repo_privacy.sh` (chạy trong CI,
chạy được trên máy trước khi commit) báo lỗi nếu có file ảnh/video/zip/chỉ mục/model, theo đuôi file, đường dẫn
(`golden/`, `models/`, thư mục kết quả) và kiểu nội dung (ảnh bị đổi đuôi). Không kiểm được dữ liệu cá nhân dạng chữ.
- `.github/workflows/release.yml`: đẩy tag trùng phiên bản app (ví dụ `v0.4.0`) thì build DMG và tạo bản phát hành
  **nháp** kèm DMG, `.sha256` và hướng dẫn cài (`tools/release_notes.sh`). Xem lại rồi bấm Publish.
- **Notarize:** khi có tài khoản Apple Developer, thêm các secret ghi ở đầu `release.yml` (chứng chỉ Developer ID dạng
  `.p12`, khoá App Store Connect API). Workflow tự ký Developer ID, notarize và staple DMG; không phải sửa code. Trên
  máy: `SIGN_IDENTITY=… TEAM_ID=… NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER=… tools/make_dmg.sh`.

Bản dịch: chuỗi giao diện nằm trong `Localizable.xcstrings` (app và `FaceFinderKit`), tiếng Việt là ngôn ngữ gốc. Thêm
chuỗi mới thì xuất bằng `xcodebuild -exportLocalizations … -exportLanguage en`, dịch, nhập lại bằng
`-importLocalizations`, rồi chạy `python3 tools/l10n_plurals.py` (thêm dạng số ít/số nhiều và bản tiếng Việt).

Cấu trúc:

| Thư mục | Nội dung |
|---|---|
| `FaceFinderKit/` | Swift package: toàn bộ bộ máy (đọc ảnh/zip, YuNet, căn mặt, ArcFace, chấm điểm, chỉ mục SQLite, ghi kết quả) + `ffcli` để đo và so với CLI. `swift test` |
| `FaceFinder/` | App SwiftUI |
| `tools/` | Tải/chuyển model, xuất/so dữ liệu đối chiếu với CLI, đóng DMG, kiểm tra chặn mạng, tự kiểm tra app |
| `.github/` | GitHub Actions: CI và phát hành |

## Công cụ dòng lệnh `findface`

Phiên bản dòng lệnh (Python) có trước app nằm trong [`face-finder/`](face-finder/), cùng thuật toán và độ chính xác;
app dùng nó làm chuẩn đối chiếu. Cài và dùng: xem [face-finder/README.md](face-finder/README.md).

Trước đây repo này chỉ chứa công cụ dòng lệnh ở thư mục gốc. Nếu đã clone từ trước: `git pull`, rồi chạy công cụ từ
thư mục `face-finder/` (`cd face-finder && ./setup.sh`).

## Giấy phép

Mã nguồn: MIT (xem `LICENSE`). Model nhận diện ArcFace của InsightFace **chỉ được dùng cho mục đích phi thương mại**,
nên app khi còn đi kèm model này cũng vậy. Các thành phần khác: xem `NOTICE`.
