import AppKit
import Foundation

/// Ngôn ngữ giao diện. Mặc định tiếng Việt (PLAN.md), kể cả khi macOS đặt tiếng Anh đứng trước; người dùng đổi được trong
/// Cài đặt. Áp dụng bằng cách đặt AppleLanguages trong miền cài đặt riêng của app, trước khi app nạp chuỗi giao diện.
enum UILanguage: String, CaseIterable, Identifiable {
    case vietnamese = "vi", english = "en", system

    var id: String { rawValue }
    static let key = "uiLanguage"

    /// Tên hiển thị bằng chính ngôn ngữ đó (không dịch).
    var nativeName: String {
        switch self {
        case .vietnamese: return "Tiếng Việt"
        case .english: return "English"
        case .system: return String(localized: "Theo macOS")
        }
    }

    static var current: UILanguage {
        UILanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .vietnamese
    }

    /// Gọi thật sớm khi app khởi động (trước khi hiện giao diện).
    static func applyAtLaunch() {
        apply(current)
    }

    static func apply(_ lang: UILanguage) {
        let d = UserDefaults.standard
        d.set(lang.rawValue, forKey: key)
        switch lang {
        case .system: d.removeObject(forKey: "AppleLanguages")
        case .vietnamese, .english: d.set([lang.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Ngôn ngữ app đang hiện (đã chọn lúc mở app).
    static var active: String { Bundle.main.preferredLocalizations.first ?? "vi" }

    /// Mở lại app để áp dụng ngôn ngữ mới.
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
