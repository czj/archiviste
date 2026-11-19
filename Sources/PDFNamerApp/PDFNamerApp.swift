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

    /// Set by an explicit "Quitter PDF Namer" (menu bar icon): no question then.
    static var quitting = false

    /// ⌘Q on a menu bar app usually means "close this", rarely "stop watching my folders": ask
    /// (or do what was chosen once and for all). A quit sent by the system (logout, the Dock's
    /// Quitter, `osascript`) arrives as an Apple event and goes through untouched.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if Self.quitting || event?.eventID == kAEQuitApplication { return .terminateNow }
        switch Presence.onQuit {
        case .quit: return .terminateNow
        case .background:
            Presence.goBackground()
            return .terminateCancel
        case .ask:
            let alert = NSAlert()
            alert.messageText = String(localized: "Quitter PDF Namer ?")
            alert.informativeText = String(localized: """
                En arrière-plan, il continue de surveiller vos dossiers, sans fenêtre. \
                Quitté, il rattrapera au prochain lancement ce qui sera arrivé entre-temps.
                """)
            alert.addButton(withTitle: String(localized: "Laisser tourner"))
            alert.addButton(withTitle: String(localized: "Quitter"))
            alert.addButton(withTitle: String(localized: "Annuler")).keyEquivalent = "\u{1b}"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Ne plus demander (modifiable dans Réglages › Général)")
            let answer = alert.runModal()
            let remember = alert.suppressionButton?.state == .on
            switch answer {
            case .alertFirstButtonReturn:
                if remember { Presence.onQuit = .background }
                Presence.goBackground()
                return .terminateCancel
            case .alertSecondButtonReturn:
                if remember { Presence.onQuit = .quit }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
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
        .commands { AppCommands(model: model) }
    }
}
