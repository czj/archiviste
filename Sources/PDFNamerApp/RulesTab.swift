import PDFNamerCore
import SwiftUI
import UniformTypeIdentifiers

/// Filing rules: a list (first match wins, drag to reorder) and the selected rule's editor,
/// plus a tester that tells which rule takes a file, and what the others miss.
struct RulesTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Rule.ID?
    @State private var test: RuleTest?
    @State private var testing = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.rulesError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).padding(8)
            }
            HSplitView {
                list.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                Group {
                    if let i = model.rules.firstIndex(where: { $0.id == selection }) {
                        RuleEditor(rule: $model.rules[i], position: i + 1)
                    } else {
                        ContentUnavailableView("Aucune règle choisie", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Une règle range et renomme un fichier d’après son nom ou son contenu, avant tout passage par le modèle."))
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            tester
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.rules) { rule in
                    HStack(spacing: 6) {
                        Image(systemName: rule.needsText ? "doc.text.magnifyingglass" : "textformat")
                            .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                            .help(rule.needsText ? "D’après le contenu" : "D’après le nom")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.label.isEmpty ? "Nouvelle règle" : rule.label).lineLimit(1)
                            Text(rule.folder.isEmpty ? "reste sur place" : "→ " + URL(fileURLWithPath: rule.folder).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if rule.patternError != nil || !rule.hasCondition {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(rule.hasCondition ? "Expression invalide" : "Aucune condition : la règle ne s’applique jamais")
                        }
                    }
                    .opacity(rule.enabled ? 1 : 0.5)
                    .tag(rule.id)
                    .contextMenu {
                        Button("Dupliquer") { duplicate(rule) }
                        Button("Supprimer", role: .destructive) { model.rules.removeAll { $0.id == rule.id } }
                    }
                }
                .onMove { model.rules.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help("Nouvelle règle")
                Button {
                    model.rules.removeAll { $0.id == selection }
                    selection = nil
                } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    .help("Supprimer la règle")
                Spacer()
                Text("\(model.rules.count) règle(s) · la première qui correspond gagne")
                    .font(.caption2).foregroundStyle(.secondary).padding(.trailing, 6)
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private var tester: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Tester sur un fichier…", action: chooseTestFile)
                Text("ou déposez-le ici").font(.caption).foregroundStyle(.secondary)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Afficher rules.json") { model.openConfigFolder() }.buttonStyle(.link).font(.caption)
            }
            if let test {
                VStack(alignment: .leading, spacing: 3) {
                    Text(test.file).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if let match = test.match {
                        Label("Règle \(match.index + 1) « \(match.rule.label) » → \(abbreviate(match.folder))/\(match.name)",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .onTapGesture { selection = model.rules.indices.contains(match.index) ? model.rules[match.index].id : nil }
                    } else {
                        Label(test.nameable ? "Aucune règle : le modèle le nommera" : "Aucune règle : le fichier ne sera pas touché",
                              systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(test.nearMisses, id: \.self) { Text("· \($0)").foregroundStyle(.secondary) }
                }
                .font(.caption)
                .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTargeted ? Color.accentColor.opacity(0.1) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            run(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func add() {
        let rule = Rule(name: "Nouvelle règle")
        let at = model.rules.firstIndex { $0.id == selection }.map { $0 + 1 } ?? model.rules.count
        model.rules.insert(rule, at: at)
        selection = rule.id
    }

    private func duplicate(_ rule: Rule) {
        var copy = rule
        copy.id = UUID()
        copy.name = rule.label + " (copie)"
        let at = (model.rules.firstIndex { $0.id == rule.id } ?? model.rules.count - 1) + 1
        model.rules.insert(copy, at: at)
        selection = copy.id
    }

    private func chooseTestFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { run(url) }
    }

    private func run(_ url: URL) {
        testing = true
        Task {
            test = await RuleTest.run(model.rules, url)
            testing = false
        }
    }

    private func abbreviate(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// What the rules would do with one file.
struct RuleTest {
    var file: String
    var match: Rules.Match?
    var nameable: Bool
    /// Earlier rules whose name pattern fits but whose text is missing phrases.
    var nearMisses: [String]

    static func run(_ rules: [Rule], _ url: URL) async -> RuleTest {
        let misses = await Rules.nearMisses(rules, for: url).map { i, rule, missing in
            "Règle \(i + 1) « \(rule.label) » : manque \(missing.map { "« \($0) »" }.joined(separator: ", "))"
        }
        var note: [String] = []
        if let original = Marker.originalName(url) { note.append("Déjà traité par PDF Namer (avant : « \(original) ») : ignoré sauf dépôt forcé") }
        return RuleTest(file: url.lastPathComponent, match: await Rules.firstMatch(rules, for: url),
                        nameable: Config.isSupported(url), nearMisses: note + misses)
    }
}

/// One rule: when (name pattern, phrases in the text), then (folder, subfolder, name).
private struct RuleEditor: View {
    @Binding var rule: Rule
    let position: Int
    @State private var phrasesText = ""

    var body: some View {
        Form {
            Section {
                TextField("Nom de la règle", text: $rule.name, prompt: Text("ex. Factures OVH"))
                Toggle("Active", isOn: $rule.enabled)
            } header: {
                Text("Règle \(position)")
            }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Nom du fichier", text: $rule.filename, prompt: Text("expression régulière, ex. ^Facture_EDF_"))
                        .font(.body.monospaced())
                    if let error = rule.patternError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Vide : tout nom convient. (?i) au début ignore la casse.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Le texte contient (toutes ces expressions, une par ligne)")
                    TextEditor(text: $phrasesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 54, maxHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        .onChange(of: phrasesText) { _, text in
                            let phrases = text.components(separatedBy: .newlines)
                            if phrases.filter({ !$0.isEmpty }) != rule.contains { rule.contains = phrases.filter { !$0.isEmpty } }
                        }
                    Text("Majuscules et accents ignorés. PDF (scans compris), images, fichiers Excel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Quand")
            } footer: {
                if !rule.hasCondition {
                    Text("Ajoutez un nom ou une expression : sans condition, la règle ne s’applique jamais.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("Ranger dans") {
                    HStack {
                        Text(rule.folder.isEmpty ? "le même dossier" : rule.folder)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Button("Choisir…", action: chooseFolder)
                        if !rule.folder.isEmpty {
                            Button { rule.folder = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Laisser le fichier sur place")
                        }
                    }
                }
                Picker("Sous-dossier", selection: $rule.subfolder) {
                    Text("Aucun").tag(Rule.Subfolder.none)
                    Text("Année (2026)").tag(Rule.Subfolder.year)
                    Text("Année-mois (2026-11)").tag(Rule.Subfolder.yearMonth)
                }
                TextField("Renommer en", text: $rule.rename, prompt: Text("garder le nom du fichier"))
                Toggle("Préfixer par la date du document (AAAA-MM-JJ - …)", isOn: $rule.datePrefix)
            } header: {
                Text("Alors")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exemple : \(example)").textSelection(.enabled)
                    Text("La date est la première trouvée dans le texte, sinon celle de création du fichier. L’original est sauvegardé comme pour un renommage.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { phrasesText = rule.contains.joined(separator: "\n") }
        .onChange(of: rule.id) { phrasesText = rule.contains.joined(separator: "\n") }
    }

    private var example: String {
        let sample = URL(fileURLWithPath: "/Téléchargements/facture_2026_1185.pdf")
        let d = rule.destination(for: sample, date: Day.today().iso)
        let dir = rule.folder.isEmpty ? "" : (d.folder.path as NSString).abbreviatingWithTildeInPath + "/"
        return dir + d.name
    }

    private func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { rule.folder = UserConfig.abbreviate(url.path) }
    }
}
