import Foundation
import GRDB

/// Một nguồn ảnh trong thư viện: thư mục (quét đệ quy) hoặc file zip.
public struct SourceRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var path: String
    public var isZip: Bool
    /// Security-scoped bookmark: để app sandbox đọc lại được nguồn sau khi khởi động lại.
    public var bookmark: Data?
    public var addedAt: Date

    public var name: String { (path as NSString).lastPathComponent }

    /// Nơi ghi kết quả mặc định (PLAN.md mục 4.1): chính thư mục nguồn, hoặc thư mục chứa file zip.
    public var defaultOutputBase: String { isZip ? (path as NSString).deletingLastPathComponent : path }

    /// Ảnh `key` có thuộc nguồn này không.
    public func contains(key: String) -> Bool {
        isZip ? key.hasPrefix(path + "::") : key.hasPrefix(path + "/")
    }
}

/// Một khuôn mặt mẫu của người cần tìm, lưu sẵn để không phải đọc lại ảnh mẫu.
public struct PersonReference: Codable, Sendable, Hashable {
    public var imageName: String
    public var imageKey: String
    public var embedding: [Float]
    /// Ảnh JPEG nhỏ của khuôn mặt, để hiển thị.
    public var thumbnail: Data?

    public init(imageName: String, imageKey: String, embedding: [Float], thumbnail: Data?) {
        self.imageName = imageName
        self.imageKey = imageKey
        self.embedding = embedding
        self.thumbnail = thumbnail
    }
}

public struct PersonRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    /// Định danh bền vững, ghi vào file đánh dấu của thư mục kết quả.
    public var uuid: String
    public var name: String
    public var createdAt: Date
    public var threshold: Double
    public var references: [PersonReference]
    /// Thư mục "Face Finder - <tên>" đang dùng; `nil` = chưa chọn.
    public var outputFolder: String?
    /// File do app tạo trong thư mục kết quả (chỉ những file này mới được app sửa/xoá).
    public var outputFiles: [OutputFile]
}

extension FaceIndex {
    // MARK: nguồn ảnh

    public func sources() throws -> [SourceRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, path, isZip, bookmark, addedAt FROM sources ORDER BY id").map {
                SourceRecord(id: $0[0], path: $0[1], isZip: $0[2], bookmark: $0[3], addedAt: Date(timeIntervalSince1970: $0[4]))
            }
        }
    }

    /// Thêm nguồn (thêm lại cùng đường dẫn thì chỉ cập nhật bookmark).
    @discardableResult
    public func addSource(path: String, isZip: Bool, bookmark: Data?) throws -> SourceRecord {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO sources (path, isZip, bookmark, addedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET bookmark = excluded.bookmark
                """, arguments: [path, isZip, bookmark, Date().timeIntervalSince1970])
        }
        return try sources().first { $0.path == path }!
    }

    /// Bỏ nguồn khỏi thư viện. Dữ liệu khuôn mặt của ảnh trong nguồn này cũng bị xoá.
    public func removeSource(_ source: SourceRecord) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [source.id])
            let pattern = source.isZip ? source.path + "::%" : source.path + "/%"
            try db.execute(sql: "DELETE FROM images WHERE key LIKE ? ESCAPE '\\'",
                           arguments: [pattern.replacingOccurrences(of: "_", with: "\\_")])
        }
    }

    // MARK: quyền ghi thư mục

    public func grants() throws -> [(path: String, bookmark: Data)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT path, bookmark FROM grants").map { ($0[0], $0[1]) }
        }
    }

    public func saveGrant(path: String, bookmark: Data) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO grants (path, bookmark) VALUES (?, ?)", arguments: [path, bookmark])
        }
    }

    // MARK: người

    public func people() throws -> [PersonRecord] {
        let decoder = JSONDecoder()
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, uuid, name, createdAt, threshold, refs, outputFolder, outputFiles FROM people ORDER BY id
                """).map { row in
                PersonRecord(id: row[0], uuid: row[1], name: row[2], createdAt: Date(timeIntervalSince1970: row[3]), threshold: row[4],
                             references: (try? decoder.decode([PersonReference].self, from: row[5] as Data)) ?? [],
                             outputFolder: row[6],
                             outputFiles: (try? decoder.decode([OutputFile].self, from: row[7] as Data)) ?? [])
            }
        }
    }

    public func addPerson(name: String, references: [PersonReference], threshold: Double, outputFolder: String?) throws -> PersonRecord {
        let uuid = UUID().uuidString
        let refs = try JSONEncoder().encode(references)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO people (uuid, name, createdAt, threshold, refs, outputFolder, outputFiles) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [uuid, name, Date().timeIntervalSince1970, threshold, refs, outputFolder, Data("[]".utf8)])
        }
        return try people().first { $0.uuid == uuid }!
    }

    public func updatePerson(_ p: PersonRecord) throws {
        let encoder = JSONEncoder()
        let refs = try encoder.encode(p.references), files = try encoder.encode(p.outputFiles)
        try db.write { db in
            try db.execute(sql: """
                UPDATE people SET name = ?, threshold = ?, refs = ?, outputFolder = ?, outputFiles = ? WHERE id = ?
                """, arguments: [p.name, p.threshold, refs, p.outputFolder, files, p.id])
        }
    }

    public func deletePerson(id: Int64) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id]) }
    }

    /// Dung lượng file chỉ mục (byte).
    public func fileSize() -> Int64 {
        let path = db.path
        return ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
