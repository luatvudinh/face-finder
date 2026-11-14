import AppKit
import FaceFinderKit

/// Quyền truy cập file của app sandbox (PLAN.md mục 3): app chỉ đọc/ghi được những gì người dùng tự chọn hoặc kéo
/// thả vào. Các quyền đó được lưu thành security-scoped bookmark, mở lại một lần khi khởi động và giữ suốt phiên.
@MainActor final class AccessStore {
    /// Thư mục được phép ghi: thư mục nguồn và thư mục người dùng đã bấm "Cho phép".
    private(set) var writableRoots: [String] = []
    private var active: [URL] = []

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Mở lại một quyền đã lưu. Trả về đường dẫn hiện tại của file/thư mục (nếu nó đã bị đổi tên thì khác đường dẫn cũ).
    @discardableResult
    func open(_ bookmark: Data, writable: Bool) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() { active.append(url) }
        if writable { writableRoots.append(ImageSource.absolutePath(url.path)) }
        return url
    }

    /// Thư mục người dùng vừa chọn/kéo thả trong phiên này (đã có quyền, chưa cần mở bookmark).
    func allowWriting(_ url: URL) {
        writableRoots.append(ImageSource.absolutePath(url.path))
    }

    func canWrite(_ path: String) -> Bool {
        writableRoots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    /// Hỏi người dùng cho phép dùng một thư mục: hộp thoại chọn thư mục mở sẵn tại `directory`.
    func askForFolder(at directory: URL?, message: String, prompt: String = "Cho phép") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        allowWriting(url)
        return url
    }
}
