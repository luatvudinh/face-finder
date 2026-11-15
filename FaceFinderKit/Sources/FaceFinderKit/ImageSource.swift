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

    public init(key: String, zipPath: String?, member: String?, name: String, size: Int64, mtime: Date, stamp: String) {
        self.key = key; self.zipPath = zipPath; self.member = member; self.name = name
        self.size = size; self.mtime = mtime; self.stamp = stamp
    }
}

public enum ImageSource {
    public static let imageExtensions: Set<String> = Set(["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff", "heic", "heif"])
        .union(rawExtensions)
    /// Ảnh RAW của máy ảnh (đọc bằng ImageIO). CLI Python không đọc các định dạng này.
    public static let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "nrw", "dng", "raf", "orf", "rw2", "pef", "srw", "3fr", "rwl"]
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
                warn(String(localized: "Không tìm thấy: \(p)", bundle: .module))
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
            warn(String(localized: "Bỏ qua file zip hỏng: \(path)", bundle: .module))
            return []
        }
        var items: [ImageItem] = []
        var listed = 0
        for entry in archive {
            listed += 1
            guard entry.type == .file else { continue }
            let name = (entry.path as NSString).lastPathComponent
            if name.hasPrefix("._") || entry.path.contains("__MACOSX") { continue }
            guard imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let mtime = entry.fileAttributes[.modificationDate] as? Date ?? .distantPast
            items.append(ImageItem(key: "\(path)::\(entry.path)", zipPath: path, member: entry.path, name: name,
                                   size: Int64(entry.uncompressedSize), mtime: mtime,
                                   stamp: "\(entry.uncompressedSize):crc\(entry.checksum)"))
        }
        // ZIPFoundation lặng lẽ bỏ qua file được mã hoá: so với số file khai báo trong zip để báo cho người dùng.
        // Khi gặp một file mã hoá, ZIPFoundation dừng luôn việc liệt kê: các ảnh sau đó cũng bị bỏ, nên đếm theo tổng số
        // ảnh khai báo trong zip trừ số ảnh liệt kê được.
        if let info = ZipInspector.inspect(path), info.entries > listed, info.encryptedImages > 0 {
            let count = max(info.encryptedImages, info.imageEntries - items.count), zipName = (path as NSString).lastPathComponent
            warn(String(localized: "\(count) ảnh trong \(zipName) được bảo vệ bằng mật khẩu, app chưa đọc được. Giải nén bằng Finder rồi thêm thư mục đã giải nén.",
                        bundle: .module))
        }
        return items
    }

    /// Bỏ ảnh trùng (cùng tên và dung lượng), ví dụ vừa có trong zip vừa có bản đã giải nén. Giữ bản gặp trước.
    /// Ảnh RAW có bản JPEG/HEIC cùng tên ở cùng chỗ (máy ảnh chụp RAW+JPEG) thì chỉ giữ bản JPEG/HEIC.
    public static func dedupe(_ items: [ImageItem]) -> [ImageItem] {
        struct Key: Hashable { let name: String; let size: Int64 }
        struct Sibling: Hashable { let place: String; let stem: String }
        func sibling(_ i: ImageItem) -> Sibling {
            let place = i.zipPath.map { $0 + "::" + ((i.member ?? "") as NSString).deletingLastPathComponent }
                ?? (i.key as NSString).deletingLastPathComponent
            return Sibling(place: place, stem: i.stem.lowercased())
        }
        func isRAW(_ i: ImageItem) -> Bool { rawExtensions.contains((i.name as NSString).pathExtension.lowercased()) }
        let developed = Set(items.filter { !isRAW($0) }.map(sibling))
        var seen = Set<Key>()
        return items.filter { item in
            if isRAW(item), developed.contains(sibling(item)) { return false }
            return seen.insert(Key(name: item.name.lowercased(), size: item.size)).inserted
        }
    }
}

public enum ImageSourceError: Error, CustomStringConvertible {
    case missingMember(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .missingMember(let key): return String(localized: "không còn thấy file trong zip: \(key)", bundle: .module)
        case .unreadable(let key): return String(localized: "không đọc được: \(key)", bundle: .module)
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

/// Đọc thẳng "thư mục trung tâm" của file zip (không qua ZIPFoundation) để đếm file bị mã hoá.
enum ZipInspector {
    struct Info { let entries: Int; let imageEntries: Int; let encryptedImages: Int }

    static func inspect(_ path: String) -> Info? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 22 else { return nil }
        let tailLength = min(size, 65_557)
        try? h.seek(toOffset: size - tailLength)
        guard let tail = try? h.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let t = [UInt8](tail)
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
        // bản ghi kết thúc thư mục trung tâm: chữ ký 50 4B 05 06, tìm từ cuối file
        guard let eocd = stride(from: t.count - 22, through: 0, by: -1).first(where: {
            t[$0] == 0x50 && t[$0 + 1] == 0x4B && t[$0 + 2] == 0x05 && t[$0 + 3] == 0x06
        }) else { return nil }
        let entries = u16(t, eocd + 10), cdSize = u32(t, eocd + 12), cdOffset = u32(t, eocd + 16)
        guard cdOffset != 0xFFFF_FFFF, cdSize > 0, UInt64(cdOffset + cdSize) <= size else { return nil }  // ZIP64: bỏ qua
        try? h.seek(toOffset: UInt64(cdOffset))
        guard let cdData = try? h.read(upToCount: cdSize) else { return nil }
        let cd = [UInt8](cdData)
        var o = 0, encrypted = 0, images = 0
        while o + 46 <= cd.count, cd[o] == 0x50, cd[o + 1] == 0x4B, cd[o + 2] == 0x01, cd[o + 3] == 0x02 {
            let flags = u16(cd, o + 8), nameLength = u16(cd, o + 28), extra = u16(cd, o + 30), comment = u16(cd, o + 32)
            guard o + 46 + nameLength <= cd.count else { break }
            let name = String(decoding: cd[(o + 46)..<(o + 46 + nameLength)], as: UTF8.self)
            let ext = (name as NSString).pathExtension.lowercased()
            let isImage = ImageSource.imageExtensions.contains(ext) && !name.contains("__MACOSX")
                && !(name as NSString).lastPathComponent.hasPrefix("._")
            if isImage { images += 1 }
            if flags & 1 != 0, isImage { encrypted += 1 }
            o += 46 + nameLength + extra + comment
        }
        return Info(entries: entries, imageEntries: images, encryptedImages: encrypted)
    }
}
