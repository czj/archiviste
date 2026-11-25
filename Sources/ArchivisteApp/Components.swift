import ArchivisteCore
import SwiftUI
import UniformTypeIdentifiers

/// State and switch in one: "⏸ Actif" (click to pause) or "▶︎ En pause" (click to resume).
struct PauseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.paused
        let color = paused ? Color.orange : Color.green
        Button { withAnimation(.snappy) { model.paused.toggle() } } label: {
            Label(paused ? String(localized: "En pause") : String(localized: "Actif"), systemImage: paused ? "play.fill" : "pause.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(color)
                .glassEffect(.regular.tint(color.opacity(0.25)).interactive(), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(paused ? String(localized: "Reprendre : renommer et ranger les fichiers en attente (⌥⌘P)")
                     : String(localized: "Mettre en pause : les fichiers déposés ou arrivés attendent, rien n’est renommé (⌥⌘P)"))
        .accessibilityLabel(paused ? String(localized: "En pause, reprendre") : String(localized: "Actif, mettre en pause"))
    }
}

struct DropZone: View {
    @Environment(AppModel.self) private var model
    var targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
            Text("Déposez des PDF ou des images").font(.headline)
            Button("Choisir des fichiers…", systemImage: "folder") { model.chooseFiles() }
                .buttonStyle(.bordered)
                .help("Choisir des fichiers (⌘O)")
            Text("ou collez-les avec ⌘V").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Color.accentColor.opacity(targeted ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }
}

/// A short label in a capsule: the chips of a proposal, the parts of a name, the steps of a flow.
struct Chip: View {
    let text: Text
    let icon: String?
    var tint: Color?

    init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = Text(text); self.icon = systemImage; self.tint = tint
    }

    init(_ key: LocalizedStringKey, systemImage: String? = nil, tint: Color? = nil) {
        self.text = Text(key); self.icon = systemImage; self.tint = tint
    }

    var body: some View {
        Group {
            if let icon { Label { text } icon: { Image(systemName: icon) } } else { text }
        }
        .font(.subheadline)
        .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
        .fixedSize()
    }
}

/// The Finder's icon for a file type, as in a Finder list.
struct FileBadge: View {
    var ext: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
            .resizable()
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

/// Folders picked in an open panel, [] if cancelled. The app comes to the front first:
/// a menu bar app is not active by itself.
func chooseFolders(multiple: Bool = false, canCreate: Bool = false, message: String? = nil) -> [URL] {
    NSApp.activate()
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    if multiple { panel.allowsMultipleSelection = true }
    if canCreate { panel.canCreateDirectories = true }
    if let message { panel.message = message }
    return panel.runModal() == .OK ? panel.urls : []
}

extension NSPasteboard {
    /// The file URLs on the pasteboard (files copied or dragged from the Finder).
    var fileURLs: [URL] {
        readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

extension NSWindow {
    /// The main window (SwiftUI names it after the scene's id).
    var isMainWindow: Bool { identifier?.rawValue.hasPrefix(MainWindow.id) == true }
}
