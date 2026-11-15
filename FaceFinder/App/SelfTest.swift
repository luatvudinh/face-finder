#if DEBUG || SELFTEST
import AppKit
import FaceFinderKit
import SwiftUI

/// Tự kiểm tra toàn luồng (chỉ có trong bản Debug hoặc build với cờ SELFTEST), dùng khi không có người bấm chuột:
///
///     FF_SELFTEST=/đường/dẫn/cấu_hình.json "Face Finder.app/Contents/MacOS/Face Finder"
///
/// Gọi đúng những hàm mà các nút bấm gọi: thêm nguồn → lập chỉ mục → thêm người từ ảnh mẫu → tìm → ghi thư mục kết
/// quả → kéo ngưỡng. Chụp cửa sổ của app ở từng bước (vẽ lại chính view của app, không cần quyền ghi màn hình).
/// Bỏ qua các hộp thoại xin quyền: coi như người dùng đã bấm "Cho phép" cho `outputBase`. Vì vậy phải chạy bản build
/// không sandbox (tools/app_selftest.sh); phần sandbox và quyền truy cập phải thử bằng tay.
///
/// Cấu hình: {"dataDir", "sources": [...], "references": [...], "name", "outputBase", "snapshots", "threshold2"}
@MainActor enum SelfTest {
    struct Config: Decodable {
        let sources: [String]
        let references: [String]
        let name: String
        let outputBase: String
        let snapshots: String
        let threshold2: Double?
    }

    static var configURL: URL? {
        ProcessInfo.processInfo.environment["FF_SELFTEST"].map { URL(fileURLWithPath: $0) }
    }

    /// Thư mục dữ liệu riêng cho lần tự kiểm tra (không đụng dữ liệu thật của app).
    static var dataDirectory: URL? {
        ProcessInfo.processInfo.environment["FF_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// FF_TILE_PREVIEW=ra.png FF_TILE_IMAGE=anh.jpg: vẽ ô ảnh ở các trạng thái ra PNG để xem giao diện, rồi thoát.
    static func renderTilePreview() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["FF_TILE_PREVIEW"] else { return }
        guard let path = env["FF_TILE_IMAGE"], let img = NSImage(contentsOfFile: path) else {
            log("thiếu FF_TILE_IMAGE hoặc không đọc được ảnh")
            exit(1)  // không được rơi xuống chạy app thật với dữ liệu thật
        }
        let item = ImageItem(key: "/x/PMH05570.JPG", zipPath: nil, member: nil, name: "PMH05570.JPG", size: 1, mtime: .distantPast, stamp: "")
        let face = FaceRecord(x: 0, y: 0, width: 1, height: 1, landmarks: [], detectionScore: 1, embedding: [])
        let s = ItemScore(item: item, score: 0.821, face: face, faceCount: 6)
        func tile(_ status: MatchStatus, mark: Bool?, selected: Bool, hover: Bool) -> some View {
            FaceTile(score: s, status: status, mark: mark, selected: selected, onSelect: {}, onOpen: {}, onMark: { _ in },
                     previewImage: img, previewHover: hover)
        }
        let grid = VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                tile(.matched, mark: nil, selected: false, hover: false)
                tile(.matched, mark: nil, selected: false, hover: true)
                tile(.matched, mark: nil, selected: true, hover: false)
                tile(.matched, mark: true, selected: false, hover: false)
            }
            SelectionBar(count: 5, onMark: { _ in }, onClear: {})
            HStack(alignment: .top, spacing: 12) {
                tile(.matched, mark: true, selected: true, hover: false)
                tile(.review, mark: nil, selected: false, hover: false)
                tile(.rejected, mark: false, selected: false, hover: false)
                tile(.none, mark: nil, selected: false, hover: true)
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        for (suffix, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let renderer = ImageRenderer(content: grid.environment(\.colorScheme, scheme))
            renderer.scale = 2
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
            }
        }
        exit(0)
    }

    static func run(_ model: AppModel) {
        renderTilePreview()
        guard let url = configURL else { return }
        Task {
            do {
                let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
                try await steps(model, config)
                log("SELFTEST OK")
                NSApp.terminate(nil)
            } catch {
                log("SELFTEST FAIL: \(error)")
                exit(1)
            }
        }
    }

    private static func steps(_ model: AppModel, _ c: Config) async throws {
        let shots = URL(fileURLWithPath: c.snapshots, isDirectory: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try await wait("cửa sổ", timeout: 20) { NSApp.windows.contains { $0.isVisible } }
        log("ngôn ngữ giao diện: \(Bundle.main.preferredLocalizations) (chọn: \(UILanguage.current.rawValue))")
        snapshot("0-trong", to: shots)

        // 1. Thêm nguồn (như kéo thả / "Thêm nguồn ảnh") và chờ lập chỉ mục
        let t0 = Date()
        model.add(c.sources.map { URL(fileURLWithPath: $0) })
        try await wait("bắt đầu lập chỉ mục", timeout: 10) { model.indexing?.phase == .analyzing || model.indexing == nil }
        if model.indexing != nil {
            try await Task.sleep(for: .seconds(8))
            snapshot("1-dang-lap-chi-muc", to: shots)
            model.setPaused(true)
            try await Task.sleep(for: .seconds(2))
            let pausedAt = model.indexing?.done ?? 0
            try await Task.sleep(for: .seconds(3))
            log("tạm dừng: \(pausedAt) -> \(model.indexing?.done ?? 0) ảnh sau 3 giây")
            model.setPaused(false)
        }
        try await wait("lập chỉ mục xong", timeout: 1800) { model.indexing == nil }
        let t = model.totalStats
        log("lập chỉ mục: \(t.images) ảnh, \(t.indexed) đã có, \(t.faces) mặt, \(t.errors) lỗi, \(Int(Date().timeIntervalSince(t0))) giây")
        snapshot("2-thu-vien", to: shots)

        // 2. Thêm người: sheet "Thêm người" với ảnh mẫu
        let draft = NewPersonModel()
        model.selfTestDraft = draft
        model.showNewPerson = true
        draft.name = c.name
        draft.add(c.references.map { URL(fileURLWithPath: $0) }, model: model)
        try await wait("phân tích ảnh mẫu", timeout: 120) {
            switch draft.phase {
            case .empty, .analyzing: return false
            default: return true
            }
        }
        guard draft.phase == .ready else { throw SelfTestError("ảnh mẫu: \(draft.phase)") }
        log("ảnh mẫu: \(draft.imageCount) ảnh, \(draft.identities.count) người, chọn #1 có \(draft.identities[0].references.count) mặt, mơ hồ: \(draft.ambiguous)")
        let base = URL(fileURLWithPath: c.outputBase, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        model.access.allowWriting(base)  // = người dùng đã bấm "Cho phép"
        draft.outputBase = base
        try await Task.sleep(for: .seconds(1))
        snapshot("3-them-nguoi", to: shots)
        guard let person = draft.create(model) else { throw SelfTestError("không tạo được người") }
        model.showNewPerson = false
        model.selfTestDraft = nil
        model.selection = .person(person.id)

        // 3. Kết quả + thư mục kết quả
        let session = try require(model.sessions[person.id], "phiên tìm")
        try await wait("tìm + ghi kết quả", timeout: 300) {
            if case .done = session.writeState { return true }
            if case .failed = session.writeState { return true }
            return session.writeState == .needsPermission
        }
        guard case .done(let message) = session.writeState else { throw SelfTestError("ghi kết quả: \(session.writeState)") }
        let r = try require(session.result, "kết quả")
        log("kết quả: \(r.matched.count) khớp, \(r.needsReview.count) cần kiểm tra (từ \(r.review)), mở rộng \(r.expandedBy); \(message)")
        log("thư mục kết quả: \(model.person(person.id)?.outputFolder ?? "-")")
        try await Task.sleep(for: .seconds(6))  // chờ ảnh khuôn mặt hiện
        snapshot("4-ket-qua", to: shots)

        // 4. Kéo ngưỡng: thư mục kết quả tự cập nhật
        if let t2 = c.threshold2 {
            session.setThreshold(t2, model: model)
            try await Task.sleep(for: .seconds(1.5))
            try await wait("ghi lại sau khi đổi ngưỡng", timeout: 120) {
                if case .done = session.writeState { return true }
                if case .failed = session.writeState { return true }
                return false
            }
            log("ngưỡng \(t2): \(session.result?.matched.count ?? -1) khớp; \(session.writeState)")
            try await Task.sleep(for: .seconds(3))
            snapshot("5-nguong-\(t2)", to: shots)
            session.setThreshold(SearchOptions().threshold, model: model)
            try await Task.sleep(for: .seconds(1.5))
            try await wait("trả ngưỡng mặc định", timeout: 120) {
                if case .done = session.writeState { return true }
                if case .failed = session.writeState { return true }
                return false
            }
            log("trả về ngưỡng mặc định: \(session.writeState)")
        }

        // 5. Đánh dấu ✓/✗: chấm lại tức thì, thư mục kết quả cập nhật theo
        let before = try require(session.result, "kết quả")
        if let review = before.needsReview.first, let wrong = before.matched.last {
            session.mark(review, correct: true, model: model)
            try await waitForWrite(session)
            session.mark(wrong, correct: false, model: model)
            try await waitForWrite(session)
            let after = try require(session.result, "kết quả sau đánh dấu")
            let files = model.person(person.id)?.outputFiles ?? []
            let reviewNowMatched = files.contains { $0.sourceKey == review.item.key && !$0.review }
            let wrongGone = !files.contains { $0.sourceKey == wrong.item.key }
            log("đánh dấu: ✓ \(review.item.name) (\(String(format: "%.3f", review.score))) -> khớp: \(reviewNowMatched); "
                + "✗ \(wrong.item.name) -> bỏ khỏi thư mục: \(wrongGone); khớp \(before.matched.count) -> \(after.matched.count), "
                + "đã loại \(after.rejectedScores.count)")
            guard reviewNowMatched, wrongGone, after.rejectedScores.map(\.item.key) == [wrong.item.key] else {
                throw SelfTestError("đánh dấu không có tác dụng như mong đợi")
            }
            try await Task.sleep(for: .seconds(3))
            snapshot("6-danh-dau", to: shots)
            session.clearMarks(model)
            try await waitForWrite(session)
            log("bỏ hết đánh dấu: \(session.result?.matched.count ?? -1) khớp, \(session.result?.needsReview.count ?? -1) cần kiểm tra")
        }

        // 5b. Đánh dấu hàng loạt (chọn nhiều): ✗ ba ảnh khớp cùng lúc, rồi bỏ đánh dấu cả ba
        if let r = session.result, r.matched.count >= 3 {
            let three = Array(r.matched.suffix(3))
            session.mark(three, correct: false, model: model)
            try await waitForWrite(session)
            let files = model.person(person.id)?.outputFiles ?? []
            let gone = three.allSatisfy { s in !files.contains { $0.sourceKey == s.item.key } }
            log("đánh dấu hàng loạt: ✗ 3 ảnh -> khớp \(session.result?.matched.count ?? -1), đã loại \(session.result?.rejectedScores.count ?? -1), bỏ khỏi thư mục: \(gone)")
            guard gone, session.result?.rejectedScores.count == 3 else { throw SelfTestError("đánh dấu hàng loạt không đúng") }
            session.mark(three, correct: nil, model: model)
            try await waitForWrite(session)
            log("bỏ đánh dấu hàng loạt: khớp \(session.result?.matched.count ?? -1), đã loại \(session.result?.rejectedScores.count ?? -1)")
        }

        // 6. Quick Look: ảnh trong zip được giải nén ra file tạm
        if let zipped = session.result?.matched.first(where: { $0.item.zipPath != nil })?.item {
            let url = try require(await PreviewFiles.url(for: zipped), "file xem trước")
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            log("xem trước \(zipped.name): \(size == zipped.size ? "đúng dung lượng" : "SAI dung lượng \(size ?? -1)")")
            guard size == zipped.size else { throw SelfTestError("file xem trước sai") }
        }

        // 7. Quét lại khi thư viện không đổi: không được tìm lại / ghi lại thư mục kết quả
        let version = model.libraryVersion
        model.rescan()
        try await wait("quét lại", timeout: 120) { model.indexing == nil }
        log("quét lại khi không có gì mới: libraryVersion \(version) -> \(model.libraryVersion)")
        guard model.libraryVersion == version else { throw SelfTestError("quét lại làm thư viện bị coi là đã đổi") }
    }

    /// Chờ một lần ghi thư mục kết quả mới bắt đầu rồi xong.
    private static func waitForWrite(_ session: PersonSession) async throws {
        let start = Date()
        while session.writeState != .writing, Date().timeIntervalSince(start) < 3 { try await Task.sleep(for: .milliseconds(20)) }
        try await wait("ghi kết quả", timeout: 120) {
            if case .done = session.writeState { return true }
            if case .failed = session.writeState { return true }
            return false
        }
        if case .failed(let m) = session.writeState { throw SelfTestError("ghi kết quả: \(m)") }
    }

    // MARK: tiện ích

    struct SelfTestError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func require<T>(_ v: T?, _ what: String) throws -> T {
        guard let v else { throw SelfTestError("thiếu \(what)") }
        return v
    }

    private static func wait(_ what: String, timeout: TimeInterval, until condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { throw SelfTestError("quá thời gian chờ: \(what)") }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    static func log(_ s: String) {
        FileHandle.standardOutput.write(Data(("[selftest] " + s + "\n").utf8))
    }

    /// Vẽ lại các cửa sổ đang hiện của app ra PNG.
    static func snapshot(_ name: String, to dir: URL) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(i).png"))
        }
    }
}
#endif
