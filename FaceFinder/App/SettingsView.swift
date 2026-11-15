import FaceFinderKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var language = UILanguage.current

    var body: some View {
        Form {
            Section("Giao diện") {
                Picker("Ngôn ngữ giao diện", selection: Binding(get: { language }, set: { language = $0; UILanguage.apply($0) })) {
                    ForEach(UILanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                }
                if language.rawValue != UILanguage.active, language != .system {
                    HStack {
                        Text("Ngôn ngữ mới có hiệu lực khi mở lại app.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Mở lại app") { UILanguage.relaunch() }
                    }
                }
            }
            Section("Dữ liệu khuôn mặt") {
                LabeledContent("Chỉ mục") {
                    let size = ByteCountFormatter.string(fromByteCount: model.index.fileSize(), countStyle: .file)
                    Text(String(localized: "\(model.totalStats.indexed.formatted()) ảnh · \(model.totalStats.faces.formatted()) khuôn mặt · \(size)"))
                }
                LabeledContent("Người đã lưu") { Text("\(model.people.count)") }
                Button("Xoá toàn bộ dữ liệu khuôn mặt…", role: .destructive) { confirmClear = true }
                Text("Chỉ mục và khuôn mặt mẫu chỉ nằm trên máy này, trong thư mục riêng của app. Thư mục kết quả đã ghi ra không bị ảnh hưởng.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Riêng tư") {
                Text("Face Finder chạy hoàn toàn trên máy. App được macOS chạy trong sandbox không có quyền truy cập mạng, và chỉ đọc/ghi được những thư mục bạn tự chọn hoặc kéo thả vào.")
                    .font(.callout)
            }
            Section("Giấy phép") {
                Text("Model nhận diện ArcFace của InsightFace chỉ được dùng cho mục đích phi thương mại. Phát hiện khuôn mặt: YuNet (OpenCV Zoo, MIT). Giải mã JPEG: libjpeg-turbo.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Xoá toàn bộ dữ liệu khuôn mặt?", isPresented: $confirmClear) {
            Button("Xoá", role: .destructive) { model.clearAllFaceData() }
        } message: {
            Text("Xoá chỉ mục và mọi người đã lưu. Lần tìm sau app sẽ phải lập chỉ mục lại từ đầu.")
        }
    }
}
