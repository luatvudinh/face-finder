import FaceFinderKit
import SwiftUI

struct NewPersonSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ownDraft = NewPersonModel()
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool

    private var draft: NewPersonModel {
        #if DEBUG || SELFTEST
        if let d = model.selfTestDraft { return d }
        #endif
        return ownDraft
    }

    var body: some View {
        @Bindable var draft = draft
        VStack(alignment: .leading, spacing: 16) {
            Text("Thêm người cần tìm").font(.title2.bold())

            TextField("Tên (vd. Bé Gấu)", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)

            references
                .frame(minHeight: 260)

            output

            HStack {
                if model.sources.isEmpty {
                    Label("Thư viện chưa có ảnh nào. Thêm nguồn ảnh trước.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Huỷ") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Tạo và tìm ảnh") {
                    if let p = draft.create(model) {
                        model.selection = .person(p.id)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canCreate || model.sources.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 720)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder private var references: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ảnh mẫu").font(.headline)
                Spacer()
                if !draft.referenceURLs.isEmpty {
                    Button("Thêm ảnh…") { draft.chooseReferences(model) }
                    Button("Xoá hết") { draft.clear() }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                    .strokeBorder(dropTargeted ? Color.accentColor : .secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 3 : 1, dash: [6]))
                content.padding(12)
            }
            .dropDestination(for: URL.self) { urls, _ in
                draft.add(urls, model: model)
                return true
            } isTargeted: { dropTargeted = $0 }
        }
    }

    @ViewBuilder private var content: some View {
        switch draft.phase {
        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "person.crop.rectangle.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Kéo thả vài ảnh rõ mặt của người cần tìm vào đây")
                Text("Nên có từ 3 ảnh trở lên, ở nhiều góc mặt và cảnh khác nhau. Ảnh có nhiều người cũng được: app tự tìm người xuất hiện nhất quán.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Chọn ảnh mẫu…") { draft.chooseReferences(model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .analyzing(let message):
            VStack(spacing: 10) {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Chọn ảnh khác…") { draft.clear(); draft.chooseReferences(model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            identities
        }
    }

    private var identities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.callout).foregroundStyle(draft.ambiguous ? .orange : .secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(draft.identities) { identity in
                        IdentityRow(identity: identity, rank: identity.id + 1, total: draft.usableCount,
                                    selected: draft.chosen == identity.id)
                            .contentShape(Rectangle())
                            .onTapGesture { draft.chosen = identity.id }
                    }
                }
            }
            if !draft.noFace.isEmpty {
                Text("Không thấy khuôn mặt trong: \(draft.noFace.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var headline: String {
        let n = draft.imageCount
        if draft.ambiguous {
            return String(localized: "Ảnh mẫu có nhiều người cùng xuất hiện — bấm vào hàng của người cần tìm (#1 là khả năng cao nhất).")
        }
        if draft.usableCount < 3 {
            return String(localized: "\(n) ảnh mẫu. Đã chọn sẵn người #1. Nên thêm ảnh (ít nhất 3) để tìm chính xác hơn.")
        }
        return String(localized: "\(n) ảnh mẫu. App đề xuất người #1; bấm vào hàng khác nếu chọn sai.")
    }

    private var output: some View {
        let base = draft.outputBase ?? model.defaultOutputBase
        let folderName = ResultFolder.folderName(for: draft.name.isEmpty ? String(localized: "<tên>") : draft.name)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Lưu kết quả vào").font(.headline)
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(base.map { (($0.path as NSString).abbreviatingWithTildeInPath as NSString).appendingPathComponent(folderName) } ?? "—")
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Chọn…") {
                    if let url = model.access.askForFolder(at: base, message: String(localized: "Chọn nơi lưu kết quả."), prompt: String(localized: "Chọn")) {
                        model.rememberGrant(url)
                        draft.outputBase = url
                    }
                }
                Button("Mở trong Finder") {
                    if let base { NSWorkspace.shared.open(base) }
                }
                .disabled(base == nil)
            }
            Text("Ảnh khớp được chép vào đây (ảnh gốc giữ nguyên); ảnh cần xem lại nằm trong thư mục con “Cần kiểm tra”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct IdentityRow: View {
    let identity: IdentityPreview
    let rank: Int
    let total: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(selected ? Color.accentColor : .secondary)
            Text("#\(rank)").font(.headline.monospacedDigit()).frame(width: 30)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(identity.references.enumerated()), id: \.offset) { _, ref in
                        FaceThumb(data: ref.thumbnail, size: 64).help(ref.imageName)
                    }
                }
            }
            Spacer()
            Text("có mặt trong \(identity.coverCount)/\(total) ảnh").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
    }
}
