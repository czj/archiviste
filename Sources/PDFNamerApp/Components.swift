import PDFNamerCore
import SwiftUI

/// State and switch in one: "⏸ Actif" (click to pause) or "▶︎ En pause" (click to resume).
struct PauseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.paused
        let color = paused ? Color.orange : Color.green
        Button { withAnimation(.snappy) { model.paused.toggle() } } label: {
            Label(paused ? "En pause" : "Actif", systemImage: paused ? "play.fill" : "pause.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(color)
                .glassEffect(.regular.tint(color.opacity(0.25)).interactive(), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p")
        .help(paused ? "Reprendre : renommer et ranger les fichiers en attente (⌘P)"
                     : "Mettre en pause : les fichiers déposés ou arrivés attendent, rien n’est renommé (⌘P)")
        .accessibilityLabel(paused ? "En pause, reprendre" : "Actif, mettre en pause")
    }
}

struct DropZone: View {
    @Environment(AppModel.self) private var model
    var targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
            Text("Déposez des PDF ou des images").font(.callout.weight(.semibold))
            HStack(spacing: 4) {
                Text("ou")
                Button("choisissez des fichiers…") { model.chooseFiles() }.buttonStyle(.link)
                    .keyboardShortcut("o").help("Choisir des fichiers (⌘O)")
                Text("· ⌘V pour coller")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(Color.accentColor.opacity(targeted ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }
}

struct FileBadge: View {
    var ext: String

    var body: some View {
        let isPDF = ext.lowercased() == "pdf"
        RoundedRectangle(cornerRadius: 3)
            .fill(.background)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
            .overlay(alignment: .bottom) {
                Text(ext.uppercased().prefix(4))
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isPDF ? Color.red : Color.blue)
                    .padding(.bottom, 3)
            }
            .frame(width: 26, height: 32)
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
    var isPDFNamerWindow: Bool { identifier?.rawValue.hasPrefix(MainWindow.id) == true }
}
