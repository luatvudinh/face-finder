import FaceFinderKit
import Foundation

/// File tạm để xem ảnh bằng Quick Look: ảnh thường thì dùng thẳng file gốc, ảnh trong zip thì giải nén một bản vào
/// thư mục tạm riêng của app (xoá khi mở app lần sau).
enum PreviewFiles {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("FaceFinderPreview", isDirectory: true) }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func url(for item: ImageItem) async -> URL? {
        guard item.zipPath != nil else { return URL(fileURLWithPath: item.key) }
        let folder = directory.appendingPathComponent(String(format: "%016llx", UInt64(bitPattern: Int64(stableHash(item.key)))))
        let url = folder.appendingPathComponent(item.name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let data = try? ItemReader().read(item) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try? data.write(to: url)) != nil ? url : nil
        }.value
    }

    /// Băm cố định giữa các lần chạy (Hasher của Swift thì đổi mỗi lần).
    private static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return Int(bitPattern: UInt(h))
    }
}
