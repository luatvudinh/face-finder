import FaceFinderKit
import SwiftUI

struct PersonView: View {
    @Environment(AppModel.self) private var model
    let person: PersonRecord
    @State private var showAllBelow = false

    private var session: PersonSession? { model.sessions[person.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let session {
                    OutputBar(person: person, session: session)
                    if let result = session.result {
                        ThresholdBar(session: session, result: result)
                        notes(session, result)
                        group("Khớp", result.matched, status: .matched, empty: "Chưa có ảnh nào đạt ngưỡng.")
                        group("Cần kiểm tra", result.needsReview, status: .review, empty: "Không có ảnh nào ở vùng cần kiểm tra.")
                        let below = result.scores.filter { $0.score >= 0 && Double($0.score) < result.review }
                        group("Dưới ngưỡng (giống nhất)", Array(below.prefix(showAllBelow ? 200 : 24)), status: .none, empty: nil)
                        if !showAllBelow, below.count > 24 {
                            Button("Hiện thêm") { showAllBelow = true }
                        }
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.isIndexing ? "Đang chờ lập chỉ mục…" : "Đang tìm…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(person.name)
        .toolbar {
            ToolbarItem {
                Button { session?.search(model) } label: { Label("Tìm lại", systemImage: "arrow.clockwise") }
                    .help("Tìm lại trong toàn bộ thư viện")
            }
        }
        .task(id: model.libraryVersion) { session?.refreshIfNeeded(model) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.largeTitle.bold())
                Text("\(person.references.count) khuôn mặt mẫu").foregroundStyle(.secondary)
            }
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(person.references.enumerated()), id: \.offset) { _, ref in
                        FaceThumb(data: ref.thumbnail, size: 56).help(ref.imageName)
                    }
                }
            }
            .frame(maxWidth: 420)
        }
    }

    @ViewBuilder private func notes(_ session: PersonSession, _ result: SearchResult) -> some View {
        let lines = [
            session.notIndexed > 0 ? "\(session.notIndexed.formatted()) ảnh trong thư viện chưa được lập chỉ mục nên chưa được tìm." : nil,
            result.expandedBy > 0 ? "Đã tự dùng thêm \(result.expandedBy) ảnh khớp chắc chắn làm mẫu để tìm được nhiều hơn." : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func group(_ title: String, _ scores: [ItemScore], status: MatchStatus, empty: String?) -> some View {
        if !scores.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) (\(scores.count))").font(.title3.bold())
                if scores.isEmpty, let empty {
                    Text(empty).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], alignment: .leading, spacing: 14) {
                        ForEach(scores, id: \.item.key) { s in
                            FaceTile(score: s, status: status)
                        }
                    }
                }
            }
        }
    }
}

struct ThresholdBar: View {
    @Environment(AppModel.self) private var model
    let session: PersonSession
    let result: SearchResult

    var body: some View {
        HStack(spacing: 14) {
            Text("Ngưỡng khớp")
            Slider(value: Binding(get: { session.threshold }, set: { session.setThreshold(($0 * 200).rounded() / 200, model: model) }),
                   in: 0.30...0.70)
                .frame(maxWidth: 320)
            Text(String(format: "%.3f", session.threshold)).monospacedDigit().frame(width: 50, alignment: .leading)
            Button("Mặc định") { session.setThreshold(SearchOptions().threshold, model: model) }
                .disabled(session.threshold == SearchOptions().threshold)
            Spacer()
            Text("\(result.matched.count) khớp · \(result.needsReview.count) cần kiểm tra (từ \(String(format: "%.3f", result.review)))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .help("Kéo sang phải để chặt hơn (ít ảnh nhầm), sang trái để tìm được nhiều hơn. Thư mục kết quả tự cập nhật theo.")
    }
}

struct OutputBar: View {
    @Environment(AppModel.self) private var model
    let person: PersonRecord
    let session: PersonSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.outputFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Chưa chọn nơi lưu kết quả")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                state.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.writeState == .needsPermission {
                Button("Cho phép ghi…") { session.grantAndWrite(model) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Mở trong Finder") {
                if let f = person.outputFolder {
                    let url = URL(fileURLWithPath: f)
                    if FileManager.default.fileExists(atPath: f) { NSWorkspace.shared.open(url) }
                    else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
                }
            }
            Menu("Khác") {
                Button("Chuyển kết quả sang…") { session.relocate(model, copy: false) }
                Button("Sao chép sang…") { session.relocate(model, copy: true) }
            }
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder private var state: some View {
        switch session.writeState {
        case .idle: Text("Kết quả được ghi tự động vào thư mục này.")
        case .writing: Text("Đang ghi kết quả…")
        case .done(let message): Text(message)
        case .needsPermission: Text("Cần bạn cho phép ghi vào thư mục này.").foregroundStyle(.orange)
        case .failed(let message): Text("Không ghi được: \(message)").foregroundStyle(.red)
        }
    }
}

struct FaceTile: View {
    let score: ItemScore
    let status: MatchStatus
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: status == .none ? 0 : 3))
            Text(score.item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(String(format: "%.3f · %d mặt", score.score, score.faceCount))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .help(score.item.key.replacingOccurrences(of: "::", with: " › "))
        .contextMenu {
            if score.item.zipPath == nil {
                Button("Mở ảnh") { NSWorkspace.shared.open(URL(fileURLWithPath: score.item.key)) }
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: score.item.key)]) }
            } else {
                Button("Hiện file zip trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: score.item.zipPath!)])
                }
            }
        }
        .task(id: score.item.key) {
            image = await ThumbnailLoader.shared.face(score)
            loaded = true
        }
    }

    private var color: Color {
        switch status {
        case .matched: return .green
        case .review: return .orange
        case .none: return .clear
        }
    }
}
