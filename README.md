# Face Finder (macOS)

Tìm những ảnh có mặt một người cụ thể trong hàng nghìn ảnh: kéo thư mục ảnh hoặc file zip vào, đưa vài ảnh mẫu
của người cần tìm, app gom ảnh khớp ra một thư mục riêng.

- **Chạy hoàn toàn trên máy.** App chạy trong App Sandbox của macOS **không có quyền truy cập mạng**: hệ điều hành
  chặn mọi kết nối ra ngoài. Tự kiểm tra: `codesign -d --entitlements - "/Applications/Face Finder.app"` (không có
  `network.client`). App chỉ đọc/ghi được thư mục bạn tự chọn hoặc kéo thả vào.
- **Lập chỉ mục một lần, tìm nhiều người.** Quét một lần (~5 phút cho 1.400 ảnh 33 MP trên Apple M1), sau đó tìm bất
  kỳ ai chỉ mất vài giây.
- **Cùng độ chính xác với công cụ dòng lệnh `findface`** (~99% ảnh chọn ra là đúng người, tìm được ~97% số ảnh có
  người đó khi có từ 3 ảnh mẫu). Bộ máy của app cho điểm trùng `findface` trên bộ ảnh thử 1.416 ảnh.

Trạng thái: **bản dùng thử** (0.2). Kế hoạch và số đo: [PLAN.md](PLAN.md).

## Cài đặt (bản dùng thử)

Yêu cầu: macOS 15 trở lên, máy Apple Silicon (M1 trở lên). Bản này chưa chạy trên Mac Intel.

1. Mở file `FaceFinder-<phiên bản>.dmg`, kéo **Face Finder** vào thư mục **Applications**.
2. Mở app lần đầu: app chưa được Apple công chứng (notarize) nên macOS sẽ chặn với thông báo không xác minh được
   nhà phát triển. Bấm **Xong**, rồi mở **System Settings → Privacy & Security**, kéo xuống mục Security, bấm
   **Open Anyway** cạnh dòng “Face Finder”, xác nhận bằng mật khẩu máy. Chỉ phải làm một lần.
   (Từ macOS 15 không còn cách chuột phải → Open.)
3. Nếu tải DMG từ mạng, nên kiểm tra file không bị sửa: `shasum -a 256 FaceFinder-*.dmg` phải ra đúng mã trong file
   `.sha256` đi kèm.

## Cách dùng

1. **Thư viện ảnh:** kéo thả thư mục ảnh hoặc file zip vào cửa sổ (hoặc bấm **+**). Thư mục được quét cả thư mục
   con; ảnh trong zip được đọc thẳng, không cần giải nén. App lập chỉ mục khuôn mặt, có thể tạm dừng hoặc huỷ;
   lần sau chỉ xử lý ảnh mới.
2. **Thêm người…:** đặt tên, kéo vào vài ảnh rõ mặt của người cần tìm (nên ≥ 3 ảnh, nhiều góc mặt). Ảnh có nhiều
   người cũng được: app tự tìm người xuất hiện nhất quán và đánh số #1, #2…; bấm vào hàng của người cần tìm nếu
   app đoán sai.
3. **Kết quả:** ảnh được chia thành *Khớp* / *Cần kiểm tra* / *Dưới ngưỡng*, kèm ảnh khuôn mặt để rà nhanh. Kéo
   **thanh ngưỡng** sang phải để chặt hơn, sang trái để tìm được nhiều hơn; kết quả đổi ngay.
4. **Thư mục kết quả:** mặc định nằm ngay trong thư mục ảnh nguồn (nguồn là zip thì nằm cạnh file zip; lần đầu app
   xin phép ghi vào thư mục đó):

   ```
   Face Finder - <tên>/
     *.JPG              ảnh khớp (bản sao, ảnh gốc giữ nguyên)
     Cần kiểm tra/      ảnh nên xem lại
     _báo cáo/          ket_qua.csv: điểm từng ảnh
   ```

   Thư mục này tự cập nhật khi bạn kéo ngưỡng. App chỉ thêm/bỏ những file do chính nó tạo (bỏ thì đưa vào Thùng
   rác); ảnh bạn tự bỏ vào không bao giờ bị đụng tới. **Khác → Chuyển kết quả sang…** để đổi chỗ lưu.

Xoá dữ liệu: **Face Finder → Settings… → Xoá toàn bộ dữ liệu khuôn mặt** (chỉ mục và người đã lưu chỉ nằm trên máy,
trong thư mục riêng của app).

## Tự build từ mã nguồn

Cần Xcode 26 trở lên, Python 3 (chỉ để chuyển model một lần).

```bash
python3 -m venv tools/.venv && tools/.venv/bin/pip install -r tools/requirements.txt
```

Tải hai model gốc (xem `face-finder/setup.sh` của công cụ dòng lệnh) vào `face-finder/models/`, rồi chuyển sang Core ML:

```bash
tools/.venv/bin/python tools/convert_models.py
```

```bash
tools/make_dmg.sh
```

Hoặc mở `FaceFinder/FaceFinder.xcodeproj` bằng Xcode (project sinh từ `FaceFinder/project.yml` bằng XcodeGen).

Cấu trúc:

| Thư mục | Nội dung |
|---|---|
| `FaceFinderKit/` | Swift package: toàn bộ bộ máy (đọc ảnh/zip, YuNet, căn mặt, ArcFace, chấm điểm, chỉ mục SQLite, ghi kết quả) + `ffcli` để đo và so với CLI. `swift test` |
| `FaceFinder/` | App SwiftUI |
| `tools/` | Chuyển model, xuất/so dữ liệu đối chiếu với CLI, đóng DMG, tự kiểm tra app |

## Giấy phép

Mã nguồn: MIT (xem `LICENSE`). Model nhận diện ArcFace của InsightFace **chỉ được dùng cho mục đích phi thương mại**,
nên app khi còn đi kèm model này cũng vậy. Các thành phần khác: xem `NOTICE`.
