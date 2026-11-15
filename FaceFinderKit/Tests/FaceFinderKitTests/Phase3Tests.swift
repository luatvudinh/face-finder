import Foundation
import Testing
import ZIPFoundation
@testable import FaceFinderKit

/// Giai đoạn 3: đánh dấu ✓/✗, ảnh hỏng, ảnh RAW, zip có mật khẩu, lịch sử tìm.
@Suite struct MarksTests {
    private func vec(_ axis: Int, tilt: Float = 0, toward other: Int = 500) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[axis] = 1; v[other] = tilt
        let n = (1 + tilt * tilt).squareRoot()
        return v.map { $0 / n }
    }

    private func item(_ name: String) -> ImageItem {
        ImageItem(key: "/x/" + name, zipPath: nil, member: nil, name: name, size: 1, mtime: .distantPast, stamp: "1:0")
    }

    private func face(_ e: [Float]) -> FaceRecord {
        FaceRecord(x: 0, y: 0, width: 50, height: 50, landmarks: [], detectionScore: 0.9, embedding: e)
    }

    @Test func confirmedAndRejectedOverrideScores() {
        let items = [item("chac.jpg"), item("kho.jpg"), item("nham.jpg"), item("giong_kho.jpg")]
        let faces: [String: [FaceRecord]] = [
            items[0].key: [face(vec(0, tilt: 0.1))],   // khớp chắc
            items[1].key: [face(vec(7))],              // điểm thấp nhưng đúng người (góc mặt khó)
            items[2].key: [face(vec(0, tilt: 0.3))],   // điểm cao nhưng là người khác
            items[3].key: [face(vec(7, tilt: 0.2))],   // giống ảnh khó
        ]
        var options = SearchOptions()
        options.expand = false
        let plain = Scorer.search(embeddings: [vec(0)], items: items, faces: faces, options: options)
        #expect(plain.status(of: plain.scores.first { $0.item.name == "kho.jpg" }!) == .none)
        #expect(plain.status(of: plain.scores.first { $0.item.name == "nham.jpg" }!) == .matched)

        let marks = SearchMarks(confirmed: [items[1].key: vec(7)], rejected: [items[2].key])
        let r = Scorer.search(embeddings: [vec(0)], items: items, faces: faces, options: options, marks: marks)
        let byName = Dictionary(uniqueKeysWithValues: r.scores.map { ($0.item.name, $0) })
        #expect(r.status(of: byName["kho.jpg"]!) == .matched)        // ✓ luôn khớp
        #expect(r.status(of: byName["nham.jpg"]!) == .rejected)      // ✗ luôn bị loại, dù điểm cao
        // ảnh giống ảnh ✓ cũng lên "Khớp" nhờ mẫu bổ sung; ảnh ✗ không còn trong "Khớp"
        #expect(r.matched.map(\.item.name).sorted() == ["chac.jpg", "giong_kho.jpg", "kho.jpg"])
        #expect(r.rejectedScores.map(\.item.name) == ["nham.jpg"])
        // ảnh ✓ thành mẫu bổ sung: ảnh giống nó được điểm cao hơn trước
        #expect(byName["giong_kho.jpg"]!.score > plain.scores.first { $0.item.name == "giong_kho.jpg" }!.score + 0.3)
        // đổi ngưỡng không làm mất đánh dấu
        let strict = r.with(threshold: 0.99)
        #expect(strict.status(of: byName["kho.jpg"]!) == .matched && strict.status(of: byName["nham.jpg"]!) == .rejected)
    }

    @Test func rejectedImagesAreNotUsedForExpansion() {
        let items = (0..<3).map { item("a\($0).jpg") }
        let faces = Dictionary(uniqueKeysWithValues: items.map { ($0.key, [face(vec(0, tilt: 0.2))]) })
        let r = Scorer.search(embeddings: [vec(0)], items: items, faces: faces, marks: SearchMarks(rejected: [items[0].key]))
        #expect(r.expandedBy == 2)
    }

    @Test func rejectedFileLeavesResultFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ffmarks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let paths = ["a.jpg", "b.jpg"].map { root.appendingPathComponent("src/" + $0) }
        for (i, p) in paths.enumerated() { try Data(count: 10 + i).write(to: p) }
        let items = ImageSource.collect(paths.map(\.path))
        let scores = items.map { ItemScore(item: $0, score: 0.8, face: nil, faceCount: 1) }
        let folder = root.appendingPathComponent("out")
        let discard: (URL) throws -> Void = { try fm.removeItem(at: $0) }
        var s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P",
                                      result: SearchResult(scores: scores, threshold: 0.5, review: 0.4, reviewBase: 0.4, expandedBy: 0),
                                      previous: [], discard: discard)
        #expect(s.files.count == 2)
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P",
                                  result: SearchResult(scores: scores, threshold: 0.5, review: 0.4, reviewBase: 0.4, expandedBy: 0,
                                                       rejected: [items[1].key]),
                                  previous: s.files, discard: discard)
        #expect(s.removed == 1 && !fm.fileExists(atPath: folder.appendingPathComponent("b.jpg").path))
        let csv = String(decoding: try Data(contentsOf: folder.appendingPathComponent("_báo cáo/ket_qua.csv")), as: UTF8.self)
        #expect(csv.contains("b.jpg,0.800,Đã loại"))
    }
}

@Suite struct IndexPhase3Tests {
    private func item(_ key: String, stamp: String = "1:1") -> ImageItem {
        ImageItem(key: key, zipPath: nil, member: nil, name: (key as NSString).lastPathComponent, size: 1, mtime: .distantPast, stamp: stamp)
    }

    @Test func brokenImagesAreRememberedUntilTheFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffidx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try FaceIndex(url: dir.appendingPathComponent("i.sqlite"))
        let ok = item("/s/ok.jpg"), bad = item("/s/hong.jpg"), gone = item("/s/da_xoa.jpg"), other = item("/khac/x.jpg")
        try index.store([(ok, []), (gone, []), (other, [])], signature: "s")
        try index.storeErrors([(bad, "Ảnh bị hỏng")], signature: "s")
        #expect(try index.load([ok, bad], signature: "s").keys.sorted() == [ok.key])  // ảnh hỏng không tính là "đã phân tích"
        #expect(try index.loadErrors([ok, bad], signature: "s") == [bad.key: "Ảnh bị hỏng"])
        #expect(try index.loadErrors([item("/s/hong.jpg", stamp: "2:2")], signature: "s").isEmpty)  // file đổi: thử lại

        // dọn ảnh không còn trong nguồn; nguồn khác không bị đụng
        #expect(try index.prune(prefixes: ["/s/"], keep: [ok.key, bad.key]) == 1)
        #expect(try index.load([ok, gone, other], signature: "s").keys.sorted() == [other.key, ok.key])
    }

    @Test func searchHistoryKeepsTheLatest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffhist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try FaceIndex(url: dir.appendingPathComponent("i.sqlite"))
        var p = try index.addPerson(name: "Bé", references: [], threshold: 0.475, outputFolder: nil)
        for n in 0..<55 { try index.addSearch(personID: p.id, images: 100, matched: n, review: 1, threshold: 0.475) }
        let history = try index.searches(personID: p.id, limit: 100)
        #expect(history.count == 50 && history.first?.matched == 54)
        p.marks = [PersonMark(key: "/a.jpg", name: "a.jpg", correct: true, embedding: [1, 2], thumbnail: nil),
                   PersonMark(key: "/b.jpg", name: "b.jpg", correct: false, embedding: nil, thumbnail: nil)]
        try index.updatePerson(p)
        let back = try #require(try index.people().first)
        #expect(back.marks == p.marks && back.searchMarks == SearchMarks(confirmed: ["/a.jpg": [1, 2]], rejected: ["/b.jpg"]))
        try index.deletePerson(id: p.id)
        #expect(try index.searches(personID: p.id).isEmpty)
    }
}

@Suite struct SourcePhase3Tests {
    let fm = FileManager.default

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures")))
    }

    @Test func truncatedJPEGIsAnErrorLikePillow() throws {
        let data = try fixture("load_draft_file")
        #expect(throws: ImageLoaderError.truncated) { try ImageLoader.load(Data(data.prefix(data.count * 6 / 10)), maxSide: 120) }
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(Data(data.prefix(300)), maxSide: 120) }
    }

    @Test func rawWithMatchingJPEGIsSkipped() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ffraw-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("khac"), withIntermediateDirectories: true)
        for name in ["DSC001.ARW", "DSC001.JPG", "DSC002.ARW", "IMG_3.HEIC", "IMG_3.dng", "khac/DSC001.ARW"] {
            try Data(count: 3).write(to: dir.appendingPathComponent(name))
        }
        let names = ImageSource.dedupe(ImageSource.collect([dir.path])).map { $0.key.dropFirst(dir.path.count + 1) }
        #expect(names.sorted() == ["DSC001.JPG", "DSC002.ARW", "IMG_3.HEIC", "khac/DSC001.ARW"])
    }

    @Test func passwordProtectedZipIsReported() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ffzip-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mat_khau.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for name in ["a.jpg", "b.jpg", "ghi_chu.txt"] {
            let payload = Data(repeating: 1, count: 100)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(payload.count),
                                 provider: { pos, size in payload.subdata(in: Int(pos)..<Int(pos) + size) })
        }
        // bật cờ "đã mã hoá" (bit 0) cho a.jpg và b.jpg, ở cả header cục bộ và thư mục trung tâm
        var bytes = [UInt8](try Data(contentsOf: url))
        var o = 0
        while o + 4 <= bytes.count {
            let local = bytes[o] == 0x50 && bytes[o + 1] == 0x4B && bytes[o + 2] == 0x03 && bytes[o + 3] == 0x04
            let central = bytes[o] == 0x50 && bytes[o + 1] == 0x4B && bytes[o + 2] == 0x01 && bytes[o + 3] == 0x02
            if local || central {
                let nameAt = o + (local ? 30 : 46), nameLength = Int(bytes[o + (local ? 26 : 28)])
                let name = String(decoding: bytes[nameAt..<(nameAt + nameLength)], as: UTF8.self)
                if name.hasSuffix(".jpg") { bytes[o + (local ? 6 : 8)] |= 1 }
            }
            o += 1
        }
        try Data(bytes).write(to: url)

        var warnings: [String] = []
        let items = ImageSource.collect([url.path]) { warnings.append($0) }
        #expect(items.isEmpty)
        // thông báo theo ngôn ngữ của máy: chỉ kiểm số ảnh và tên file zip
        #expect(warnings.count == 1 && warnings[0].contains("2") && warnings[0].contains("mat_khau.zip"))
    }
}

@Suite struct OrphanTests {
    /// Ảnh gốc biến mất khỏi thư viện (ổ đĩa rút ra, nguồn bị bỏ): bản sao trong thư mục kết quả phải được giữ.
    @Test func copiesOfVanishedSourcesAreKept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fforphan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let paths = ["a.jpg", "b.jpg"].map { root.appendingPathComponent("src/" + $0) }
        for p in paths { try Data(count: 10).write(to: p) }
        let items = ImageSource.collect(paths.map(\.path))
        let discard: (URL) throws -> Void = { try fm.removeItem(at: $0) }
        let folder = root.appendingPathComponent("out")
        func result(_ scores: [(ImageItem, Float)]) -> SearchResult {
            SearchResult(scores: scores.map { ItemScore(item: $0.0, score: $0.1, face: nil, faceCount: 1) },
                         threshold: 0.5, review: 0.4, reviewBase: 0.4, expandedBy: 0)
        }
        var s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result([(items[0], 0.9), (items[1], 0.9)]),
                                      previous: [], discard: discard)
        // thư viện rỗng (vd. vừa mở app) rồi chỉ còn b: a phải được giữ
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result([]), previous: s.files, discard: discard)
        #expect(s.removed == 0 && s.files.count == 2)
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result([(items[1], 0.1)]),
                                  previous: s.files, discard: discard)
        #expect(s.removed == 1 && s.files.map(\.sourceKey) == [items[0].key])
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("a.jpg").path) && !fm.fileExists(atPath: folder.appendingPathComponent("b.jpg").path))
    }
}

@Suite struct HalfTests {
    /// vImage phải làm tròn y như Float16 của Swift (= numpy float16 của CLI), để chỉ mục cũ và điểm số không đổi.
    @Test func matchesSwiftFloat16() {
        var rng = SystemRandomNumberGenerator()
        let values = (0..<20_000).map { _ in Float.random(in: -1...1, using: &rng) } + [0, 1, -1, 65504, 1e-8, 0.000_061_035, 0.333_333]
        #if arch(arm64)
        let swift = values.map { Float(Float16($0)) }
        #expect(Half.round(values) == swift)
        let bytes = values.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
        #expect(Half.encode(values) == bytes && Half.decode(bytes) == swift)
        #endif
        #expect(Half.decode(Half.encode([])) == [])
    }
}

/// Các lỗi do workflow soát lỗi tìm ra (Giai đoạn 3).
@Suite struct ReviewFixTests {
    let fm = FileManager.default

    private func setup(_ names: [String]) throws -> (root: URL, items: [ImageItem]) {
        let root = fm.temporaryDirectory.appendingPathComponent("fffix-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let paths = names.enumerated().map { i, n in (root.appendingPathComponent("src/" + n), i) }
        for (p, i) in paths { try Data(count: 10 + i).write(to: p) }
        return (root, ImageSource.collect(paths.map(\.0.path)))
    }

    private func result(_ items: [ImageItem], _ score: Float = 0.9, rejected: Set<String> = []) -> SearchResult {
        SearchResult(scores: items.map { ItemScore(item: $0, score: score, face: nil, faceCount: 1) },
                     threshold: 0.5, review: 0.4, reviewBase: 0.4, expandedBy: 0, rejected: rejected)
    }

    @Test func missingOriginalDoesNotLoseTrackOfOtherCopies() throws {
        let (root, items) = try setup(["a.jpg", "b.jpg", "c.jpg"])
        defer { try? fm.removeItem(at: root) }
        try fm.removeItem(atPath: items[1].key)  // ảnh gốc b bị xoá sau khi lập chỉ mục
        let folder = root.appendingPathComponent("out")
        var s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result(items), previous: [],
                                      discard: { try FileManager.default.removeItem(at: $0) })
        #expect(s.added == 2 && s.errors.count == 1 && s.files.count == 2)
        // lần sau không chép lại a, c thành bản trùng
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result(items), previous: s.files,
                                  discard: { try FileManager.default.removeItem(at: $0) })
        #expect(s.added == 0 && s.files.count == 2)
        #expect(try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jpg") }.sorted() == ["a.jpg", "c.jpg"])
    }

    @Test func undeletableFilesStayTracked() throws {
        let (root, items) = try setup(["a.jpg", "b.jpg"])
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("out")
        var s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result(items), previous: [],
                                      discard: { try FileManager.default.removeItem(at: $0) })
        struct NoTrash: Error {}
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result(items, 0.1), previous: s.files,
                                  discard: { _ in throw NoTrash() })  // vd. ổ mạng không có Thùng rác
        #expect(s.removed == 0 && s.errors.count == 2 && s.files.count == 2)
    }

    @Test func folderMovedAwayMidSyncIsNotRecreated() throws {
        let (root, items) = try setup(["a.jpg", "b.jpg", "c.jpg"])
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("out/Face Finder - P")
        var s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result([items[0]]), previous: [],
                                      discard: { try FileManager.default.removeItem(at: $0) })
        // người dùng chuyển thư mục kết quả đi đúng lúc app đang bỏ ảnh a
        let elsewhere = root.appendingPathComponent("noi_khac")
        s = try ResultWriter.sync(folder: folder, personID: "P", personName: "P", result: result(items, rejected: [items[0].key]),
                                  previous: s.files, discard: { _ in try FileManager.default.moveItem(at: folder, to: elsewhere) })
        #expect(s.interrupted && s.added == 0)
        #expect(!fm.fileExists(atPath: folder.path))  // không tạo lại thư mục cũ (không có file đánh dấu)
        #expect(fm.fileExists(atPath: elsewhere.appendingPathComponent(".facefinder").path))
    }

    @Test func reservedFoldersAreSkipped() {
        let base = URL(fileURLWithPath: "/tmp/khong-ton-tai-\(UUID().uuidString)")
        let first = ResultFolder.choose(in: base, personName: "An", personID: "P1")
        let second = ResultFolder.choose(in: base, personName: "An", personID: "P2", reserved: [first.standardizedFileURL.path])
        #expect(first.lastPathComponent == "Face Finder - An" && second.lastPathComponent == "Face Finder - An (2)")
    }

    @Test func pruneOutsideDropsRemovedSources() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ffprune-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let index = try FaceIndex(url: dir.appendingPathComponent("i.sqlite"))
        func item(_ k: String) -> ImageItem { ImageItem(key: k, zipPath: nil, member: nil, name: k, size: 1, mtime: .distantPast, stamp: "1") }
        let keep = item("/a/x.jpg"), nested = item("/a/b/y.jpg"), gone = item("/c/z.jpg"), zip = item("/d.zip::q.jpg")
        try index.store([(keep, []), (nested, []), (gone, []), (zip, [])], signature: "s")
        #expect(try index.pruneOutside(prefixes: ["/a/", "/d.zip::"]) == 1)
        #expect(try index.load([keep, nested, gone, zip], signature: "s").keys.sorted() == [nested.key, keep.key, zip.key].sorted())
    }
}
