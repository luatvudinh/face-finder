import Foundation
import GRDB

/// Chỉ mục khuôn mặt (SQLite): lập một lần, sau đó tìm bất kỳ ai cũng không phải quét lại ảnh.
///
/// File chứa "vân mặt" (dữ liệu sinh trắc học) nên chỉ chủ máy được đọc/ghi.
public final class FaceIndex: Sendable {
    let db: DatabaseQueue

    public static var defaultURL: URL {
        // Application Support chứ không phải Caches: ngoài chỉ mục còn có người đã lưu, không được để hệ thống tự xoá.
        // Trong app (sandbox) thư mục này nằm trong container riêng của app.
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FaceFinder/index.sqlite")
    }

    public init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        db = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1: images + faces") { db in
            try db.execute(sql: """
                CREATE TABLE images (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    key TEXT NOT NULL UNIQUE,        -- đường dẫn, hoặc zip::tên_trong_zip
                    stamp TEXT NOT NULL,             -- dung lượng + mtime/CRC: nhận biết file đã đổi
                    signature TEXT NOT NULL,         -- cấu hình phân tích đã dùng
                    faceCount INTEGER NOT NULL
                );
                CREATE TABLE faces (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    imageId INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
                    idx INTEGER NOT NULL,
                    x REAL NOT NULL, y REAL NOT NULL, width REAL NOT NULL, height REAL NOT NULL,
                    detectionScore REAL NOT NULL,
                    landmarks BLOB NOT NULL,         -- 10 x Float32
                    embedding BLOB NOT NULL          -- 512 x Float16
                );
                CREATE INDEX faces_imageId ON faces(imageId, idx);
                """)
        }
        m.registerMigration("v2: sources + grants + people") { db in
            try db.execute(sql: """
                CREATE TABLE sources (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL UNIQUE,       -- thư mục hoặc file zip
                    isZip INTEGER NOT NULL,
                    bookmark BLOB,                   -- security-scoped bookmark (app sandbox)
                    addedAt REAL NOT NULL
                );
                CREATE TABLE grants (               -- thư mục người dùng cho phép ghi (vd. thư mục chứa zip)
                    path TEXT PRIMARY KEY,
                    bookmark BLOB NOT NULL
                );
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    uuid TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    threshold REAL NOT NULL,
                    refs BLOB NOT NULL,              -- JSON [PersonReference]: khuôn mặt mẫu + ảnh nhỏ
                    outputFolder TEXT,               -- thư mục "Face Finder - <tên>" đang dùng
                    outputFiles BLOB NOT NULL        -- JSON [OutputFile]: file do app tạo trong thư mục đó
                );
                """)
        }
        return m
    }

    /// Lấy kết quả đã lưu cho những ảnh chưa đổi (cùng `stamp`) và cùng cấu hình phân tích.
    public func load(_ items: [ImageItem], signature: String) throws -> [String: [FaceRecord]] {
        let wanted = Dictionary(items.map { ($0.key, $0.stamp) }, uniquingKeysWith: { a, _ in a })
        var out: [String: [FaceRecord]] = [:]
        try db.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT i.key, i.stamp, f.idx, f.x, f.y, f.width, f.height, f.detectionScore, f.landmarks, f.embedding
                FROM images i LEFT JOIN faces f ON f.imageId = i.id
                WHERE i.signature = ? ORDER BY i.id, f.idx
                """, arguments: [signature])
            while let row = try rows.next() {
                let key: String = row[0]
                guard wanted[key] == (row[1] as String) else { continue }
                guard let _: Int = row[2] else { out[key] = []; continue }  // ảnh không có khuôn mặt
                let lm: Data = row[8], emb: Data = row[9]
                out[key, default: []].append(FaceRecord(
                    x: Float(row[3] as Double), y: Float(row[4] as Double), width: Float(row[5] as Double), height: Float(row[6] as Double),
                    landmarks: lm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) },
                    detectionScore: Float(row[7] as Double),
                    embedding: emb.withUnsafeBytes { $0.bindMemory(to: Float16.self).map { Float($0) } }))
            }
        }
        return out
    }

    /// Ghi (hoặc ghi đè) kết quả phân tích của một loạt ảnh trong một giao dịch.
    public func store(_ entries: [(item: ImageItem, faces: [FaceRecord])], signature: String) throws {
        if entries.isEmpty { return }
        try db.write { db in
            for (item, faces) in entries {
                try db.execute(sql: "DELETE FROM images WHERE key = ?", arguments: [item.key])
                try db.execute(sql: "INSERT INTO images (key, stamp, signature, faceCount) VALUES (?, ?, ?, ?)",
                               arguments: [item.key, item.stamp, signature, faces.count])
                let imageId = db.lastInsertedRowID
                for (idx, f) in faces.enumerated() {
                    let lm = f.landmarks.withUnsafeBufferPointer { Data(buffer: $0) }
                    let emb = f.embedding.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
                    try db.execute(sql: """
                        INSERT INTO faces (imageId, idx, x, y, width, height, detectionScore, landmarks, embedding)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [imageId, idx, Double(f.x), Double(f.y), Double(f.width), Double(f.height),
                                         Double(f.detectionScore), lm, emb])
                }
            }
        }
    }

    public func counts() throws -> (images: Int, faces: Int) {
        try db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM images") ?? 0, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM faces") ?? 0)
        }
    }

    /// "Xoá toàn bộ dữ liệu khuôn mặt": chỉ mục và người đã lưu (cả hai đều chứa "vân mặt").
    /// Giữ lại danh sách nguồn ảnh và quyền truy cập thư mục. Thư mục kết quả đã ghi ra không bị đụng tới.
    public func removeAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM images")
            try db.execute(sql: "DELETE FROM people")
        }
        try db.vacuum()
    }
}
