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
            case .always: "Toujours"
            case .withWindow: "Quand la fenêtre est ouverte"
            case .never: "Jamais"
            }
        }
    }

    static func register() {
        UserDefaults.standard.register(defaults: [menuBarKey: true, dockKey: Dock.withWindow.rawValue])
    }

    static var showInMenuBar: Bool { UserDefaults.standard.bool(forKey: menuBarKey) }
    static var dock: Dock { Dock(rawValue: UserDefaults.standard.string(forKey: dockKey) ?? "") ?? .withWindow }

    @MainActor static var windowIsOpen: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.isVisible }
    }

    /// Dock icon (and with it the app menu and ⌘Tab) according to the setting.
    @MainActor static func applyDock(windowOpen: Bool? = nil) {
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
