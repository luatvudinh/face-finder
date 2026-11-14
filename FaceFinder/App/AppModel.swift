import AppKit
import FaceFinderKit
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case library
    case person(Int64)
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct SourceStats: Equatable {
    var images = 0
    var indexed = 0
    var faces = 0
    var errors = 0
}

struct IndexingProgress {
    enum Phase { case listing, loadingModels, analyzing }
    var phase = Phase.listing
    var done = 0
    var total = 0
    var started = Date()
    var paused = false

    var rate: Double {
        let t = Date().timeIntervalSince(started)
        return t > 1 && done > 0 ? Double(done) / t : 0
    }

    var remaining: TimeInterval? { rate > 0 ? Double(total - done) / rate : nil }
}

/// Trạng thái chung của app: thư viện nguồn ảnh, chỉ mục khuôn mặt, những người đã tạo.
@MainActor @Observable final class AppModel {
    let index: FaceIndex
    @ObservationIgnored let access = AccessStore()
    @ObservationIgnored let control = PipelineControl()

    private(set) var sources: [SourceRecord] = []
    private(set) var stats: [Int64: SourceStats] = [:]
    private(set) var people: [PersonRecord] = []
    private(set) var sessions: [Int64: PersonSession] = [:]

    var selection: SidebarItem? = .library
    var showNewPerson = false
    var indexing: IndexingProgress?
    var lastIndexing: String?
    /// Tăng mỗi khi chỉ mục thay đổi, để các màn hình kết quả tìm lại.
    private(set) var libraryVersion = 0
    var alert: AlertMessage?
    #if DEBUG || SELFTEST
    /// Bản nháp "Thêm người" do SelfTest điều khiển (để chụp được sheet).
    var selfTestDraft: NewPersonModel?
    #endif

    @ObservationIgnored private var analyzerTask: Task<Analyzer, Error>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    init() {
        var url = FaceIndex.defaultURL
        #if DEBUG || SELFTEST
        if let dir = SelfTest.dataDirectory { url = dir.appendingPathComponent("index.sqlite") }
        #endif
        do {
            index = try FaceIndex(url: url)
        } catch {
            fatalError("Không mở được dữ liệu của app: \(error)")
        }
        for g in (try? index.grants()) ?? [] { access.open(g.bookmark, writable: true) }
        reloadSources()
        for s in sources { if let b = s.bookmark { access.open(b, writable: !s.isZip) } }
        reloadPeople()
        startIndexing()
        #if DEBUG || SELFTEST
        SelfTest.run(self)
        #endif
    }

    // MARK: thư viện

    func reloadSources() {
        sources = (try? index.sources()) ?? []
    }

    /// Ảnh của các nguồn (bỏ ảnh trùng tên + dung lượng, bỏ thư mục kết quả của app), chạy ngoài luồng chính.
    nonisolated static func collect(_ sources: [SourceRecord]) -> [ImageItem] {
        ImageSource.dedupe(ImageSource.collect(sources.map(\.path)))
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        panel.message = "Chọn thư mục ảnh hoặc file zip. Thư mục được quét cả thư mục con."
        panel.prompt = "Thêm"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var added = 0, rejected: [String] = []
        for url in urls {
            let path = ImageSource.absolutePath(url.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let isZip = !isDir.boolValue && url.pathExtension.lowercased() == "zip"
            guard isDir.boolValue || isZip else { rejected.append(url.lastPathComponent); continue }
            do {
                try index.addSource(path: path, isZip: isZip, bookmark: AccessStore.bookmark(for: url))
                if isDir.boolValue { access.allowWriting(url) }
                added += 1
            } catch {
                alert = AlertMessage(title: "Không thêm được nguồn", message: "\(url.path): \(error)")
            }
        }
        if !rejected.isEmpty {
            alert = AlertMessage(title: "Chỉ nhận thư mục hoặc file zip",
                                 message: "Bỏ qua: \(rejected.prefix(5).joined(separator: ", "))\(rejected.count > 5 ? "…" : "")")
        }
        if added > 0 {
            reloadSources()
            startIndexing()
        }
    }

    func remove(_ source: SourceRecord) {
        indexTask?.cancel()
        try? index.removeSource(source)
        reloadSources()
        startIndexing()
    }

    func analyzer() async throws -> Analyzer {
        if let task = analyzerTask { return try await task.value }
        guard let dir = Bundle.main.resourceURL else { throw ModelError.notFound(Bundle.main.bundleURL) }
        let task = Task.detached { try await Analyzer(modelsDirectory: dir, device: .gpu) }
        analyzerTask = task
        do {
            return try await task.value
        } catch {
            analyzerTask = nil
            throw error
        }
    }

    // MARK: lập chỉ mục

    func startIndexing() {
        indexTask?.cancel()
        control.isPaused = false
        let snapshot = sources
        indexing = IndexingProgress()
        indexTask = Task { await runIndexing(snapshot) }
    }

    func setPaused(_ paused: Bool) {
        control.isPaused = paused
        indexing?.paused = paused
    }

    func cancelIndexing() {
        indexTask?.cancel()
        control.isPaused = false
    }

    private func runIndexing(_ sources: [SourceRecord]) async {
        let index = self.index
        let items = await Task.detached { Self.collect(sources) }.value
        let signature = AnalyzerConfig().signature
        var faces = (try? await Task.detached { try index.load(items, signature: signature) }.value) ?? [:]
        var errors: [String: String] = [:]
        let todo = items.filter { faces[$0.key] == nil }
        stats = Self.stats(sources, items, faces, errors)  // hiện ngay số ảnh, kể cả khi chưa lập chỉ mục xong
        var analyzed = 0
        if !todo.isEmpty, !Task.isCancelled {
            // Báo cho macOS đây là việc người dùng đang chờ: không bị App Nap hạ ưu tiên khi cửa sổ không ở phía
            // trước (đo được: chậm gần gấp đôi), và máy không ngủ giữa chừng.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Lập chỉ mục khuôn mặt")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                indexing?.phase = .loadingModels
                let analyzer = try await analyzer()
                indexing?.phase = .analyzing
                indexing?.total = todo.count
                indexing?.started = Date()
                let out = try await Pipeline.analyze(todo, analyzer: analyzer, index: index, control: control) { done, total in
                    Task { @MainActor in
                        self.indexing?.done = done
                        self.indexing?.total = total
                    }
                }
                faces.merge(out.faces) { _, new in new }
                errors = out.errors
                analyzed = todo.count
            } catch is CancellationError {
                lastIndexing = "Đã huỷ lập chỉ mục. Ảnh đã xử lý được giữ lại; bấm “Lập chỉ mục” để làm tiếp."
            } catch {
                if Task.isCancelled {
                    lastIndexing = "Đã huỷ lập chỉ mục."
                } else {
                    alert = AlertMessage(title: "Lập chỉ mục thất bại", message: "\(error)")
                }
            }
        }
        // khi bị huỷ, đọc lại từ chỉ mục những gì đã xử lý xong
        if Task.isCancelled { faces = (try? await Task.detached { try index.load(items, signature: signature) }.value) ?? faces }

        stats = Self.stats(sources, items, faces, errors)
        if !Task.isCancelled {
            if analyzed > 0 {
                let elapsed = Date().timeIntervalSince(indexing?.started ?? Date())
                lastIndexing = "Đã lập chỉ mục \(analyzed) ảnh trong \(Self.duration(elapsed))"
                    + (errors.isEmpty ? "." : ". \(errors.count) ảnh không đọc được.")
            }
            indexing = nil
        } else if indexTask?.isCancelled == true {
            indexing = nil
        }
        libraryVersion += 1
    }

    private static func stats(_ sources: [SourceRecord], _ items: [ImageItem], _ faces: [String: [FaceRecord]],
                              _ errors: [String: String]) -> [Int64: SourceStats] {
        var out: [Int64: SourceStats] = [:]
        for s in sources { out[s.id] = SourceStats() }
        for item in items {
            guard let s = sources.first(where: { $0.contains(key: item.key) }) else { continue }
            out[s.id]!.images += 1
            if errors[item.key] != nil {
                out[s.id]!.errors += 1
            } else if let f = faces[item.key] {
                out[s.id]!.indexed += 1
                out[s.id]!.faces += f.count
            }
        }
        return out
    }

    var isIndexing: Bool { indexing != nil }

    var totalStats: SourceStats {
        stats.values.reduce(into: SourceStats()) {
            $0.images += $1.images; $0.indexed += $1.indexed; $0.faces += $1.faces; $0.errors += $1.errors
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? "\(s / 60) phút \(s % 60) giây" : "\(s) giây"
    }

    // MARK: người

    func reloadPeople() {
        people = (try? index.people()) ?? []
        for p in people where sessions[p.id] == nil { sessions[p.id] = PersonSession(personID: p.id, threshold: p.threshold) }
        sessions = sessions.filter { id, _ in people.contains { $0.id == id } }
    }

    func person(_ id: Int64) -> PersonRecord? { people.first { $0.id == id } }

    func save(_ person: PersonRecord) {
        do {
            try index.updatePerson(person)
            if let i = people.firstIndex(where: { $0.id == person.id }) { people[i] = person }
        } catch {
            alert = AlertMessage(title: "Không lưu được", message: "\(error)")
        }
    }

    func delete(_ person: PersonRecord) {
        try? index.deletePerson(id: person.id)
        if selection == .person(person.id) { selection = .library }
        reloadPeople()
    }

    /// Lưu quyền ghi vào một thư mục (vd. thư mục chứa file zip) để lần sau không phải hỏi lại.
    func rememberGrant(_ url: URL) {
        guard let bookmark = AccessStore.bookmark(for: url) else { return }
        try? index.saveGrant(path: ImageSource.absolutePath(url.path), bookmark: bookmark)
    }

    /// Đảm bảo app được ghi vào `directory`; chưa có quyền thì hỏi người dùng. Trả về thư mục dùng được (người dùng
    /// có thể chọn chỗ khác), hoặc `nil` nếu họ huỷ.
    func ensureWritable(_ directory: URL, reason: String) -> URL? {
        let path = ImageSource.absolutePath(directory.path)
        if access.canWrite(path) { return directory }
        guard let url = access.askForFolder(at: directory, message: reason) else { return nil }
        rememberGrant(url)
        return url
    }

    /// Nơi ghi kết quả mặc định: thư mục của nguồn đầu tiên (thư mục chứa zip nếu nguồn là zip).
    var defaultOutputBase: URL? {
        sources.first.map { URL(fileURLWithPath: $0.defaultOutputBase, isDirectory: true) }
    }

    func clearAllFaceData() {
        cancelIndexing()
        try? index.removeAll()
        sessions = [:]
        selection = .library
        reloadPeople()
        startIndexing()
    }
}
