import Foundation

/// Một file do app tạo trong thư mục kết quả.
public struct OutputFile: Codable, Sendable, Hashable {
    /// Đường dẫn tương đối với thư mục kết quả (nên chuyển cả thư mục đi chỗ khác vẫn đúng).
    public var path: String
    public var sourceKey: String
    public var size: Int64
    /// Nằm trong "Cần kiểm tra/" (không thì nằm ngay trong thư mục kết quả).
    public var review: Bool
}

public enum ResultFolderError: Error, CustomStringConvertible {
    case notOurs(String)

    public var description: String {
        switch self {
        case .notOurs(let path):
            return String(localized: "Thư mục \(path) không do Face Finder tạo cho người này, không ghi vào đó.", bundle: .module)
        }
    }
}

/// Thư mục kết quả của một người (PLAN.md mục 4.1):
///
///     Face Finder - <tên người>/
///       *.JPG            ảnh khớp
///       Cần kiểm tra/
///       _báo cáo/        ket_qua.csv
///       .facefinder      file đánh dấu: thư mục do app tạo (khi lập chỉ mục, thư mục có file này bị bỏ qua)
public enum ResultFolder {
    public static let prefix = "Face Finder - "

    public static func folderName(for personName: String) -> String {
        let clean = personName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + (clean.isEmpty ? "Không tên" : clean)
    }

    /// Người sở hữu thư mục (đọc từ file đánh dấu); `nil` nếu không phải thư mục của app.
    public static func owner(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ImageSource.resultMarker)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["person"] as? String
    }

    /// Chọn thư mục kết quả trong `base`: dùng lại thư mục của chính người này; tên đã bị một thư mục khác chiếm
    /// thì thêm " (2)", " (3)"...
    /// `reserved`: thư mục đã dành cho người khác nhưng có thể chưa được tạo trên đĩa.
    public static func choose(in base: URL, personName: String, personID: String, reserved: Set<String> = []) -> URL {
        let fm = FileManager.default
        let name = folderName(for: personName)
        for n in 1... {
            let url = base.appendingPathComponent(n == 1 ? name : "\(name) (\(n))", isDirectory: true)
            if reserved.contains(url.standardizedFileURL.path) { continue }
            if !fm.fileExists(atPath: url.path) || owner(of: url) == personID { return url }
        }
        fatalError("không tới được")
    }

    static func writeMarker(_ folder: URL, personID: String, personName: String) throws {
        let obj: [String: Any] = ["app": "Face Finder", "person": personID, "name": personName,
                                  "note": "Thư mục kết quả do Face Finder tạo. Ảnh bạn tự thêm vào đây sẽ không bị app đụng tới."]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent(ImageSource.resultMarker))
    }

    /// Chuyển (hoặc sao chép) cả thư mục kết quả vào `parent`. Trả về đường dẫn mới.
    public static func relocate(_ folder: URL, to parent: URL, personName: String, personID: String, copy: Bool) throws -> URL {
        var dest = choose(in: parent, personName: personName, personID: personID)
        if dest.standardizedFileURL == folder.standardizedFileURL { return folder }
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            // thư mục cũ của chính người này ở chỗ mới: không ghi đè, đặt tên khác
            dest = choose(in: parent, personName: personName, personID: UUID().uuidString)
        }
        if copy {
            try fm.copyItem(at: folder, to: dest)
        } else {
            try fm.moveItem(at: folder, to: dest)
        }
        return dest
    }
}

public struct SyncSummary: Sendable {
    /// File do app quản lý sau lần đồng bộ này (kể cả khi có lỗi giữa chừng: luôn phải lưu lại danh sách này).
    public var files: [OutputFile]
    public var added = 0, removed = 0, moved = 0
    /// Lỗi từng file (ảnh gốc không đọc được, Thùng rác không dùng được trên ổ mạng...). Các file khác vẫn được xử lý.
    public var errors: [String] = []
    /// Thư mục kết quả biến mất / bị chuyển đi trong lúc ghi: dừng lại, không tạo lại thư mục cũ.
    public var interrupted = false
}

/// Ghi kết quả tìm vào thư mục kết quả và giữ nó luôn khớp với kết quả hiện tại (đổi ngưỡng thì thêm/bỏ ảnh).
///
/// An toàn: chỉ thêm, chuyển, xoá những file nằm trong `previous` (do chính app tạo) và vẫn còn nguyên dung lượng;
/// xoá thì đưa vào Thùng rác. File người dùng tự bỏ vào không bao giờ bị đụng tới. Ảnh gốc không bị đổi.
public enum ResultWriter {
    /// `discard`: cách bỏ một file không còn khớp (mặc định đưa vào Thùng rác; test thì xoá hẳn).
    public static func sync(folder: URL, personID: String, personName: String, result: SearchResult,
                            previous: [OutputFile],
                            discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        throws -> SyncSummary {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            if let owner = ResultFolder.owner(of: folder), owner != personID { throw ResultFolderError.notOurs(folder.path) }
            if ResultFolder.owner(of: folder) == nil, !((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
                throw ResultFolderError.notOurs(folder.path)
            }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ResultFolder.writeMarker(folder, personID: personID, personName: personName)
        let reviewDir = folder.appendingPathComponent(Report.reviewDirectory, isDirectory: true)

        var wanted: [String: (item: ImageItem, review: Bool)] = [:]
        var order: [String] = []
        for s in result.scores {
            let status = result.status(of: s)
            guard status == .matched || status == .review else { continue }
            if wanted[s.item.key] == nil { order.append(s.item.key) }
            wanted[s.item.key] = (s.item, status == .review)
        }

        var summary = SyncSummary(files: [])
        var kept: [String: OutputFile] = [:]
        var untouched: [OutputFile] = []  // vẫn của app, giữ nguyên chỗ cũ (ảnh gốc biến mất, hoặc không xoá/chuyển được)
        func url(_ f: OutputFile) -> URL { folder.appendingPathComponent(f.path) }
        func intact(_ f: OutputFile) -> Bool {
            ((try? fm.attributesOfItem(atPath: url(f).path)[.size]) as? NSNumber)?.int64Value == f.size
        }
        /// Thư mục kết quả vẫn ở đây và vẫn là của người này (người dùng có thể chuyển nó đi trong lúc đang ghi).
        func stillOurs() -> Bool {
            if ResultFolder.owner(of: folder) == personID { return true }
            summary.interrupted = true
            return false
        }
        func ensureReviewDir() throws {
            if !fm.fileExists(atPath: reviewDir.path) {
                try fm.createDirectory(at: reviewDir, withIntermediateDirectories: false)  // không tạo lại thư mục cha
            }
        }

        // 1. file cũ: còn cần thì giữ (chuyển nhóm nếu cần), không cần thì đưa vào Thùng rác
        let scored = Set(result.scores.map(\.item.key))
        for f in previous {
            guard intact(f) else { continue }  // người dùng đã xoá/sửa: bỏ khỏi danh sách, không đụng tới
            // Ảnh gốc không còn trong thư viện (bị xoá, ổ đĩa rút ra, nguồn bị bỏ...): không biết nó có khớp không,
            // nên giữ nguyên bản sao — có khi đó là bản duy nhất còn lại.
            guard scored.contains(f.sourceKey), !summary.interrupted else {
                untouched.append(f)
                continue
            }
            guard let w = wanted[f.sourceKey], kept[f.sourceKey] == nil else {
                do {
                    try discard(url(f))
                    summary.removed += 1
                } catch {
                    untouched.append(f)  // vd. ổ mạng không có Thùng rác: để nguyên, vẫn theo dõi
                    summary.errors.append("\((f.path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
                continue
            }
            if w.review == f.review || !stillOurs() {
                kept[f.sourceKey] = f
                continue
            }
            do {
                if w.review { try ensureReviewDir() }
                let dest = uniqueURL(in: w.review ? reviewDir : folder, name: (f.path as NSString).lastPathComponent)
                try fm.moveItem(at: url(f), to: dest)
                kept[f.sourceKey] = OutputFile(path: relative(dest, to: folder), sourceKey: f.sourceKey, size: f.size, review: w.review)
                summary.moved += 1
            } catch {
                kept[f.sourceKey] = f  // chưa chuyển được: vẫn ở chỗ cũ
                summary.errors.append("\((f.path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 2. ảnh mới khớp: chép (ảnh trong zip thì giải nén ra bản sao)
        let reader = ItemReader()
        for key in order where kept[key] == nil {
            guard stillOurs() else { break }
            let (item, review) = wanted[key]!
            var dest: URL?
            do {
                if review { try ensureReviewDir() }
                let target = uniqueURL(in: review ? reviewDir : folder, name: item.name)
                dest = target
                if item.zipPath == nil {
                    try fm.copyItem(at: URL(fileURLWithPath: item.key), to: target)
                } else {
                    try reader.read(item).write(to: target)
                    try? fm.setAttributes([.modificationDate: item.mtime], ofItemAtPath: target.path)
                }
                let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value ?? item.size
                kept[key] = OutputFile(path: relative(target, to: folder), sourceKey: key, size: size, review: review)
                summary.added += 1
            } catch {
                if let d = dest, fm.fileExists(atPath: d.path) { try? fm.removeItem(at: d) }  // bản chép dở do chính app tạo
                summary.errors.append("\(item.name): \(error.localizedDescription)")
            }
        }

        // 3. báo cáo
        if stillOurs() {
            let reportDir = folder.appendingPathComponent(Report.reportDirectory, isDirectory: true)
            try? fm.createDirectory(at: reportDir, withIntermediateDirectories: false)
            try? Report.csv(result, errors: [:]).write(to: reportDir.appendingPathComponent(Report.csvName))
            if let left = try? fm.contentsOfDirectory(atPath: reviewDir.path), left.isEmpty { try? fm.removeItem(at: reviewDir) }
        }

        summary.files = order.compactMap { kept[$0] } + untouched
        return summary
    }

    /// Tên chưa có trong thư mục: `a.jpg`, rồi `a_1.jpg`, `a_2.jpg`... (như CLI).
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 1
        while (try? url.checkResourceIsReachable()) == true || FileManager.default.fileExists(atPath: url.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)")
            n += 1
        }
        return url
    }

    static func relative(_ url: URL, to folder: URL) -> String {
        let p = url.standardizedFileURL.path, f = folder.standardizedFileURL.path
        return p.hasPrefix(f + "/") ? String(p.dropFirst(f.count + 1)) : url.lastPathComponent
    }
}
