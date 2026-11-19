import SwiftUI

@main
struct PDFNamerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(model)
        } label: {
            Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass")
        }
        .menuBarExtraStyle(.window)

        Window("Règles", id: RulesWindow.id) {
            RulesWindow().environment(model)
        }
        .defaultSize(width: 1080, height: 680)
        // `-openRulesAtLaunch YES` on the command line opens it right away (handy to look at a build).
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "openRulesAtLaunch") ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(model)
        }
    }
}

extension RulesWindow {
    static let id = "rules"
}

extension OpenWindowAction {
    /// Brings the Rules window to the front (a menu bar app is not active by itself).
    func rules() {
        NSApp.activate()
        callAsFunction(id: RulesWindow.id)
    }
}
