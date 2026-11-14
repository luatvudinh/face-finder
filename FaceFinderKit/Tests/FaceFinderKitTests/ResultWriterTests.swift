import Foundation
import Testing
import ZIPFoundation
@testable import FaceFinderKit

/// Thư mục kết quả (PLAN.md mục 4.1 và mục 6): ghi đúng chỗ, cập nhật khi đổi ngưỡng, không bao giờ đụng file
/// không do app tạo.
@Suite struct ResultWriterTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ffwriter-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("nguon/con"), withIntermediateDirectories: true)
    }

    private func image(_ rel: String, bytes: Int) throws -> ImageItem {
        let url = root.appendingPathComponent("nguon/" + rel)
        try Data(repeating: UInt8(bytes % 251), count: bytes).write(to: url)
        return ImageSource.collect([url.path])[0]
    }

    private func result(_ scores: [(ImageItem, Float)], threshold: Double = 0.475) -> SearchResult {
        SearchResult(scores: scores.map { ItemScore(item: $0.0, score: $0.1, face: nil, faceCount: 1) }.sorted { $0.score > $1.score },
                     threshold: threshold, review: min(threshold, 0.40), reviewBase: 0.40, expandedBy: 0)
    }

    private func exists(_ rel: String, in folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(rel).path) }
    private let discard: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    @Test func writesUpdatesAndNeverTouchesUserFiles() throws {
        defer { try? fm.removeItem(at: root) }
        let a = try image("a.jpg", bytes: 10), b = try image("con/b.jpg", bytes: 20), c = try image("c.jpg", bytes: 30)
        let source = root.appendingPathComponent("nguon")
        let folder = ResultFolder.choose(in: source, personName: "Bé", personID: "P1")
        #expect(folder.lastPathComponent == "Face Finder - Bé")

        // người dùng đã có sẵn một file trùng tên với ảnh sắp được chép
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ResultFolder.writeMarker(folder, personID: "P1", personName: "Bé")
        try Data("của tôi".utf8).write(to: folder.appendingPathComponent("a.jpg"))

        var s = try ResultWriter.sync(folder: folder, personID: "P1", personName: "Bé",
                                      result: result([(a, 0.6), (b, 0.5), (c, 0.42)]), previous: [], discard: discard)
        #expect(s.added == 3 && s.files.count == 3)
        #expect(exists("a_1.jpg", in: folder) && exists("b.jpg", in: folder) && exists("Cần kiểm tra/c.jpg", in: folder))
        #expect(String(decoding: try Data(contentsOf: folder.appendingPathComponent("a.jpg")), as: UTF8.self) == "của tôi")
        #expect(exists("_báo cáo/ket_qua.csv", in: folder) && ResultFolder.owner(of: folder) == "P1")
        #expect(fm.fileExists(atPath: a.key))  // ảnh gốc vẫn còn (chép, không di chuyển)

        // người dùng tự thêm ảnh vào thư mục kết quả
        try Data("thêm".utf8).write(to: folder.appendingPathComponent("tu_them.jpg"))

        // tăng ngưỡng: b xuống "Cần kiểm tra", c rơi khỏi kết quả
        s = try ResultWriter.sync(folder: folder, personID: "P1", personName: "Bé",
                                  result: result([(a, 0.6), (b, 0.5), (c, 0.3)], threshold: 0.55), previous: s.files, discard: discard)
        #expect(s.moved == 1 && s.removed == 1 && s.added == 0)
        #expect(!exists("b.jpg", in: folder) && exists("Cần kiểm tra/b.jpg", in: folder) && !exists("Cần kiểm tra/c.jpg", in: folder))
        #expect(exists("a.jpg", in: folder) && exists("tu_them.jpg", in: folder))

        // người dùng sửa một ảnh kết quả rồi ảnh đó không còn khớp: không bị xoá
        try Data(count: 99).write(to: folder.appendingPathComponent("a_1.jpg"))
        s = try ResultWriter.sync(folder: folder, personID: "P1", personName: "Bé",
                                  result: result([(a, 0.1), (b, 0.5), (c, 0.3)], threshold: 0.55), previous: s.files, discard: discard)
        #expect(exists("a_1.jpg", in: folder) && s.files.map(\.sourceKey) == [b.key])

        // chuyển cả thư mục kết quả đi chỗ khác, cập nhật tiếp ở chỗ mới
        let other = root.appendingPathComponent("khac")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let moved = try ResultFolder.relocate(folder, to: other, personName: "Bé", personID: "P1", copy: false)
        #expect(!fm.fileExists(atPath: folder.path) && exists("Cần kiểm tra/b.jpg", in: moved))
        s = try ResultWriter.sync(folder: moved, personID: "P1", personName: "Bé",
                                  result: result([(a, 0.1), (b, 0.6), (c, 0.3)], threshold: 0.55), previous: s.files, discard: discard)
        #expect(s.moved == 1 && exists("b.jpg", in: moved))
    }

    @Test func folderOfSomeoneElseIsNeverUsed() throws {
        defer { try? fm.removeItem(at: root) }
        let a = try image("a.jpg", bytes: 10)
        let base = root.appendingPathComponent("nguon")
        let taken = base.appendingPathComponent("Face Finder - Bé")
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: taken.appendingPathComponent("anh.jpg"))  // thư mục người dùng tự đặt tên trùng
        #expect(ResultFolder.choose(in: base, personName: "Bé", personID: "P1").lastPathComponent == "Face Finder - Bé (2)")
        #expect(throws: ResultFolderError.self) {
            try ResultWriter.sync(folder: taken, personID: "P1", personName: "Bé", result: result([(a, 0.9)]), previous: [], discard: discard)
        }
        // thư mục kết quả của người khác cũng vậy
        let theirs = base.appendingPathComponent("Face Finder - Bố")
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try ResultFolder.writeMarker(theirs, personID: "P2", personName: "Bố")
        #expect(throws: ResultFolderError.self) {
            try ResultWriter.sync(folder: theirs, personID: "P1", personName: "Bố", result: result([(a, 0.9)]), previous: [], discard: discard)
        }
        // và thư mục có .facefinder bị bỏ qua khi lập chỉ mục
        #expect(ImageSource.collect([base.path]).map(\.name).sorted() == ["a.jpg", "anh.jpg"])
    }

    @Test func extractsFromZipWithoutTouchingTheZip() throws {
        defer { try? fm.removeItem(at: root) }
        let zipURL = root.appendingPathComponent("anh.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let payload = Data(repeating: 7, count: 1234)
        try archive.addEntry(with: "thu muc/x.jpg", type: .file, uncompressedSize: Int64(payload.count),
                             provider: { pos, size in payload.subdata(in: Int(pos)..<Int(pos) + size) })
        let items = ImageSource.collect([zipURL.path])
        #expect(items.map(\.key) == [zipURL.path + "::thu muc/x.jpg"])
        let folder = ResultFolder.choose(in: root, personName: "Bé", personID: "P1")
        let s = try ResultWriter.sync(folder: folder, personID: "P1", personName: "Bé", result: result([(items[0], 0.9)]),
                                      previous: [], discard: discard)
        #expect(try Data(contentsOf: folder.appendingPathComponent("x.jpg")) == payload && s.files[0].size == 1234)
    }

    @Test func thresholdChangeKeepsScores() {
        let r = SearchResult(scores: [], threshold: 0.475, review: 0.43, reviewBase: 0.43, expandedBy: 3)
        #expect(r.with(threshold: 0.40).review == 0.40 && r.with(threshold: 0.6).review == 0.43 && r.with(threshold: 0.6).expandedBy == 3)
    }
}
