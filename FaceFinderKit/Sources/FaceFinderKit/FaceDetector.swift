import CoreML
import CoreVideo
import Foundation

/// Một khuôn mặt do YuNet tìm thấy, toạ độ tính theo pixel của ảnh đưa vào `detect`.
public struct DetectedFace: Sendable {
    /// Khung mặt: x, y (góc trên trái), rộng, cao.
    public var x: Float, y: Float, width: Float, height: Float
    /// 5 điểm mốc theo thứ tự của YuNet: mắt phải, mắt trái, mũi, khoé miệng phải, khoé miệng trái
    /// ("phải/trái" là của người trong ảnh).
    public var landmarks: [SIMD2<Float>]
    public var score: Float
}

/// YuNet (Core ML) + phần giải mã và NMS chép theo `cv2.FaceDetectorYN` để cho kết quả như CLI Python.
public final class FaceDetector: @unchecked Sendable {
    public static let maxSide = 2432
    private static let strides = [8, 16, 32]

    private let model: MLModel
    public let scoreThreshold: Float
    public let nmsThreshold: Float
    public let topK: Int

    public init(model: MLModel, scoreThreshold: Float = 0.7, nmsThreshold: Float = 0.3, topK: Int = 5000) {
        self.model = model
        self.scoreThreshold = scoreThreshold
        self.nmsThreshold = nmsThreshold
        self.topK = topK
    }

    public convenience init(modelURL: URL, device: ComputeDevice = .auto, scoreThreshold: Float = 0.7) async throws {
        self.init(model: try await ModelStore.load(modelURL, device: device), scoreThreshold: scoreThreshold)
    }

    public func detect(_ image: BGRAImage) throws -> [DetectedFace] {
        // OpenCV chèn viền đen bên phải/dưới cho đủ bội số của 32 rồi mới đưa vào mạng.
        let padW = ((image.width - 1) / 32 + 1) * 32, padH = ((image.height - 1) / 32 + 1) * 32
        precondition(padW <= Self.maxSide && padH <= Self.maxSide, "ảnh phải được thu nhỏ trước khi phát hiện mặt")
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: try Self.paddedBuffer(image, padW, padH))
        ])
        let out = try model.prediction(from: input)

        var faces: [DetectedFace] = []
        for stride in Self.strides {
            guard let grid = out.featureValue(for: "s\(stride)")?.multiArrayValue else {
                throw ModelError.badOutput("thiếu đầu ra s\(stride)")
            }
            try decode(grid, stride: stride, rows: padH / stride, cols: padW / stride, into: &faces)
        }
        return nms(faces)
    }

    private static func paddedBuffer(_ image: BGRAImage, _ padW: Int, _ padH: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, padW, padH, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { throw ModelError.badOutput("không tạo được bộ đệm ảnh \(padW)x\(padH)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let dst = CVPixelBufferGetBaseAddress(buffer)!
        let dstRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(dst, 0, dstRow * padH)
        image.data.withUnsafeBytes { src in
            for y in 0..<image.height {
                memcpy(dst + y * dstRow, src.baseAddress! + y * image.bytesPerRow, image.width * 4)
            }
        }
        return buffer
    }

    /// Lưới [1, 16, rows, cols]: kênh 0 = cls, 1 = obj, 2..5 = bbox, 6..15 = 5 điểm mốc.
    private func decode(_ grid: MLMultiArray, stride: Int, rows: Int, cols: Int, into faces: inout [DetectedFace]) throws {
        let shape = grid.shape.map(\.intValue)
        guard grid.dataType == .float32, shape == [1, 16, rows, cols] else {
            throw ModelError.badOutput("s\(stride) có dạng \(shape), cần [1, 16, \(rows), \(cols)]")
        }
        let st = grid.strides.map(\.intValue)
        let (sc, sr, sx) = (st[1], st[2], st[3])
        let s = Float(stride), threshold = scoreThreshold
        grid.withUnsafeBufferPointer(ofType: Float.self) { p in
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * sr + c * sx
                    let cls = min(max(p[i], 0), 1), obj = min(max(p[i + sc], 0), 1)
                    let score = (cls * obj).squareRoot()
                    if score < threshold { continue }
                    let cx = (Float(c) + p[i + 2 * sc]) * s, cy = (Float(r) + p[i + 3 * sc]) * s
                    let w = exp(p[i + 4 * sc]) * s, h = exp(p[i + 5 * sc]) * s
                    var lm: [SIMD2<Float>] = []
                    lm.reserveCapacity(5)
                    for n in 0..<5 {
                        lm.append(SIMD2((p[i + (6 + 2 * n) * sc] + Float(c)) * s, (p[i + (7 + 2 * n) * sc] + Float(r)) * s))
                    }
                    faces.append(DetectedFace(x: cx - w / 2, y: cy - h / 2, width: w, height: h, landmarks: lm, score: score))
                }
            }
        }
    }

    /// Như `cv::dnn::NMSBoxes`: khung được cắt về số nguyên, xét theo điểm giảm dần, giữ khung nếu IoU với mọi
    /// khung đã giữ <= ngưỡng.
    private func nms(_ faces: [DetectedFace]) -> [DetectedFace] {
        if faces.count <= 1 { return faces }
        struct Box { var x0: Int, y0: Int, w: Int, h: Int }
        let boxes = faces.map { Box(x0: Int($0.x), y0: Int($0.y), w: Int($0.width), h: Int($0.height)) }
        // sắp xếp ổn định theo điểm giảm dần (như std::stable_sort của OpenCV)
        let order = faces.indices.sorted { faces[$0].score != faces[$1].score ? faces[$0].score > faces[$1].score : $0 < $1 }
        var kept: [Int] = []
        for i in order.prefix(topK) {
            let a = boxes[i]
            var keep = true
            for j in kept {
                let b = boxes[j]
                let iw = min(a.x0 + a.w, b.x0 + b.w) - max(a.x0, b.x0), ih = min(a.y0 + a.h, b.y0 + b.h) - max(a.y0, b.y0)
                let inter = iw > 0 && ih > 0 ? Double(iw * ih) : 0
                let union = Double(a.w * a.h + b.w * b.h) - inter
                let iou = union > 0 ? inter / union : 1
                if iou > Double(nmsThreshold) { keep = false; break }
            }
            if keep { kept.append(i) }
        }
        return kept.map { faces[$0] }
    }
}
