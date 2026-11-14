import Foundation

public struct AnalysisOutput: Sendable {
    public var faces: [String: [FaceRecord]] = [:]
    /// Ảnh không đọc/giải mã được, kèm lý do.
    public var errors: [String: String] = [:]
    /// Số ảnh lấy lại từ chỉ mục, không phải phân tích lại.
    public var cached = 0
}

/// Phát việc cho các luồng xử lý, mỗi lần một ảnh.
private actor WorkQueue {
    private var items: ArraySlice<ImageItem>
    init(_ items: [ImageItem]) { self.items = items[...] }
    func next() -> ImageItem? { items.popFirst() }
}

public enum Pipeline {
    /// Số luồng giải mã + phát hiện mặt chạy song song. Phần trích vân mặt dùng chung một model trên GPU.
    public static var defaultWorkers: Int { max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2 + 1)) }

    /// Phân tích các ảnh chưa có trong chỉ mục, chạy song song; ảnh đã có thì lấy lại ngay.
    /// `progress(đã xong, tổng số cần phân tích)` được gọi sau mỗi ảnh.
    public static func analyze(_ items: [ImageItem], analyzer: Analyzer, index: FaceIndex?, workers: Int = defaultWorkers,
                               progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> AnalysisOutput {
        var out = AnalysisOutput()
        let signature = analyzer.config.signature
        if let index { out.faces = try index.load(items, signature: signature) }
        out.cached = out.faces.count
        let todo = items.filter { out.faces[$0.key] == nil }
        if todo.isEmpty { return out }

        typealias Result = (item: ImageItem, faces: [FaceRecord], error: String?)
        let queue = WorkQueue(todo)
        let (stream, continuation) = AsyncStream<Result>.makeStream()
        let group = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<max(1, min(workers, todo.count)) {
                    group.addTask {
                        let reader = ItemReader()
                        while !Task.isCancelled, let item = await queue.next() {
                            let result: Result = autoreleasepool {
                                do { return (item, try analyzer.analyze(try reader.read(item)), nil) }
                                catch { return (item, [], "\(error)") }
                            }
                            continuation.yield(result)
                        }
                    }
                }
            }
            continuation.finish()
        }

        var pending: [(item: ImageItem, faces: [FaceRecord])] = []
        var done = 0
        do {
            for await r in stream {
                out.faces[r.item.key] = r.faces
                if let e = r.error { out.errors[r.item.key] = e } else { pending.append((r.item, r.faces)) }
                if pending.count >= 100 {
                    try index?.store(pending, signature: signature)
                    pending.removeAll()
                }
                done += 1
                progress(done, todo.count)
                try Task.checkCancellation()
            }
            try index?.store(pending, signature: signature)
        } catch {
            group.cancel()
            try? index?.store(pending, signature: signature)
            throw error
        }
        return out
    }
}
