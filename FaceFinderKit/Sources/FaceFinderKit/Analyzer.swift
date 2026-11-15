import Foundation

/// Một khuôn mặt đã phân tích xong. Toạ độ tính theo ảnh **gốc** (chưa thu nhỏ).
public struct FaceRecord: Sendable {
    public var x: Float, y: Float, width: Float, height: Float
    /// 5 điểm mốc (x, y nối tiếp nhau), thứ tự của YuNet.
    public var landmarks: [Float]
    public var detectionScore: Float
    /// "Vân mặt" 512 chiều, độ dài 1. Đã làm tròn qua Float16 đúng như dữ liệu lưu trong chỉ mục (và như CLI).
    public var embedding: [Float]

    public init(x: Float, y: Float, width: Float, height: Float, landmarks: [Float], detectionScore: Float, embedding: [Float]) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.landmarks = landmarks; self.detectionScore = detectionScore; self.embedding = embedding
    }
}

/// Cấu hình phân tích ảnh. Đổi bất kỳ giá trị nào thì kết quả cũ trong chỉ mục không còn dùng được (`signature`).
public struct AnalyzerConfig: Sendable, Equatable {
    public var maxSide = 2400
    public var minFace = 20
    public var detectionThreshold: Float = 0.7
    public var jpegMode = ImageLoader.JPEGMode.turbo
    /// Tăng số này khi đổi model hoặc đổi cách xử lý làm kết quả khác đi.
    public static let pipelineVersion = 3

    public init() {}

    public var signature: String { "\(Self.pipelineVersion)|\(maxSide)|\(minFace)|\(detectionThreshold)|\(jpegMode.rawValue)" }
}

/// Chuỗi xử lý một ảnh: giải mã + thu nhỏ → YuNet → căn mặt → ArcFace. Tương đương `findface.analyze()`.
public final class Analyzer: Sendable {
    public let config: AnalyzerConfig
    private let detector: FaceDetector
    private let embedder: Embedder

    public init(detector: FaceDetector, embedder: Embedder, config: AnalyzerConfig = AnalyzerConfig()) {
        self.detector = detector
        self.embedder = embedder
        self.config = config
    }

    public convenience init(modelsDirectory: URL, device: ComputeDevice = .gpu, detectorDevice: ComputeDevice? = nil,
                            embedBatch: Int = Embedder.defaultBatchSize, config: AnalyzerConfig = AnalyzerConfig()) async throws {
        let detector = try await FaceDetector(modelURL: Self.modelURL("YuNet", in: modelsDirectory), device: detectorDevice ?? device,
                                              scoreThreshold: config.detectionThreshold)
        let embedder = try await Embedder(modelURL: Self.modelURL("ArcFaceR50", in: modelsDirectory), device: device,
                                          batchSize: embedBatch)
        self.init(detector: detector, embedder: embedder, config: config)
    }

    /// Ưu tiên bản đã biên dịch (.mlmodelc, như trong bundle của app), không có thì dùng .mlpackage.
    static func modelURL(_ name: String, in dir: URL) -> URL {
        let compiled = dir.appendingPathComponent(name + ".mlmodelc")
        return FileManager.default.fileExists(atPath: compiled.path) ? compiled : dir.appendingPathComponent(name + ".mlpackage")
    }

    public func analyze(_ data: Data) throws -> [FaceRecord] {
        let (image, scale) = try ImageLoader.load(data, maxSide: config.maxSide, jpeg: config.jpegMode)
        return try analyze(image, scale: scale)
    }

    public func analyze(_ image: BGRAImage, scale: Double) throws -> [FaceRecord] {
        var faces: [FaceRecord] = []
        var crops: [UInt8] = []
        let inv = Float(1 / scale)
        for d in try detector.detect(image) {
            if min(d.width, d.height) < Float(config.minFace) { continue }
            guard let m = Aligner.robust(Aligner.ordered(d.landmarks), Aligner.template) else { continue }
            crops += Aligner.warp(image, m)
            faces.append(FaceRecord(x: d.x * inv, y: d.y * inv, width: d.width * inv, height: d.height * inv,
                                    landmarks: d.landmarks.flatMap { [$0.x * inv, $0.y * inv] },
                                    detectionScore: d.score, embedding: []))
        }
        if faces.isEmpty { return [] }
        let emb = try embedder.embed(crops, count: faces.count)
        for i in faces.indices {
            faces[i].embedding = Half.round(Array(emb[(i * Embedder.dimension)..<((i + 1) * Embedder.dimension)]))
        }
        return faces
    }
}
