import SwiftUI

/// A menu bar app: closing its window must not quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window; set by the App, which holds SwiftUI's openWindow.
    var open: () -> Void = {}

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Spotlight, Raycast, the Dock) shows its window: the way
    /// back when both the menu bar icon and the Dock icon are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        open()
        return false
    }
}

@main
struct PDFNamerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel
    @State private var status: StatusItem
    @Environment(\.openWindow) private var openWindow

    init() {
        Presence.register()
        let model = AppModel()
        _model = State(initialValue: model)
        _status = State(initialValue: StatusItem(model: model))
    }

    var body: some Scene {
        // The menu bar icon opens this window: one place for everything.
        let _ = status.open = { [openWindow] in openWindow(id: MainWindow.id) }
        let _ = delegate.open = { [status] in status.show(nil) }

        Window("PDF Namer", id: MainWindow.id) {
            MainWindow().environment(model)
        }
        .defaultSize(width: 1180, height: 720)
        // `-openAtLaunch YES` on the command line opens it right away (handy to look at a build).
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "openAtLaunch") ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            // Réglages… (⌘,) opens the main window's General page: there is no separate settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Réglages…") { openWindow.main(.general, model: model) }.keyboardShortcut(",")
            }
        }
    }
}
