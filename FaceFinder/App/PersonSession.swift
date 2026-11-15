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
    private(set) var history: [SearchRecord] = []

    @ObservationIgnored private var searchedVersion = -1
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var writeAgain = false

    init(personID: Int64, threshold: Double) {
        self.personID = personID
        self.threshold = threshold
    }

    /// Tìm lại nếu thư viện đã thay đổi kể từ lần tìm trước.
    func refreshIfNeeded(_ model: AppModel) {
        guard model.libraryVersion > 0, searchedVersion != model.libraryVersion else { return }
        search(model)
    }

    /// Tìm trong toàn bộ thư viện đã lập chỉ mục (ảnh chụp thư viện trong bộ nhớ: không đọc lại ổ đĩa, ~1 giây).
    /// `record`: ghi vào lịch sử tìm (không ghi khi chỉ chấm lại vì đánh dấu ✓/✗).
    func search(_ model: AppModel, record: Bool = true) {
        // Thư viện chưa nạp xong (vừa mở app): kết quả sẽ rỗng và làm thư mục kết quả bị dọn nhầm. Chờ.
        guard let person = model.person(personID), model.libraryVersion > 0 else { return }
        searching = true
        searchedVersion = model.libraryVersion
        searchGeneration += 1
        let generation = searchGeneration
        let snapshot = model.snapshot, embeddings = person.references.map(\.embedding), marks = person.searchMarks
        let threshold = self.threshold
        Task {
            let found = await Task.detached { () -> SearchResult in
                var options = SearchOptions()
                options.threshold = threshold
                return Scorer.search(embeddings: embeddings, items: snapshot.indexedItems, faces: snapshot.faces,
                                     options: options, marks: marks)
            }.value
            guard generation == searchGeneration else { return }  // đã có lần tìm mới hơn
            searching = false
            result = found.with(threshold: self.threshold)
            notIndexed = snapshot.notIndexed
            if record, !snapshot.items.isEmpty, let r = result {
                try? model.index.addSearch(personID: personID, images: snapshot.faces.count, matched: r.matched.count,
                                           review: r.needsReview.count, threshold: r.threshold)
            }
            history = (try? model.index.searches(personID: personID)) ?? []
            scheduleWrite(model, after: .zero)
        }
    }

    /// Đánh dấu ảnh đúng (✓) / sai (✗) / bỏ đánh dấu (`nil`), rồi chấm lại ngay.
    func mark(_ score: ItemScore, correct: Bool?, model: AppModel) {
        mark([score], correct: correct, model: model)
    }

    /// Đánh dấu hàng loạt (chọn nhiều ảnh): lưu một lần, chấm lại một lần.
    /// Ảnh không có khuôn mặt thì không đánh dấu ✓ được (không có gì để làm mẫu): bỏ qua ảnh đó.
    func mark(_ scores: [ItemScore], correct: Bool?, model: AppModel) {
        guard var person = model.person(personID), !scores.isEmpty else { return }
        let keys = Set(scores.map(\.item.key))
        person.marks.removeAll { keys.contains($0.key) }
        if let correct {
            for score in scores where !correct || score.face != nil {
                person.marks.append(PersonMark(key: score.item.key, name: score.item.name, correct: correct,
                                               embedding: correct ? score.face?.embedding : nil, thumbnail: nil))
            }
        }
        model.save(person)
        search(model, record: false)
    }

    func mark(of score: ItemScore, in model: AppModel) -> Bool? {
        model.person(personID)?.marks.first { $0.key == score.item.key }?.correct
    }

    /// Bỏ mọi đánh dấu ✓/✗ của người này.
    func clearMarks(_ model: AppModel) {
        guard var person = model.person(personID), !person.marks.isEmpty else { return }
        person.marks = []
        model.save(person)
        search(model, record: false)
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
            if s.added > 0 { changes.append(String(localized: "thêm \(s.added) ảnh")) }
            if s.moved > 0 { changes.append(String(localized: "chuyển nhóm \(s.moved) ảnh")) }
            if s.removed > 0 { changes.append(String(localized: "bỏ \(s.removed) ảnh (vào Thùng rác)")) }
            let list = changes.joined(separator: ", ")
            if s.interrupted {
                writeState = .failed(String(localized: "Thư mục kết quả bị chuyển đi hoặc xoá trong lúc ghi; đã dừng lại."))
            } else if let first = s.errors.first {
                let count = s.errors.count
                writeState = .failed(String(localized: "\(count) ảnh không ghi được (vd. \(first)). Các ảnh khác đã được cập nhật."))
            } else {
                writeState = .done(changes.isEmpty ? String(localized: "Thư mục kết quả đã khớp.")
                                                   : String(localized: "Đã cập nhật: \(list)."))
            }
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
        guard let granted = model.ensureWritable(parent, reason: String(localized: "Cho phép Face Finder ghi kết quả vào thư mục này.")) else { return }
        // Người dùng có thể chọn đúng thư mục cần ghi, chính thư mục kết quả, hoặc một chỗ khác hẳn.
        if !model.access.canWrite(folder), !model.access.canWrite(parent.path), var p = model.person(personID) {
            p.outputFolder = ResultFolder.choose(in: granted, personName: p.name, personID: p.uuid,
                                                 reserved: model.reservedOutputFolders(except: p.id)).path
            p.outputFiles = []  // thư mục mới: danh sách file của thư mục cũ không còn đúng
            model.save(p)
        }
        scheduleWrite(model, after: .zero)
    }

    /// Đang ghi thư mục kết quả (không được chuyển/sao chép thư mục lúc này).
    var isWriting: Bool { writing || writeState == .writing }

    /// "Chuyển kết quả sang…" / "Sao chép sang…".
    func relocate(_ model: AppModel, copy: Bool) {
        guard !isWriting else {
            model.alert = AlertMessage(title: String(localized: "Đang ghi kết quả"),
                                       message: String(localized: "Chờ app ghi xong thư mục kết quả rồi thử lại."))
            return
        }
        guard let folder = model.person(personID)?.outputFolder else { return }
        let current = URL(fileURLWithPath: folder, isDirectory: true)
        guard let dest = model.access.askForFolder(
            at: current.deletingLastPathComponent(),
            message: copy ? String(localized: "Chọn nơi giữ thêm một bản thư mục kết quả.")
                          : String(localized: "Chọn nơi chuyển thư mục kết quả tới. Các lần cập nhật sau sẽ ghi vào chỗ mới."),
            prompt: copy ? String(localized: "Sao chép vào đây") : String(localized: "Chuyển vào đây")) else { return }
        model.rememberGrant(dest)
        // đọc lại sau hộp thoại: trong lúc chọn, đánh dấu / ngưỡng có thể đã đổi
        guard var person = model.person(personID), person.outputFolder == folder, !isWriting else { return }
        do {
            if !FileManager.default.fileExists(atPath: current.path) {
                guard !copy else { return }
                person.outputFolder = ResultFolder.choose(in: dest, personName: person.name, personID: person.uuid,
                                                          reserved: model.reservedOutputFolders(except: person.id)).path
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
            model.alert = AlertMessage(title: copy ? String(localized: "Không sao chép được") : String(localized: "Không chuyển được"),
                                       message: "\(error)")
        }
    }
}
