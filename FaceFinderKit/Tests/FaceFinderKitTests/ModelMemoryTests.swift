import CoreML
import Foundation
import Testing
@testable import FaceFinderKit

/// Cách gọi model để bộ nhớ GPU không tăng theo số ảnh (PLAN.md mục 5.4). Cần models/*.mlpackage ở gốc dự án
/// (tools/fetch_models.sh + tools/convert_models.py); không có thì bỏ qua. CI chạy test sau bước chuẩn bị model.
private let modelsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("models")
private let haveModels = FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent("ArcFaceR50.mlpackage").path)
    && FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent("YuNet.mlpackage").path)

/// Sinh số giả ngẫu nhiên có seed (SplitMix64): lỗi tái hiện được.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Chọn kích thước nào chạy GPU cho YuNet: không cần model.
@Suite struct ShapeBudgetTests {
    @Test func firstShapesFillFreeSlots() {
        var b = ShapeBudget(capacity: 4)
        for k in 1...4 { let gpu = b.useGPU(k); #expect(gpu) }
        let fifth = b.useGPU(5)
        #expect(!fifth)
        let again = b.useGPU(1)
        #expect(again)  // kích thước đã có chỗ vẫn chạy GPU
    }

    /// Ảnh mẫu lạ cỡ chiếm hết chỗ trước, rồi thư viện ảnh máy ảnh (2 kích thước) phải giành được chỗ.
    @Test func frequentShapesTakeOverFromEarlyOddShapes() {
        var b = ShapeBudget(capacity: 4)
        for k in 100...103 { _ = b.useGPU(k) }
        var g = SeededRNG(state: 1)
        var onCPU = 0
        for i in 0..<1000 {
            let key = Int.random(in: 0..<10, using: &g) == 0 ? 2 : 1   // dọc 10%, ngang 90%
            let gpu = b.useGPU(key)
            if !gpu { onCPU += 1 }
            if i > 200 { #expect(b.onGPU.contains(1) && b.onGPU.contains(2)) }
        }
        #expect(onCPU < 40, "\(onCPU) ảnh chạy CPU")
        #expect(b.swaps == 2)
    }

    /// Nhiều kích thước luân phiên đều nhau: không được đổi chỗ liên tục (mỗi lần đổi là một lần biên dịch lại).
    @Test func noThrashingWithManyEqualShapes() {
        var b = ShapeBudget(capacity: 4)
        for i in 0..<10_000 { _ = b.useGPU(i % 10) }
        #expect(b.swaps == 0)
        var c = ShapeBudget(capacity: 4)
        var g = SeededRNG(state: 7)
        for _ in 0..<10_000 { _ = c.useGPU(Int.random(in: 0..<10, using: &g)) }
        #expect(c.swaps <= 3, "\(c.swaps) lần đổi")
    }
}

@Suite(.enabled(if: haveModels, "cần models/*.mlpackage"), .serialized) struct ModelMemoryTests {
    private func crops(_ n: Int) -> [UInt8] {
        var g = SeededRNG(state: 42)
        return (0..<(n * Embedder.cropBytes)).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// Lô cố định + đệm mặt rỗng cho đúng vân mặt như chạy từng mặt một, với mọi số mặt.
    @Test func paddedBatchesMatchSingleFaces() async throws {
        let url = modelsDir.appendingPathComponent("ArcFaceR50.mlpackage")
        let single = try await Embedder(modelURL: url, device: .gpu, batchSize: 1)
        let batched = try await Embedder(modelURL: url, device: .gpu, batchSize: 4)
        #expect(batched.batchSize == 4)
        let data = crops(7)
        let one = try single.embed(data, count: 7)
        let d = Embedder.dimension
        func cosine(_ a: [Float], _ i: Int, _ b: [Float], _ j: Int) -> Float {
            zip(a[(i * d)..<((i + 1) * d)], b[(j * d)..<((j + 1) * d)]).map(*).reduce(0, +)
        }
        // Mức phân biệt: hai mặt nhiễu khác nhau vẫn có cosine tới ~0,9 (đo trên M1), nên ngưỡng 0,999 vẫn bắt được lỗi
        // đọc nhầm hàng hay đệm sai, mà không đòi giống từng bit.
        var otherFaces: Float = -1
        for i in 0..<7 { for j in 0..<7 where i != j { otherFaces = max(otherFaces, cosine(one, i, one, j)) } }
        #expect(otherFaces < 0.99, "ảnh nhiễu cho vân mặt quá giống nhau: test không phân biệt được (\(otherFaces))")
        for n in [1, 3, 4, 5, 7] {
            let got = try batched.embed(Array(data.prefix(n * Embedder.cropBytes)), count: n)
            #expect(got.count == n * d)
            // So theo cosine từng mặt, không theo từng phần tử: trên GPU của M1 giống hệt từng bit, nhưng máy CI (máy ảo,
            // Xcode 26.6) cho lệch từng phần tử ~1e-3 ngay cả khi n = 1, tức là do cách Core ML biên dịch theo cỡ lô
            // trên máy đó, không phải do đệm. Mức lệch này không đổi kết quả tìm người.
            let worst = (0..<n).map { cosine(got, $0, one, $0) }.min() ?? 0
            #expect(worst > 0.999, "n = \(n): cosine thấp nhất \(worst)")
        }
    }

    /// Kích thước ảnh lạ (quá `maxGPUShapes`) chạy trên CPU và vẫn cho cùng ứng viên như trên GPU.
    @Test func extraImageShapesFallBackToCPU() async throws {
        let url = modelsDir.appendingPathComponent("YuNet.mlpackage")
        let gpu = try await ModelStore.load(url, device: .gpu)
        let cpu = try await ModelStore.load(url, device: .cpu)
        // Ngưỡng điểm thấp để ảnh nhiễu vẫn có ứng viên mà so (không có ảnh mặt người thật trong repo).
        let detector = FaceDetector(model: gpu, cpuModel: cpu, scoreThreshold: 0.02)
        let gpuOnly = FaceDetector(model: gpu, scoreThreshold: 0.02)
        var g = SeededRNG(state: 3)
        func image(_ w: Int, _ h: Int) -> BGRAImage {
            BGRAImage(width: w, height: h, bytesPerRow: w * 4, data: (0..<(w * h * 4)).map { _ in UInt8.random(in: 0...255, using: &g) })
        }
        func iou(_ a: DetectedFace, _ b: DetectedFace) -> Float {
            let w = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
            let h = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
            return w * h / (a.width * a.height + b.width * b.height - w * h)
        }
        let sizes = [(320, 240), (240, 320), (352, 256), (256, 352), (384, 288), (288, 384)]
        #expect(sizes.count > FaceDetector.maxGPUShapes)
        var compared = 0
        for (w, h) in sizes {
            let img = image(w, h)
            let a = try detector.detect(img)   // 4 kích thước đầu: GPU; 2 kích thước sau: CPU (xem ShapeBudgetTests)
            let b = try gpuOnly.detect(img)
            // Ghép theo khung trùng nhau nhiều nhất, không theo thứ tự điểm (điểm sát nhau có thể đổi thứ tự).
            for x in a.sorted(by: { $0.score > $1.score }).prefix(5) where x.score > 0.05 {
                let best = b.max { iou(x, $0) < iou(x, $1) }
                #expect(best.map { iou(x, $0) > 0.95 && abs(x.score - $0.score) < 0.002 } == true, "\(w)x\(h)")
                compared += 1
            }
        }
        #expect(compared > 0, "ảnh nhiễu không cho ứng viên nào: test không kiểm được gì")
    }
}
