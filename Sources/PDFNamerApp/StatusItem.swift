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

    init(model: AppModel) {
        self.model = model
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "PDF Namer · clic droit : menu · déposez des fichiers ici"
        let drop = DropTarget(frame: button.bounds) { [weak self] urls in
            self?.model.add(urls)
            self?.show(.activity)
        }
        drop.autoresizingMask = [.width, .height]
        button.addSubview(drop)
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
        withObservationTracking {
            let symbol = model.isBusy || model.isTidying ? "arrow.triangle.2.circlepath"
                : model.paused ? "pause.circle" : "doc.text.magnifyingglass"
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PDF Namer")
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    func show(_ section: AppSection?) {
        if let section { model.section = section }
        // After the status item's own event, so the activation is not lost in the click.
        DispatchQueue.main.async { [self] in
            // Cooperative activation alone is refused when another app is active; the click on
            // our icon is the user asking for us, so take the focus.
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true }) {
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
        menu.addItem(entry("Ouvrir PDF Namer", "0") { [weak self] in self?.show(nil) })
        menu.addItem(entry("Ranger maintenant", "") { [weak self] in
            self?.model.tidyNow()
            self?.show(.activity)
        })
        menu.addItem(entry(model.paused ? "Reprendre" : "Mettre en pause", "") { [weak self] in self?.model.paused.toggle() })
        menu.addItem(.separator())
        menu.addItem(entry("Règles…", "") { [weak self] in self?.show(.rules) })
        menu.addItem(entry("Réglages…", ",") { [weak self] in self?.show(.general) })
        menu.addItem(.separator())
        menu.addItem(entry("Quitter PDF Namer", "q") { NSApp.terminate(nil) })
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

/// Lets files be dropped on the menu bar icon, as on the old panel. Clicks pass through.
private final class DropTarget: NSView {
    private let onDrop: ([URL]) -> Void

    init(frame: NSRect, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    nonisolated required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the button

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        superview.map { ($0 as? NSButton)?.highlight(true) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { (superview as? NSButton)?.highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? NSButton)?.highlight(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
