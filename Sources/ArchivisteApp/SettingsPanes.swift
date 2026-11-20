import ArchivisteCore
import ServiceManagement
import SwiftUI

// The main window's settings pages.

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
                            .font(.caption).foregroundStyle(.secondary)
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
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                login = SMAppService.mainApp.status  // approved meanwhile in System Settings
            }
            Section("Format du nom") {
                HStack(spacing: 4) {
                    ForEach([String(localized: "Date"), String(localized: "Type"), String(localized: "Émetteur"),
                             String(localized: "Détail"), String(localized: "Montant")], id: \.self) { part in
                        Text(part).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text("Exemple : 2026-03-14 - Facture Kiné Durand - Séances de rééducation genou - 180.00 EUR.pdf")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Le montant n’apparaît que pour les factures, reçus, devis, avoirs, quittances et notes de frais. Les photos et captures d’écran prennent la date de prise de vue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Modèle") {
                switch model.engineState {
                case .loading: Text("Chargement…")
                case .ready: Label("Modèle Apple sur l’appareil, prêt", systemImage: "checkmark.circle").foregroundStyle(.green)
                case .unavailable(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Configuration") {
                    HStack {
                        Text(UserConfig.abbreviate(UserConfig.directory.path)).foregroundStyle(.secondary)
                        Button("Afficher") { model.openConfigFolder() }
                    }
                }
                if model.localKeys.isEmpty {
                    Text("Ce Mac suit config.json.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Propre à ce Mac : \(model.localKeys.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revenir à config.json") { model.resetLocalConfig() }
                    }
                }
                if let configError = model.configError {
                    Text(configError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("config.json est la configuration commune (à versionner avec tes dotfiles) ; l’app ne la modifie jamais. Ce que tu changes ici va dans config.local.json, qui ne concerne que ce Mac. La commande archiviste lit les deux.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Faire le ménage maintenant") { Task { await model.runHousekeeping() } }
                    Spacer()
                    if let last = model.lastHousekeeping { Text(last).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseBackupDir() {
        if let url = chooseFolders(canCreate: true).first { model.settings.backupDir = UserConfig.abbreviate(url.path) }
    }
}
