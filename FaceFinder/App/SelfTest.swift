#if DEBUG || SELFTEST
import AppKit
import FaceFinderKit

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

    static func run(_ model: AppModel) {
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
        try await wait("phân tích ảnh mẫu", timeout: 120) { draft.phase != .empty && draft.phase != .analyzing("Đang tìm khuôn mặt trong ảnh mẫu…") }
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
