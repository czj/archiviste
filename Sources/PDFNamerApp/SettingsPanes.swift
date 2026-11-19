import PDFNamerCore
import SwiftUI

// The main window's settings pages.

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Valider chaque nom avant de renommer (fichiers déposés)", isOn: $model.settings.confirmBeforeRename)
                Toggle("Ouvrir au démarrage de la session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in model.launchAtLogin = on }
            }
            Section("Format du nom") {
                HStack(spacing: 4) {
                    ForEach(["Date", "Type", "Émetteur", "Détail", "Montant"], id: \.self) { part in
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
                        Text((UserConfig.directory.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
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
                Text("config.json est la configuration commune (à versionner avec tes dotfiles) ; l’app ne la modifie jamais. Ce que tu changes ici va dans config.local.json, qui ne concerne que ce Mac. La commande pdf-namer lit les deux.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}

struct FoldersPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if model.settings.watchedFolders.isEmpty {
                    Text("Aucun dossier surveillé").foregroundStyle(.secondary)
                }
                ForEach($model.settings.watchedFolders) { $folder in
                    HStack {
                        Image(systemName: folder.relay == nil ? "folder" : "arrow.right.circle")
                            .foregroundStyle(.tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name)
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Menu {
                            Button("Renommer et ranger ici") { folder.moveTo = nil }
                            Button("Seulement déplacer vers…") { chooseRelay(for: $folder) }
                        } label: {
                            Text(folder.relay.map { "→ \($0.lastPathComponent)" } ?? "Renommer et ranger")
                        }
                        .fixedSize()
                        .help(folder.relay.map { "Dossier relais : chaque fichier qui arrive est déplacé vers \(($0.path as NSString).abbreviatingWithTildeInPath), sans autre traitement (pour la boîte d’envoi d’une app de scan, par exemple)" }
                              ?? "Les règles, puis le modèle, sur chaque fichier qui arrive")
                        Toggle("Actif", isOn: $folder.enabled).labelsHidden().toggleStyle(.switch)
                        Button {
                            model.settings.watchedFolders.removeAll { $0.path == folder.path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Retirer \(folder.name)")
                    }
                }
                Button("Ajouter un dossier…") { model.addFolder() }
            } footer: {
                Text("Chaque fichier qui arrive dans ces dossiers passe d’abord par les règles (rangé et renommé s’il en suit une), sinon le modèle nomme les PDF et images, avec une notification. Les fichiers déjà présents, ceux déjà traités par PDF Namer et ceux nommés « AAAA-MM-JJ - … » ne sont pas renommés par le modèle. Un dossier relais (« Seulement déplacer vers… ») passe ses fichiers à un autre dossier, par exemple les scans d’une app vers le Bureau. « Ranger maintenant » (⇧⌘R) passe les règles sur les fichiers déjà là, avec un aperçu avant de ranger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.settings.datedFolders.isEmpty {
                    Text("Aucun dossier classé par date").foregroundStyle(.secondary)
                }
                ForEach($model.settings.datedFolders) { $folder in
                    HStack {
                        Image(systemName: "calendar").foregroundStyle(.tint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name)
                            Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Picker("Sous-dossier", selection: $folder.subfolder) {
                            Text("Année").tag(Rule.Subfolder.year)
                            Text("Année-mois").tag(Rule.Subfolder.yearMonth)
                            Text("Aucun").tag(Rule.Subfolder.none)
                        }
                        .labelsHidden().fixedSize()
                        Toggle("Préfixe AAAA-MM-JJ", isOn: $folder.datePrefix)
                            .toggleStyle(.checkbox).fixedSize()
                            .help("Ajouter « AAAA-MM-JJ - » devant les noms qui ne l’ont pas")
                        Toggle("Actif", isOn: $folder.enabled).labelsHidden().toggleStyle(.switch)
                        Button {
                            model.settings.datedFolders.removeAll { $0.path == folder.path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Retirer \(folder.name)")
                    }
                }
                Button("Ajouter un dossier…", action: addDatedFolder)
            } header: {
                Text("Classement par date")
            } footer: {
                Text("« Ranger maintenant » propose de ranger les fichiers laissés à la racine de ces dossiers, et seulement de ceux-là, dans leur sous-dossier d’année ou de mois, préfixés par leur date : celle du nom s’il en a une, sinon celle du document, sinon celle du fichier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let suggestions = model.settings.datedSuggestions(model.rules)
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.folder.path) { suggestion in
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.folder.name)
                                Text("règle « \(suggestion.rule) » · \(subfolderTitle(suggestion.folder.subfolder))\(suggestion.folder.datePrefix ? ", préfixe" : "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .help(suggestion.folder.path)
                            Spacer()
                            Button("Ajouter") { model.settings.datedFolders.append(suggestion.folder) }
                        }
                    }
                } header: {
                    Text("Suggestions · destinations de règles datées")
                } footer: {
                    Text("Ces dossiers reçoivent des fichiers datés par tes règles, mais ne sont pas classés par date. Ajoutés, ils prennent les réglages de la première règle qui les vise.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func subfolderTitle(_ s: Rule.Subfolder) -> String {
        switch s {
        case .none: "sans sous-dossier"
        case .year: "par année"
        case .yearMonth: "par mois"
        }
    }

    private func addDatedFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.settings.datedFolders.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            model.settings.datedFolders.append(UserConfig.DatedFolder(path: url.path))
        }
    }

    private func chooseRelay(for folder: Binding<UserConfig.Folder>) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Où déplacer les fichiers qui arrivent dans « \(folder.wrappedValue.name) » ?"
        guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != folder.wrappedValue.url.standardizedFileURL else { return }
        folder.wrappedValue.moveTo = UserConfig.abbreviate(url.path)
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
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.settings.backupDir = UserConfig.abbreviate(url.path) }
    }
}
