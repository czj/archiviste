import AppKit

/// Where the app shows itself: menu bar icon, Dock icon. Stored per Mac in UserDefaults
/// (these are this Mac's habits, not shared configuration) and applied live, no relaunch.
enum Presence {
    static let menuBarKey = "showInMenuBar"
    static let dockKey = "dockIcon"

    enum Dock: String, CaseIterable, Identifiable {
        case always, withWindow, never
        var id: Self { self }
        var title: String {
            switch self {
            case .always: String(localized: "Toujours")
            case .withWindow: String(localized: "Quand la fenêtre est ouverte")
            case .never: String(localized: "Jamais")
            }
        }
    }

    /// What ⌘Q does (also Quitter in the app menu): the Quitter of the menu bar icon, the Dock's
    /// and a logout always quit.
    static let quitKey = "onQuit"

    enum OnQuit: String, CaseIterable, Identifiable {
        case ask, background, quit
        var id: Self { self }
        var title: String {
            switch self {
            case .ask: String(localized: "Demander")
            case .background: String(localized: "Laisser tourner en arrière-plan")
            case .quit: String(localized: "Quitter")
            }
        }
    }

    static var onQuit: OnQuit {
        get { OnQuit(rawValue: UserDefaults.standard.string(forKey: quitKey) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: quitKey) }
    }

    static func register() {
        UserDefaults.standard.register(defaults: [menuBarKey: true, dockKey: Dock.withWindow.rawValue,
                                                  quitKey: OnQuit.ask.rawValue])
    }

    /// Closes the window and keeps watching folders, as if ⌘Q had said "background".
    static func goBackground() {
        for window in NSApp.windows where window.isPDFNamerWindow { window.close() }
    }

    static var showInMenuBar: Bool { UserDefaults.standard.bool(forKey: menuBarKey) }
    static var dock: Dock { Dock(rawValue: UserDefaults.standard.string(forKey: dockKey) ?? "") ?? .withWindow }

    static var windowIsOpen: Bool { NSApp.windows.contains { $0.isPDFNamerWindow && $0.isVisible } }

    /// Dock icon (and with it the app menu and ⌘Tab) according to the setting.
    static func applyDock(windowOpen: Bool? = nil) {
        let open = windowOpen ?? windowIsOpen
        let regular = switch dock {
        case .always: true
        case .withWindow: open
        case .never: false
        }
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        // Going back to accessory deactivates the app; keep an open window in front.
        if !regular, open { NSApp.activate() }
    }
}
