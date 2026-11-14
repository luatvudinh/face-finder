import AppKit
import FaceFinderKit
import Observation

/// Kết quả tìm của một người + việc giữ thư mục kết quả luôn khớp với kết quả đó.
@MainActor @Observable final class PersonSession {
    enum WriteState: Equatable {
        case idle
        case writing
        case done(String)
        case needsPermission
        case failed(String)
    }

    let personID: Int64
    private(set) var result: SearchResult?
    private(set) var searching = false
    /// Ảnh trong thư viện chưa được lập chỉ mục (chưa tính vào kết quả).
    private(set) var notIndexed = 0
    private(set) var threshold: Double
    private(set) var writeState = WriteState.idle

    @ObservationIgnored private var searchedVersion = -1
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var writeAgain = false

    init(personID: Int64, threshold: Double) {
        self.personID = personID
        self.threshold = threshold
    }

    /// Tìm lại nếu chỉ mục đã thay đổi kể từ lần tìm trước.
    func refreshIfNeeded(_ model: AppModel) {
        guard searchedVersion != model.libraryVersion, !searching else { return }
        search(model)
    }

    func search(_ model: AppModel) {
        guard let person = model.person(personID) else { return }
        searching = true
        searchedVersion = model.libraryVersion
        let sources = model.sources, index = model.index
        let embeddings = person.references.map(\.embedding)
        let threshold = self.threshold
        Task {
            let outcome = await Task.detached { () -> (SearchResult, Int)? in
                let items = AppModel.collect(sources)
                guard let faces = try? index.load(items, signature: AnalyzerConfig().signature) else { return nil }
                var options = SearchOptions()
                options.threshold = threshold
                let indexed = items.filter { faces[$0.key] != nil }
                return (Scorer.search(embeddings: embeddings, items: indexed, faces: faces, options: options), items.count - indexed.count)
            }.value
            searching = false
            guard let (result, missing) = outcome else { return }
            self.result = result.with(threshold: self.threshold)
            notIndexed = missing
            scheduleWrite(model, after: .zero)
        }
    }

    /// Kéo thanh trượt: chia nhóm lại ngay (điểm đã có sẵn), ghi thư mục kết quả sau khi thả tay một lúc.
    func setThreshold(_ value: Double, model: AppModel) {
        threshold = value
        result = result?.with(threshold: value)
        if var person = model.person(personID), person.threshold != value {
            person.threshold = value
            model.save(person)
        }
        scheduleWrite(model, after: .milliseconds(800))
    }

    func scheduleWrite(_ model: AppModel, after delay: Duration) {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await write(model)
        }
    }

    /// Đồng bộ thư mục kết quả với kết quả hiện tại (chỉ đụng tới file do app tạo).
    func write(_ model: AppModel) async {
        if writing { writeAgain = true; return }
        guard let person = model.person(personID), let folder = person.outputFolder, let result else { return }
        let parent = (folder as NSString).deletingLastPathComponent
        guard model.access.canWrite(parent) || model.access.canWrite(folder) else {
            writeState = .needsPermission
            return
        }
        writing = true
        writeState = .writing
        let uuid = person.uuid, name = person.name, previous = person.outputFiles
        let outcome = await Task.detached { () -> Result<SyncSummary, Error> in
            Result { try ResultWriter.sync(folder: URL(fileURLWithPath: folder, isDirectory: true), personID: uuid,
                                           personName: name, result: result, previous: previous) }
        }.value
        writing = false
        switch outcome {
        case .success(let s):
            if var p = model.person(personID) {
                p.outputFiles = s.files
                model.save(p)
            }
            var changes: [String] = []
            if s.added > 0 { changes.append("thêm \(s.added)") }
            if s.moved > 0 { changes.append("chuyển nhóm \(s.moved)") }
            if s.removed > 0 { changes.append("bỏ \(s.removed) (vào Thùng rác)") }
            writeState = .done(changes.isEmpty ? "Thư mục kết quả đã khớp." : "Đã cập nhật: " + changes.joined(separator: ", ") + " ảnh.")
        case .failure(let error):
            writeState = .failed("\(error)")
        }
        if writeAgain {
            writeAgain = false
            await write(model)
        }
    }

    /// Chưa có quyền ghi: hỏi người dùng (hộp thoại mở sẵn tại thư mục cần ghi) rồi ghi.
    func grantAndWrite(_ model: AppModel) {
        guard let person = model.person(personID), let folder = person.outputFolder else { return }
        let parent = URL(fileURLWithPath: (folder as NSString).deletingLastPathComponent, isDirectory: true)
        guard let granted = model.ensureWritable(parent, reason: "Cho phép Face Finder ghi kết quả vào thư mục này.") else { return }
        if ImageSource.absolutePath(granted.path) != parent.path {
            var p = person
            p.outputFolder = ResultFolder.choose(in: granted, personName: p.name, personID: p.uuid).path
            model.save(p)
        }
        scheduleWrite(model, after: .zero)
    }

    /// "Chuyển kết quả sang…" / "Sao chép sang…".
    func relocate(_ model: AppModel, copy: Bool) {
        guard var person = model.person(personID), let folder = person.outputFolder else { return }
        let current = URL(fileURLWithPath: folder, isDirectory: true)
        guard let dest = model.access.askForFolder(
            at: current.deletingLastPathComponent(),
            message: copy ? "Chọn nơi giữ thêm một bản thư mục kết quả." : "Chọn nơi chuyển thư mục kết quả tới. Các lần cập nhật sau sẽ ghi vào chỗ mới.",
            prompt: copy ? "Sao chép vào đây" : "Chuyển vào đây") else { return }
        model.rememberGrant(dest)
        do {
            if !FileManager.default.fileExists(atPath: current.path) {
                guard !copy else { return }
                person.outputFolder = ResultFolder.choose(in: dest, personName: person.name, personID: person.uuid).path
                person.outputFiles = []
            } else {
                let moved = try ResultFolder.relocate(current, to: dest, personName: person.name, personID: person.uuid, copy: copy)
                if copy {
                    NSWorkspace.shared.activateFileViewerSelecting([moved])
                    return
                }
                person.outputFolder = moved.path
            }
            model.save(person)
            scheduleWrite(model, after: .zero)
        } catch {
            model.alert = AlertMessage(title: copy ? "Không sao chép được" : "Không chuyển được", message: "\(error)")
        }
    }
}
