import FaceFinderKit
import Foundation

/// `ffcli find`: bản Swift của lệnh findface, dùng để so kết quả và tốc độ với CLI Python.
struct Find {
    let args: Arguments

    init(_ args: Arguments) { self.args = args }

    func run() async throws {
        let refPaths = args.list("ref"), inputPaths = args.list("input")
        guard !refPaths.isEmpty, !inputPaths.isEmpty, let outArg = args.string("output") else {
            fail("cần đủ -r ẢNH_MẪU, -i NGUỒN và -o THƯ_MỤC (xem ffcli help)")
        }
        let out = URL(fileURLWithPath: ImageSource.absolutePath(outArg))
        var options = SearchOptions()
        options.threshold = args.double("threshold") ?? options.threshold
        options.review = args.double("review")
        options.expand = !args.has("no-expand")
        options.expandThreshold = args.double("expand-threshold") ?? options.expandThreshold

        log("Đang liệt kê ảnh...")
        let warn: (String) -> Void = { log("  " + $0) }
        let refItems = ImageSource.dedupe(ImageSource.collect(refPaths, warn: warn))
        if refItems.isEmpty { fail("không tìm thấy ảnh mẫu nào") }
        let since = parseSince(args.string("since"))
        let inputItems = ImageSource.dedupe(ImageSource.collect(inputPaths, since: since, excluding: [out.path], warn: warn))
        if inputItems.isEmpty { fail("không tìm thấy ảnh nào để quét" + (since != nil ? " (kiểm tra lại --since)" : "")) }
        let zips = Set(inputItems.compactMap(\.zipPath)).count
        log("  \(refItems.count) ảnh mẫu, \(inputItems.count) ảnh cần quét" + (zips > 0 ? " (trong đó \(zips) file zip)" : ""))

        let start = Date()
        let device = args.device("device", default: .gpu)
        var config = AnalyzerConfig()
        if let raw = args.string("jpeg") {
            guard let mode = ImageLoader.JPEGMode(rawValue: raw) else { fail("--jpeg phải là turbo, imageio hoặc thumbnail") }
            config.jpegMode = mode
        }
        let analyzer = try await Analyzer(modelsDirectory: args.modelsURL(), device: device,
                                          detectorDevice: args.device("detector-device", default: device),
                                          embedBatch: args.int("batch", default: Embedder.defaultBatchSize), config: config)
        let index = args.has("no-cache") ? nil : try FaceIndex(url: args.url("index", default: FaceIndex.defaultURL.path))
        let workers = args.int("workers", default: Pipeline.defaultWorkers)

        // 1. Ảnh mẫu: xác định người cần tìm
        let refs = try await analyze(refItems, "Ảnh mẫu", analyzer, index, workers)
        let (identities, noFace, usable) = try Scorer.findIdentities(references: refItems, faces: refs.faces, anchor: args.string("anchor"))
        for item in noFace { log("  ! Bỏ ảnh mẫu \(item.name): không thấy khuôn mặt") }
        if identities.isEmpty { fail("không lấy được khuôn mặt nào từ ảnh mẫu") }
        var choice = 0
        if let pick = args.int("pick") {
            guard (1...identities.count).contains(pick) else { fail("--pick phải từ 1 đến \(identities.count)") }
            choice = pick - 1
        } else if Scorer.isAmbiguous(identities, usableReferences: usable) {
            log("  ! Ảnh mẫu có \(identities.count) người cùng xuất hiện — không chắc ai là người cần tìm.")
            for (k, p) in identities.enumerated() {
                log(String(format: "    #%d: điểm %.3f, có mặt trong %d/%d ảnh mẫu", k + 1, p.score, p.cover.count, usable))
            }
            guard args.has("yes") else { fail("chạy lại với --pick N (N = số thứ tự người cần tìm), hoặc -y để chọn người #1") }
            log("    Đã chọn người #1 (do dùng -y). Nếu sai, chạy lại với --pick N.")
        }
        let person = identities[choice]
        for m in person.members where m.similarity < Scorer.minRefSimilarity {
            log(String(format: "  ! Bỏ ảnh mẫu %@: không thấy người cần tìm (giống nhất %.2f)", m.item.name, m.similarity))
        }
        let references = person.references
        log("  Dùng \(references.count) khuôn mặt mẫu" + (references.count < 3 ? "  (nên dùng ≥ 3 ảnh mẫu, nhiều góc mặt để chính xác hơn)" : ""))
        if Scorer.referencesNearlyIdentical(references) {
            log("  ! Các ảnh mẫu gần như giống hệt nhau (cùng một loạt chụp?). Thêm ảnh ở cảnh/góc/ánh sáng khác để tìm được nhiều ảnh hơn.")
        }

        // 2. Quét + chấm điểm
        let scan = try await analyze(inputItems, "Quét ảnh", analyzer, index, workers)
        let result = Scorer.search(references: references, items: inputItems, faces: scan.faces, options: options)
        if result.expandedBy > 0 { log("  Mở rộng: thêm \(result.expandedBy) khuôn mặt mẫu từ những ảnh khớp chắc chắn") }

        // 3. Báo cáo
        let reportDir = out.appendingPathComponent(Report.reportDirectory)
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try Report.csv(result, errors: scan.errors).write(to: reportDir.appendingPathComponent(Report.csvName))

        let elapsed = Date().timeIntervalSince(start)
        log()
        log(String(format: "Xong sau %dm%02ds. Đã quét %d ảnh.", Int(elapsed) / 60, Int(elapsed) % 60, inputItems.count))
        log("  Khớp:          \(result.matched.count) ảnh  (điểm ≥ \(result.threshold))")
        if result.review < result.threshold {
            log(String(format: "  Cần kiểm tra:  %d ảnh  (điểm %.3f–%@)", result.needsReview.count, result.review, "\(result.threshold)"))
        }
        if !scan.errors.isEmpty { log("  Lỗi đọc:       \(scan.errors.count) ảnh (xem \(Report.csvName))") }
        log("  Báo cáo:  \(reportDir.path)  [chưa chép ảnh]")
    }

    private func analyze(_ items: [ImageItem], _ label: String, _ analyzer: Analyzer, _ index: FaceIndex?, _ workers: Int) async throws -> AnalysisOutput {
        let t0 = Date()
        let shown = Shown()
        let out = try await Pipeline.analyze(items, analyzer: analyzer, index: index, workers: workers) { done, total in
            let now = Date()
            guard shown.due(now) || done == total else { return }
            let eta = now.timeIntervalSince(t0) / Double(done) * Double(total - done)
            FileHandle.standardError.write(Data(String(format: "\r  %@: %d/%d (%d%%)  còn ~%dm%02ds   ", label, done, total,
                                                       done * 100 / max(1, total), Int(eta) / 60, Int(eta) % 60).utf8))
            if done == total { log() }
        }
        if out.cached > 0 { log("  \(label): \(out.cached) ảnh lấy từ chỉ mục") }
        return out
    }

    private func parseSince(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        let now = Date()
        if ["today", "homnay", "hôm nay"].contains(s) { return Calendar.current.startOfDay(for: now) }
        if let n = Double(s.dropLast()), s.hasSuffix("d") || s.hasSuffix("h") { return now.addingTimeInterval(-n * (s.hasSuffix("d") ? 86400 : 3600)) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { fail("--since không hợp lệ: \(s) (dùng today, 3d, 12h hoặc YYYY-MM-DD)") }
        return d
    }
}

/// Giới hạn tần suất in tiến độ (0,5 giây một lần).
private final class Shown: @unchecked Sendable {
    private var last = Date.distantPast
    private let lock = NSLock()
    func due(_ now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(last) < 0.5 { return false }
        last = now
        return true
    }
}
