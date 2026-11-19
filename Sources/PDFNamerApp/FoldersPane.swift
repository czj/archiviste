import PDFNamerCore
import SwiftUI

/// The Dossiers page: the two kinds of folders PDF Namer watches, kept apart.
///
/// - Inboxes (Downloads, Desktop, a scanner's folder): each file that arrives goes through the
///   rules (name, then content), else the model names it in place. Or a relay, moving it as is.
/// - Classeurs (Achats, Ventes…): each file landing at the top, by hand or from a rule, goes to its
///   year or month subfolder.
///
/// A folder is one or the other, never both.
struct FoldersPane: View {
    @Environment(AppModel.self) private var model
    /// Folders the last "Ajouter" left out because they are listed already.
    @State private var notice: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                FlowDiagram()
            }
            Section {
                if model.settings.watchedFolders.isEmpty {
                    Text("Aucune boîte d’arrivée").foregroundStyle(.secondary)
                }
                ForEach($model.settings.watchedFolders) { $folder in
                    InboxRow(folder: $folder)
                }
                Button("Ajouter une boîte d’arrivée…") { report(model.addFolder()) }
            } header: {
                Label("Boîtes d’arrivée", systemImage: "tray.and.arrow.down")
            } footer: {
                Text("Chaque fichier qui arrive passe par les règles : d’abord celles sur le nom, puis celles sur le contenu. La première qui convient le renomme et le range. Sans règle, le modèle nomme les PDF et les images sur place (« Date - Type Émetteur - Détail »). Un relais déplace ses fichiers tels quels vers un autre dossier, par exemple les scans d’une app vers le Bureau.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.settings.datedFolders.isEmpty {
                    Text("Aucun classeur").foregroundStyle(.secondary)
                }
                ForEach($model.settings.datedFolders) { $folder in
                    ClasseurRow(folder: $folder, rules: ruleCount(folder.url))
                }
                Button("Ajouter un classeur…") { report(model.addClasseur()) }
            } header: {
                Label("Classeurs", systemImage: "calendar")
            } footer: {
                Text("Tout fichier posé à la racine d’un classeur, à la main ou par une règle, part dans son sous-dossier d’année ou de mois : date du document, sinon celle du nom, sinon celle du fichier. Une règle qui range ici y dépose directement le fichier, au bon endroit. Pour les fichiers déjà en vrac, utilisez « Ranger maintenant » (⇧⌘R) : un aperçu s’affiche avant de déplacer quoi que ce soit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice {
                Section { Label(notice, systemImage: "info.circle").foregroundStyle(.secondary) }
            }
            let others = unsortedDestinations
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.url) { dest in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
                            FolderLabel(name: dest.url.lastPathComponent, path: UserConfig.abbreviate(dest.url.path),
                                        detail: rulesText(dest.count))
                            Spacer()
                            Button("En faire un classeur") {
                                model.settings.datedFolders.append(UserConfig.DatedFolder(path: dest.url.path))
                            }
                        }
                    }
                } header: {
                    Text("Autres destinations des règles")
                } footer: {
                    Text("Ces dossiers reçoivent des fichiers par les règles, tels quels, sans sous-dossier. Un classeur les rangerait par année.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func report(_ already: [String]) {
        notice = already.isEmpty ? nil
            : "Déjà dans la liste : \(already.joined(separator: ", ")). Un dossier est soit une boîte d’arrivée, soit un classeur."
    }

    /// How many enabled rules file into this folder.
    private func ruleCount(_ url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return model.rules.count { $0.enabled && !$0.folder.isEmpty && UserConfig.expand($0.folder).standardizedFileURL.path == path }
    }

    /// Rule destinations that are neither a classeur nor an inbox, with their rule count.
    private var unsortedDestinations: [(url: URL, count: Int)] {
        var counts: [String: Int] = [:], order: [URL] = []
        for rule in model.rules where rule.enabled && !rule.folder.isEmpty {
            let url = UserConfig.expand(rule.folder).standardizedFileURL
            guard !model.settings.isListed(url) else { continue }
            if counts[url.path] == nil { order.append(url) }
            counts[url.path, default: 0] += 1
        }
        return order.map { ($0, counts[$0.path] ?? 0) }
    }
}

func rulesText(_ n: Int) -> String {
    switch n {
    case 0: "aucune règle n’y range"
    case 1: "1 règle y range"
    default: "\(n) règles y rangent"
    }
}

/// What happens to a file, in one line.
private struct FlowDiagram: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Step(icon: "tray.and.arrow.down", text: "Boîte d’arrivée")
                Arrow()
                Step(icon: "textformat", text: "Règle sur le nom")
                Text("sinon").font(.caption2).foregroundStyle(.secondary)
                Step(icon: "doc.text.magnifyingglass", text: "sur le contenu")
                Arrow()
                Step(icon: "calendar", text: "Classeur › 2026")
            }
            HStack(spacing: 6) {
                Text("Aucune règle :").font(.caption).foregroundStyle(.secondary)
                Step(icon: "sparkles", text: "le modèle nomme le fichier sur place")
            }
            HStack(spacing: 6) {
                Text("Posé à la main dans un classeur :").font(.caption).foregroundStyle(.secondary)
                Step(icon: "calendar", text: "rangé dans 2026 ou 2026-11")
            }
        }
        .padding(.vertical, 2)
    }

    private struct Step: View {
        let icon: String, text: String
        var body: some View {
            Label(text, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }

    private struct Arrow: View {
        var body: some View { Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary) }
    }
}

private struct FolderLabel: View {
    let name: String, path: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
        .help(path)
    }
}

private struct InboxRow: View {
    @Environment(AppModel.self) private var model
    @Binding var folder: UserConfig.Folder

    var body: some View {
        HStack {
            Image(systemName: folder.relay == nil ? "tray.and.arrow.down" : "arrow.right.circle")
                .foregroundStyle(.tint).frame(width: 20)
            FolderLabel(name: folder.name, path: folder.path)
            Spacer()
            Menu {
                Button("Règles, puis le modèle") { folder.moveTo = nil }
                Button("Seulement déplacer vers…", action: chooseRelay)
            } label: {
                Text(folder.relay.map { "Déplacer vers \($0.lastPathComponent)" } ?? "Règles, puis le modèle")
            }
            .fixedSize()
            .help(folder.relay.map { "Relais : chaque fichier qui arrive est déplacé vers \(UserConfig.abbreviate($0.path)), sans autre traitement" }
                  ?? "Les règles (nom, puis contenu), sinon le modèle, sur chaque fichier qui arrive")
            Toggle("Actif", isOn: $folder.enabled).labelsHidden().toggleStyle(.switch)
                .help(folder.enabled ? "Surveillé : décocher pour suspendre ce dossier seulement" : "Suspendu : rien n’y est renommé")
            Button {
                model.settings.watchedFolders.removeAll { $0.path == folder.path }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Ne plus surveiller ce dossier (ses fichiers ne bougent pas)")
            .accessibilityLabel("Retirer \(folder.name)")
        }
    }

    private func chooseRelay() {
        let message = "Où déplacer les fichiers qui arrivent dans « \(folder.name) » ?"
        guard let url = chooseFolders(canCreate: true, message: message).first,
              !UserConfig.same(url, folder.url) else { return }
        folder.moveTo = UserConfig.abbreviate(url.path)
    }
}

private struct ClasseurRow: View {
    @Environment(AppModel.self) private var model
    @Binding var folder: UserConfig.DatedFolder
    let rules: Int

    var body: some View {
        HStack {
            Image(systemName: "calendar").foregroundStyle(.tint).frame(width: 20)
            FolderLabel(name: folder.name, path: folder.path, detail: rulesText(rules))
            Spacer()
            Picker("Sous-dossier", selection: $folder.subfolder) {
                Text("Par année").tag(Rule.Subfolder.year)
                Text("Par mois").tag(Rule.Subfolder.yearMonth)
                Text("Sans sous-dossier").tag(Rule.Subfolder.none)
            }
            .labelsHidden().fixedSize()
            .help("2026, 2026-11, ou à la racine (seulement le préfixe de date)")
            Toggle("Dater les noms", isOn: $folder.datePrefix)
                .toggleStyle(.checkbox).fixedSize()
                .help("Fichiers posés à la main : mettre « AAAA-MM-JJ - » devant leur nom. Ceux qu’une règle range gardent le nom qu’elle leur donne.")
            Toggle("Actif", isOn: $folder.enabled).labelsHidden().toggleStyle(.switch)
                .help(folder.enabled ? "Surveillé : chaque fichier posé à la racine est rangé" : "Non surveillé : les règles y rangent toujours par année ou par mois, mais rien de posé à la main n’est rangé")
            Button {
                model.settings.datedFolders.removeAll { $0.path == folder.path }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Retirer ce classeur (ses fichiers ne bougent pas)")
            .accessibilityLabel("Retirer \(folder.name)")
        }
    }
}

/// A destination folder's sorting, from wherever it is shown (a rule's editor): the classeur's
/// setting, shared by every rule filing there and by the files put there by hand.
struct ClasseurPicker: View {
    @Environment(AppModel.self) private var model
    let folder: String

    private enum Choice: Hashable { case off, flat, year, month }

    var body: some View {
        let url = UserConfig.expand(folder)
        if model.settings.isInbox(url) {
            LabeledContent("Classement du dossier") {
                Text("aucun : c’est une boîte d’arrivée").foregroundStyle(.secondary)
            }
        } else {
            let choice = current(url)
            Picker("Classement du dossier", selection: Binding(get: { choice }, set: { set($0, url) })) {
                Text("Aucun").tag(Choice.off)
                Text("Par année (2026)").tag(Choice.year)
                Text("Par mois (2026-11)").tag(Choice.month)
                if choice == .flat { Text("Sans sous-dossier").tag(Choice.flat) }
            }
            .help("Réglage du dossier « \(url.lastPathComponent) » (page Dossiers) : vaut pour toutes les règles qui y rangent et pour les fichiers posés là à la main.")
        }
    }

    private func index(_ url: URL) -> Int? {
        model.settings.datedFolders.firstIndex { UserConfig.same($0.url, url) }
    }

    private func current(_ url: URL) -> Choice {
        guard let i = index(url) else { return .off }
        return switch model.settings.datedFolders[i].subfolder {
        case .none: .flat
        case .year: .year
        case .yearMonth: .month
        }
    }

    private func set(_ choice: Choice, _ url: URL) {
        let subfolder: Rule.Subfolder
        switch choice {
        case .off:
            if let i = index(url) { model.settings.datedFolders.remove(at: i) }
            return
        case .flat: subfolder = .none
        case .year: subfolder = .year
        case .month: subfolder = .yearMonth
        }
        if let i = index(url) {
            model.settings.datedFolders[i].subfolder = subfolder
        } else {
            model.settings.datedFolders.append(UserConfig.DatedFolder(path: folder, subfolder: subfolder))
        }
    }
}
