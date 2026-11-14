import Accelerate
import CoreML
import Foundation

/// ArcFace (Core ML): ảnh mặt đã căn 112x112 -> "vân mặt" 512 chiều, đã chuẩn hoá độ dài về 1.
public final class Embedder: @unchecked Sendable {
    public static let dimension = 512
    public static let cropBytes = Aligner.size * Aligner.size * 3

    private let model: MLModel
    public let maxBatch: Int

    public init(model: MLModel, maxBatch: Int = 64) {
        self.model = model
        self.maxBatch = maxBatch
    }

    public convenience init(modelURL: URL, device: ComputeDevice = .auto, maxBatch: Int = 64) async throws {
        self.init(model: try await ModelStore.load(modelURL, device: device), maxBatch: maxBatch)
    }

    /// `crops`: `count` ảnh mặt nối liền nhau, mỗi ảnh 112*112*3 byte R, G, B (đầu ra của `Aligner.warp`).
    /// Trả về `count * 512` số thực; mỗi vector đã chuẩn hoá.
    public func embed(_ crops: UnsafeBufferPointer<UInt8>, count: Int) throws -> [Float] {
        precondition(crops.count >= count * Self.cropBytes)
        var out = [Float](repeating: 0, count: count * Self.dimension)
        var done = 0
        while done < count {
            let n = min(maxBatch, count - done)
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
        let input = try MLMultiArray(shape: [n, 3, side, side].map { NSNumber(value: $0) }, dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
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
              emb.shape.map(\.intValue) == [n, Self.dimension] else {
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
