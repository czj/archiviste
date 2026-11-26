import AppKit
import Observation
import UniformTypeIdentifiers

/// The menu bar icon. A click opens the main window (there is no separate panel any more);
/// a right-click (or ⌃-click) shows a short menu; files dropped on it are renamed.
/// AppKit, because a SwiftUI MenuBarExtra can only show a menu or a panel on click.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    /// Opens the main window; set by the App, which holds SwiftUI's openWindow.
    var open: () -> Void = {}
    /// Opens the Settings window; set by the App, which holds SwiftUI's openSettings.
    var openSettings: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = String(localized: "Archiviste · clic droit : menu · déposez des fichiers ici")
        // Files dropped on the icon: the status item's window forwards drags to its delegate. A
        // view laid over the button would break ⌘-dragging the icon along the menu bar.
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
        track()
        item.isVisible = Presence.showInMenuBar
        var dock = Presence.dock
        if dock == .always { Presence.applyDock(windowOpen: false) }
        // The settings apply at once, whoever changes them (the General page, `defaults write`).
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.item.isVisible != Presence.showInMenuBar { self.item.isVisible = Presence.showInMenuBar }
                if dock != Presence.dock {
                    dock = Presence.dock
                    Presence.applyDock()
                }
            }
        }
    }

    /// The icon follows the state: busy, paused, idle.
    private func track() {
        Task { [weak self, model] in
            let symbols = Observations {
                model.isBusy || model.isTidying ? "arrow.triangle.2.circlepath"
                    : model.paused ? "pause.circle" : "doc.text.magnifyingglass"
            }
            for await symbol in symbols {
                self?.item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Archiviste")
            }
        }
    }

    func show(_ section: AppSection?) {
        if let section { model.section = section }
        // After the status item's own event, so the activation is not lost in the click.
        DispatchQueue.main.async { [self] in
            // Cooperative activation alone is refused when another app is active; the click on
            // our icon is the user asking for us, so take the focus.
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: \.isMainWindow) {
                // Already open (behind other apps, on another desktop, minimized): bring it here.
                window.collectionBehavior.insert(.moveToActiveSpace)
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else {
                open()
            }
        }
    }

    /// The Settings window, in front: a menu bar app is not active by itself.
    func showSettings() {
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu()
            item.button?.performClick(nil)  // shows the menu
            item.menu = nil                 // so the next left click opens the window again
        } else {
            show(nil)
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(entry(String(localized: "Ouvrir Archiviste"), "0") { [weak self] in self?.show(nil) })
        menu.addItem(entry(String(localized: "Ranger maintenant"), "") { [weak self] in
            self?.model.tidyNow()
            self?.show(.activity)
        })
        let pause = model.paused ? String(localized: "Reprendre") : String(localized: "Mettre en pause")
        menu.addItem(entry(pause, "") { [weak self] in self?.model.paused.toggle() })
        menu.addItem(.separator())
        menu.addItem(entry(String(localized: "Règles…"), "") { [weak self] in self?.show(.rules) })
        menu.addItem(entry(String(localized: "Réglages…"), ",") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        menu.addItem(entry(String(localized: "À propos d’Archiviste"), "") { About.show() })
        menu.addItem(entry(String(localized: "Aide d’Archiviste"), "") { NSWorkspace.shared.open(About.readme) })
        menu.addItem(entry(String(localized: "Quitter Archiviste"), "q") {
            AppDelegate.quitting = true
            NSApp.terminate(nil)
        })
        return menu
    }

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    private func entry(_ title: String, _ key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runItem(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = Action(action)
        return item
    }

    @objc private func runItem(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
}

/// Files dropped on the menu bar icon are renamed.
extension StatusItem: NSWindowDelegate, NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        item.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) { item.button?.highlight(false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let urls = sender.draggingPasteboard.fileURLs
        guard !urls.isEmpty else { return false }
        model.add(urls)
        show(.activity)
        return true
    }
}
