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
    /// Bản chạy trên CPU cho ảnh có kích thước lạ (xem `maxGPUShapes`); nil nếu `model` vốn đã chạy trên CPU.
    private let cpuModel: MLModel?
    public let scoreThreshold: Float
    public let nmsThreshold: Float
    public let topK: Int

    /// Số kích thước ảnh (sau khi chèn viền) tối đa được chạy trên GPU; các kích thước khác chạy trên CPU. Core ML trên
    /// GPU giữ một bản biên dịch + bộ nhớ riêng cho mỗi kích thước đầu vào và chỉ giữ được rất ít kích thước (tính chung
    /// cho cả tiến trình). Thư viện lẫn nhiều kích thước thì lần gọi nào cũng biên dịch lại và bộ nhớ GPU tăng không giới
    /// hạn (10 kích thước: 9,4 GB sau 300 ảnh; PLAN.md mục 5.4). Kết quả trên CPU lệch không đáng kể (≤ 0,00001 so với
    /// ONNX, như GPU). Chỗ trên GPU dành cho các kích thước gặp nhiều nhất (`ShapeBudget`).
    public static let maxGPUShapes = 4
    private let lock = NSLock()
    private var budget = ShapeBudget(capacity: FaceDetector.maxGPUShapes)

    public init(model: MLModel, cpuModel: MLModel? = nil, scoreThreshold: Float = 0.7, nmsThreshold: Float = 0.3,
                topK: Int = 5000) {
        self.model = model
        self.cpuModel = cpuModel
        self.scoreThreshold = scoreThreshold
        self.nmsThreshold = nmsThreshold
        self.topK = topK
    }

    public convenience init(modelURL: URL, device: ComputeDevice = .auto, scoreThreshold: Float = 0.7) async throws {
        let model = try await ModelStore.load(modelURL, device: device)
        let cpu = device == .cpu ? nil : try await ModelStore.load(modelURL, device: .cpu)
        self.init(model: model, cpuModel: cpu, scoreThreshold: scoreThreshold)
    }

    /// Model dùng cho ảnh kích thước này: GPU nếu kích thước đang có chỗ trên GPU, không thì CPU.
    private func model(forWidth w: Int, height h: Int) -> MLModel {
        guard let cpuModel else { return model }
        lock.lock()
        let gpu = budget.useGPU(w << 16 | h)
        lock.unlock()
        return gpu ? model : cpuModel
    }

    public func detect(_ image: BGRAImage) throws -> [DetectedFace] {
        // OpenCV chèn viền đen bên phải/dưới cho đủ bội số của 32 rồi mới đưa vào mạng.
        let padW = ((image.width - 1) / 32 + 1) * 32, padH = ((image.height - 1) / 32 + 1) * 32
        precondition(padW <= Self.maxSide && padH <= Self.maxSide, "ảnh phải được thu nhỏ trước khi phát hiện mặt")
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: try Self.paddedBuffer(image, padW, padH))
        ])
        let out = try model(forWidth: padW, height: padH).prediction(from: input)

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

/// Chọn kích thước ảnh nào được chạy trên GPU (tối đa `capacity` kích thước), theo số lần gặp.
///
/// Còn chỗ thì kích thước mới được vào ngay. Hết chỗ thì một kích thước chỉ thay được kích thước ít gặp nhất trên GPU khi
/// đã gặp nhiều hơn hẳn (gấp đôi + `margin`), để: (1) vài ảnh lạ cỡ gặp đầu tiên (ví dụ ảnh mẫu là ảnh chụp màn hình)
/// không giữ chỗ mãi trong khi cả thư viện ảnh máy ảnh phải chạy CPU; (2) không đổi chỗ qua lại liên tục (mỗi lần đổi là
/// một lần biên dịch lại trên GPU), số lần đổi chỉ tăng theo log của số ảnh.
struct ShapeBudget {
    let capacity: Int
    var margin = 8
    private(set) var counts: [Int: Int] = [:]
    private(set) var onGPU: Set<Int> = []
    private(set) var swaps = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func useGPU(_ key: Int) -> Bool {
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        if onGPU.contains(key) { return true }
        if onGPU.count < capacity { onGPU.insert(key); return true }
        guard let weakest = onGPU.min(by: { (counts[$0] ?? 0, $0) < (counts[$1] ?? 0, $1) }),
              n >= 2 * (counts[weakest] ?? 0) + margin else { return false }
        onGPU.remove(weakest)
        onGPU.insert(key)
        swaps += 1
        return true
    }
}
