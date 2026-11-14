import Foundation
import ZIPFoundation

/// Một ảnh cần xử lý: file thường, hoặc một file nằm trong zip (đọc thẳng, không giải nén ra đĩa).
public struct ImageItem: Sendable, Hashable {
    /// Định danh duy nhất: đường dẫn, hoặc `đường_dẫn_zip::tên_trong_zip` (cùng quy ước với CLI Python).
    public let key: String
    public let zipPath: String?
    public let member: String?
    public let name: String
    public let size: Int64
    public let mtime: Date
    /// Dấu nhận biết file đã đổi hay chưa: dung lượng + thời điểm sửa (file thường) hoặc dung lượng + CRC (trong zip).
    public let stamp: String

    public var stem: String { (name as NSString).deletingPathExtension }
}

public enum ImageSource {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff", "heic", "heif"]
    /// Thư mục có file này là thư mục kết quả do app tạo: bỏ qua khi quét (PLAN.md mục 4.1).
    public static let resultMarker = ".facefinder"

    /// Gom danh sách ảnh từ các file / thư mục / zip. Thư mục được quét đệ quy theo thứ tự tên, bỏ file và thư mục ẩn.
    public static func collect(_ paths: [String], since: Date? = nil, excluding: [String] = [],
                               warn: (String) -> Void = { _ in }) -> [ImageItem] {
        let fm = FileManager.default
        let excluded = Set(excluding.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var items: [ImageItem] = []

        func add(_ path: String) {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") { return }
            guard let attrs = try? fm.attributesOfItem(atPath: path), let mtime = attrs[.modificationDate] as? Date else { return }
            if let since, mtime < since { return }
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "zip" {
                items += zipItems(path, warn: warn)
            } else if imageExtensions.contains(ext) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let ns = Int64((mtime.timeIntervalSince1970 * 1e9).rounded())
                items.append(ImageItem(key: path, zipPath: nil, member: nil, name: name, size: size, mtime: mtime, stamp: "\(size):\(ns)"))
            }
        }

        func walk(_ dir: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if names.contains(resultMarker) { return }
            var files: [String] = [], dirs: [String] = []
            for n in names {
                var isDir: ObjCBool = false
                let p = (dir as NSString).appendingPathComponent(n)
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if isDir.boolValue { dirs.append(n) } else { files.append(n) }
            }
            for f in files.sorted() { add((dir as NSString).appendingPathComponent(f)) }
            for d in dirs.sorted() where !d.hasPrefix(".") {
                let p = (dir as NSString).appendingPathComponent(d)
                if !excluded.contains(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) { walk(p) }
            }
        }

        for raw in paths {
            let p = absolutePath(raw)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: p, isDirectory: &isDir) {
                warn("Không tìm thấy: \(p)")
            } else if isDir.boolValue {
                walk(p)
            } else {
                add(p)
            }
        }
        return items
    }

    /// Đường dẫn tuyệt đối, bỏ ".", ".." và "//" nhưng **không** đi theo symlink — như `os.path.abspath` của Python.
    /// Không dùng `standardizedFileURL`/`standardizingPath`: chúng tự cắt tiền tố "/private" (vd. /private/tmp → /tmp),
    /// làm khoá của ảnh trong chỉ mục và cột "nguồn" trong báo cáo khác với CLI.
    public static func absolutePath(_ raw: String) -> String {
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = FileManager.default.currentDirectoryPath + "/" + path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func zipItems(_ path: String, warn: (String) -> Void) -> [ImageItem] {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
            warn("Bỏ qua file zip hỏng: \(path)")
            return []
        }
        var items: [ImageItem] = []
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            if name.hasPrefix("._") || entry.path.contains("__MACOSX") { continue }
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let mtime = entry.fileAttributes[.modificationDate] as? Date ?? .distantPast
            items.append(ImageItem(key: "\(path)::\(entry.path)", zipPath: path, member: entry.path, name: name,
                                   size: Int64(entry.uncompressedSize), mtime: mtime,
                                   stamp: "\(entry.uncompressedSize):crc\(entry.checksum)"))
        }
        return items
    }

    /// Bỏ ảnh trùng (cùng tên và dung lượng), ví dụ vừa có trong zip vừa có bản đã giải nén. Giữ bản gặp trước.
    public static func dedupe(_ items: [ImageItem]) -> [ImageItem] {
        struct Key: Hashable { let name: String; let size: Int64 }
        var seen = Set<Key>()
        return items.filter { seen.insert(Key(name: $0.name.lowercased(), size: $0.size)).inserted }
    }
}

public enum ImageSourceError: Error, CustomStringConvertible {
    case missingMember(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .missingMember(let key): return "không còn thấy file trong zip: \(key)"
        case .unreadable(let key): return "không đọc được: \(key)"
        }
    }
}

/// Đọc nội dung ảnh. Mỗi luồng xử lý dùng một `ItemReader` riêng (file zip đang mở không dùng chung giữa các luồng).
public final class ItemReader {
    private var archives: [String: (Archive, [String: Entry])] = [:]

    public init() {}

    public func read(_ item: ImageItem) throws -> Data {
        guard let zipPath = item.zipPath, let member = item.member else {
            return try Data(contentsOf: URL(fileURLWithPath: item.key), options: .mappedIfSafe)
        }
        if archives[zipPath] == nil {
            let archive = try Archive(url: URL(fileURLWithPath: zipPath), accessMode: .read)
            archives[zipPath] = (archive, Dictionary(archive.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        guard let (archive, entries) = archives[zipPath], let entry = entries[member] else {
            throw ImageSourceError.missingMember(item.key)
        }
        var data = Data(capacity: Int(entry.uncompressedSize))
        _ = try archive.extract(entry, bufferSize: 1 << 20) { data.append($0) }
        return data
    }
}
