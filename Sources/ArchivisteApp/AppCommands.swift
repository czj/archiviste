import SwiftUI

/// What the Rules page lets the menus do with its list.
struct RulesCommands {
    var hasSelection: Bool
    var selectionEnabled: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var showTester: Binding<Bool>
    var duplicate: () -> Void
    var toggle: () -> Void
    var move: (Int) -> Void
    var delete: () -> Void
}

extension FocusedValues {
    @Entry var rules: RulesCommands?
    /// Puts the focus in the page's search field (⌘F).
    @Entry var search: FocusState<Bool>.Binding?
}

/// The menu bar menus: every shortcut of the window is listed in one of them.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.rules) private var rules
    @FocusedValue(\.search) private var search

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("À propos d’Archiviste") { About.show() }
        }

        CommandGroup(replacing: .help) {
            Button("Aide d’Archiviste") { NSWorkspace.shared.open(About.readme) }
                .keyboardShortcut("?")
            Button("Signaler un problème…") { NSWorkspace.shared.open(About.issues) }
            Divider()
            Button("Ouvrir le dossier de configuration") { model.openConfigFolder() }
        }

        // Réglages… opens the main window's General page: there is no separate settings window.
        CommandGroup(replacing: .appSettings) {
            Button("Réglages…") { show(.general) }.keyboardShortcut(",")
        }

        CommandGroup(replacing: .newItem) {
            Button("Choisir des fichiers à renommer…") {
                show(.activity)
                model.chooseFiles()
            }
            .keyboardShortcut("o")
            Button("Nouvelle règle") {
                model.pendingNewRule = true
                show(.rules)
            }
            .keyboardShortcut("n")
            Button("Tester un fichier sur les règles…") {
                model.chooseTestFile()
                if model.pendingTest != nil { show(.rules) }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("Afficher les sauvegardes") { model.showBackups() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Rechercher") { search?.wrappedValue = true }
                .keyboardShortcut("f")
                .disabled(search == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { show(section) }.keyboardShortcut(section.key)
            }
            Divider()
        }

        CommandMenu("Renommage") {
            Button("Ranger maintenant") {
                show(.activity)
                if !model.isTidying { model.tidyNow() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.settings.watchedFolders.contains(where: \.enabled))
            Button("Tout ranger") { model.tidyAll() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canTidyAll)
            Divider()
            Button(model.paused ? String(localized: "Reprendre") : String(localized: "Mettre en pause")) { model.paused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }

        CommandMenu("Règles") {
            Button("Dupliquer la règle") { rules?.duplicate() }
                .keyboardShortcut("d")
                .disabled(rules?.hasSelection != true)
            // Espace in the list; not a menu shortcut, which would take the space bar from text fields.
            Button(rules?.selectionEnabled == false ? String(localized: "Activer la règle (Espace)") : String(localized: "Désactiver la règle (Espace)")) { rules?.toggle() }
                .disabled(rules?.hasSelection != true)
            Divider()
            Button("Monter") { rules?.move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(rules?.canMoveUp != true)
            Button("Descendre") { rules?.move(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(rules?.canMoveDown != true)
            Divider()
            // ⌫ in the list (Édition › Supprimer); ⌘⌫ would take a shortcut from text fields.
            Button("Supprimer la règle") { rules?.delete() }
                .disabled(rules?.hasSelection != true)
            Divider()
            Toggle("Afficher le testeur", isOn: rules?.showTester ?? .constant(false))
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(rules == nil)
        }
    }

    private func show(_ section: AppSection) { openWindow.main(section, model: model) }
}
