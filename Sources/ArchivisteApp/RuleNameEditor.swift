import ArchivisteCore
import SwiftUI

/// The file name condition of a rule: words in order and a kind of file, or, for what words
/// can't say, the regex itself. Either way, the history shows which files it would take.
struct RuleNameEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: Rule
    /// Regex mode; a rule opens in words whenever its regex reads as words.
    @State private var advanced: Bool
    @State private var confirmReset = false

    init(rule: Binding<Rule>) {
        _rule = rule
        _advanced = State(initialValue: rule.wrappedValue.nameMatch == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Le nom du fichier")
                Spacer()
                Picker("Mode", selection: Binding(get: { advanced }, set: switchMode)) {
                    Text("Mots").tag(false)
                    Text("Expression régulière").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if advanced {
                regexField
            } else {
                WordsEditor(match: Binding(
                    get: { rule.nameMatch ?? NameMatch() },
                    set: { rule.filename = $0.pattern }))
            }
            NameMatchesPreview(rule: rule)
        }
        .confirmationDialog("Repartir de mots ?", isPresented: $confirmReset) {
            Button("Effacer l’expression", role: .destructive) {
                rule.filename = ""
                advanced = false
            }
        } message: {
            Text("Cette expression dit plus que des mots dans un ordre (alternatives, chiffres, caractères au choix…) : elle ne se traduit pas en mots.")
        }
    }

    private func switchMode(_ toAdvanced: Bool) {
        if toAdvanced || rule.nameMatch != nil { advanced = toAdvanced } else { confirmReset = true }
    }

    private var regexField: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Nom du fichier", text: $rule.filename, prompt: Text("expression régulière, ex. ^Facture_EDF_"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if rule.patternError != nil {
                Text("Expression invalide").font(.subheadline).foregroundStyle(.red)
            } else {
                Text("Vide : tout nom convient. (?i) au début ignore la casse.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Words as chips, in order, then the kind of file.
private struct WordsEditor: View {
    @Binding var match: NameMatch
    @State private var newWord = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(Array(match.cleanWords.enumerated()), id: \.offset) { i, word in
                    if i > 0 {
                        Text("puis").font(.subheadline).foregroundStyle(.secondary)
                    }
                    WordChip(word: word) { remove(at: i) }
                }
                TextField("Mot", text: $newWord,
                          prompt: Text(match.cleanWords.isEmpty ? "Ajouter un mot du nom, ex. Facture" : "Ajouter un mot"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .frame(minWidth: 150)
                    .onSubmit(add)
                    // Leaving the field keeps what was typed: no word lost for a missing ↩.
                    .onChange(of: typing) { _, now in if !now { add() } }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            if !match.cleanWords.isEmpty {
                Toggle("Le nom commence par le premier mot", isOn: $match.atStart)
            }
            Picker("Type de fichier", selection: Binding(
                get: { match.kind },
                set: { if $0 != .custom { match.extensions = $0.extensions } })) {
                ForEach(NameMatch.Kind.allCases.filter { $0 != .custom }) { Text($0.title).tag($0) }
                if match.kind == .custom {
                    Text("Autres : \(match.extensions.joined(separator: ", "))").tag(NameMatch.Kind.custom)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Majuscules ignorées ; espace, _ et - se valent. N’importe quoi peut se trouver entre les mots.")
                if !match.pattern.isEmpty {
                    Text("Expression : \(Text(match.pattern).font(.subheadline.monospaced()))")
                        .textSelection(.enabled)
                } else {
                    Text("Sans mot ni type : tout nom convient.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        newWord = ""
        guard !word.isEmpty else { return }
        match.words = match.cleanWords + [word]
    }

    private func remove(at i: Int) {
        var words = match.cleanWords
        words.remove(at: i)
        match.words = words
    }
}

private struct WordChip: View {
    let word: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Retirer « \(word) »")
                .accessibilityLabel("Retirer \(word)")
        }
        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

/// Which recent files the name condition takes: a broader rule shows at once.
private struct NameMatchesPreview: View {
    @Environment(AppModel.self) private var model
    let rule: Rule

    var body: some View {
        if rule.hasNameCondition, rule.patternError == nil, !model.recent.isEmpty {
            let names = model.recent.map(\.oldName)
            let hits = names.filter(rule.matchesName)
            VStack(alignment: .leading, spacing: 3) {
                Label(hits.isEmpty
                      ? String(localized: "Aucun des \(names.count) derniers fichiers n’a un tel nom")
                      : String(localized: "Parmi les \(names.count) derniers fichiers, \(hits.count) ont un tel nom"),
                      systemImage: hits.isEmpty ? "circle.dashed" : "checkmark.circle")
                ForEach(hits.prefix(4), id: \.self) { name in
                    Text(name).lineLimit(1).truncationMode(.middle).padding(.leading, 22)
                }
                if hits.count > 4 {
                    Text("et \(hits.count - 4) autre(s)").padding(.leading, 22)
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .help("Le nom d’origine des fichiers de l’historique. Une règle qui lit aussi le contenu en prendra peut-être moins.")
        }
    }
}

extension NameMatch.Kind {
    var title: String {
        switch self {
        case .any: String(localized: "Tous les fichiers")
        case .pdf: String(localized: "PDF")
        case .image: String(localized: "Images")
        case .audio: String(localized: "Audio")
        case .video: String(localized: "Vidéos")
        case .sheet: String(localized: "Tableurs")
        case .custom: String(localized: "Autres")
        }
    }
}

/// Lays its children out in rows, wrapping to the next when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                // The last item of a row (the text field) takes what is left.
                let width = i == subviews.count - 1 ? max(size.width, bounds.maxX - x) : size.width
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
