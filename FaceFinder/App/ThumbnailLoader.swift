import AppKit
import FaceFinderKit

/// Giới hạn số việc chạy cùng lúc (giải mã ảnh 33 MP tốn RAM).
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

private struct SendableImage: @unchecked Sendable { let cg: CGImage? }

/// Ảnh khuôn mặt cho lưới kết quả, có bộ nhớ đệm.
@MainActor final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let limiter = Limiter(4)

    init() { cache.countLimit = 600 }

    func face(_ score: ItemScore) async -> NSImage? {
        guard let f = score.face else { return nil }
        let key = "\(score.item.key)#\(Int(f.x)),\(Int(f.y))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        await limiter.acquire()
        let item = score.item
        let img = await Task.detached(priority: .userInitiated) { () -> SendableImage in
            guard !Task.isCancelled, let data = try? ItemReader().read(item) else { return SendableImage(cg: nil) }
            return SendableImage(cg: FaceCrop.image(from: data, x: f.x, y: f.y, width: f.width, height: f.height, side: 200))
        }.value
        await limiter.release()
        guard let cg = img.cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
