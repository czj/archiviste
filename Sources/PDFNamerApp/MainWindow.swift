import PDFNamerCore
import SwiftUI

/// The main window's pages, in sidebar order.
enum AppSection: String, CaseIterable, Identifiable {
    case activity, rules, folders, cleanup, general
    var id: Self { self }

    var title: String {
        switch self {
        case .activity: "Activité"
        case .rules: "Règles"
        case .folders: "Dossiers surveillés"
        case .cleanup: "Sauvegardes et ménage"
        case .general: "Général"
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
/// The menu bar panel stays for the quick things (drop, glance, pause).
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
        .background {
            // ⌘1…⌘5 go from page to page.
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.section = section }.keyboardShortcut(section.key)
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            // ⇧⌘R from any page: show Activité and run the pass.
            Button("Ranger maintenant") {
                model.section = .activity
                if !model.isTidying { model.tidyNow() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        // A menu bar app has no Dock icon nor menu bar; while this window is open it gets both,
        // so ⌘Tab finds it and Édition › Annuler works.
        // Back to menu bar only when the window really closes: onDisappear also fires when it is
        // merely hidden or changes space, which would leave a visible window that can't be activated.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix(MainWindow.id) == true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        .frame(minWidth: 940, minHeight: 540)
    }

    private func badge(_ section: AppSection) -> Int {
        switch section {
        case .activity: model.items.filter { $0.phase.isPending || $0.phase == .proposed }.count
        case .rules: model.rules.filter { $0.patternError != nil || !$0.hasCondition }.count
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
    @State private var targeted = false

    var body: some View {
        List {
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
            if !model.batch.isEmpty {
                Section {
                    ForEach(model.batch) { ItemCard(item: $0).listRowSeparator(.hidden) }
                } header: {
                    HStack {
                        Text(model.isBusy ? "En cours · \(model.finishedCount) sur \(model.batch.count)" : "Dernier lot")
                        Spacer()
                        if model.isBusy {
                            Button("Arrêter") { model.stop() }
                        } else {
                            Button("Effacer") { model.clear() }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            Section {
                if history.isEmpty {
                    Text(query.isEmpty ? "Rien de renommé pour l’instant." : "Aucun fichier ne contient « \(query) ».")
                        .foregroundStyle(.secondary)
                }
                ForEach(history) { entry in
                    HistoryRow(entry: entry)
                }
            } header: {
                Text("Historique · \(model.recent.count) fichier(s)")
            }
        }
        .listStyle(.inset)
        .onPasteCommand(of: [.fileURL]) { _ in model.paste() }  // ⌘V: copied files from the Finder
        .searchable(text: $query, placement: .toolbar, prompt: "Nom, ancien nom, règle…")
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Ranger maintenant", systemImage: "tray.and.arrow.down") { model.tidyNow() }
                    .disabled(model.isTidying || model.settings.watchedFolders.filter(\.enabled).isEmpty)
                    .help("Passer les règles sur les fichiers déjà présents dans les dossiers surveillés, avec un aperçu avant de ranger (⇧⌘R)")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Choisir des fichiers…", systemImage: "plus") { model.chooseFiles() }
                    .keyboardShortcut("o")
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
        let ready = model.tidyReady.count
        let reading = model.tidyItems.filter(\.phase.isPending).count
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: model.isTidying ? "magnifyingglass" : ready > 0 ? "tray.full.fill" : "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(model.isTidying ? Color.accentColor : ready > 0 ? .orange : .green)
                .symbolEffect(.pulse, isActive: model.isTidying)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isTidying ? "Lecture des fichiers… encore \(reading)"
                     : ready > 0 ? "\(ready) fichier(s) à ranger" : "Rien à ranger")
                    .font(.headline)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isTidying {
                Button("Arrêter") { model.tidyDismiss() }
            } else {
                Button("Fermer") { model.tidyDismiss() }
                    .help("Oublier ces propositions : les fichiers restent où ils sont")
                if ready > 0 {
                    Button("Tout ranger (\(ready))") { model.tidyAll() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Ranger chaque fichier comme proposé ci-dessous (⌘↩). Chacun reste annulable.")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var details: String {
        var parts = ["\(scan.scanned) fichier(s) dans \((scan.folders + scan.dated).formatted(.list(type: .and)))"]
        if scan.relayed > 0 { parts.append("\(scan.relayed) passé(s) par un dossier relais") }
        if scan.noRule > 0 { parts.append("\(scan.noRule) sans règle, laissés en place") }
        if scan.alreadyHandled > 0 { parts.append("\(scan.alreadyHandled) déjà traités ou en place") }
        return parts.joined(separator: " · ")
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: RecentEntry

    var body: some View {
        let url = URL(fileURLWithPath: entry.path)
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
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Ouvrir") { NSWorkspace.shared.open(url) }
            Button("Afficher dans le Finder") { model.reveal(url) }
            Button("Créer une règle pour ce type de fichier…") {
                model.makeRule(from: url, originalName: entry.oldName)
            }
            Divider()
            Button("Copier le nom") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.newName, forType: .string)
            }
        }
        .help(entry.path)
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
