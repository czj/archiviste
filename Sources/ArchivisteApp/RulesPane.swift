import ArchivisteCore
import SwiftUI
import UniformTypeIdentifiers

/// Filing rules, a page of the main window: a searchable list (first match wins, drag to reorder),
/// the selected rule's editor, and a tester in the inspector that tells which rule takes a file.
///
/// Keyboard: the menus (AppCommands) for ⌘N, ⌘D, ⌥⌘↑/↓, ⌘F, ⌥⌘T, ⌥⌘O; here ⌫ delete,
/// Espace on/off, ⌘Z / ⇧⌘Z undo and redo.
struct RulesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    @AppStorage("rulesSort") private var sort = RuleSort.priority
    @AppStorage("rulesTester") private var showTester = false
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var tester = Tester()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: listWidth)
            Divider().overlay { resizeHandle }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: $showTester) {
            TesterPanel(tester: tester, run: run)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .navigationSubtitle("\(model.rules.count) règles · sur le nom, puis sur le contenu : la première qui correspond gagne")
        .searchable(text: $query, placement: .toolbar, prompt: "Nom, dossier, expression…")
        .searchFocused($searching)
        .toolbar { toolbar }
        .focusedSceneValue(\.rules, commands)
        .focusedSceneValue(\.search, $searching)
        .task(id: model.pendingNewRule) {
            guard model.pendingNewRule else { return }
            model.pendingNewRule = false
            add()
        }
        // Drop a file anywhere on the window to see which rule takes it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            run(url)
            return true
        } isTargeted: { tester.targeted = $0 }
        .task(id: model.pendingTest) {
            guard let url = model.pendingTest else { return }
            model.pendingTest = nil
            run(url)
        }
    }

    // MARK: Sidebar

    /// The list's width, dragged from its edge and kept across launches.
    @AppStorage("rulesListWidth") private var listWidth = 310.0
    @State private var dragStartWidth: Double?

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStartWidth ?? listWidth
                    dragStartWidth = start
                    listWidth = min(max(start + drag.translation.width, 240), 720)
                }
                .onEnded { _ in dragStartWidth = nil })
            .onTapGesture(count: 2) { listWidth = 310 }  // double-click: back to the default
            .help("Glisser pour élargir la liste · double-clic : largeur par défaut")
    }

    private var sidebar: some View {
        @Bindable var model = model
        let shown = shown
        return List(selection: $model.selectedRuleID) {
            if let error = model.rulesError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            }
            if shown.isEmpty, !query.isEmpty {
                Text("Aucune règle ne contient « \(query) »").foregroundStyle(.secondary)
            }
            switch sort {
            case .priority where query.isEmpty:
                ForEach(shown, id: \.rule.id) { row($0.rule, rank: $0.rank) }
                    .onMove { from, to in model.changeRules(String(localized: "Déplacer"), undo: undo) { $0.move(fromOffsets: from, toOffset: to) } }
            case .priority, .name:
                ForEach(shown, id: \.rule.id) { row($0.rule, rank: $0.rank) }
            case .folder:
                let groups = Dictionary(grouping: shown) { RuleStyle.folderKey($0.rule) }
                ForEach(groups.keys.sorted(), id: \.self) { key in
                    let rows = groups[key]!  // already by rank: grouping keeps the order of `shown`
                    Section {
                        ForEach(rows, id: \.rule.id) { row($0.rule, rank: $0.rank) }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: rows[0].rule.folder.isEmpty ? "mappin" : "folder.fill")
                                .foregroundStyle(RuleStyle.color(rows[0].rule))
                            Text(RuleStyle.folderTitle(rows[0].rule))
                            Spacer()
                            Text(rows.count, format: .number).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .help(rows[0].rule.folder)
                    }
                }
            }
        }
        .onDeleteCommand(perform: delete)
        .onKeyPress(.space) {
            guard let selection else { return .ignored }
            toggle(selection)
            return .handled
        }
        .animation(.snappy, value: model.rules.map(\.id))
    }

    /// (rule, its priority) in display order, filtered by the search.
    private var shown: [(rule: Rule, rank: Int)] {
        let all = model.rules.enumerated().map { (rule: $1, rank: $0 + 1) }
            .filter { query.isEmpty || RuleStyle.searchText($0.rule).localizedStandardContains(query) }
        switch sort {
        case .priority: return all
        case .name: return all.sorted { $0.rule.label.localizedStandardCompare($1.rule.label) == .orderedAscending }
        case .folder:
            return all.map { (key: RuleStyle.folderKey($0.rule), row: $0) }
                .sorted { ($0.key, $0.row.rank) < ($1.key, $1.row.rank) }
                .map(\.row)
        }
    }

    /// The destination, unless the name already says it (or the section does): then what the rule looks for.
    private func subtitle(_ rule: Rule) -> String {
        let folder = RuleStyle.folderTitle(rule)
        if sort != .folder, !rule.label.localizedStandardContains(folder) {
            return rule.folder.isEmpty ? String(localized: "reste sur place") : "→ " + folder
        }
        if !rule.contains.isEmpty {
            return String(localized: "contient \(rule.contains.map(RuleStyle.quoted).joined(separator: " + "))")
        }
        return rule.filename.isEmpty ? String(localized: "aucune condition") : rule.filename
    }

    private func row(_ rule: Rule, rank: Int) -> some View {
        HStack(spacing: 10) {
            RuleIcon(rule: rule)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.label.isEmpty ? String(localized: "Nouvelle règle") : rule.label).lineLimit(1)
                Text(subtitle(rule))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !rule.isUsable {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(rule.hasCondition ? String(localized: "Expression invalide") : String(localized: "Aucune condition : la règle ne s’applique jamais"))
            }
            if sort != .priority || !query.isEmpty {
                Text(verbatim: "#\(rank)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .help("Rang : les règles s’appliquent dans l’ordre de priorité")
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.enabled ? 1 : 0.45)
        .tag(rule.id)
        .contextMenu {
            Button(rule.enabled ? String(localized: "Désactiver") : String(localized: "Activer")) { toggle(rule.id) }
            Button("Dupliquer") { duplicate(rule.id) }
            Divider()
            Button("Monter") { move(rule.id, by: -1) }.disabled(rank == 1)
            Button("Descendre") { move(rule.id, by: 1) }.disabled(rank == model.rules.count)
            if !rule.folder.isEmpty {
                Button("Afficher le dossier dans le Finder") {
                    NSWorkspace.shared.open(UserConfig.expand(rule.folder))
                }
            }
            Divider()
            Button("Supprimer", role: .destructive) { delete(rule.id) }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        @Bindable var model = model
        if let i = selectedIndex {
            RuleEditor(rule: $model.rules[i], position: i + 1, count: model.rules.count,
                       move: { move(model.rules[i].id, by: $0) })
                .id(model.rules[i].id)
        } else {
            ContentUnavailableView {
                Label("Aucune règle choisie", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Une règle range et renomme un fichier d’après son nom ou son contenu, avant tout passage par le modèle.")
            } actions: {
                Button("Nouvelle règle", action: add).buttonStyle(.glassProminent)
                Button("Tester un fichier…") { model.chooseTestFile() }.buttonStyle(.glass)
            }
        }
    }

    // MARK: Toolbar and keys

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Nouvelle règle", systemImage: "plus", action: add)
                .help("Nouvelle règle, après celle choisie (⌘N)")
            Button("Dupliquer", systemImage: "plus.square.on.square") { selection.map(duplicate) }
                .disabled(selection == nil)
                .help("Dupliquer la règle (⌘D)")
            Button("Supprimer", systemImage: "trash") { selection.map(delete) }
                .disabled(selection == nil)
                .help("Supprimer la règle (⌫, annulable par ⌘Z)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Trier par", selection: $sort) {
                    ForEach(RuleSort.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Trier", systemImage: "arrow.up.arrow.down")
            }
            .help("Trier la liste : l’ordre d’application reste celui de priorité")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showTester) {
                Label("Tester", systemImage: "testtube.2")
            }
            .help("Tester les règles sur un fichier (⌥⌘T) : déposez-le n’importe où dans la fenêtre")
        }
    }

    /// The Règles menu acts on the selection through this.
    private var commands: RulesCommands {
        let i = selectedIndex
        return RulesCommands(
            hasSelection: i != nil,
            selectionEnabled: i.map { model.rules[$0].enabled } ?? true,
            canMoveUp: i.map { $0 > 0 } ?? false,
            canMoveDown: i.map { $0 < model.rules.count - 1 } ?? false,
            showTester: $showTester,
            duplicate: { selection.map(duplicate) },
            toggle: { selection.map(toggle) },
            move: { step in selection.map { move($0, by: step) } },
            delete: { selection.map(delete) })
    }

    // MARK: Actions

    private var selection: Rule.ID? { model.selectedRuleID }
    private var selectedIndex: Int? { model.rules.firstIndex { $0.id == selection } }

    private func add() {
        let rule = Rule(name: String(localized: "Nouvelle règle"))
        let at = selectedIndex.map { $0 + 1 } ?? model.rules.count
        model.changeRules(String(localized: "Nouvelle règle"), undo: undo) { $0.insert(rule, at: at) }
        model.selectedRuleID = rule.id
        query = ""
    }

    private func duplicate(_ id: Rule.ID) {
        guard let i = model.rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = model.rules[i]
        copy.id = UUID()
        copy.name = String(localized: "\(copy.label) (copie)")
        model.changeRules(String(localized: "Dupliquer"), undo: undo) { $0.insert(copy, at: i + 1) }
        model.selectedRuleID = copy.id
    }

    private func delete() { selection.map(delete) }

    /// Deletes and selects the next rule, so ⌫ ⌫ ⌫ walks down the list.
    private func delete(_ id: Rule.ID) {
        guard let i = model.rules.firstIndex(where: { $0.id == id }) else { return }
        model.changeRules(String(localized: "Supprimer « \(model.rules[i].label) »"), undo: undo) { $0.remove(at: i) }
        if model.selectedRuleID == id {
            model.selectedRuleID = model.rules.indices.contains(i) ? model.rules[i].id : model.rules.last?.id
        }
    }

    private func toggle(_ id: Rule.ID) {
        guard let i = model.rules.firstIndex(where: { $0.id == id }) else { return }
        model.changeRules(model.rules[i].enabled ? String(localized: "Désactiver") : String(localized: "Activer"), undo: undo) { $0[i].enabled.toggle() }
    }

    private func move(_ id: Rule.ID, by step: Int) {
        guard let i = model.rules.firstIndex(where: { $0.id == id }), model.rules.indices.contains(i + step) else { return }
        model.changeRules(step < 0 ? String(localized: "Monter") : String(localized: "Descendre"), undo: undo) { $0.swapAt(i, i + step) }
    }

    private func run(_ url: URL) {
        showTester = true
        tester.url = url
        tester.running = true
        Task {
            let result = await RuleTest.run(model.rules, url, readDate: model.readDate, sorted: model.settings.datedFolders)
            if tester.url == url {
                tester.result = result
                tester.running = false
            }
        }
    }
}

enum RuleSort: String, CaseIterable, Identifiable {
    case priority, folder, name
    var id: Self { self }
    var title: String {
        switch self {
        case .priority: String(localized: "Priorité")
        case .folder: String(localized: "Dossier de destination")
        case .name: String(localized: "Nom de règle")
        }
    }
    var icon: String {
        switch self {
        case .priority: "list.number"
        case .folder: "folder"
        case .name: "textformat.abc"
        }
    }
}

/// Colors and labels shared by the sidebar, the editor and the tester.
enum RuleStyle {
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .mint, .cyan, .brown, .red, .yellow]

    /// One color per destination folder, stable from one launch to the next (hashValue is not).
    static func color(_ rule: Rule) -> Color {
        guard !rule.folder.isEmpty else { return .gray }
        let hash = rule.folder.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// Sorted by folder name; the full path keeps two folders of the same name apart.
    static func folderKey(_ rule: Rule) -> String {
        rule.folder.isEmpty ? "" : URL(fileURLWithPath: rule.folder).lastPathComponent.lowercased() + "\u{0}" + rule.folder
    }

    static func folderTitle(_ rule: Rule) -> String {
        rule.folder.isEmpty ? String(localized: "Sur place") : URL(fileURLWithPath: rule.folder).lastPathComponent
    }

    /// A phrase between the language's quotation marks: « … » in French, “…” in English.
    static func quoted(_ text: String) -> String { String(localized: "« \(text) »") }

    static func searchText(_ rule: Rule) -> String {
        ([rule.label, rule.folder, rule.filename, rule.rename] + rule.contains).joined(separator: "\n")
    }
}

/// A small colored tile: the folder's color, a glyph for "by name" or "by content".
struct RuleIcon: View {
    let rule: Rule
    var size: CGFloat = 26

    var body: some View {
        let color = RuleStyle.color(rule)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: rule.needsText ? "doc.text.magnifyingglass" : "textformat")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .saturation(rule.enabled ? 1 : 0)
            .help(rule.needsText ? String(localized: "D’après le contenu") : String(localized: "D’après le nom"))
    }
}

// MARK: Tester

@Observable final class Tester {
    var url: URL?
    var result: RuleTest?
    var running = false
    var targeted = false
}

/// What the rules would do with one file.
struct RuleTest {
    var file: String
    var match: Rules.Match?
    var nameable: Bool
    /// Earlier rules whose name pattern fits but whose text is missing phrases.
    var nearMisses: [String]

    static func run(_ rules: [Rule], _ url: URL, readDate: Rules.DateReader?, sorted: [UserConfig.DatedFolder]) async -> RuleTest {
        let misses = await Rules.nearMisses(rules, for: url).map { i, rule, missing in
            String(localized: "Règle \(i + 1) « \(rule.label) » : manque \(missing.map(RuleStyle.quoted).joined(separator: ", "))")
        }
        var note: [String] = []
        if let original = Marker.originalName(url) {
            note.append(String(localized: "Déjà traité par Archiviste (avant : « \(original) ») : l’app le laisse de côté, seule la commande archiviste --force le reprend"))
        }
        return RuleTest(file: url.lastPathComponent, match: await Rules.firstMatch(rules, for: url, readDate: readDate, sorted: sorted),
                        nameable: Config.isSupported(url), nearMisses: note + misses)
    }
}

private struct TesterPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undo
    let tester: Tester
    let run: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                dropZone
                if let result = tester.result, let url = tester.url, !tester.running {
                    outcome(result, url: url)
                }
            }
            .padding(14)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            if tester.running {
                ProgressView().controlSize(.small)
                Text("Lecture de \(tester.url?.lastPathComponent ?? "…")").font(.caption).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "arrow.down.doc").font(.system(size: 26, weight: .light)).foregroundStyle(.tint)
                Text("Déposez un fichier").font(.callout.weight(.semibold))
                Text("dans la fenêtre, ou ⌥⌘O").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(Color.accentColor.opacity(tester.targeted ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .animation(.snappy, value: tester.targeted)
    }

    @ViewBuilder private func outcome(_ result: RuleTest, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FileRow(name: result.file, detail: String(localized: "fichier testé"))
            if let match = result.match {
                Image(systemName: "arrow.down").foregroundStyle(.secondary).frame(width: 26)
                FileRow(name: match.name, detail: UserConfig.abbreviate(match.folder.path))
                Button {
                    model.selectedRuleID = model.rules.indices.contains(match.index) ? model.rules[match.index].id : nil
                } label: {
                    HStack(spacing: 8) {
                        RuleIcon(rule: match.rule, size: 20)
                        Text("Règle \(match.index + 1) · \(match.rule.label)").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Afficher cette règle")
                if match.dateSource != .unused {
                    Label(match.dateSource == .document ? String(localized: "Date du document, lue par le modèle : \(match.date)")
                          : match.dateSource == .name ? String(localized: "Date déjà dans le nom : \(match.date)")
                          : String(localized: "Pas de date dans le document : date du fichier, \(match.date)"),
                          systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(result.nameable ? String(localized: "Aucune règle : le modèle le nommera")
                                      : String(localized: "Aucune règle : le fichier ne sera pas touché"),
                      systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            if !result.nearMisses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Presque").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(result.nearMisses, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button(result.match == nil ? String(localized: "Créer une règle depuis ce fichier") : String(localized: "Créer une variante pour ce fichier")) {
                model.makeRule(from: url, suggestion: result.match.map(Suggestion.init), undo: undo)
            }
            .buttonStyle(.glass)
        }
        .textSelection(.enabled)
    }
}

/// A file as the history shows it: badge, name, a line of detail.
struct FileRow: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            FileBadge(ext: (name as NSString).pathExtension)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(2).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

// MARK: Editor

/// One rule: when (name pattern, phrases in the text), then (folder, name). The destination's
/// year or month subfolder is the folder's setting, shown and changeable here.
private struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: Rule
    let position: Int
    let count: Int
    let move: (Int) -> Void
    @State private var phrasesText = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    RuleIcon(rule: rule, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Nom de la règle", text: $rule.name, prompt: Text("ex. Factures OVH"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                        Group {
                            if rule.needsText {
                                Text("Priorité \(position) sur \(count) · lit le contenu : essayée après les règles sur le nom")
                            } else {
                                Text("Priorité \(position) sur \(count) · sur le nom : essayée avant les règles sur le contenu")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ControlGroup {
                        Button("Monter", systemImage: "chevron.up") { move(-1) }.disabled(position == 1)
                        Button("Descendre", systemImage: "chevron.down") { move(1) }.disabled(position == count)
                    }
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .help("Changer la priorité (⌥⌘↑ / ⌥⌘↓)")
                    Toggle("Active", isOn: $rule.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(rule.enabled ? String(localized: "Active (Espace dans la liste pour basculer)") : String(localized: "Désactivée"))
                }
                .padding(.vertical, 4)
            }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Le nom du fichier correspond à")
                    TextField("Nom du fichier", text: $rule.filename, prompt: Text("expression régulière, ex. ^Facture_EDF_"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    if rule.patternError != nil {
                        Text("Expression invalide").font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Vide : tout nom convient. (?i) au début ignore la casse.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Le texte contient (toutes ces expressions, une par ligne)")
                    TextEditor(text: $phrasesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 54, maxHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: phrasesText) { _, text in
                            let phrases = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                            if phrases != rule.contains { rule.contains = phrases }
                        }
                    Text("Majuscules et accents ignorés. PDF (scans compris), images, fichiers Excel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Label("Quand", systemImage: "line.3.horizontal.decrease")
            } footer: {
                if !rule.hasCondition {
                    Text("Ajoutez un nom ou une expression : sans condition, la règle ne s’applique jamais.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("Ranger dans") {
                    HStack {
                        Text(rule.folder.isEmpty ? String(localized: "le même dossier") : rule.folder)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Button("Choisir…", action: chooseFolder)
                        if !rule.folder.isEmpty {
                            Button { rule.folder = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Laisser le fichier sur place")
                        }
                    }
                }
                if !rule.folder.isEmpty {
                    ClasseurPicker(folder: rule.folder)
                }
                TextField("Renommer en", text: $rule.rename, prompt: Text("garder le nom du fichier"))
                Toggle("Préfixer par la date du document (AAAA-MM-JJ - …)", isOn: $rule.datePrefix)
            } header: {
                Label("Alors", systemImage: "arrow.turn.down.right")
            } footer: {
                Group {
                    if rule.subfolder != .none && !rule.folder.isEmpty
                        && UserConfig.DatedFolder.find(UserConfig.expand(rule.folder), in: model.settings.datedFolders) == nil {
                        if rule.subfolder == .year {
                            Text("Cette règle range encore elle-même dans un sous-dossier d’année (ancien format). Choisissez un classement du dossier pour le remplacer.")
                        } else {
                            Text("Cette règle range encore elle-même dans un sous-dossier de mois (ancien format). Choisissez un classement du dossier pour le remplacer.")
                        }
                    } else {
                        Text("Le classement par année ou par mois est celui du dossier : il vaut pour toutes les règles qui y rangent et pour les fichiers posés là à la main (page Dossiers). La date est celle du document, lue par le modèle ; à défaut, celle de création du fichier. L’original est sauvegardé comme pour un renommage.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Exemple") {
                FileRow(name: "facture_2026_1185.pdf", detail: "~/Downloads")
                FileRow(name: example.name, detail: example.folder)
            }
        }
        .formStyle(.grouped)
        .onAppear { phrasesText = rule.contains.joined(separator: "\n") }
    }

    private var example: (name: String, folder: String) {
        let sample = UserConfig.expand("~/Downloads/facture_2026_1185.pdf")
        let d = rule.destination(for: sample, date: Day.today().iso, sorted: model.settings.datedFolders)
        return (d.name, UserConfig.abbreviate(d.folder.path))
    }

    private func chooseFolder() {
        if let url = chooseFolders(canCreate: true).first { rule.folder = UserConfig.abbreviate(url.path) }
    }
}
