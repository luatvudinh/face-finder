import Foundation
import Testing
@testable import FaceFinderKit

@Suite struct ScorerTests {
    /// Vector đơn vị 512 chiều, chủ yếu theo trục `axis`, lệch một chút theo trục `other`.
    private func vec(_ axis: Int, tilt: Float = 0, toward other: Int = 500) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[axis] = 1; v[other] = tilt
        let n = (1 + tilt * tilt).squareRoot()
        return v.map { $0 / n }
    }

    private func item(_ name: String) -> ImageItem {
        ImageItem(key: "/x/" + name, zipPath: nil, member: nil, name: name, size: 1, mtime: .distantPast, stamp: "1:0")
    }

    private func face(_ embedding: [Float], size: Float = 100) -> FaceRecord {
        FaceRecord(x: 0, y: 0, width: size, height: size, landmarks: [], detectionScore: 0.9, embedding: embedding)
    }

    @Test func centroidIsUnitLength() {
        let c = Scorer.centroid([vec(0), vec(1)])
        #expect(abs(Scorer.dot(c, c) - 1) < 1e-5)
        #expect(abs(c[0] - c[1]) < 1e-6)
    }

    @Test func picksThePersonPresentInEveryReference() throws {
        // Người A (trục 0) có trong cả 3 ảnh mẫu; mỗi ảnh có thêm một người lạ khác nhau, mặt to hơn.
        let refs = [item("a.jpg"), item("b.jpg"), item("c.jpg")]
        let faces: [String: [FaceRecord]] = [
            refs[0].key: [face(vec(0, tilt: 0.1)), face(vec(10), size: 120)],
            refs[1].key: [face(vec(11), size: 120), face(vec(0, tilt: 0.2))],
            refs[2].key: [face(vec(0, tilt: -0.1)), face(vec(12), size: 120)],
        ]
        let (ids, noFace, usable) = try Scorer.findIdentities(references: refs, faces: faces)
        #expect(noFace.isEmpty && usable == 3)
        #expect(ids[0].references.count == 3)
        #expect(ids[0].members.map(\.faceIndex) == [0, 1, 0])
        #expect(!Scorer.isAmbiguous(ids, usableReferences: usable))
    }

    @Test func twoPeopleInEveryReferenceIsAmbiguous() throws {
        let refs = [item("a.jpg"), item("b.jpg"), item("c.jpg")]
        let faces = Dictionary(uniqueKeysWithValues: refs.map { ($0.key, [face(vec(0)), face(vec(1))]) })
        let (ids, _, usable) = try Scorer.findIdentities(references: refs, faces: faces)
        #expect(ids.count == 2)
        #expect(Scorer.isAmbiguous(ids, usableReferences: usable))
    }

    @Test func singleReferenceWithTwoBigFacesIsAmbiguous() throws {
        let ref = item("a.jpg")
        let (ids, _, usable) = try Scorer.findIdentities(references: [ref], faces: [ref.key: [face(vec(0)), face(vec(1), size: 80), face(vec(2), size: 30)]])
        #expect(ids.count == 2)  // mặt nhỏ (9% diện tích) không được xét
        #expect(Scorer.isAmbiguous(ids, usableReferences: usable))
    }

    @Test func anchorMustBeAReference() {
        let ref = item("a.jpg")
        #expect(throws: ScorerError.self) {
            try Scorer.findIdentities(references: [ref], faces: [ref.key: [face(vec(0))]], anchor: "khac.jpg")
        }
    }

    @Test func autoReviewThresholdFollowsTheCrowd() {
        #expect(Scorer.autoReviewThreshold(faceScores: [0.1, 0.2], threshold: 0.475) == 0.40)  // ít mặt: mặc định
        let low = [Float](repeating: 0.05, count: 400)
        #expect(Scorer.autoReviewThreshold(faceScores: low, threshold: 0.475) == 0.40)
        let spread = (0..<400).map { Float($0 % 2 == 0 ? 0.0 : 0.3) }  // tb 0.15, lệch chuẩn 0.15 -> 0.60, bị chặn bởi ngưỡng
        #expect(Scorer.autoReviewThreshold(faceScores: spread, threshold: 0.475) == 0.475)
        let mid = (0..<400).map { Float($0 % 2 == 0 ? 0.1 : 0.2) }  // tb 0.15, lệch chuẩn 0.05 -> 0.30 -> sàn 0.40
        #expect(Scorer.autoReviewThreshold(faceScores: mid, threshold: 0.475) == 0.40)
    }

    @Test func searchRanksAndExpands() {
        let ref = RefFace(item: item("ref.jpg"), faceIndex: 0, face: face(vec(0)), similarity: 1)
        let items = [item("la.jpg"), item("gan.jpg"), item("trung.jpg"), item("khong_mat.jpg")]
        let faces: [String: [FaceRecord]] = [
            items[0].key: [face(vec(5))],
            items[1].key: [face(vec(0, tilt: 1.0))],             // cosine ~0.707 với mẫu
            items[2].key: [face(vec(5)), face(vec(0, tilt: 0.05))],  // có người cần tìm, cạnh một người lạ
        ]
        var options = SearchOptions()
        options.expand = false
        let plain = Scorer.search(references: [ref], items: items, faces: faces, options: options)
        #expect(plain.scores.map(\.item.name) == ["trung.jpg", "gan.jpg", "la.jpg", "khong_mat.jpg"])
        #expect(plain.scores[3].score == -1 && plain.scores[3].faceCount == 0)
        #expect(plain.matched.count == 2 && plain.expandedBy == 0)
        #expect(plain.status(of: 0.5) == .matched && plain.status(of: 0.42) == .review && plain.status(of: 0.2) == MatchStatus.none)

        let expanded = Scorer.search(references: [ref], items: items, faces: faces)
        #expect(expanded.expandedBy == 2)
        // "gan.jpg" đã thành ảnh mẫu bổ sung nên tâm dịch về phía nó: điểm của nó tăng lên
        #expect(expanded.scores.first { $0.item.name == "gan.jpg" }!.score > plain.scores.first { $0.item.name == "gan.jpg" }!.score)
    }

    @Test func csvMatchesPythonFormat() {
        let ref = RefFace(item: item("ref.jpg"), faceIndex: 0, face: face(vec(0)), similarity: 1)
        let items = [item("a, \"b\".jpg"), item("hong.jpg")]
        let result = Scorer.search(references: [ref], items: items, faces: [items[0].key: [face(vec(0))]])
        let text = String(decoding: Report.csv(result, errors: [items[1].key: "ImageLoaderError"]), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "\u{FEFF}tên file,điểm,kết quả,số khuôn mặt,nguồn,lỗi")
        #expect(lines[1] == "\"a, \"\"b\"\".jpg\",1.000,Khớp,1,\"/x/a, \"\"b\"\".jpg\",")
        #expect(lines[2] == "hong.jpg,-1.000,Lỗi đọc ảnh,0,/x/hong.jpg,ImageLoaderError")
    }
}

@Suite struct StorageTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func indexRoundTripAndInvalidation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.sqlite")
        let index = try FaceIndex(url: url)
        let a = ImageItem(key: "/p/a.jpg", zipPath: nil, member: nil, name: "a.jpg", size: 10, mtime: .distantPast, stamp: "10:1")
        let b = ImageItem(key: "/p/b.jpg", zipPath: nil, member: nil, name: "b.jpg", size: 20, mtime: .distantPast, stamp: "20:1")
        let emb = (0..<512).map { Float(Float16(Float($0) / 1000 - 0.25)) }
        let f = FaceRecord(x: 1.5, y: 2.5, width: 30, height: 40, landmarks: (0..<10).map(Float.init), detectionScore: 0.875, embedding: emb)
        try index.store([(a, [f, f]), (b, [])], signature: "s1")

        let got = try index.load([a, b], signature: "s1")
        #expect(got[a.key]?.count == 2 && got[b.key]?.count == 0)  // ảnh không có mặt vẫn được nhớ là đã quét
        #expect(got[a.key]?[1].embedding == emb && got[a.key]?[0].landmarks == f.landmarks && got[a.key]?[0].width == 30)
        #expect(try index.load([a], signature: "s2").isEmpty)  // đổi cấu hình phân tích
        let changed = ImageItem(key: a.key, zipPath: nil, member: nil, name: "a.jpg", size: 11, mtime: .distantPast, stamp: "11:2")
        #expect(try index.load([changed], signature: "s1").isEmpty)  // file đã đổi
        try index.store([(changed, [f])], signature: "s1")  // ghi đè, không nhân đôi
        #expect(try index.counts() == (2, 1))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        try index.removeAll()
        #expect(try index.counts() == (0, 0))
    }

    @Test func absolutePathBehavesLikePythonAbspath() {
        #expect(ImageSource.absolutePath("/private/tmp/a/./b/../c//d.jpg") == "/private/tmp/a/c/d.jpg")  // giữ /private
        #expect(ImageSource.absolutePath("/a/../../b/") == "/b")
        #expect(ImageSource.absolutePath("~/x") == NSHomeDirectory() + "/x")
        #expect(ImageSource.absolutePath("anh/1.jpg") == FileManager.default.currentDirectoryPath + "/anh/1.jpg")
    }

    @Test func collectKeepsThePathAsGiven() throws {
        // /var/folders/... là symlink tới /private/var/...: khoá của ảnh phải giữ đúng dạng người dùng đưa vào
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 3).write(to: dir.appendingPathComponent("a.jpg"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Ảnh lớp/ngày 2"), withIntermediateDirectories: true)
        try Data(count: 5).write(to: dir.appendingPathComponent("Ảnh lớp/ngày 2/b.jpg"))
        let items = ImageSource.collect([dir.path + "/./"])
        #expect(items.map(\.key) == [dir.path + "/a.jpg", dir.path + "/Ảnh lớp/ngày 2/b.jpg"])
        #expect(ImageSource.collect([dir.path + "/a.jpg"]).map(\.key) == [dir.path + "/a.jpg"])  // một file lẻ
    }

    @Test func collectSkipsHiddenResultFoldersAndDuplicates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        func put(_ path: String, _ bytes: Int = 3) throws {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try put("b.JPG"); try put("a.jpg"); try put("ghi_chu.txt"); try put(".an.jpg")
        try put("con/c.png"); try put("con/a.jpg")              // trùng tên + dung lượng với a.jpg ở trên
        try put(".thu_muc_an/d.jpg")
        try put("Face Finder - Be/e.jpg"); try put("Face Finder - Be/.facefinder", 0)  // thư mục kết quả của app
        try put("loai_tru/f.jpg")
        let items = ImageSource.collect([dir.path], excluding: [dir.appendingPathComponent("loai_tru").path])
        #expect(items.map(\.name) == ["a.jpg", "b.JPG", "a.jpg", "c.png"])
        #expect(ImageSource.dedupe(items).map(\.name) == ["a.jpg", "b.JPG", "c.png"])
    }
}
