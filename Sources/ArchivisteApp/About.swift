import AppKit

/// The standard About panel (name, icon, version, copyright from Info.plist), plus what it
/// does, the source code and the licence.
enum About {
    static let repository = URL(string: "https://github.com/czj/archiviste")!
    static let readme = URL(string: "https://github.com/czj/archiviste#readme")!
    static let issues = URL(string: "https://github.com/czj/archiviste/issues")!

    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "Renomme vos PDF, scans et images d’après leur contenu, entièrement sur votre Mac.") + "\n\n",
            attributes: small)
        var link = small
        link[.link] = repository
        credits.append(NSAttributedString(string: String(localized: "Code source sur GitHub"), attributes: link))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
