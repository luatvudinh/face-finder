import CoreServices
import Foundation

/// Theo dõi thay đổi file trong các thư mục (FSEvents). Gọi `onChange` với các đường dẫn đã đổi, gộp trong `latency` giây.
final class FolderWatcher {
    private final class Box {
        let onChange: ([String]) -> Void
        init(_ f: @escaping ([String]) -> Void) { onChange = f }
    }

    private var stream: FSEventStreamRef?

    init?(paths: [String], latency: TimeInterval = 2, onChange: @escaping ([String]) -> Void) {
        let box = Unmanaged.passRetained(Box(onChange))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil,
                                           release: { Unmanaged<AnyObject>.fromOpaque($0!).release() }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            box.release()
            return nil
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
