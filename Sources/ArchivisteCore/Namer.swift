import Foundation

/// A suggested name for one file.
public struct Suggestion: Sendable {
    public let fields: [String: String]
    /// New file name, extension included.
    public let name: String
    /// The filing rule that gave this name, nil when the model did.
    public let match: Rules.Match?
    /// Short labels for the UI, computed once (the cards redraw often).
    public let chips: [String]

    public init(fields: [String: String], name: String, match: Rules.Match? = nil) {
        self.fields = fields
        self.name = name
        self.match = match
        if let match {
            let f = match.folder
            let place = match.subfolder == .none ? f.lastPathComponent
                : f.deletingLastPathComponent().lastPathComponent + "/" + f.lastPathComponent
            chips = ["Règle « \(match.rule.label) »", "→ " + place]
        } else {
            chips = Naming.chips(fields)
        }
    }

    public init(_ match: Rules.Match) { self.init(fields: [:], name: match.name, match: match) }
}

public enum Namer {
    /// The document's issue date as the model reads it (AAAA-MM-JJ, picked among the dates written
    /// in it, never in the future); nil for other files, or when it finds none.
    public static func issueDate(_ url: URL, engine: Engine) async -> String? {
        guard Config.isSupported(url), let ex = try? await Extractor.extract(url), ex.text != nil,
              let fields = try? await engine.ask(ex, isImage: Config.isImage(url), myNames: [], strategy: .dateOnly, only: ["date"]),
              let raw = fields["date"]?.trimmingCharacters(in: .whitespaces),
              let day = Day(iso: raw), day <= .today() else { return nil }
        return day.iso
    }

    /// `issueDate` as the rules take it.
    public static func dateReader(_ engine: Engine) -> Rules.DateReader {
        { url in await issueDate(url, engine: engine) }
    }

    /// nil when nothing in the file is readable.
    /// `myNames`: the user's own names (`UserConfig.myNames`), never the issuer.
    public static func suggest(_ url: URL, _ ex: Extracted, engine: Engine, myNames: [String] = []) async throws -> Suggestion? {
        guard !ex.isEmpty else { return nil }
        let raw = try await engine.ask(ex, isImage: Config.isImage(url), myNames: myNames, strategy: .app)
        let fields = Naming.cleanFields(raw, myNames: myNames, text: ex.text)
        let ext = url.lastPathComponent.pySplitExt.1.lowercased()
        let name = Naming.buildFilename(fields, original: url.lastPathComponent, captureDate: ex.captureDate) + ext
        return Suggestion(fields: fields, name: name)
    }
}
