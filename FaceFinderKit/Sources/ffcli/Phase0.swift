import CryptoKit
import FaceFinderKit
import Foundation

/// Giai đoạn 0 của PLAN.md: so bộ máy Core ML với đáp án mẫu do CLI Python xuất ra.
struct Phase0 {
    struct Manifest: Decodable {
        struct Face: Decodable {
            let box: [Float], lm: [Float], score: Float, crop: Int, M: [Double]?
        }
        struct Image: Decodable {
            let file: String, name: String, width: Int, height: Int, sha1: String, faces: [Face]
        }
        let crops: Int, has_gpu: Bool, det_threshold: Float, min_face: Int, images: [Image]
    }

    let golden: URL, models: URL, devices: [ComputeDevice], limit: Int

    init(_ args: Arguments) {
        golden = args.url("golden", default: "golden")
        models = args.modelsURL()
        devices = args.string("devices", default: "gpu,ne,cpu").split(separator: ",").map {
            guard let d = ComputeDevice(rawValue: String($0)) else { fail("thiết bị không hợp lệ: \($0) (auto, gpu, ne, cpu)") }
            return d
        }
        limit = args.int("limit", default: .max)
    }

    func run() async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: golden.appendingPathComponent("manifest.json")))
        let crops = [UInt8](try Data(contentsOf: golden.appendingPathComponent("crops.rgb")))
        let embCPU = try floats("emb_cpu.f32")
        let embGPU = manifest.has_gpu ? try floats("emb_gpu.f32") : nil
        let n = manifest.crops
        guard crops.count == n * Embedder.cropBytes, embCPU.count == n * Embedder.dimension else {
            fail("golden data không nhất quán với manifest")
        }
        print("Golden: \(manifest.images.count) ảnh, \(manifest.images.reduce(0) { $0 + $1.faces.count }) khuôn mặt, \(n) ảnh mặt đã căn\n")

        // ---- 1. ArcFace trên cùng ảnh mặt đã căn
        print("1) ArcFace Core ML trên cùng ảnh mặt đã căn — cosine so với CLI (ONNX Runtime, CPU)")
        if let g = embGPU {
            print(row("CLI: GPU so với CPU", cosines(g, embCPU), note: "mức lệch sẵn có trong chính CLI"))
        }
        var embedders: [(ComputeDevice, Embedder)] = []
        for device in devices {
            let e = try await Embedder(modelURL: models.appendingPathComponent("ArcFaceR50.mlpackage"), device: device, maxBatch: 32)
            _ = try e.embed(Array(crops.prefix(32 * Embedder.cropBytes)), count: min(32, n))  // làm nóng
            let t0 = Date()
            let got = try e.embed(crops, count: n)
            let ms = Date().timeIntervalSince(t0) * 1000 / Double(n)
            print(row("Core ML \(device.rawValue)", cosines(got, embCPU), note: String(format: "%.1f ms/mặt", ms)))
            embedders.append((device, e))
        }

        // ---- 2. YuNet trên cùng pixel
        print("\n2) YuNet Core ML trên đúng ảnh CLI đã thấy — so khung mặt và 5 điểm mốc")
        let images = Array(manifest.images.prefix(limit))
        var detected: [[DetectedFace]] = []
        var loaded = 0
        for device in devices where device != .neuralEngine {
            let detector = try await FaceDetector(modelURL: models.appendingPathComponent("YuNet.mlpackage"), device: device,
                                                  scoreThreshold: manifest.det_threshold)
            var total = 0, found = 0, extra = 0, pixelMismatch = 0
            var lmErr: [Float] = [], boxErr: [Float] = [], scoreErr: [Float] = []
            var seconds = 0.0
            var all: [[DetectedFace]] = []
            for (k, info) in images.enumerated() {
                guard let img = BGRAImage.loadExact(url: golden.appendingPathComponent(info.file)) else { fail("không đọc được \(info.file)") }
                if Insecure.SHA1.hash(data: Data(img.bgrBytes())).map({ String(format: "%02x", $0) }).joined() != info.sha1 { pixelMismatch += 1 }
                if k == 0 { _ = try detector.detect(img) }  // làm nóng
                let t0 = Date()
                let faces = try detector.detect(img)
                seconds += Date().timeIntervalSince(t0)
                all.append(faces)
                var used = Set<Int>()
                for g in info.faces {
                    total += 1
                    var best = -1, bestIoU: Float = 0
                    for (j, f) in faces.enumerated() where !used.contains(j) {
                        let v = iou(g.box, [f.x, f.y, f.width, f.height])
                        if v > bestIoU { bestIoU = v; best = j }
                    }
                    guard best >= 0, bestIoU >= 0.5 else { continue }
                    used.insert(best)
                    found += 1
                    let f = faces[best]
                    lmErr.append((0..<5).map { max(abs(f.landmarks[$0].x - g.lm[2 * $0]), abs(f.landmarks[$0].y - g.lm[2 * $0 + 1])) }.max()!)
                    boxErr.append(zip([f.x, f.y, f.width, f.height], g.box).map { abs($0 - $1) }.max()!)
                    scoreErr.append(abs(f.score - g.score))
                }
                extra += faces.count - used.count
            }
            loaded = images.count
            if detected.isEmpty { detected = all }
            print("   [\(device.rawValue)] tìm lại \(found)/\(total) mặt (\(pct(found, total))), thừa \(extra) mặt"
                  + (pixelMismatch > 0 ? "  ⚠️ \(pixelMismatch) ảnh đọc ra khác pixel so với CLI" : "  (pixel đọc vào trùng CLI 100%)"))
            print("        lệch điểm mốc: tb \(f3(mean(lmErr))) px, p99 \(f3(percentile(lmErr, 0.99))) px, lớn nhất \(f3(lmErr.max() ?? 0)) px"
                  + "   lệch khung lớn nhất \(f3(boxErr.max() ?? 0)) px   lệch điểm tin cậy lớn nhất \(f3(scoreErr.max() ?? 0))")
            print(String(format: "        %.0f ms/ảnh", seconds * 1000 / Double(max(1, images.count))))
        }

        // ---- 3. Căn mặt: từ điểm mốc của CLI, căn bằng Swift rồi trích vân mặt
        guard let (device, embedder) = embedders.first, loaded > 0 else { return }
        print("\n3) Căn mặt bằng Swift (điểm mốc lấy của CLI) + ArcFace \(device.rawValue) — cosine so với CLI")
        var robustCrops: [UInt8] = [], lsCrops: [UInt8] = [], e2eCrops: [UInt8] = []
        var refIdx: [Int] = [], e2eIdx: [Int] = []
        var mErr: [Float] = [], dropped = 0, pixelDiff: [Float] = []
        for (k, info) in images.enumerated() {
            guard let img = BGRAImage.loadExact(url: golden.appendingPathComponent(info.file)) else { continue }
            var used = Set<Int>()
            for g in info.faces where g.crop >= 0 {
                let lm = Aligner.ordered((0..<5).map { SIMD2(g.lm[2 * $0], g.lm[2 * $0 + 1]) })
                guard let r = Aligner.robust(lm, Aligner.template), let l = Aligner.leastSquares(lm, Aligner.template) else { continue }
                if r != l { dropped += 1 }
                let crop = Aligner.warp(img, r)
                robustCrops += crop
                lsCrops += Aligner.warp(img, l)
                refIdx.append(g.crop)
                if let m = g.M { mErr.append(zip(r.matrix, m).map { Float(abs($0 - $1)) }.max()!) }
                let gold = crops[(g.crop * Embedder.cropBytes)..<((g.crop + 1) * Embedder.cropBytes)]
                pixelDiff.append(zip(crop, gold).reduce(Float(0)) { $0 + abs(Float($1.0) - Float($1.1)) } / Float(crop.count))

                // toàn chuỗi: mặt do Swift phát hiện -> căn -> trích
                var best = -1, bestIoU: Float = 0
                for (j, f) in detected[k].enumerated() where !used.contains(j) {
                    let v = iou(g.box, [f.x, f.y, f.width, f.height])
                    if v > bestIoU { bestIoU = v; best = j }
                }
                if best >= 0, bestIoU >= 0.5, let s = Aligner.robust(Aligner.ordered(detected[k][best].landmarks), Aligner.template) {
                    used.insert(best)
                    e2eCrops += Aligner.warp(img, s)
                    e2eIdx.append(g.crop)
                }
            }
        }
        func pick(_ idx: [Int]) -> [Float] {
            idx.flatMap { embCPU[($0 * Embedder.dimension)..<(($0 + 1) * Embedder.dimension)] }
        }
        let ref = pick(refIdx)
        print(row("bền vững (như LMEDS)", cosines(try embedder.embed(robustCrops, count: refIdx.count), ref),
                  note: "loại điểm mốc ở \(dropped)/\(refIdx.count) mặt"))
        print(row("bình phương tối thiểu", cosines(try embedder.embed(lsCrops, count: refIdx.count), ref), note: "Umeyama, không loại điểm"))
        print("        ma trận bền vững so với CLI: lệch tb \(f3(mean(mErr))), p99 \(f3(percentile(mErr, 0.99))), lớn nhất \(f3(mErr.max() ?? 0))"
              + "   ảnh mặt lệch tb \(f3(mean(pixelDiff))) mức xám")

        print("\n4) Toàn chuỗi Swift trên cùng pixel: YuNet -> căn mặt -> ArcFace \(device.rawValue) — cosine so với CLI")
        print(row("toàn chuỗi", cosines(try embedder.embed(e2eCrops, count: e2eIdx.count), pick(e2eIdx)), note: "\(e2eIdx.count) mặt"))
    }

    // ---- tiện ích

    private func floats(_ name: String) throws -> [Float] {
        try Data(contentsOf: golden.appendingPathComponent(name)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func cosines(_ a: [Float], _ b: [Float]) -> [Float] {
        let d = Embedder.dimension
        return (0..<(a.count / d)).map { i in
            var s: Float = 0
            for k in 0..<d { s += a[i * d + k] * b[i * d + k] }
            return s
        }
    }

    private func row(_ label: String, _ cos: [Float], note: String = "") -> String {
        guard !cos.isEmpty else { return "   \(label): không có dữ liệu" }
        let below = cos.filter { $0 < 0.999 }.count
        return "   " + label.padding(toLength: 24, withPad: " ", startingAt: 0)
            + String(format: "nhỏ nhất %.5f  p1 %.5f  tb %.5f  dưới 0.999: %d/%d", cos.min()!, percentile(cos, 0.01), mean(cos), below, cos.count)
            + (note.isEmpty ? "" : "   [\(note)]")
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let iw = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]), ih = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
        guard iw > 0, ih > 0 else { return 0 }
        return iw * ih / (a[2] * a[3] + b[2] * b[3] - iw * ih)
    }

    private func mean(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.reduce(0, +) / Float(v.count) }
    private func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    private func f3(_ v: Float) -> String { String(format: "%.3f", v) }
    private func pct(_ a: Int, _ b: Int) -> String { String(format: "%.2f%%", 100 * Double(a) / Double(max(1, b))) }
}
