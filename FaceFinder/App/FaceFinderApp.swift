import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FaceFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        UILanguage.applyAtLaunch()  // trước khi nạp bất kỳ chuỗi giao diện nào
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Face Finder", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Thêm thư mục hoặc file zip…") { model.chooseSources() }
                    .keyboardShortcut("o")
                Button("Thêm người…") { model.showNewPerson = true }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
