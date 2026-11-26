import ArchivisteCore
import SwiftUI

/// One file in the batch: its name, where it stands, then what can be done with it.
/// The name is the main line whatever the phase; what it was before, the status and the chips
/// are secondary. Not selectable: a click on it must not turn it into a blank highlight.
struct ItemCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let item: Item
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .fontWeight(item.phase == .proposed || item.phase == .done ? .semibold : .regular)
                        .foregroundStyle(item.phase == .waiting ? .secondary : .primary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let before {
                    Text("était « \(before) »")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(item.phase == .waiting ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }

    /// The file as it is called now, or as it will be once the proposal is applied.
    private var title: String {
        switch item.phase {
        case .proposed: item.suggestion?.name ?? item.originalName
        case .done, .cancelled: item.url.lastPathComponent
        default: item.originalName
        }
    }

    /// Its first name, when the title shows another one.
    private var before: String? {
        title == item.originalName ? nil : item.originalName
    }

    @ViewBuilder private var icon: some View {
        switch item.phase {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .reading, .analyzing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .proposed: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .unchanged: Image(systemName: "equal.circle").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var status: String {
        switch item.phase {
        case .waiting: return model.paused ? String(localized: "en pause") : String(localized: "en attente")
        case .reading: return String(localized: "lecture…")
        case .analyzing: return String(localized: "analyse…")
        case .proposed: return String(localized: "à valider")
        case .unchanged: return String(localized: "déjà bien nommé")
        case .cancelled: return String(localized: "annulé")
        case .skipped(let why): return why
        case .failed: return String(localized: "erreur")
        case .done: return item.took.map { String(format: "%.1f s", $0) } ?? ""
        }
    }

    @ViewBuilder private var content: some View {
        switch item.phase {
        case .failed(let msg):
            Text(msg).font(.subheadline).foregroundStyle(.red).textSelection(.enabled)
        case .proposed, .done:
            if editing {
                HStack {
                    TextField("Nouveau nom", text: $draft).textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                    Button("OK", action: commit).keyboardShortcut(.defaultAction)
                    Button("Annuler") { editing = false }
                }
            } else {
                actions
            }
        case .skipped, .unchanged, .cancelled:
            HStack {
                Spacer()
                ruleButton
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    /// "Files like this one: rename and file them so" — opens the Rules window on a drafted rule.
    private var ruleButton: some View {
        Button("Créer une règle…", systemImage: "text.badge.plus") {
            model.makeRule(from: item.url, suggestion: item.suggestion, originalName: item.originalName,
                           dated: item.dating != nil)
            openWindow.main(model: model)  // makeRule already chose the Rules page
        }
        .help("Une règle pour les fichiers nommés comme celui-ci : où les ranger et comment les nommer")
    }

    /// Real buttons, icon and text; in a narrow window they shrink to icons (each keeps its tooltip).
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow.labelStyle(.titleAndIcon)
            actionRow.labelStyle(.iconOnly)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            ForEach(item.suggestion?.chips ?? [], id: \.self) { chip in
                Chip(chip)
            }
            Spacer(minLength: 8)
            if item.phase == .proposed {
                Button("Modifier", systemImage: "pencil", action: startEditing)
                    .help("Changer le nom proposé avant de renommer")
                Button("Ignorer", systemImage: "xmark") { model.skip(item) }
                    .help("Laisser ce fichier tel quel")
                Button(item.suggestion?.match == nil ? String(localized: "Renommer") : String(localized: "Ranger"),
                       systemImage: "checkmark") { model.apply(item, name: title) }
                    .buttonStyle(.borderedProminent)
                    .help("Appliquer ce nom (l’original est sauvegardé)")
            } else {
                Button("Modifier", systemImage: "pencil", action: startEditing)
                    .help("Changer le nom donné")
                Button(String(localized: "undo-rename", defaultValue: "Annuler", comment: "Undo a rename (not Cancel)"),
                       systemImage: "arrow.uturn.backward") {
                    model.undo(item)
                }
                    .help("Remettre le nom et le dossier d’origine")
                Button("Afficher", systemImage: "folder") { model.reveal(item.url) }
                    .help("Afficher le fichier dans le Finder")
                ruleButton
            }
        }
        .buttonStyle(.bordered)
    }

    private func startEditing() {
        draft = (title as NSString).deletingPathExtension
        editing = true
    }

    private func commit() {
        editing = false
        model.apply(item, name: draft)
    }
}
