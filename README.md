# findface: tìm ảnh có mặt một người, chạy hoàn toàn trên máy

Đưa vào vài ảnh mẫu của người cần tìm, công cụ quét thư mục ảnh hoặc file zip và **sao chép** những ảnh
có người đó sang một thư mục riêng (ảnh gốc giữ nguyên).

**Mọi thứ chạy trên chính máy Mac của bạn.** Ảnh không bị tải lên đâu, không cần tài khoản, không dùng
dịch vụ nhận diện trên mạng. Sau khi cài đặt, công cụ chạy được cả khi đã ngắt mạng hoàn toàn.

- **Nhanh:** trên máy thử nghiệm (Apple M1, RAM 16 GB), 1416 ảnh 33MP (13 GB, 7 file zip) quét xong trong
  ~5 phút khi máy rảnh. Chạy lại trên cùng bộ ảnh chỉ mất vài giây nhờ cache.
- **Chính xác:** khi có từ 3 ảnh mẫu trở lên, ~99% ảnh chọn ra là đúng người và tìm được ~97% số ảnh có người đó.
- **Riêng tư:** ảnh và dữ liệu khuôn mặt không rời khỏi máy. Đã kiểm chứng: chặn hẳn mạng thì công cụ vẫn
  chạy và cho kết quả giống hệt; khi có mạng, công cụ không mở một kết nối nào.

## Chạy hoàn toàn trên máy (local)

**Ảnh của bạn đi đâu:** không đi đâu cả. Công cụ đọc ảnh trực tiếp từ ổ đĩa, kể cả ảnh nằm trong file zip
(không cần giải nén). Việc phát hiện và nhận diện khuôn mặt chạy bằng CPU/GPU của chính máy
(OpenCV, ONNX Runtime, CoreML của Apple).

**Internet chỉ cần một lần, lúc cài đặt:** `setup.sh` tải thư viện Python (từ PyPI) và hai model nhận diện
(từ GitHub: OpenCV Zoo và InsightFace). Sau đó có thể ngắt mạng hoàn toàn.

**Không gửi dữ liệu ra ngoài:**

- Code của công cụ không có lệnh mạng nào.
- Thư viện ONNX Runtime (của Microsoft) bản cho macOS **mặc định có gửi telemetry** về
  `mobile.events.data.microsoft.com`. Nội dung gồm loại máy, phiên bản macOS, số nhân CPU, dung lượng RAM,
  tên file model và một mã định danh thiết bị (không có ảnh, khuôn mặt hay đường dẫn file).
  **findface tắt tính năng này** ngay khi khởi động (biến môi trường `ORT_DISABLE_TELEMETRY=1` và hàm
  `disable_telemetry_events()`), trước khi thư viện được nạp.

**Đã kiểm chứng** (macOS, onnxruntime 1.30.0, trên bộ ảnh thử nghiệm ở mục Hiệu năng):

| Phép thử | Kết quả |
|---|---|
| Quét toàn bộ 1416 ảnh trong sandbox của macOS chặn mọi kết nối mạng | Chạy trọn vẹn, vẫn dùng GPU. Trong cùng sandbox, `curl` không kết nối được tới trang web nào |
| Quét cùng 213 ảnh với cùng cấu hình, một lần có mạng và một lần chặn mạng | `ket_qua.csv` giống hệt nhau (cùng ảnh khớp, cùng điểm) |
| Quét khi có mạng, theo dõi kết nối mạng của mọi tiến trình Python 3 lần mỗi giây (`lsof`) | 0 kết nối. Hàng đợi telemetry của ONNX Runtime không thêm sự kiện nào |
| Đối chứng: nạp ONNX Runtime mà không tắt telemetry | Sinh ngay 9 sự kiện chờ gửi về Microsoft, và tạo file mã thiết bị |

**Tự kiểm tra trên máy bạn:** đứng trong thư mục công cụ, thay `<ảnh mẫu>` và `<nguồn>` bằng ảnh của bạn rồi
chạy lệnh dưới đây. `sandbox-exec` có sẵn trong macOS. `--no-cache` buộc công cụ phân tích lại mọi ảnh ngay
trong sandbox, `--dry-run` để không chép ảnh.

```bash
sandbox-exec -p '(version 1)(allow default)(deny network*)' ./findface --no-cache --dry-run -r <ảnh mẫu> -i <nguồn> -o ~/Desktop/"findface - thử sandbox"
```

Muốn chắc sandbox thật sự chặn mạng, thử cùng sandbox với `curl` (sẽ báo `Could not resolve host`):

```bash
sandbox-exec -p '(version 1)(allow default)(deny network*)' curl -sI https://github.com
```

Sandbox chỉ chứng minh công cụ **không cần** mạng. Muốn thấy công cụ **không kết nối** ra ngoài, hãy chạy
bình thường (có mạng), và theo dõi ở một tab Terminal khác (dòng nào hiện ra là một kết nối; nhấn Ctrl+C để dừng):

```bash
while true; do lsof -nP -i -a -c Python; sleep 0.5; done
```

**Dữ liệu công cụ lưu lại trên máy:**

| Ở đâu | Chứa gì |
|---|---|
| Thư mục `-o` | Bản sao các ảnh khớp, thư mục `Cần kiểm tra/` và `_báo cáo/` (ảnh ghép các khuôn mặt, file `ket_qua.csv` có đường dẫn của mọi ảnh đã quét) |
| Thư mục `--extract-to` (chỉ khi dùng tuỳ chọn này) | Bản giải nén của toàn bộ ảnh trong các file zip |
| `~/.cache/findface/faces.pkl` | Đường dẫn từng ảnh đã quét, vị trí và "vân mặt" (embedding, 512 con số) của mọi khuôn mặt trong ảnh. Giúp lần chạy sau gần như tức thì. Khoảng 20 MB cho 1400 ảnh, lớn dần khi quét thêm bộ ảnh mới, không tự dọn |
| `models/` trong thư mục công cụ | Hai file model đã tải lúc cài đặt |

"Vân mặt" là dữ liệu sinh trắc học, nên file cache chỉ chủ máy đọc được (quyền 600). Đừng chia sẻ file này,
và xoá đi khi không cần nữa: `rm ~/.cache/findface/faces.pkl`. Chạy với `--no-cache` thì công cụ không đọc
cũng không ghi file này (lần chạy sau sẽ phải quét lại từ đầu).

macOS có thể tự để lại dấu vết như với mọi file ảnh khác: Spotlight lập chỉ mục thư mục kết quả, Preview ghi
`chon_nguoi.jpg` vào danh sách mở gần đây, tiến trình dùng GPU có thể tạo vài file log rỗng `mat-debug-*.log`
trong thư mục tạm của hệ thống. Tất cả đều nằm trên máy.

**Dọn dấu vết telemetry cũ (nếu có):** nếu máy bạn từng chạy một chương trình dùng ONNX Runtime mà không tắt
telemetry (kể cả bản đầu tiên của findface), thư viện đã tạo thư mục
`~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/` (mã thiết bị và hàng đợi sự kiện chưa
gửi). findface không đọc, không ghi thư mục này; có thể xoá:

```bash
rm -rf ~/Library/Application\ Support/Microsoft/DeveloperTools/.onnxruntime
```

## Cài đặt (một lần, cần internet)

```bash
git clone https://github.com/luatvudinh/face-finder.git
cd face-finder
./setup.sh
```

- Cần macOS và `python3` (nếu chưa có, cài từ python.org).
- `setup.sh` tạo môi trường Python riêng (`venv/`) với các phiên bản thư viện đã kiểm chứng (ghi trong
  `requirements.txt`), rồi tải model về `models/` (tải về ~280 MB, sau khi giải nén chỉ giữ lại ~170 MB).
- Chạy lại `setup.sh` khi: xoá thư mục `venv/` hoặc `models/`, chuyển công cụ sang máy khác, hoặc sau khi
  gỡ/nâng cấp Python (venv gắn với bản Python dùng lúc cài).

Lưu ý bản quyền: model nhận diện của InsightFace chỉ được dùng cho mục đích cá nhân, phi thương mại.

## Gọi lệnh findface từ Terminal

**Không cần chuẩn bị gì thêm** (không cần "activate venv"). File `findface` tự dùng đúng môi trường Python
riêng của công cụ, nên đứng ở thư mục nào chạy cũng như nhau.

### Khi đang đứng trong thư mục công cụ

```bash
cd face-finder
./findface -h
```

(`face-finder` là thư mục bạn đã clone về; nếu đang ở chỗ khác thì `cd` bằng đường dẫn đầy đủ tới nó.)
Phải có `./` ở đầu: zsh không tự tìm lệnh trong thư mục hiện tại, thiếu `./` sẽ báo `command not found`.

### Ở bất kỳ đâu (alias)

Đứng trong thư mục công cụ, chạy **một lần** lệnh dưới đây để thêm alias vào `~/.zprofile` (zsh là shell mặc
định của macOS), rồi mở tab Terminal mới hoặc chạy `source ~/.zprofile`:

```bash
echo "alias findface=\"'$PWD/findface'\"" >> ~/.zprofile
```

Lệnh tự ghi đường dẫn thật của thư mục công cụ; hai lớp ngoặc giúp alias vẫn chạy khi đường dẫn có dấu cách.
Sau đó gõ `findface ...` ở thư mục nào cũng được. Nếu chuyển thư mục công cụ đi chỗ khác, mở `~/.zprofile`
sửa lại đường dẫn trong dòng alias. Alias không có tác dụng trong script hay sau `sandbox-exec`; khi đó hãy gọi
bằng `./findface` (đứng trong thư mục công cụ) hoặc đường dẫn đầy đủ tới file `findface`.

### Tóm tắt các cách gọi

| Cách gọi | Khi nào dùng |
|---|---|
| `./findface ...` | Đang đứng trong thư mục công cụ |
| `findface ...` | Ở bất cứ đâu trong Terminal, sau khi đã thêm alias |
| `/đường/dẫn/tới/face-finder/findface ...` | Trong script, hoặc sau `sandbox-exec` khi không đứng trong thư mục công cụ |
| `source venv/bin/activate` rồi `python findface.py ...` | Không cần; chỉ hữu ích khi muốn sửa code hoặc cài thêm thư viện |

### Ghi đường dẫn trong lệnh

- Ảnh mẫu, nguồn và thư mục kết quả nên ghi đường dẫn đầy đủ (bắt đầu bằng `~/` hoặc `/`). Nếu chỉ ghi tên ngắn
  như `KetQua`, thư mục sẽ được tạo ngay tại chỗ bạn đang đứng.
- Tên có dấu cách thì đặt trong ngoặc kép, nhưng để `~/` **ở ngoài** ngoặc:
  `~/Desktop/"Kết quả mới"` là đúng, còn `"~/Desktop/Kết quả mới"` là sai.
- Khi gõ số luôn dùng dấu chấm: `-t 0.5`, không dùng `-t 0,5`.

## Cách dùng: ảnh mẫu, nguồn, kết quả

```bash
findface -r <ảnh mẫu...> -i <nguồn...> -o <thư mục kết quả>
```

(Nếu đang đứng trong thư mục công cụ thì thay `findface` bằng `./findface`.)

- `-r` ảnh mẫu: các file ảnh, một thư mục, hoặc file zip. **Nên dùng 3–10 ảnh, mỗi ảnh một cảnh khác nhau**
  (khác chỗ, khác ánh sáng, khác góc mặt). Ảnh mẫu có lẫn người khác cũng được (xem "Ảnh mẫu có nhiều người").
- `-i` nguồn: thư mục (quét cả thư mục con và file zip bên trong), file ảnh, file zip (đọc thẳng, không cần
  giải nén). Hỗ trợ JPG, PNG, WEBP, HEIC/HEIF (iPhone), TIFF, BMP.
- `-o` kết quả: ảnh khớp được **sao chép** vào đây (ảnh gốc giữ nguyên).

### Ví dụ

```bash
# Ảnh mẫu để trong một thư mục, quét các file zip tải về hôm nay trong Downloads
findface -r ~/Desktop/AnhMau -i ~/Downloads/*.zip --since today -o ~/Desktop/"Kết quả"

# Giải nén zip ra thư mục rồi lọc
findface -r ~/Desktop/AnhMau -i ~/Downloads/*.zip --extract-to ~/Downloads/AnhSuKien -o ~/Desktop/"Kết quả"

# Vài ảnh mẫu cụ thể, quét cả thư mục Pictures
findface -r ~/Desktop/mau1.jpg ~/Desktop/mau2.jpg ~/Desktop/mau3.jpg -i ~/Pictures -o ~/Desktop/AnhCuaToi
```

## Kết quả

Mỗi ảnh có một **điểm** từ 0 đến 1 cho biết khuôn mặt giống người cần tìm đến đâu (càng cao càng giống).
Ảnh có điểm từ ngưỡng trở lên (mặc định 0.475, đổi bằng `-t`) được coi là khớp.

```
<thư mục kết quả>/
  *.JPG               ảnh khớp (điểm ≥ ngưỡng)
  Cần kiểm tra/       ảnh không chắc chắn, nên xem bằng mắt (thường là ảnh mờ, xa, nghiêng)
  _báo cáo/
    anh_mau.jpg       khuôn mặt đã dùng từ mỗi ảnh mẫu (xem để chắc chắn đúng người)
    khop.jpg          mặt trong các ảnh khớp, kèm điểm (rà nhanh xem có ảnh nhầm không)
    can_kiem_tra.jpg  mặt trong các ảnh cần kiểm tra
    chon_nguoi.jpg    (chỉ khi ảnh mẫu mơ hồ) các ứng viên để chọn người cần tìm
    ket_qua.csv       điểm của tất cả ảnh (mở bằng Excel/Numbers)
```

## Ảnh mẫu có nhiều người

Công cụ tự chọn người **xuất hiện nhất quán qua các ảnh mẫu** và có mặt to, rõ. Khi không chắc chắn
(ví dụ vài ảnh nhóm chụp liên tiếp, nơi mọi người đều có mặt trong tất cả ảnh; hoặc 1 ảnh có 2 người
mặt to như nhau), công cụ dừng lại **trước khi quét** và tạo `_báo cáo/chon_nguoi.jpg`: mỗi hàng là một người.

- Chạy trong Terminal: ảnh `chon_nguoi.jpg` được mở ra, bạn nhập số thứ tự người cần tìm (nhấn Enter là chọn
  người #1).
- Chạy không tương tác (script): dùng `--pick N` để chọn người số N, hoặc `-y` để chấp nhận người #1.

## Tuỳ chọn hay dùng

| Tuỳ chọn | Ý nghĩa |
|---|---|
| `--since today` / `3d` / `12h` / `2026-09-25` | Chỉ quét file được tải về/sửa từ thời điểm đó: `today` = từ 0 giờ hôm nay, `3d` = 3 ngày qua, `12h` = 12 giờ qua, hoặc một ngày cụ thể (năm-tháng-ngày). Tính theo ngày của file/zip, không phải ngày chụp |
| `-t 0.5` | Ngưỡng khớp (mặc định 0.475). Tăng để chặt hơn, giảm để tìm được nhiều hơn nhưng dễ lẫn người khác |
| `--review 0.4` | Điểm thấp nhất để ảnh được đưa vào "Cần kiểm tra" (mặc định tự điều chỉnh, xem mục Kỹ thuật). Đặt bằng ngưỡng `-t` để tắt thư mục này |
| `--pick N`, `-y` | Chọn người khi ảnh mẫu mơ hồ (xem mục trên) |
| `--anchor TÊN_ẢNH` | Khi ảnh mẫu có nhiều người: lấy mặt lớn nhất trong ảnh mẫu này (ví dụ `IMG_0123.JPG`, phải là một trong các ảnh mẫu) làm người cần tìm |
| `--no-expand` | Tắt bước tự bổ sung ảnh mẫu (mặc định công cụ lấy thêm các ảnh khớp chắc chắn làm ảnh mẫu rồi chấm lại, để tìm thêm ảnh khác góc/ánh sáng) |
| `--dry-run` | Chỉ chấm điểm và tạo báo cáo, không chép ảnh |
| `--move` / `--link` | Di chuyển ảnh gốc / tạo lối tắt (symlink) trỏ về ảnh gốc, thay vì sao chép. Ảnh nằm trong file zip thì luôn được sao chép ra |
| `--extract-to DIR` | Giải nén toàn bộ ảnh trong zip ra DIR trước khi lọc (cần chỗ trống bằng tổng dung lượng ảnh trong các zip) |
| `--no-cache` | Không đọc/ghi cache "vân mặt" (xem mục "Chạy hoàn toàn trên máy") |
| `--workers N` | Số tiến trình chạy song song (mặc định tự chọn, xem mục Hiệu năng) |
| `--device cpu` | Không dùng GPU (mặc định dùng GPU của Mac qua CoreML nếu có; GPU lỗi thì tự chuyển sang CPU) |

Xem đầy đủ: `findface -h`.

## Mẹo

- **Chạy lại rất nhanh:** nhờ cache "vân mặt", đổi ảnh mẫu hoặc ngưỡng rồi chạy lại trên cùng nguồn chỉ mất
  vài giây.
- **Ảnh mẫu nên đa dạng:** 3 ảnh ở 3 cảnh khác nhau tốt hơn nhiều so với 10 ảnh chụp liên tiếp.
  Công cụ sẽ cảnh báo nếu các ảnh mẫu gần như giống hệt nhau.
- **Bổ sung ảnh mẫu:** chép vài ảnh đúng trong `Cần kiểm tra/` (nhất là góc nghiêng, ảnh mờ) vào thư mục
  ảnh mẫu rồi chạy lại.
- **Gỡ bỏ hoàn toàn:** xoá thư mục công cụ, thư mục `~/.cache/findface` và dòng alias trong `~/.zprofile`
  (nếu đã thêm).

## Độ chính xác (đã kiểm chứng)

Kiểm tra trên 1416 ảnh của một sự kiện đông người (~18.000 khuôn mặt), với 8 người khác nhau: 5 trẻ em
(mặc đồng phục giống nhau), 1 người dẫn chương trình đeo kính, 1 nam và 1 nữ người lớn. Đáp án được gán nhãn
bằng mắt qua nhiều vòng đối chiếu.

| Số ảnh mẫu | Độ chính xác (ảnh chọn ra đúng người) | Tìm được (trên tổng số ảnh có người đó) |
|---|---|---|
| 1 | ~97–98% | ~91–93% |
| 3 | ~99% | ~97% |
| 5–10 | ~99% | ~97% |

Với 1 ảnh mẫu, hai lần đo với các bộ ảnh mẫu chọn ngẫu nhiên khác nhau cho kết quả hơi khác nhau, nên ghi
dưới dạng khoảng. Tính cả thư mục "Cần kiểm tra" thì tìm được ~98%. Lỗi còn lại chủ yếu là trẻ trông rất giống
nhau, và ảnh có mặt quá mờ, quay nghiêng hẳn hoặc bị che.

Một lượt dùng thực tế với 15 ảnh mẫu của một em bé: tìm đủ **53/53** ảnh đã xác nhận có em, chỉ lẫn 2 ảnh
của một bé khác trông rất giống.

## Hiệu năng

Tốc độ phụ thuộc vào máy, độ phân giải ảnh, số khuôn mặt mỗi ảnh và việc máy có đang bận việc khác hay không.
Các số dưới đây là **số đo tham khảo** trên một máy thử nghiệm; dùng để ước lượng, rồi tự đo trên máy bạn
(xem "Lưu ý khi chạy trên máy của bạn").

- **Máy thử nghiệm:** Apple M1 (CPU 8 nhân: 4 hiệu năng + 4 tiết kiệm điện; GPU 8 nhân), RAM 16 GB.
- **Bộ ảnh:** 1416 ảnh JPEG 33MP (7008×4672) của một sự kiện đông người, tổng 13 GB trong 7 file zip
  (đọc thẳng, không giải nén). Có 18.399 khuôn mặt: trung bình 13 mặt mỗi ảnh, ảnh đông nhất 92 mặt.

| Tình huống | Thời gian | Ghi chú |
|---|---|---|
| Quét lần đầu toàn bộ 1416 ảnh, GPU, máy rảnh | **5 phút 8 giây** (~4,6 ảnh/giây) | Tính cả chép 62 ảnh kết quả |
| Quét lần đầu toàn bộ 1416 ảnh, GPU, máy đang bận | 11 phút 46 giây | macOS đang phân tích ảnh chạy nền (`mediaanalysisd` ~170% CPU); chạy trong sandbox chặn mạng |
| Quét lần đầu toàn bộ 1416 ảnh, chỉ dùng CPU | 17 phút 56 giây | 8 tiến trình (tương đương `--device cpu`) |
| Chạy lại toàn bộ 1416 ảnh (có cache) | **9 giây** | |
| Đổi ảnh mẫu rồi chạy lại (có cache) | **8 giây** | Không phải quét lại ảnh nào |

Số đo lúc máy rảnh và số đo CPU dùng một bản trước đó của công cụ, chỉ khác bản hiện tại ở chỗ còn lưu bộ nhớ
đệm model cho GPU (tiết kiệm ~1 giây mỗi lần chạy) và chưa tắt telemetry; phần xử lý ảnh giống hệt.

RAM dùng tối đa ~5,5 GB với 5 tiến trình con, tức khoảng 1 GB mỗi tiến trình (cộng bộ nhớ của tất cả tiến
trình, nên con số thật có thể thấp hơn vì phần dùng chung bị cộng trùng). Chặn mạng không làm chậm đi: đo đối
chứng trên 68 ảnh, mỗi kiểu chạy 2 lần, chạy thường được 38s và 30s, chặn mạng được 35s và 30s.

**Thời gian đi vào đâu** (một ảnh 33MP có 39 khuôn mặt):

| Bước | Thời gian |
|---|---|
| Giải mã ảnh và thu nhỏ về 2400px | 0,31 s/ảnh |
| Phát hiện khuôn mặt (YuNet) | 0,18 s/ảnh |
| Trích "vân mặt" (ArcFace) bằng CPU, 1 luồng | 157 ms/mặt |
| Trích "vân mặt" bằng CPU, 8 luồng | 66 ms/mặt |
| Trích "vân mặt" bằng GPU (CoreML) | **14 ms/mặt**, kết quả trùng với CPU (độ tương đồng 1,0000) |

Ảnh sự kiện trung bình có 13 khuôn mặt, nên bước trích "vân mặt" chiếm phần lớn thời gian. Chuyển bước này
sang GPU giúp cả lượt quét nhanh hơn ~3,5 lần (17 phút 56 giây xuống 5 phút 8 giây, cùng đo khi máy rảnh).

**Số tiến trình chạy song song** (80 ảnh, 1 ảnh mẫu, không cache, `--dry-run`):

| Cấu hình | 2 tiến trình | 3 | 4 | 5 | 6 | 8 |
|---|---|---|---|---|---|---|
| GPU | 32s | 26s | 24s | **22s** | 29s | 42s |
| CPU | — | — | — | — | — | 59s |

Nhiều tiến trình quá thì chúng tranh nhau GPU và chậm lại. Vì vậy khi chạy GPU, công cụ mặc định dùng nửa số
nhân CPU cộng 1, tối đa 6 (máy 8 nhân là 5); khi chỉ dùng CPU thì dùng hết số nhân. Thay đổi bằng
`--workers N` nếu cần.

### Lưu ý khi chạy trên máy của bạn

- **GPU:** trên Mac có GPU dùng được qua CoreML (như Apple M1 trở lên), lượt quét đầu nhanh hơn nhiều so với
  chỉ dùng CPU (~3,5 lần trên máy thử nghiệm). Nếu thấy dòng `Không dùng được GPU ... chuyển sang CPU`, kết quả
  vẫn đúng nhưng sẽ chậm hơn.
- **Máy đang bận có thể làm chậm gấp đôi:** sau khi bạn chép hoặc tải nhiều ảnh, macOS thường tự phân tích ảnh
  và lập chỉ mục Spotlight chạy nền (`mediaanalysisd`, `corespotlightd`). Mở Activity Monitor; nếu các tiến
  trình này đang chiếm nhiều CPU, đợi chúng xong rồi quét sẽ nhanh hơn. Với laptop, nên cắm sạc và tắt
  Chế độ nguồn điện thấp (Low Power Mode).
- **RAM:** mỗi tiến trình cần khoảng 1 GB. Nếu máy ít RAM, hoặc Activity Monitor báo Memory Pressure vàng/đỏ
  khi đang quét, giảm số tiến trình (ví dụ `--workers 3`).
- **Bộ ảnh của bạn:** thời gian tăng theo số ảnh, độ phân giải và số khuôn mặt mỗi ảnh. Ảnh ít người (ảnh gia
  đình, chân dung) nhanh hơn nhiều so với ảnh sự kiện đông người ở trên.
- **Ổ đĩa:** `--extract-to` cần chỗ trống bằng tổng dung lượng ảnh trong zip; cache tốn khoảng 20 MB cho 1400 ảnh.
- **Tự đo:** chạy thử trên một thư mục hoặc một file zip nhỏ với vài giá trị `--workers`. `--no-cache` để mỗi
  lần đều quét lại từ đầu, `--dry-run` để không chép ảnh; dòng cuối `Xong sau ...` cho biết thời gian:

  ```bash
  ./findface --no-cache --dry-run --workers 4 -r <ảnh mẫu> -i <một file zip> -o ~/Desktop/"findface - đo thử"
  ```

## Kỹ thuật

- Toàn bộ xử lý chạy trên máy (chạy được khi ngắt mạng) bằng OpenCV (đọc ảnh, phát hiện mặt) và ONNX Runtime
  (nhận diện, đã tắt telemetry), dùng GPU của Mac qua CoreML; nếu GPU lỗi sẽ tự chuyển sang CPU.
- Phát hiện khuôn mặt: YuNet (OpenCV Zoo), ảnh thu về cạnh dài 2400px.
- So khớp: ArcFace `w600k_r50` (bộ `buffalo_l` của InsightFace). Điểm = cosine giữa khuôn mặt và **tâm**
  (trung bình) các khuôn mặt mẫu; điểm ảnh = khuôn mặt cao nhất trong ảnh.
- Tự bổ sung ảnh mẫu: sau lượt đầu, khuôn mặt trong các ảnh khớp chắc chắn (≥ 0.60) được thêm vào tâm rồi chấm
  lại, giúp bắt được ảnh khác góc/ánh sáng (tăng ~6% số ảnh tìm được khi chỉ có 1 ảnh mẫu).
- "Cần kiểm tra" tự điều chỉnh: điểm thấp nhất = trung bình + 3 độ lệch chuẩn của điểm toàn bộ khuôn mặt
  (gần như toàn là người khác), giới hạn trong 0.40–0.475. Trẻ em cùng lớp trông giống nhau nên mức này cao
  (ít ảnh rác); với người lớn thì thấp hơn, giữ lại các ảnh khó.
