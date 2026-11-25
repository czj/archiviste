import ArchivisteCore
import ServiceManagement
import SwiftUI

/// Réglages (⌘,): what is set once, in its own window with tabs, as on any Mac app. The work
/// (activity, rules, folders) stays in the main window.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralPane() }
            Tab("Sauvegardes et ménage", systemImage: "archivebox") { CleanupPane() }
        }
        .scenePadding(.minimum, edges: .top)
        .frame(width: 620, height: 600)
        // Like the main window: a Dock icon (and ⌘Tab) while it is open, if so set.
        .onAppear { Presence.applyDock(windowOpen: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow)?.isSettingsWindow == true else { return }
            Presence.applyDock(windowOpen: Presence.windowIsOpen)
        }
    }
}

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var login = SMAppService.mainApp.status
    @AppStorage(Presence.menuBarKey) private var showInMenuBar = true
    @AppStorage(Presence.dockKey) private var dock = Presence.Dock.withWindow
    @AppStorage(Presence.quitKey) private var onQuit = Presence.OnQuit.ask

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Valider chaque nom avant de renommer (fichiers déposés)", isOn: $model.settings.confirmBeforeRename)
            }
            Section {
                Toggle("Ouvrir à l’ouverture de session", isOn: Binding(
                    get: { login == .enabled || login == .requiresApproval },
                    set: { on in
                        model.setLaunchAtLogin(on)
                        login = SMAppService.mainApp.status
                    }))
                if login == .requiresApproval {
                    HStack {
                        Text("À autoriser dans Réglages Système › Général › Ouverture.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ouvrir les Réglages") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Icône dans la barre des menus", isOn: $showInMenuBar)
                Picker("Icône dans le Dock", selection: $dock) {
                    ForEach(Presence.Dock.allCases) { Text($0.title).tag($0) }
                }
                Picker("⌘Q", selection: $onQuit) {
                    ForEach(Presence.OnQuit.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Démarrage et affichage")
            } footer: {
                if !showInMenuBar && dock != .always {
                    Text("Sans icône, Archiviste travaille en arrière-plan : rouvrez-le depuis le Finder, Spotlight ou Raycast pour retrouver cette fenêtre.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login = SMAppService.mainApp.status  // approved meanwhile in System Settings
            }
            Section("Format du nom") {
                HStack(spacing: 6) {
                    ForEach([String(localized: "Date"), String(localized: "Type"), String(localized: "Émetteur"),
                             String(localized: "Détail"), String(localized: "Montant")], id: \.self) { part in
                        Chip(part, tint: .accentColor)
                    }
                }
                Text("Exemple : 2026-03-14 - Facture Kiné Durand - Séances de rééducation genou - 180.00 EUR.pdf")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Le montant n’apparaît que pour les factures, reçus, devis, avoirs, quittances et notes de frais. Les photos et captures d’écran prennent la date de prise de vue.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Modèle") {
                switch model.engineState {
                case .loading: Text("Chargement…")
                case .ready:
                    Label { Text("Modèle Apple sur l’appareil, prêt") } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                case .unavailable(let why):
                    Label { Text(why) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section {
                LabeledContent("Configuration") {
                    HStack {
                        Text(UserConfig.abbreviate(UserConfig.directory.path)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Afficher") { model.openConfigFolder() }
                    }
                }
                if model.localKeys.isEmpty {
                    Text("Ce Mac suit config.json.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Propre à ce Mac : \(model.localKeys.joined(separator: ", "))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revenir à config.json") { model.resetLocalConfig() }
                    }
                }
                if let configError = model.configError {
                    Text(configError).font(.subheadline).foregroundStyle(.red)
                }
            } footer: {
                Text("config.json est la configuration commune (à versionner avec vos dotfiles) ; l’app ne la modifie jamais. Ce que vous changez ici va dans config.local.json, qui ne concerne que ce Mac. La commande archiviste lit les deux.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)

    }
}

struct CleanupPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Dossier des originaux") {
                    HStack {
                        Text(model.settings.backupDir).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head).help(model.settings.backupDir)
                        Button("Changer…", action: chooseBackupDir)
                    }
                }
                Picker("Supprimer les sauvegardes après", selection: $model.settings.backupMaxAgeDays) {
                    Text("6 mois").tag(180)
                    Text("1 an").tag(365)
                    Text("Jamais").tag(0)
                }
                Picker("Mettre à la corbeille les autres fichiers après", selection: $model.settings.expireMaxAgeDays) {
                    Text("Jamais").tag(0)
                    Text("6 mois").tag(180)
                    Text("1 an").tag(365)
                    Text("18 mois").tag(548)
                    Text("2 ans").tag(730)
                }
            } footer: {
                Text("Chaque original est copié sous le nom « RENAME BACKUP <date> - … » avant d’être renommé. Les autres fichiers de ce dossier (rangés là à la main) peuvent aussi être mis à la corbeille après un temps, d’après leur date d’ajout.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Faire le ménage maintenant") { Task { await model.runHousekeeping() } }
                    Spacer()
                    if let last = model.lastHousekeeping { Text(last).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseBackupDir() {
        if let url = chooseFolders(canCreate: true).first { model.settings.backupDir = UserConfig.abbreviate(url.path) }
    }
}
