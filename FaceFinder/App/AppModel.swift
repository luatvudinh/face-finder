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
    /// Vấn đề của cả nguồn (không tìm thấy, zip hỏng, zip có mật khẩu...).
    var problems: [String] = []
}

/// Toàn bộ thư viện đã lập chỉ mục, giữ trong bộ nhớ để tìm/chấm lại tức thì (~40 MB cho 18.000 khuôn mặt).
struct LibrarySnapshot: Sendable {
    var items: [ImageItem] = []
    var faces: [String: [FaceRecord]] = [:]
    var errors: [String: String] = [:]

    /// Ảnh đã phân tích xong (có trong `faces`).
    var indexedItems: [ImageItem] { items.filter { faces[$0.key] != nil } }
    var notIndexed: Int { items.filter { faces[$0.key] == nil && errors[$0.key] == nil }.count }

    /// Dấu nhận biết thư viện có đổi không (để không tìm lại / ghi lại thư mục kết quả khi không cần).
    var fingerprint: Int {
        var h = Hasher()
        for i in items { h.combine(i.key); h.combine(i.stamp); h.combine(faces[i.key]?.count ?? -1); h.combine(errors[i.key]) }
        return h.finalize()
    }
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
    /// Tăng mỗi khi thư viện thật sự thay đổi, để các màn hình kết quả tìm lại.
    private(set) var libraryVersion = 0
    @ObservationIgnored private(set) var snapshot = LibrarySnapshot()
    @ObservationIgnored private var lastFingerprint: Int?
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var lastScan = Date.distantPast
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
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
        reloadSources()
        reopenAccess()
        reloadPeople()
        startIndexing()
        PreviewFiles.cleanUp()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.rescanIfStale() }
        }
        // cắm ổ đĩa chứa nguồn ảnh vào sau khi mở app: mở lại quyền truy cập và quét lại
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.rescan() }
        }
        #if DEBUG || SELFTEST
        SelfTest.run(self)
        #endif
    }

    // MARK: thư viện

    func reloadSources() {
        sources = (try? index.sources()) ?? []
        watchFolders()
    }

    /// Ảnh của các nguồn (bỏ ảnh trùng, bỏ thư mục kết quả của app) + vấn đề của từng nguồn. Chạy ngoài luồng chính.
    nonisolated static func collect(_ sources: [SourceRecord]) -> (items: [ImageItem], problems: [Int64: [String]]) {
        var items: [ImageItem] = [], problems: [Int64: [String]] = [:]
        for s in sources {
            if !FileManager.default.fileExists(atPath: s.path) {
                problems[s.id, default: []].append(s.isZip ? String(localized: "Không tìm thấy file zip (đã bị xoá, đổi tên hoặc ổ đĩa chưa cắm?)")
                                                           : String(localized: "Không tìm thấy thư mục (đã bị xoá, đổi tên hoặc ổ đĩa chưa cắm?)"))
                continue
            }
            items += ImageSource.collect([s.path]) { problems[s.id, default: []].append($0) }
        }
        return (ImageSource.dedupe(items), problems)
    }

    // MARK: quét bổ sung

    /// Theo dõi thư mục nguồn: có ảnh mới / bị xoá thì tự quét lại (file zip được kiểm lại khi quay lại app).
    private func watchFolders() {
        let folders = sources.filter { !$0.isZip }.map(\.path)
        watcher = folders.isEmpty ? nil : FolderWatcher(paths: folders) { [weak self] paths in
            Task { @MainActor in
                guard let self, paths.contains(where: { Self.isRelevantChange($0) }) else { return }
                self.scheduleRescan()
            }
        }
    }

    /// Bỏ qua thay đổi không liên quan: file ẩn, file không phải ảnh/zip, và mọi thứ trong thư mục kết quả của app
    /// (chính app ghi vào đó, không được tự kích hoạt quét lại).
    nonisolated static func isRelevantChange(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") && $0 != ".." }) { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext != "zip", !ImageSource.imageExtensions.contains(ext) { return false }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(ImageSource.resultMarker)) { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return true
    }

    func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            rescan()
        }
    }

    /// Quét lại thư viện (chỉ ảnh mới hoặc đã đổi mới phải phân tích). Đang lập chỉ mục thì để quét sau.
    func rescan() {
        if indexing != nil { rescanPending = true } else { startIndexing() }
    }

    private func rescanIfStale() {
        if Date().timeIntervalSince(lastScan) > 60 { rescan() }
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // Phải liệt kê cả .folder: có allowedContentTypes mà thiếu .folder thì macOS không cho chọn thư mục (nút Thêm mờ),
        // dù canChooseDirectories = true.
        panel.allowedContentTypes = [.folder, .zip]
        panel.message = String(localized: "Chọn thư mục ảnh hoặc file zip. Thư mục được quét cả thư mục con.")
        panel.prompt = String(localized: "Thêm")
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
                alert = AlertMessage(title: String(localized: "Không thêm được nguồn"), message: "\(url.path): \(error)")
            }
        }
        if !rejected.isEmpty {
            let names = rejected.prefix(5).joined(separator: ", ") + (rejected.count > 5 ? "…" : "")
            alert = AlertMessage(title: String(localized: "Chỉ nhận thư mục hoặc file zip"),
                                 message: String(localized: "Bỏ qua: \(names)"))
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
        rescanTask?.cancel()
        rescanPending = false  // huỷ là huỷ: không tự quét lại ngay sau đó
        control.isPaused = false
    }

    /// Mở các quyền truy cập đã lưu (nguồn ảnh, thư mục được phép ghi) chưa mở được, vd. vì ổ đĩa lúc trước chưa cắm.
    /// Bookmark lỗi thời (file/thư mục đã đổi tên, chuyển chỗ) được làm mới để lần sau vẫn mở được.
    private func reopenAccess() {
        for g in (try? index.grants()) ?? [] {
            if let r = access.open(g.bookmark, writable: true), let fresh = r.refreshed {
                try? index.saveGrant(path: g.path, bookmark: fresh)
            }
        }
        for s in sources {
            guard let b = s.bookmark, let r = access.open(b, writable: !s.isZip), let fresh = r.refreshed else { continue }
            try? index.addSource(path: s.path, isZip: s.isZip, bookmark: fresh)
        }
    }

    private func runIndexing(_ sources: [SourceRecord]) async {
        let index = self.index, signature = AnalyzerConfig().signature
        lastScan = Date()
        reopenAccess()
        let (items, problems) = await Task.detached { Self.collect(sources) }.value
        let known = await Task.detached { () -> (faces: [String: [FaceRecord]], errors: [String: String]) in
            // Dọn dữ liệu của ảnh không còn trong nguồn. Chỉ với nguồn liệt kê ra được ít nhất một ảnh: ổ đĩa rút ra hay
            // mất quyền đọc thì nguồn trông như rỗng, không được xoá dữ liệu của nó.
            let reachable = sources.filter { s in items.contains { s.contains(key: $0.key) } }
            _ = try? index.prune(prefixes: reachable.map { $0.isZip ? $0.path + "::" : $0.path + "/" }, keep: Set(items.map(\.key)))
            // ảnh của nguồn đã bị bỏ khỏi thư viện (kể cả phần lập chỉ mục dở dang ghi xuống sau khi bỏ nguồn)
            _ = try? index.pruneOutside(prefixes: sources.map { $0.isZip ? $0.path + "::" : $0.path + "/" })
            return ((try? index.load(items, signature: signature)) ?? [:], (try? index.loadErrors(items, signature: signature)) ?? [:])
        }.value
        var snap = LibrarySnapshot(items: items, faces: known.faces, errors: known.errors)
        let todo = items.filter { snap.faces[$0.key] == nil && snap.errors[$0.key] == nil }
        stats = Self.stats(sources, snap, problems)  // hiện ngay số ảnh, kể cả khi chưa lập chỉ mục xong
        var analyzed = 0, newErrors = 0
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
                snap.faces.merge(out.faces) { _, new in new }
                snap.errors.merge(out.errors) { _, new in new }
                analyzed = todo.count
                newErrors = out.errors.count
            } catch is CancellationError {
                lastIndexing = String(localized: "Đã huỷ lập chỉ mục. Ảnh đã xử lý được giữ lại; bấm “Lập chỉ mục” để làm tiếp.")
            } catch {
                if Task.isCancelled {
                    lastIndexing = String(localized: "Đã huỷ lập chỉ mục.")
                } else {
                    alert = AlertMessage(title: String(localized: "Lập chỉ mục thất bại"), message: "\(error)")
                }
            }
        }
        // khi bị huỷ, đọc lại từ chỉ mục những gì đã xử lý xong
        if Task.isCancelled {
            snap.faces = (try? await Task.detached { try index.load(items, signature: signature) }.value) ?? snap.faces
        }
        // Một lần quét mới đã thay chỗ lần này: không công bố gì, kẻo đè lên kết quả mới hơn.
        if Task.isCancelled && indexTask?.isCancelled == false { return }
        stats = Self.stats(sources, snap, problems)
        do {
            if !Task.isCancelled, analyzed > 0 {
                let elapsed = Date().timeIntervalSince(indexing?.started ?? Date())
                let time = Self.duration(elapsed)
                lastIndexing = newErrors == 0
                    ? String(localized: "Đã lập chỉ mục \(analyzed) ảnh trong \(time).")
                    : String(localized: "Đã lập chỉ mục \(analyzed) ảnh trong \(time). \(newErrors) ảnh không đọc được.")
            }
            indexing = nil
        }
        snapshot = snap
        let fingerprint = snap.fingerprint
        if fingerprint != lastFingerprint {
            lastFingerprint = fingerprint
            libraryVersion += 1
        }
        if rescanPending {
            rescanPending = false
            startIndexing()
        }
    }

    private static func stats(_ sources: [SourceRecord], _ snap: LibrarySnapshot, _ problems: [Int64: [String]]) -> [Int64: SourceStats] {
        var out: [Int64: SourceStats] = [:]
        for s in sources { out[s.id] = SourceStats(problems: problems[s.id] ?? []) }
        for item in snap.items {
            guard let s = sources.first(where: { $0.contains(key: item.key) }) else { continue }
            out[s.id]!.images += 1
            if snap.errors[item.key] != nil {
                out[s.id]!.errors += 1
            } else if let f = snap.faces[item.key] {
                out[s.id]!.indexed += 1
                out[s.id]!.faces += f.count
            }
        }
        return out
    }

    /// Ảnh không đọc được của một nguồn (để hiện danh sách).
    func brokenImages(in source: SourceRecord) -> [(name: String, path: String, reason: String)] {
        snapshot.errors.filter { source.contains(key: $0.key) }
            .map { (($0.key as NSString).lastPathComponent, $0.key.replacingOccurrences(of: "::", with: " › "), $0.value) }
            .sorted { $0.path < $1.path }
    }

    var isIndexing: Bool { indexing != nil }

    var totalStats: SourceStats {
        stats.values.reduce(into: SourceStats()) {
            $0.images += $1.images; $0.indexed += $1.indexed; $0.faces += $1.faces; $0.errors += $1.errors
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let m = s / 60, r = s % 60
        return s >= 60 ? String(localized: "\(m) phút \(r) giây") : String(localized: "\(s) giây")
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
            alert = AlertMessage(title: String(localized: "Không lưu được"), message: "\(error)")
        }
    }

    func delete(_ person: PersonRecord) {
        try? index.deletePerson(id: person.id)
        if selection == .person(person.id) { selection = .library }
        reloadPeople()
    }

    /// Thư mục kết quả đã dành cho những người khác (kể cả khi chưa được tạo trên đĩa).
    func reservedOutputFolders(except id: Int64) -> Set<String> {
        Set(people.filter { $0.id != id }.compactMap { $0.outputFolder.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
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
