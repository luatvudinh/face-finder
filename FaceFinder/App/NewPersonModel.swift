import AppKit
import FaceFinderKit
import Observation

/// Một người có thể là "người cần tìm" trong các ảnh mẫu (thay cho chon_nguoi.jpg / --pick của CLI).
struct IdentityPreview: Identifiable, Sendable {
    let id: Int
    let references: [PersonReference]
    /// Số ảnh mẫu có người này.
    let coverCount: Int
}

/// Màn hình "Thêm người": kéo ảnh mẫu vào, app tách khuôn mặt, gom theo người và đề xuất người xuất hiện nhất quán.
@MainActor @Observable final class NewPersonModel {
    enum Phase: Equatable {
        case empty
        case analyzing(String)
        case ready
        case failed(String)
    }

    var name = ""
    private(set) var phase = Phase.empty
    private(set) var referenceURLs: [URL] = []
    private(set) var imageCount = 0
    private(set) var usableCount = 0
    private(set) var identities: [IdentityPreview] = []
    private(set) var ambiguous = false
    private(set) var noFace: [String] = []
    var chosen = 0
    var outputBase: URL?

    func chooseReferences(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .zip]
        panel.message = "Chọn vài ảnh rõ mặt của người cần tìm (càng nhiều góc mặt càng tốt; nên có ít nhất 3 ảnh)."
        panel.prompt = "Dùng làm ảnh mẫu"
        guard panel.runModal() == .OK else { return }
        add(panel.urls, model: model)
    }

    func add(_ urls: [URL], model: AppModel) {
        let known = Set(referenceURLs.map(\.path))
        referenceURLs += urls.filter { !known.contains($0.path) }
        analyze(model)
    }

    func clear() {
        referenceURLs = []
        identities = []
        noFace = []
        phase = .empty
    }

    private func analyze(_ model: AppModel) {
        guard !referenceURLs.isEmpty else { return }
        phase = .analyzing("Đang tìm khuôn mặt trong ảnh mẫu…")
        let paths = referenceURLs.map { ImageSource.absolutePath($0.path) }, index = model.index
        Task {
            do {
                let analyzer = try await model.analyzer()
                let built = try await Task.detached { try await Self.build(paths, analyzer: analyzer, index: index) }.value
                imageCount = built.images
                usableCount = built.usable
                identities = built.identities
                noFace = built.noFace
                ambiguous = built.ambiguous
                chosen = 0
                phase = built.identities.isEmpty ? .failed("Không thấy khuôn mặt nào trong ảnh mẫu.") : .ready
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    private nonisolated static func build(_ paths: [String], analyzer: Analyzer, index: FaceIndex) async throws
        -> (images: Int, usable: Int, identities: [IdentityPreview], noFace: [String], ambiguous: Bool) {
        let items = ImageSource.dedupe(ImageSource.collect(paths))
        let out = try await Pipeline.analyze(items, analyzer: analyzer, index: index)
        let (ids, noFace, usable) = try Scorer.findIdentities(references: items, faces: out.faces)
        let reader = ItemReader()
        var data: [String: Data] = [:]
        var previews: [IdentityPreview] = []
        for (k, identity) in ids.enumerated() {
            let refs = identity.references.map { ref -> PersonReference in
                let bytes = data[ref.item.key] ?? (try? reader.read(ref.item))
                data[ref.item.key] = bytes
                let f = ref.face
                let thumb = bytes.flatMap { FaceCrop.image(from: $0, x: f.x, y: f.y, width: f.width, height: f.height, side: 160) }
                    .flatMap { FaceCrop.jpeg($0) }
                return PersonReference(imageName: ref.item.name, imageKey: ref.item.key, embedding: f.embedding, thumbnail: thumb)
            }
            previews.append(IdentityPreview(id: k, references: refs, coverCount: identity.cover.count))
        }
        return (items.count, usable, previews, noFace.map(\.name), Scorer.isAmbiguous(ids, usableReferences: usable))
    }

    var canCreate: Bool {
        phase == .ready && !name.trimmingCharacters(in: .whitespaces).isEmpty && identities.indices.contains(chosen)
    }

    /// Tạo người. Nếu chưa có quyền ghi vào nơi lưu kết quả (vd. thư mục chứa file zip) thì hỏi người dùng trước.
    func create(_ model: AppModel) -> PersonRecord? {
        guard canCreate else { return nil }
        guard let base = outputBase ?? model.defaultOutputBase else {
            model.alert = AlertMessage(title: "Chưa có nguồn ảnh", message: "Thêm thư mục ảnh hoặc file zip vào Thư viện trước.")
            return nil
        }
        guard let writable = model.ensureWritable(base, reason: "Face Finder lưu kết quả vào thư mục này (thư mục con “\(ResultFolder.folderName(for: name))”). Bấm “Cho phép” để đồng ý.") else {
            return nil
        }
        let personName = name.trimmingCharacters(in: .whitespaces)
        do {
            var person = try model.index.addPerson(name: personName, references: identities[chosen].references,
                                                   threshold: SearchOptions().threshold, outputFolder: nil)
            person.outputFolder = ResultFolder.choose(in: writable, personName: personName, personID: person.uuid).path
            try model.index.updatePerson(person)
            model.reloadPeople()
            return person
        } catch {
            model.alert = AlertMessage(title: "Không tạo được người", message: "\(error)")
            return nil
        }
    }
}
