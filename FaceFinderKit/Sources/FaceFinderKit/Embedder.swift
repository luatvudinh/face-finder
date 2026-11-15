import Accelerate
import CoreML
import Foundation

/// ArcFace (Core ML): ảnh mặt đã căn 112x112 -> "vân mặt" 512 chiều, đã chuẩn hoá độ dài về 1.
public final class Embedder: @unchecked Sendable {
    public static let dimension = 512
    public static let cropBytes = Aligner.size * Aligner.size * 3

    private let model: MLModel
    /// Cỡ lô cố định: mọi lần gọi model đều có đúng `batchSize` mặt; lô cuối thiếu thì đệm mặt rỗng (bỏ kết quả).
    ///
    /// Không gọi model với số mặt tuỳ ý: Core ML trên GPU giữ một bản biên dịch + bộ nhớ riêng cho mỗi kích thước đầu
    /// vào và chỉ giữ được rất ít kích thước, tính chung cho mọi model trong tiến trình. Khi ArcFace có từ 2 cỡ lô trở lên
    /// xen kẽ với YuNet, bộ nhớ GPU tăng đều theo số lần gọi (lập chỉ mục 1416 ảnh từng lên tới 13,7 GB; PLAN.md mục 5.4).
    /// Với một cỡ lô duy nhất thì ổn định. Kết quả của từng mặt không phụ thuộc cỡ lô (lô ≤ 12 cho vân mặt giống hệt
    /// lô 1) nên đệm thêm mặt rỗng không làm đổi kết quả.
    public let batchSize: Int

    public static let defaultBatchSize = 4

    public init(model: MLModel, batchSize: Int = Embedder.defaultBatchSize) {
        self.model = model
        self.batchSize = min(max(batchSize, 1), 64)
    }

    public convenience init(modelURL: URL, device: ComputeDevice = .auto, batchSize: Int = Embedder.defaultBatchSize) async throws {
        self.init(model: try await ModelStore.load(modelURL, device: device), batchSize: batchSize)
    }

    /// `crops`: `count` ảnh mặt nối liền nhau, mỗi ảnh 112*112*3 byte R, G, B (đầu ra của `Aligner.warp`).
    /// Trả về `count * 512` số thực; mỗi vector đã chuẩn hoá.
    public func embed(_ crops: UnsafeBufferPointer<UInt8>, count: Int) throws -> [Float] {
        precondition(crops.count >= count * Self.cropBytes)
        var out = [Float](repeating: 0, count: count * Self.dimension)
        var done = 0
        while done < count {
            let n = min(batchSize, count - done)
            let part = UnsafeBufferPointer(rebasing: crops[(done * Self.cropBytes)..<((done + n) * Self.cropBytes)])
            try out.withUnsafeMutableBufferPointer { dst in
                try run(part, count: n, into: UnsafeMutableBufferPointer(rebasing: dst[(done * Self.dimension)..<((done + n) * Self.dimension)]))
            }
            done += n
        }
        return out
    }

    public func embed(_ crops: [UInt8], count: Int) throws -> [Float] {
        try crops.withUnsafeBufferPointer { try embed($0, count: count) }
    }

    private func run(_ crops: UnsafeBufferPointer<UInt8>, count n: Int, into dst: UnsafeMutableBufferPointer<Float>) throws {
        let side = Aligner.size, plane = side * side
        let input = try MLMultiArray(shape: [batchSize, 3, side, side].map { NSNumber(value: $0) }, dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            if n < batchSize {  // mặt rỗng để đủ lô
                p.baseAddress!.advanced(by: n * 3 * plane).update(repeating: 0, count: (batchSize - n) * 3 * plane)
            }
            // RGB xen kẽ -> 3 mặt phẳng R, G, B (model tự chuẩn hoá (x - 127.5) / 127.5)
            for f in 0..<n {
                let src = crops.baseAddress! + f * Self.cropBytes
                for c in 0..<3 {
                    vDSP_vfltu8(src + c, 3, p.baseAddress! + (f * 3 + c) * plane, 1, vDSP_Length(plane))
                }
            }
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["faces": MLFeatureValue(multiArray: input)]))
        guard let emb = result.featureValue(for: "embedding")?.multiArrayValue, emb.dataType == .float32,
              emb.shape.map(\.intValue) == [batchSize, Self.dimension] else {
            throw ModelError.badOutput("embedding")
        }
        let st = emb.strides.map(\.intValue)
        emb.withUnsafeBufferPointer(ofType: Float.self) { p in
            for f in 0..<n {
                let o = dst.baseAddress! + f * Self.dimension
                let src = p.baseAddress! + f * st[0]
                var norm: Float = 0
                vDSP_svesq(src, st[1], &norm, vDSP_Length(Self.dimension))
                var inv = 1 / max(norm.squareRoot(), 1e-12)
                vDSP_vsmul(src, st[1], &inv, o, 1, vDSP_Length(Self.dimension))
            }
        }
    }
}
