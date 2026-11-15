import FaceFinderKit
import QuickLook
import SwiftUI

/// Một nhóm ảnh trên màn hình kết quả.
private struct ResultGroup {
    /// Khoá bền vững (lưu trạng thái thu gọn).
    let id: String
    let title: String
    let scores: [ItemScore]
    let status: MatchStatus
    let empty: String?
}

struct PersonView: View {
    @Environment(AppModel.self) private var model
    let person: PersonRecord
    @State private var showAllBelow = false
    /// Các ảnh đang chọn (Cmd+bấm: thêm/bớt; Shift+bấm: chọn cả dải).
    @State private var selection: Set<String> = []
    /// Ảnh "đang đứng" (phím mũi tên, Space xem lớn).
    @State private var cursor: String?
    /// Mốc của Shift+bấm / Shift+mũi tên.
    @State private var anchor: String?
    @State private var previewURL: URL?
    @State private var gridWidth: CGFloat = 800
    @FocusState private var gridFocused: Bool
    /// Nhóm đang thu gọn (nhớ giữa các lần mở app).
    @AppStorage("collapsedGroups") private var collapsedRaw = ""

    private var session: PersonSession? { model.sessions[person.id] }

    private static let tileWidth: CGFloat = FaceTile.width, spacing: CGFloat = 12

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggleCollapsed(_ id: String) {
        var c = collapsed
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        withAnimation(.easeOut(duration: 0.2)) { collapsedRaw = c.sorted().joined(separator: ",") }
        // ảnh trong nhóm vừa thu gọn không còn chọn được bằng bàn phím
        if let result = session?.result, c.contains(id), let g = groups(result).first(where: { $0.id == id }) {
            let hidden = Set(g.scores.map(\.item.key))
            selection.subtract(hidden)
            if let cur = cursor, hidden.contains(cur) { cursor = nil }
        }
    }

    /// Các nhóm theo thứ tự trên màn hình.
    private func groups(_ result: SearchResult) -> [ResultGroup] {
        let below = result.scores.filter { $0.score >= 0 && result.status(of: $0) == .none }
        return [
            ResultGroup(id: "matched", title: String(localized: "Khớp"), scores: result.matched, status: .matched,
                        empty: String(localized: "Chưa có ảnh nào đạt ngưỡng.")),
            ResultGroup(id: "review", title: String(localized: "Cần kiểm tra"), scores: result.needsReview, status: .review,
                        empty: String(localized: "Không có ảnh nào ở vùng cần kiểm tra.")),
            ResultGroup(id: "below", title: String(localized: "Dưới ngưỡng (giống nhất)"),
                        scores: Array(below.prefix(showAllBelow ? 200 : 24)), status: .none, empty: nil),
            ResultGroup(id: "rejected", title: String(localized: "Đã loại (✗)"), scores: result.rejectedScores, status: .rejected, empty: nil),
        ]
    }

    /// Ảnh đang hiện (không tính nhóm thu gọn), theo thứ tự trên màn hình.
    private var visible: [ItemScore] {
        guard let result = session?.result else { return [] }
        return groups(result).filter { !collapsed.contains($0.id) }.flatMap(\.scores)
    }

    private var selectedScores: [ItemScore] { visible.filter { selection.contains($0.item.key) } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let session {
                        OutputBar(person: person, session: session)
                        if let result = session.result {
                            ThresholdBar(session: session, result: result)
                            notes(session, result)
                            ForEach(groups(result), id: \.id) { g in
                                group(g, session: session)
                            }
                            let belowCount = result.scores.filter { $0.score >= 0 && result.status(of: $0) == .none }.count
                            if !showAllBelow, belowCount > 24, !collapsed.contains("below") {
                                Button("Hiện thêm ảnh dưới ngưỡng") { showAllBelow = true }
                            }
                            HistoryView(history: session.history)
                        } else {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(model.isIndexing ? String(localized: "Đang chờ lập chỉ mục…") : String(localized: "Đang tìm…")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, selection.count > 1 ? 56 : 0)  // chừa chỗ cho thanh thao tác
                .frame(maxWidth: .infinity, alignment: .leading)
                // bấm vào chỗ trống (không phải ô ảnh hay nút) thì bỏ chọn
                .contentShape(Rectangle())
                .onTapGesture { clearSelection(); gridFocused = true }
                .background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
            }
            .onPreferenceChange(WidthKey.self) { gridWidth = $0 - 40 }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, proxy: proxy) }
            .onChange(of: cursor) { _, key in
                if previewURL != nil, let key { Task { await preview(key) } }
            }
        }
        .overlay(alignment: .bottom) {
            if selection.count > 1, let session {
                SelectionBar(count: selection.count,
                             onMark: { session.mark(selectedScores, correct: $0, model: model) },
                             onClear: { clearSelection() })
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection.count > 1)
        .quickLookPreview($previewURL)
        .navigationTitle(person.name)
        .toolbar {
            ToolbarItem {
                Button { session?.search(model) } label: { Label("Tìm lại", systemImage: "arrow.clockwise") }
                    .help("Tìm lại trong toàn bộ thư viện")
            }
        }
        .task(id: model.libraryVersion) { session?.refreshIfNeeded(model) }
        .onAppear { gridFocused = true }
    }

    // MARK: chọn

    private func clearSelection() {
        selection = []
        cursor = nil
        anchor = nil
    }

    /// Các ảnh từ `a` tới `b` (theo thứ tự trên màn hình).
    private func range(from a: String, to b: String) -> Set<String> {
        let keys = visible.map(\.item.key)
        guard let i = keys.firstIndex(of: a), let j = keys.firstIndex(of: b) else { return [b] }
        return Set(keys[min(i, j)...max(i, j)])
    }

    /// Bấm vào một ảnh: thường = chọn riêng ảnh đó; Cmd = thêm/bớt; Shift = chọn cả dải từ mốc.
    private func click(_ key: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let a = anchor {
            let r = range(from: a, to: key)
            selection = flags.contains(.command) ? selection.union(r) : r
        } else if flags.contains(.command) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
            anchor = key
        } else {
            selection = [key]
            anchor = key
        }
        cursor = key
        gridFocused = true
    }

    /// Đánh dấu từ nút / menu của một ô: nếu ô đó nằm trong nhóm đang chọn thì áp dụng cho cả nhóm.
    private func targets(for s: ItemScore) -> [ItemScore] {
        selection.contains(s.item.key) && selection.count > 1 ? selectedScores : [s]
    }

    // MARK: bàn phím

    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let result = session?.result, let session else { return .ignored }
        // Cmd+A: chọn tất cả ảnh đang hiện. Các tổ hợp Cmd/Ctrl/Option khác là phím tắt của menu.
        if press.modifiers.contains(.command), press.characters.lowercased() == "a", press.phase == .down {
            selection = Set(visible.map(\.item.key))
            if cursor == nil { cursor = visible.first?.item.key }
            anchor = anchor ?? cursor
            return .handled
        }
        if !press.modifiers.intersection([.command, .control, .option]).isEmpty { return .ignored }
        let extend = press.modifiers.contains(.shift)
        let columns = max(1, Int((gridWidth + Self.spacing) / (Self.tileWidth + Self.spacing)))
        // các hàng của lưới, theo từng nhóm đang mở (mỗi nhóm bắt đầu hàng mới)
        var rows: [[ItemScore]] = []
        for g in groups(result) where !g.scores.isEmpty && !collapsed.contains(g.id) {
            rows += stride(from: 0, to: g.scores.count, by: columns).map { Array(g.scores[$0..<min($0 + columns, g.scores.count)]) }
        }
        let list = rows.flatMap { $0 }
        let current = cursor.flatMap { key in list.firstIndex { $0.item.key == key } }
        let position: (row: Int, column: Int)? = cursor.flatMap { key in
            for (r, row) in rows.enumerated() { if let c = row.firstIndex(where: { $0.item.key == key }) { return (r, c) } }
            return nil
        }
        func go(_ s: ItemScore) -> KeyPress.Result {
            let key = s.item.key
            if extend, let a = anchor ?? cursor {
                anchor = a
                selection = range(from: a, to: key)
            } else {
                selection = [key]
                anchor = key
            }
            cursor = key
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key) }
            return .handled
        }
        func step(_ delta: Int) -> KeyPress.Result {
            guard !list.isEmpty else { return .ignored }
            guard let i = current else { return go(list[delta > 0 ? 0 : list.count - 1]) }
            return go(list[min(max(i + delta, 0), list.count - 1)])
        }
        func vertical(_ delta: Int) -> KeyPress.Result {
            guard !rows.isEmpty else { return .ignored }
            guard let p = position else { return go(list[0]) }
            let r = min(max(p.row + delta, 0), rows.count - 1)
            return go(rows[r][min(p.column, rows[r].count - 1)])
        }
        /// Ảnh sẽ được đánh dấu: các ảnh đang chọn, hoặc ảnh đang đứng.
        var marked: [ItemScore] {
            if !selection.isEmpty { return selectedScores }
            return current.map { [list[$0]] } ?? []
        }
        switch press.key {
        case .leftArrow: return step(-1)
        case .rightArrow: return step(1)
        case .upArrow: return vertical(-1)
        case .downArrow: return vertical(1)
        case .escape:
            guard press.phase == .down else { return .handled }
            if previewURL != nil { previewURL = nil } else if !selection.isEmpty || cursor != nil { clearSelection() } else { return .ignored }
            return .handled
        case .space:
            guard press.phase == .down else { return .handled }
            if previewURL != nil { previewURL = nil } else if let key = cursor ?? list.first?.item.key {
                cursor = key
                if selection.isEmpty { selection = [key]; anchor = key }
                Task { await preview(key) }
            }
            return .handled
        case .delete, .deleteForward:
            guard press.phase == .down, !marked.isEmpty else { return .ignored }
            session.mark(marked, correct: nil, model: model)
            return .handled
        default:
            guard press.phase == .down, !marked.isEmpty else { return .ignored }
            let correct: Bool
            switch press.characters.lowercased() {
            case "d", "y", "=", "+": correct = true   // Đúng
            case "s", "n", "-", "x": correct = false  // Sai
            default: return .ignored
            }
            let many = marked.count > 1
            session.mark(marked, correct: correct, model: model)
            return many ? .handled : step(1)  // đánh dấu từng ảnh thì chuyển sang ảnh kế tiếp cho nhanh
        }
    }

    private func preview(_ key: String) async {
        guard let item = visible.first(where: { $0.item.key == key })?.item else { return }
        previewURL = await PreviewFiles.url(for: item)
    }

    // MARK: các phần

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.largeTitle.bold())
                Text("\(person.references.count) khuôn mặt mẫu").foregroundStyle(.secondary)
                let confirmed = person.marks.filter(\.correct).count, rejected = person.marks.count - confirmed
                if !person.marks.isEmpty {
                    HStack(spacing: 8) {
                        Text("Đã đánh dấu: \(confirmed) đúng, \(rejected) sai").foregroundStyle(.secondary)
                        Button("Bỏ hết") { session?.clearMarks(model) }.buttonStyle(.link)
                    }
                    .font(.callout)
                }
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
            session.notIndexed > 0 ? String(localized: "\(session.notIndexed.formatted()) ảnh trong thư viện chưa được lập chỉ mục nên chưa được tìm.") : nil,
            result.expandedBy > 0 ? String(localized: "Đã tự dùng thêm \(result.expandedBy) ảnh khớp chắc chắn làm mẫu để tìm được nhiều hơn.") : nil,
            String(localized: "Bấm chọn ảnh (Cmd hoặc Shift để chọn nhiều) rồi nhấn D (đúng) hoặc S (sai) để dạy thêm cho app, Space để xem ảnh lớn, phím mũi tên để chuyển ảnh."),
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func group(_ g: ResultGroup, session: PersonSession) -> some View {
        if !g.scores.isEmpty || g.empty != nil {
            let isCollapsed = collapsed.contains(g.id)
            VStack(alignment: .leading, spacing: 10) {
                // tiêu đề nhóm: bấm để thu gọn / mở rộng
                Button { toggleCollapsed(g.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 14)
                        Text(verbatim: "\(g.title) (\(g.scores.count))").font(.title3.bold())
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? String(localized: "Mở rộng") : String(localized: "Thu gọn"))
                if !isCollapsed {
                    if g.scores.isEmpty, let empty = g.empty {
                        Text(empty).foregroundStyle(.secondary).padding(.leading, 20)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth + 40), spacing: Self.spacing)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(g.scores, id: \.item.key) { s in
                                FaceTile(score: s, status: g.status, mark: session.mark(of: s, in: model),
                                         selected: selection.contains(s.item.key),
                                         batch: selection.contains(s.item.key) ? selection.count : 1,
                                         onSelect: { click(s.item.key) },
                                         onOpen: { selection = [s.item.key]; anchor = s.item.key; cursor = s.item.key
                                                   Task { await preview(s.item.key) } },
                                         onMark: { session.mark(targets(for: s), correct: $0, model: model) })
                                    .id(s.item.key)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
    }
}

/// Thanh thao tác khi chọn nhiều ảnh.
struct SelectionBar: View {
    let count: Int
    let onMark: (Bool?) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Đã chọn \(count) ảnh").font(.callout.weight(.medium)).monospacedDigit()
            Divider().frame(height: 18)
            Button { onMark(true) } label: { Label("Đúng người này", systemImage: "checkmark") }
                .tint(.green)
                .help("Đánh dấu tất cả ảnh đang chọn là đúng người này (D)")
            Button { onMark(false) } label: { Label("Không phải", systemImage: "xmark") }
                .tint(.red)
                .help("Đánh dấu tất cả ảnh đang chọn là không phải người này (S)")
            Button("Bỏ đánh dấu") { onMark(nil) }
            Divider().frame(height: 18)
            Button("Bỏ chọn") { onClear() }
                .help("Bỏ chọn (Esc)")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct HistoryView: View {
    let history: [SearchRecord]
    @State private var expanded = false

    var body: some View {
        if !history.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Text("Thời gian"); Text("Ảnh đã tìm"); Text("Khớp"); Text("Cần kiểm tra"); Text("Ngưỡng")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(history) { h in
                        GridRow {
                            Text(h.at.formatted(date: .abbreviated, time: .shortened))
                            Text(h.images.formatted())
                            Text(h.matched.formatted())
                            Text(h.review.formatted())
                            Text(String(format: "%.3f", h.threshold))
                        }
                        .monospacedDigit()
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Lịch sử tìm (\(history.count))").font(.headline)
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
                Text(person.outputFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Chưa chọn nơi lưu kết quả"))
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
            .disabled(session.isWriting)
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
    /// Đánh dấu của người dùng: true = ✓, false = ✗, nil = chưa.
    let mark: Bool?
    let selected: Bool
    /// Số ảnh mà nút ✓/✗ và menu của ô này sẽ áp dụng (lớn hơn 1 khi ô nằm trong nhóm đang chọn).
    var batch: Int = 1
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onMark: (Bool?) -> Void
    @State private var image: NSImage?
    @State private var loaded = false
    @State private var hovering = false

    init(score: ItemScore, status: MatchStatus, mark: Bool?, selected: Bool, batch: Int = 1, onSelect: @escaping () -> Void,
         onOpen: @escaping () -> Void, onMark: @escaping (Bool?) -> Void, previewImage: NSImage? = nil, previewHover: Bool = false) {
        self.score = score; self.status = status; self.mark = mark; self.selected = selected; self.batch = batch
        self.onSelect = onSelect; self.onOpen = onOpen; self.onMark = onMark
        _image = State(initialValue: previewImage)
        _loaded = State(initialValue: previewImage != nil)
        _hovering = State(initialValue: previewHover)
    }

    private static let size: CGFloat = 150
    private static let corner: CGFloat = 10
    /// Bề rộng cả ô (ảnh + khoảng hở cho vòng chọn).
    static let width: CGFloat = size + 6

    /// Thanh ✓/✗ chỉ hiện khi rê chuột hoặc đang chọn ảnh, để không che ảnh lúc rà nhanh.
    private var showControls: Bool { hovering || selected }

    var body: some View {
        VStack(spacing: 5) {
            thumbnail
            caption
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Chọn ngay ở lần bấm đầu (không chờ xem có bấm đúp không), lần bấm thứ hai mới mở xem lớn.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onOpen() } else { onSelect() }
        }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.spring(duration: 0.25), value: mark)
        .help(score.item.key.replacingOccurrences(of: "::", with: " › "))
        .contextMenu { menu }
        .task(id: score.item.key) {
            guard image == nil else { return }
            image = await ThumbnailLoader.shared.face(score)
            loaded = true
        }
    }

    // MARK: ảnh

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if !loaded {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .opacity(status == .rejected ? 0.4 : 1)  // ảnh đã loại: mờ đi nhưng giữ màu (huy hiệu ✗ vẫn rõ)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        // huy hiệu đánh dấu: nhỏ, ở góc (vùng nền của ảnh cắt quanh khuôn mặt), luôn hiện khi đã đánh dấu
        .overlay(alignment: .topTrailing) {
            if let mark, !showControls {
                MarkBadge(correct: mark).padding(7).transition(.scale.combined(with: .opacity))
            }
        }
        // thanh ✓/✗: ở mép dưới (vùng áo), không che mặt, không bị góc bo cắt
        .overlay(alignment: .bottom) {
            if showControls {
                controls.padding(.bottom, 8).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // ảnh đang chọn: một vòng mảnh cách ảnh một khoảng (như Photos), không chồng lên viền khác
        .padding(3)
        .overlay(RoundedRectangle(cornerRadius: Self.corner + 3, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .opacity(selected ? 1 : 0))
        .shadow(color: .black.opacity(hovering && !selected ? 0.22 : 0), radius: 6, y: 3)
        .scaleEffect(hovering && !selected ? 1.015 : 1)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            markButton(true)
            markButton(false)
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    private func markButton(_ correct: Bool) -> some View {
        let active = mark == correct
        let tint: Color = correct ? .green : .red
        return Button {
            onMark(active ? nil : correct)
        } label: {
            Image(systemName: correct ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : tint)
                .frame(width: 34, height: 24)
                .background(Capsule().fill(active ? tint : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(correct && score.face == nil)
        .help(correct ? (active ? String(localized: "Bỏ đánh dấu") : String(localized: "Đúng người này (D)"))
                      : (active ? String(localized: "Bỏ đánh dấu") : String(localized: "Không phải người này (S)")))
    }

    // MARK: chú thích

    private var caption: some View {
        VStack(spacing: 2) {
            // tên file: đang chọn thì tô nền như trong Finder
            Text(score.item.name)
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.clear))
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(String(format: String(localized: "%.3f · %d mặt"), score.score, score.faceCount))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .matched: return .green
        case .review: return .orange
        case .none: return .secondary.opacity(0.5)
        case .rejected: return .red
        }
    }

    @ViewBuilder private var menu: some View {
        if batch > 1 {
            Button("Đánh dấu \(batch) ảnh là đúng (D)") { onMark(true) }
            Button("Đánh dấu \(batch) ảnh là không phải (S)") { onMark(false) }
            Button("Bỏ đánh dấu \(batch) ảnh") { onMark(nil) }
        } else {
            Button("Đúng người này (D)") { onMark(true) }.disabled(score.face == nil)
            Button("Không phải (S)") { onMark(false) }
            if mark != nil { Button("Bỏ đánh dấu") { onMark(nil) } }
        }
        Divider()
        Button("Xem ảnh lớn (Space)") { onOpen() }
        if score.item.zipPath == nil {
            Button("Mở ảnh") { NSWorkspace.shared.open(URL(fileURLWithPath: score.item.key)) }
            Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: score.item.key)]) }
        } else {
            Button("Hiện file zip trong Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: score.item.zipPath!)])
            }
        }
    }
}

/// Huy hiệu nhỏ cho ảnh đã đánh dấu đúng (✓ xanh) / sai (✗ đỏ).
private struct MarkBadge: View {
    let correct: Bool

    var body: some View {
        Image(systemName: correct ? "checkmark" : "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(correct ? Color.green : Color.red))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
