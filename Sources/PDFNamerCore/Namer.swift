import Foundation

/// A suggested name for one file.
public struct Suggestion: Sendable {
    public let fields: [String: String]
    /// New file name, extension included.
    public let name: String
    /// The filing rule that gave this name, nil when the model did.
    public let match: Rules.Match?
    public var chips: [String] {
        guard let match else { return Naming.chips(fields) }
        let f = match.folder
        let place = match.rule.subfolder == .none ? f.lastPathComponent
            : f.deletingLastPathComponent().lastPathComponent + "/" + f.lastPathComponent
        return ["Règle « \(match.rule.label) »", "→ " + place]
    }

    public init(fields: [String: String], name: String, match: Rules.Match? = nil) {
        self.fields = fields
        self.name = name
        self.match = match
    }

    public init(_ match: Rules.Match) { self.init(fields: [:], name: match.name, match: match) }
}

public enum Namer {
    /// The document's issue date as the model reads it (AAAA-MM-JJ, picked among the dates written
    /// in it, never in the future); nil for other files, or when it finds none.
    public static func issueDate(_ url: URL, engine: Engine) async -> String? {
        guard Config.isSupported(url), let ex = try? await Extractor.extract(url), ex.text != nil,
              let fields = try? await engine.ask(ex, isImage: Config.isImage(url)),
              let raw = fields["date"]?.trimmingCharacters(in: .whitespaces),
              let day = Day(iso: raw), day <= .today() else { return nil }
        return day.iso
    }

    /// nil when nothing in the file is readable.
    public static func suggest(_ url: URL, _ ex: Extracted, engine: Engine) async throws -> Suggestion? {
        guard !ex.isEmpty else { return nil }
        let fields = try await engine.ask(ex, isImage: Config.isImage(url))
        let ext = url.lastPathComponent.pySplitExt.1.lowercased()
        let name = Naming.buildFilename(fields, original: url.lastPathComponent, captureDate: ex.captureDate) + ext
        return Suggestion(fields: fields, name: name)
    }
}
