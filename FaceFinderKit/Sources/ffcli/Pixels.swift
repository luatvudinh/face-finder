import FaceFinderKit
import Foundation

/// `ffcli pixels`: đọc lại file ảnh gốc bằng ImageLoader của Swift rồi so với ảnh CLI Python đã thấy (golden),
/// từng pixel và qua cả chuỗi nhận diện. Dùng để chọn cách giải mã/thu nhỏ cho điểm số trùng CLI.
struct Pixels {
    let args: Arguments

    init(_ args: Arguments) { self.args = args }

    func run() async throws {
        let golden = args.url("golden", default: "golden")
        guard let mode = ImageLoader.JPEGMode(rawValue: args.string("jpeg", default: "turbo")) else {
            fail("--jpeg phải là turbo, imageio hoặc thumbnail")
        }
        let manifest = try JSONDecoder().decode(Phase0.Manifest.self, from: Data(contentsOf: golden.appendingPathComponent("manifest.json")))
        let embeddings = try Data(contentsOf: golden.appendingPathComponent("emb_cpu.f32")).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let items = Dictionary(ImageSource.collect(args.list("input")).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var config = AnalyzerConfig()
        config.jpegMode = mode
        let analyzer = try await Analyzer(modelsDirectory: args.modelsURL(), device: args.device("device", default: .gpu), config: config)
        let reader = ItemReader()
        let limit = args.int("limit", default: .max)

        var meanDiff: [Double] = [], over4: [Double] = [], sizeMismatch = 0, missing = 0
        var cos: [Float] = [], total = 0, found = 0, extra = 0, loadSeconds = 0.0
        for info in manifest.images.prefix(limit) {
            guard let item = items[info.name], let gold = BGRAImage.loadExact(url: golden.appendingPathComponent(info.file)) else { missing += 1; continue }
            let data = try reader.read(item)
            let t0 = Date()
            let (image, scale) = try ImageLoader.load(data, maxSide: config.maxSide, jpeg: mode)
            loadSeconds += Date().timeIntervalSince(t0)
            if image.width != gold.width || image.height != gold.height {
                sizeMismatch += 1
            } else {
                var sum = 0, big = 0
                let a = image.bgrBytes(), b = gold.bgrBytes()
                for i in a.indices {
                    let d = abs(Int(a[i]) - Int(b[i]))
                    sum += d
                    if d > 4 { big += 1 }
                }
                meanDiff.append(Double(sum) / Double(a.count))
                over4.append(100 * Double(big) / Double(a.count))
            }
            // toàn chuỗi: so vân mặt với CLI theo từng khuôn mặt (toạ độ của golden là trên ảnh đã thu nhỏ)
            let faces = try analyzer.analyze(image, scale: scale)
            var used = Set<Int>()
            let s = Float(scale)
            for g in info.faces where g.crop >= 0 {
                total += 1
                var best = -1, bestIoU: Float = 0
                for (j, f) in faces.enumerated() where !used.contains(j) {
                    let v = iou(g.box, [f.x * s, f.y * s, f.width * s, f.height * s])
                    if v > bestIoU { bestIoU = v; best = j }
                }
                guard best >= 0, bestIoU >= 0.5 else { continue }
                used.insert(best)
                found += 1
                var d: Float = 0
                for k in 0..<Embedder.dimension { d += faces[best].embedding[k] * embeddings[g.crop * Embedder.dimension + k] }
                cos.append(d)
            }
            extra += faces.count - used.count
        }
        let n = max(1, meanDiff.count)
        cos.sort()
        print("Bộ giải mã JPEG: \(mode.rawValue)   (\(meanDiff.count) ảnh so được, \(sizeMismatch) ảnh khác kích thước, \(missing) ảnh không tìm thấy file gốc)")
        print(String(format: "  Pixel: lệch trung bình %.3f mức xám (ảnh tệ nhất %.3f); pixel lệch > 4 mức: %.2f%%",
                     meanDiff.reduce(0, +) / Double(n), meanDiff.max() ?? 0, over4.reduce(0, +) / Double(n)))
        print(String(format: "  Giải mã + thu nhỏ: %.0f ms/ảnh", loadSeconds * 1000 / Double(n + sizeMismatch)))
        print("  Khuôn mặt: tìm lại \(found)/\(total), thừa \(extra)")
        if !cos.isEmpty {
            print(String(format: "  Cosine vân mặt so với CLI: nhỏ nhất %.4f  p1 %.4f  p10 %.4f  trung vị %.4f  tb %.4f",
                         cos[0], cos[cos.count / 100], cos[cos.count / 10], cos[cos.count / 2], cos.reduce(0, +) / Float(cos.count)))
        }
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let iw = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]), ih = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
        guard iw > 0, ih > 0 else { return 0 }
        return iw * ih / (a[2] * a[3] + b[2] * b[3] - iw * ih)
    }
}

