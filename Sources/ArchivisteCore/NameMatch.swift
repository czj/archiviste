import Foundation

/// A rule's file name condition in plain terms: words found in this order anywhere in the name,
/// case ignored, and the kind of file. The rule still stores a regex (`Rule.filename`): this
/// writes it, and reads back most hand-written ones ("Facture.+Power UP", "^Releve_.+\.pdf$").
/// Those it can't read (alternatives, character classes…) stay regexes, edited as such.
public struct NameMatch: Equatable, Sendable {
    /// Each word may hold spaces: "Power UP" also finds "Power_UP" and "Power-UP".
    public var words: [String] = []
    /// The first word starts the name.
    public var atStart = false
    /// Lowercased, without the dot; [] = any kind of file.
    public var extensions: [String] = []

    public init(words: [String] = [], atStart: Bool = false, extensions: [String] = []) {
        self.words = words
        self.atStart = atStart
        self.extensions = extensions
    }

    // MARK: Kinds of file

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case any, pdf, image, audio, video, sheet, custom
        public var id: Self { self }

        public var extensions: [String] {
            switch self {
            case .any, .custom: []
            case .pdf: ["pdf"]
            case .image: ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff"]
            case .audio: ["mp3", "m4a", "wav", "aac", "flac", "ogg"]
            case .video: ["mp4", "mov", "m4v"]
            case .sheet: ["xlsx", "xls", "csv", "numbers"]
            }
        }
    }

    /// The preset these extensions make, `.custom` for any other list.
    public var kind: Kind {
        if extensions.isEmpty { return .any }
        let set = Set(extensions)
        return Kind.allCases.first { $0 != .any && $0 != .custom && Set($0.extensions) == set } ?? .custom
    }

    // MARK: Writing

    static let separators = CharacterSet(charactersIn: " _-").union(.whitespacesAndNewlines)
    /// Between the parts of one word: spaces, underscores, dashes or nothing ("Market Place" finds "marketplace").
    static let gap = "[ _-]*"

    /// A word's parts: "Power-UP" and "Power UP" are the same word.
    static func parts(_ word: String) -> [String] {
        word.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// The words as typed, cleaned: parts joined by one space, empty ones dropped.
    public var cleanWords: [String] {
        words.map { Self.parts($0).joined(separator: " ") }.filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { cleanWords.isEmpty && extensions.isEmpty }

    /// The regex the rule stores; "" when there is nothing to look for (any name).
    public var pattern: String {
        let words = cleanWords
        guard !words.isEmpty || !extensions.isEmpty else { return "" }
        var p = "(?i)"
        if atStart && !words.isEmpty { p += "^" }
        p += words.map { Self.parts($0).map(NSRegularExpression.escapedPattern(for:)).joined(separator: Self.gap) }
            .joined(separator: ".*")
        if !extensions.isEmpty {
            if !words.isEmpty { p += ".*" }
            // Escaped: an extension is literal text, whatever it holds.
            let exts = extensions.map(NSRegularExpression.escapedPattern(for:))
            p += "\\." + (exts.count == 1 ? exts[0] : "(?:" + exts.joined(separator: "|") + ")") + "\\z"
        }
        return p
    }

    // MARK: Reading

    /// `\.pdf\z`, `\.(pdf|PDF)$`, `\.(?:mp3|m4a)`, at the very end.
    static let extensionSuffix = Rx(#"\\\.(?:\(\?:|\()?([A-Za-z0-9]+(?:\|[A-Za-z0-9]+)*)\)?(?:\\z|\$)?$"#)

    /// nil when the regex says more than words in order and a kind of file.
    public init?(pattern: String) {
        var s = pattern.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        if s.isEmpty { return }
        if s.hasPrefix("(?i)") { s.removeFirst(4) }
        if s.hasPrefix("^") { atStart = true; s.removeFirst() }
        if let m = Self.extensionSuffix.first(s), let r = Range(m.range, in: s), let e = Range(m.range(at: 1), in: s) {
            var seen = Set<String>()
            extensions = s[e].split(separator: "|").map { $0.lowercased() }.filter { seen.insert($0).inserted }
            s = String(s[..<r.lowerBound])
        }
        guard let words = Self.words(s) else { return nil }
        if words.leadingWildcard { atStart = false }
        self.words = words.list
        if self.words.isEmpty && extensions.isEmpty { return nil }
        if self.words.isEmpty { atStart = false }
    }

    /// The literal words of a regex made of words and `.+`/`.*` between them; nil for anything else.
    static func words(_ s: String) -> (list: [String], leadingWildcard: Bool)? {
        var list: [String] = [], current = "", leading = false
        var chars = Array(s)[...]
        func flush() {
            let w = parts(current).joined(separator: " ")
            if !w.isEmpty { list.append(w) }
            current = ""
        }
        while let c = chars.popFirst() {
            switch c {
            case "\\":
                guard let next = chars.popFirst(), !next.isLetter, !next.isNumber else { return nil }
                current.append(next)
            case "." where chars.first == "*" || chars.first == "+":
                chars.removeFirst()
                if list.isEmpty && parts(current).isEmpty { leading = true }
                flush()
            case "[":
                // Only a gap between parts of a word, as this type writes it.
                guard let g = ["[ _-]*", "[ _-]+", "[ _.-]+", "[_ -]+", "[-_ ]+"].first(where: { String(chars.prefix($0.count - 1)) == $0.dropFirst() })
                else { return nil }
                chars.removeFirst(g.count - 1)
                current.append(" ")
            case "(", ")", "{", "}", "]", "|", "^", "$", "?", "*", "+", ".":
                return nil
            default:
                current.append(c)
            }
        }
        flush()
        return (list, leading)
    }
}

extension Rule {
    /// The name condition in plain terms, nil when only a regex can say it.
    public var nameMatch: NameMatch? { NameMatch(pattern: filename) }
}
