import PDFNamerCore
import QuickLook
import SwiftUI

/// The main window's pages, in sidebar order.
enum AppSection: String, CaseIterable, Identifiable {
    case activity, rules, folders, cleanup, general
    var id: Self { self }

    var title: String {
        switch self {
        case .activity: String(localized: "Activité")
        case .rules: String(localized: "Règles")
        case .folders: String(localized: "Dossiers")
        case .cleanup: String(localized: "Sauvegardes et ménage")
        case .general: String(localized: "Général")
        }
    }

    var icon: String {
        switch self {
        case .activity: "clock.arrow.circlepath"
        case .rules: "line.3.horizontal.decrease.circle"
        case .folders: "folder"
        case .cleanup: "archivebox"
        case .general: "gearshape"
        }
    }

    /// ⌘1 … ⌘5
    var key: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// Everything in one window: a sidebar of pages, the page on the right.
/// The menu bar icon opens it, takes dropped files and has a short menu.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(badge(section))
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { status }
        } detail: {
            Group {
                switch model.section {
                case .activity: ActivityPane()
                case .rules: RulesPane()
                case .folders: FoldersPane()
                case .cleanup: CleanupPane()
                case .general: GeneralPane()
                }
            }
            .navigationTitle(model.section.title)
        }
        // Shortcuts (⌘1…⌘5, ⇧⌘R…) live in the menus: AppCommands.
        // By default a menu bar app has no Dock icon nor menu bar; while this window is open it
        // gets both, so ⌘Tab finds it and Édition › Annuler shows (Réglages › Général changes that).
        // Back to menu bar only when the window really closes: onDisappear also fires when it is
        // merely hidden or changes space, which would leave a visible window that can't be activated.
        .onAppear { Presence.applyDock(windowOpen: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard (note.object as? NSWindow)?.isPDFNamerWindow == true else { return }
            Presence.applyDock(windowOpen: false)
        }
        .frame(minWidth: 940, minHeight: 540)
    }

    private func badge(_ section: AppSection) -> Int {
        switch section {
        case .activity: model.items.count { $0.phase.isPending || $0.phase == .proposed }
        case .rules: model.rules.count { !$0.isUsable }
        default: 0
        }
    }

    /// Model state and the pause switch, under the sidebar.
    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                switch model.engineState {
                case .loading: ProgressView().controlSize(.mini); Text("Chargement du modèle…")
                case .ready: Image(systemName: "apple.intelligence").foregroundStyle(.tint); Text("Modèle prêt, sur l’appareil")
                case .unavailable(let why): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(why)
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            PauseButton()
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

/// Files in progress, then everything renamed or filed lately.
struct ActivityPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var targeted = false
    /// History rows picked (click, ⇧/⌘-click): Espace previews them, the context menu acts on them.
    @State private var selection: Set<RecentEntry.ID> = []
    @State private var preview: URL?

    var body: some View {
        // Each read below filters the items: once per redraw.
        let batch = model.batch, history = history
        let busy = batch.contains { $0.phase.isPending }
        List(selection: $selection) {
            Section {
                DropZone(targeted: targeted)
                    .listRowSeparator(.hidden)
            }
            if let scan = model.tidyScan {
                Section {
                    TidyBanner(scan: scan).listRowSeparator(.hidden)
                    ForEach(model.tidyItems.filter { $0.phase != .waiting }) { ItemCard(item: $0).listRowSeparator(.hidden) }
                } header: {
                    Text("Ranger maintenant")
                }
            }
            if !batch.isEmpty {
                Section {
                    ForEach(batch) { ItemCard(item: $0).listRowSeparator(.hidden) }
                } header: {
                    HStack {
                        Text(busy ? String(localized: "En cours · \(batch.count { !$0.phase.isPending }) sur \(batch.count)")
                                  : String(localized: "Dernier lot"))
                        Spacer()
                        if busy {
                            Button("Arrêter", systemImage: "stop.fill") { model.stop() }
                        } else {
                            Button("Effacer", systemImage: "xmark.circle") { model.clear() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Section {
                if history.isEmpty {
                    Text(query.isEmpty ? String(localized: "Rien de renommé pour l’instant.")
                                       : String(localized: "Aucun fichier ne contient « \(query) »."))
                        .foregroundStyle(.secondary)
                }
                ForEach(history) { entry in
                    HistoryRow(entry: entry).tag(entry.id)
                }
            } header: {
                Text("Historique · \(model.recent.count) fichier(s)")
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: RecentEntry.ID.self) { ids in
            HistoryMenu(entries: model.recent.filter { ids.contains($0.id) }, preview: $preview)
        } primaryAction: { ids in
            for entry in model.recent where ids.contains(entry.id) { NSWorkspace.shared.open(entry.url) }
        }
        // Espace: Quick Look, as in the Finder; ↑/↓ then move through the previews.
        .onKeyPress(.space) {
            guard let entry = history.first(where: { selection.contains($0.id) }) else { return .ignored }
            preview = preview == nil ? entry.url : nil
            return .handled
        }
        .quickLookPreview($preview, in: history.filter { selection.count < 2 || selection.contains($0.id) }.map(\.url))
        .onPasteCommand(of: [.fileURL]) { _ in model.paste() }  // ⌘V: copied files from the Finder
        .searchable(text: $query, placement: .toolbar, prompt: "Nom, ancien nom, règle…")
        .searchFocused($searching)
        .focusedSceneValue(\.search, $searching)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ranger maintenant", systemImage: "tray.and.arrow.down") { model.tidyNow() }
                    .disabled(model.isTidying || !model.settings.watchedFolders.contains(where: \.enabled))
                    .help("Passer les règles sur les fichiers déjà présents dans les dossiers surveillés, avec un aperçu avant de ranger (⇧⌘R)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Choisir des fichiers…", systemImage: "plus") { model.chooseFiles() }
                    .help("Choisir des fichiers à renommer (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Afficher les sauvegardes", systemImage: "archivebox") { model.showBackups() }
                    .help("Ouvrir le dossier des originaux")
            }
        }
    }

    private var history: [RecentEntry] {
        guard !query.isEmpty else { return model.recent }
        return model.recent.filter { [$0.newName, $0.oldName, $0.rule ?? "", $0.path].joined(separator: "\n").localizedStandardContains(query) }
    }
}

/// The pass over the files already there: progress, then what it found and "Tout ranger".
private struct TidyBanner: View {
    @Environment(AppModel.self) private var model
    let scan: AppModel.TidyScan

    var body: some View {
        let items = model.tidyItems
        let ready = items.count { $0.phase == .proposed }
        let reading = items.count(where: \.phase.isPending)
        let tidying = reading > 0
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: tidying ? "magnifyingglass" : ready > 0 ? "tray.full.fill" : "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(tidying ? Color.accentColor : ready > 0 ? .orange : .green)
                .symbolEffect(.pulse, isActive: tidying)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(tidying ? String(localized: "Lecture des fichiers… encore \(reading)")
                     : ready > 0 ? String(localized: "\(ready) fichier(s) à ranger") : String(localized: "Rien à ranger"))
                    .font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tidying {
                Button("Arrêter") { model.tidyDismiss() }
            } else {
                Button("Fermer") { model.tidyDismiss() }
                    .help("Oublier ces propositions : les fichiers restent où ils sont")
                if ready > 0 {
                    Button("Tout ranger (\(ready))") { model.tidyAll() }
                        .buttonStyle(.glassProminent)
                        .help("Ranger chaque fichier comme proposé ci-dessous (⌘↩). Chacun reste annulable.")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var details: String {
        let folders = (scan.folders + scan.dated).formatted(.list(type: .and))
        var parts = [String(localized: "\(scan.scanned) fichier(s) dans \(folders)")]
        if scan.relayed > 0 { parts.append(String(localized: "\(scan.relayed) passé(s) par un dossier relais")) }
        if scan.noRule > 0 { parts.append(String(localized: "\(scan.noRule) sans règle, laissés en place")) }
        if scan.alreadyHandled > 0 { parts.append(String(localized: "\(scan.alreadyHandled) déjà traités ou en place")) }
        return parts.joined(separator: " · ")
    }
}

private struct HistoryRow: View {
    let entry: RecentEntry

    var body: some View {
        let url = entry.url
        HStack(spacing: 10) {
            FileBadge(ext: url.pathExtension)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.newName).lineLimit(1).truncationMode(.middle)
                Text("était « \(entry.oldName) »").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                if let rule = entry.rule {
                    Label(rule, systemImage: "line.3.horizontal.decrease").lineLimit(1)
                } else {
                    Label("Modèle", systemImage: "apple.intelligence")
                }
                Text(entry.date.formatted(.relative(presentation: .named)))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Drag the file itself out: to the Finder, a mail, a web upload.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(entry.path)
    }
}

/// Right-click on history rows (the one clicked, or all those selected).
private struct HistoryMenu: View {
    @Environment(AppModel.self) private var model
    let entries: [RecentEntry]
    @Binding var preview: URL?

    var body: some View {
        let urls = entries.map(\.url)
        if !entries.isEmpty {
            Button("Ouvrir") { urls.forEach { NSWorkspace.shared.open($0) } }
            Button("Aperçu (Espace)") { preview = urls.first }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            ShareLink(items: urls) { Text("Partager…") }
            Divider()
            Button("Copier le nom") { copy(entries.map(\.newName)) }
            Button("Copier le chemin") { copy(entries.map(\.path)) }
            if let entry = entries.first, entries.count == 1 {
                Divider()
                Button("Créer une règle pour ce type de fichier…") {
                    model.makeRule(from: entry.url, originalName: entry.oldName)
                }
            }
            Divider()
            Button(entries.count == 1 ? String(localized: "Annuler le renommage")
                                      : String(localized: "Annuler ces \(entries.count) renommages")) {
                entries.forEach(model.undo)
            }
            .help("Remettre le nom et le dossier d’origine")
        }
    }

    private func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

extension MainWindow {
    static let id = "main"
}

extension OpenWindowAction {
    /// Brings the main window to the front on a page (a menu bar app is not active by itself).
    @MainActor func main(_ section: AppSection? = nil, model: AppModel) {
        if let section { model.section = section }
        NSApp.activate()
        callAsFunction(id: MainWindow.id)
    }
}
