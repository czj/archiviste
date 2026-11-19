import SwiftUI

@main
struct PDFNamerApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(model)
        } label: {
            Image(systemName: model.isBusy || model.isTidying ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass")
        }
        .menuBarExtraStyle(.window)

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
