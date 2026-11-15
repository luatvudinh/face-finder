import FaceFinderKit
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sources.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(model.sources) { source in
                            SourceRow(source: source, stats: model.stats[source.id])
                                .contextMenu {
                                    Button("Hiện trong Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
                                    }
                                    Divider()
                                    Button("Bỏ khỏi thư viện", role: .destructive) { model.remove(source) }
                                }
                        }
                    } header: {
                        summary
                    } footer: {
                        Text("Kéo thả thêm thư mục ảnh hoặc file zip vào đây. Thư mục được quét cả thư mục con; ảnh trong zip được đọc thẳng, không cần giải nén.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            if model.indexing != nil || model.lastIndexing != nil {
                Divider()
                IndexingBar()
                    .padding(12)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Thư viện ảnh")
        .toolbar {
            ToolbarItem {
                Button { model.rescan() } label: { Label("Quét lại", systemImage: "arrow.clockwise") }
                    .help("Tìm ảnh mới hoặc đã thay đổi trong các nguồn (app cũng tự làm khi thư mục nguồn thay đổi)")
                    .disabled(model.sources.isEmpty)
            }
            ToolbarItem {
                Button { model.chooseSources() } label: { Label("Thêm nguồn ảnh", systemImage: "plus") }
                    .help("Thêm thư mục ảnh hoặc file zip")
            }
        }
    }

    private var summary: some View {
        let t = model.totalStats
        return HStack {
            Text("\(model.sources.count) nguồn · \(t.images.formatted()) ảnh · \(t.faces.formatted()) khuôn mặt")
            Spacer()
            if model.people.isEmpty, t.indexed > 0, model.indexing == nil {
                Button("Thêm người cần tìm…") { model.showNewPerson = true }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Kéo thả thư mục ảnh hoặc file zip vào đây").font(.title2)
            Text("Face Finder lập chỉ mục khuôn mặt một lần, sau đó tìm ảnh của bất kỳ ai chỉ trong vài giây.\nMọi thứ chạy trên máy này; app không có quyền truy cập mạng.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Chọn thư mục hoặc file zip…") { model.chooseSources() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: SourceRecord
    let stats: SourceStats?
    @State private var showBroken = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isZip ? "doc.zipper" : "folder")
                .font(.title2).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.headline).lineLimit(1)
                Text((source.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(stats?.problems ?? [], id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
            Spacer()
            status
        }
        .padding(.vertical, 4)
        .popover(isPresented: $showBroken, arrowEdge: .trailing) { BrokenList(items: model.brokenImages(in: source)) }
    }

    @ViewBuilder private var status: some View {
        if !FileManager.default.fileExists(atPath: source.path) {
            Label("Không tìm thấy", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if let s = stats {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(s.images.formatted()) ảnh").monospacedDigit()
                Group {
                    if s.indexed < s.images {
                        Text("đã lập chỉ mục \(s.indexed.formatted())/\(s.images.formatted())")
                    } else {
                        Text("\(s.faces.formatted()) khuôn mặt")
                    }
                    if s.errors > 0 {
                        Button("\(s.errors) ảnh không đọc được…") { showBroken = true }
                            .buttonStyle(.link).foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Danh sách ảnh không đọc được của một nguồn, kèm lý do.
struct BrokenList: View {
    let items: [(name: String, path: String, reason: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ảnh không đọc được (\(items.count))").font(.headline)
            Text("Các ảnh này bị bỏ qua khi tìm. Nếu ảnh được chép lại hoặc tải lại, app sẽ tự đọc lại.")
                .font(.caption).foregroundStyle(.secondary)
            List(items, id: \.path) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout.bold())
                    Text(item.reason).font(.caption)
                    Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(width: 440, height: min(360, CGFloat(items.count) * 58 + 20))
        }
        .padding(14)
    }
}

struct IndexingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.indexing {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    switch p.phase {
                    case .listing:
                        Text("Đang liệt kê ảnh…")
                        ProgressView().progressViewStyle(.linear)
                    case .loadingModels:
                        Text("Đang nạp model nhận diện…")
                        ProgressView().progressViewStyle(.linear)
                    case .analyzing:
                        Text(p.paused ? String(localized: "Đã tạm dừng") : String(localized: "Đang lập chỉ mục khuôn mặt"))
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                        Text(detail(p)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if p.phase == .analyzing {
                    Button(p.paused ? String(localized: "Tiếp tục") : String(localized: "Tạm dừng")) { model.setPaused(!p.paused) }
                }
                Button("Huỷ") { model.cancelIndexing() }
            }
        } else if let last = model.lastIndexing {
            HStack {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(last).foregroundStyle(.secondary)
                Spacer()
                if model.totalStats.indexed < model.totalStats.images {
                    Button("Lập chỉ mục") { model.startIndexing() }
                }
            }
        }
    }

    private func detail(_ p: IndexingProgress) -> String {
        var s = String(localized: "\(p.done.formatted())/\(p.total.formatted()) ảnh")
        if p.rate > 0 { s += String(format: String(localized: " · %.1f ảnh/giây"), p.rate) }
        if let r = p.remaining, !p.paused { s += String(localized: " · còn khoảng \(AppModel.duration(r))") }
        return s
    }
}
