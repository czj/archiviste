import Foundation
import PDFKit

/// A filing rule, tried before the model: when a file's name and/or text match, it is renamed
/// and moved as the rule says, with no model call. Rules are tried in order; the first match wins.
///
///     {
///       "name": "OVH",
///       "filename": "",                           // ICU regex on the file name, "" = any name
///       "contains": ["OVH", "Roubaix"],           // all of them in the text (case and accents ignored)
///       "folder": "~/Documents/Factures",         // "" = stays where it is
///       "subfolder": "yearMonth",                 // none | year | yearMonth, from the document's date
///       "rename": "Facture OVH cloud",            // "" = keeps its name
///       "datePrefix": true                        // "2026-11-05 - …"
///     }
public struct Rule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Subfolder: String, Codable, CaseIterable, Sendable { case none, year, yearMonth }

    /// For lists and editing only; not stored.
    public var id = UUID()
    public var name = ""
    public var enabled = true
    public var filename = ""
    public var contains: [String] = []
    public var folder = ""
    public var subfolder = Subfolder.none
    public var rename = ""
    public var datePrefix = true

    public init(name: String = "", filename: String = "", contains: [String] = [], folder: String = "",
                subfolder: Subfolder = .none, rename: String = "", datePrefix: Bool = true, enabled: Bool = true) {
        self.name = name
        self.filename = filename
        self.contains = contains
        self.folder = folder
        self.subfolder = subfolder
        self.rename = rename
        self.datePrefix = datePrefix
        self.enabled = enabled
    }

    /// Same rule whatever its (session-only) id.
    public static func == (a: Rule, b: Rule) -> Bool {
        a.name == b.name && a.enabled == b.enabled && a.filename == b.filename && a.contains == b.contains
            && a.folder == b.folder && a.subfolder == b.subfolder && a.rename == b.rename && a.datePrefix == b.datePrefix
    }

    public func hash(into h: inout Hasher) {
        h.combine(name); h.combine(enabled); h.combine(filename); h.combine(contains)
        h.combine(folder); h.combine(subfolder); h.combine(rename); h.combine(datePrefix)
    }

    enum CodingKeys: String, CodingKey { case name, enabled, filename, contains, folder, subfolder, rename, datePrefix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        subfolder = try c.decodeIfPresent(Subfolder.self, forKey: .subfolder) ?? .none
        rename = try c.decodeIfPresent(String.self, forKey: .rename) ?? ""
        datePrefix = try c.decodeIfPresent(Bool.self, forKey: .datePrefix) ?? true
    }

    // MARK: Conditions

    var phrases: [String] { contains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var namePattern: String { filename.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping }

    /// A rule with no condition would take every file: it never matches.
    public var hasCondition: Bool { !namePattern.isEmpty || !phrases.isEmpty }
    /// Content conditions need the file's text.
    public var needsText: Bool { !phrases.isEmpty }
    /// The new name or the subfolder depends on the document's date.
    public var usesDate: Bool { datePrefix || subfolder != .none }

    /// Why the filename pattern can't be used, nil when it is fine (or empty).
    public var patternError: String? {
        guard !namePattern.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: namePattern); return nil } catch { return "Expression invalide" }
    }

    public func matchesName(_ filename: String) -> Bool {
        guard !namePattern.isEmpty else { return true }
        guard let re = try? NSRegularExpression(pattern: namePattern) else { return false }
        let s = filename.precomposedStringWithCanonicalMapping
        return re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    /// The phrases missing from `text` (all present → matches).
    public func missingPhrases(in text: String?) -> [String] {
        phrases.filter { text?.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
    }

    public func matches(filename: String, text: String?) -> Bool {
        enabled && hasCondition && patternError == nil && matchesName(filename) && missingPhrases(in: text).isEmpty
    }

    /// Short label for lists: its name, else what it looks for.
    public var label: String {
        if !name.isEmpty { return name }
        if !rename.isEmpty { return rename }
        return ([namePattern] + phrases).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Drafting

    static let longDigits = Rx(#"\d{3,}"#)
    static let copySuffix = Rx(#"(?: \(\d+\)| - \d+)$"#)

    /// A rule for "files named like this one": its name up to the extension, with long numbers
    /// (dates, invoice numbers) generalised, and as new name the type and issuer the model gave
    /// ("2026-09-16 - Facture EDF - Électricité - 81.20 EUR.pdf" → "Facture EDF"). To be adjusted.
    public static func draft(from filename: String, suggestedName: String? = nil) -> Rule {
        let stem = copySuffix.sub(filename.precomposedStringWithCanonicalMapping.pySplitExt.0, "")
        let pattern = "^" + longDigits.sub(NSRegularExpression.escapedPattern(for: stem), "\\d+")
        var rename = ""
        if let suggestedName {
            let s = Naming.datePrefix.sub(suggestedName.pySplitExt.0, "")
            rename = s.components(separatedBy: " - ").first ?? s
        }
        return Rule(name: rename.isEmpty ? stem : rename, filename: pattern, rename: rename)
    }

    // MARK: Action

    /// Where and under which name a matching file goes. `date` is the document's (AAAA-MM-JJ).
    public func destination(for url: URL, date: String) -> (folder: URL, name: String) {
        var dir = folder.isEmpty ? url.deletingLastPathComponent() : UserConfig.expand(folder)
        switch subfolder {
        case .none: break
        case .year: dir.appendPathComponent(String(date.prefix(4)))
        case .yearMonth: dir.appendPathComponent(String(date.prefix(7)))
        }
        let original = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let ext = original.pySplitExt.1.lowercased()
        var stem = rename.trimmingCharacters(in: .whitespaces).isEmpty
            ? original.pySplitExt.0 : rename.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        if datePrefix && !Naming.isNamed(stem + ext) { stem = "\(date) - \(stem)" }
        return (dir, stem + ext)
    }
}

/// rules.json in the configuration folder: written by the app's Rules tab, readable by hand.
public enum Rules {
    public static var fileURL: URL { UserConfig.directory.appendingPathComponent("rules.json") }

    struct File: Codable { var rules: [Rule] }

    /// [] when the file is missing; a malformed file throws (and is never overwritten).
    public static func load(from url: URL = fileURL) throws -> [Rule] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode(File.self, from: data).rules
    }

    public static func save(_ rules: [Rule], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (enc.encode(File(rules: rules)) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    /// The outcome of trying the rules on one file.
    public struct Match: Sendable {
        public let rule: Rule
        public let index: Int
        public let folder: URL
        public let name: String
        public let date: String
        /// Where `date` comes from: the document (read by the model), the file, or unused by the rule.
        public let dateSource: DateSource
    }

    public enum DateSource: Sendable { case document, file, unused }

    /// Reads a document's issue date (AAAA-MM-JJ), nil if it can't tell: see `Namer.issueDate`.
    public typealias DateReader = @Sendable (URL) async -> String?

    /// The first enabled rule matching `url`, reading its text only if a content rule needs it.
    /// When the rule dates the file (prefix or dated subfolder), `readDate` picks the issue date
    /// (the model, choosing among the dates written in the document); the file's creation date otherwise.
    public static func firstMatch(_ rules: [Rule], for url: URL, readDate: DateReader? = nil) async -> Match? {
        let filename = url.lastPathComponent
        var text: String?? = .none  // read once, lazily
        for (i, rule) in rules.enumerated() where rule.enabled && rule.hasCondition && rule.matchesName(filename) {
            if rule.needsText && text == nil { text = .some(await RuleText.read(url)) }
            guard rule.matches(filename: filename, text: text ?? nil) else { continue }
            var date = fileDate(url), source = DateSource.file
            if !rule.usesDate {
                source = .unused
            } else if let read = await readDate?(url) {
                date = read
                source = .document
            }
            let (folder, name) = rule.destination(for: url, date: date)
            return Match(rule: rule, index: i, folder: folder, name: name, date: date, dateSource: source)
        }
        return nil
    }

    /// Rules tried before the match (or all, if none) that almost took the file: name fits and
    /// some of their phrases are in the text, but not all. The tester's "why not" list.
    public static func nearMisses(_ rules: [Rule], for url: URL) async -> [(index: Int, rule: Rule, missing: [String])] {
        var out: [(Int, Rule, [String])] = []
        var text: String??
        for (i, rule) in rules.enumerated() where rule.enabled && rule.hasCondition && rule.matchesName(url.lastPathComponent) {
            if rule.needsText && text == nil { text = .some(await RuleText.read(url)) }
            let missing = rule.missingPhrases(in: text ?? nil)
            if missing.isEmpty { break }
            if missing.count < rule.phrases.count { out.append((i, rule, missing)) }
        }
        return out
    }

    /// The file's creation date (what the Ruby script used), today if unknown.
    static func fileDate(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.creationDateKey])
        let d = v?.creationDate ?? Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return Day(c.year!, c.month!, c.day!)?.iso ?? Day.today().iso
    }
}

/// The text the content conditions look into: a PDF's whole text (OCR for scans), an image's OCR,
/// an Excel sheet's strings. nil for other files.
public enum RuleText {
    @concurrent
    public static func read(_ url: URL) async -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            if let doc = PDFDocument(url: url) {
                let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return try? await Extractor.extract(url).text  // scan
        case "xlsx":
            return xlsxStrings(url)
        default:
            return Config.isImage(url) ? try? await Extractor.extract(url).text : nil
        }
    }

    /// Enough for any real sheet; a crafted zip (a watched Downloads folder takes anything)
    /// must not make us inflate gigabytes.
    static let maxXLSXText = 10 << 20

    /// An .xlsx is a zip; its text lives in xl/sharedStrings.xml.
    static func xlsxStrings(_ url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip treats the archive name as a wildcard only when no file has that exact name; we pass
        // an existing absolute path, so "[a].xlsx" is opened as is (escaping it would break that).
        p.arguments = ["-p", url.path, "xl/sharedStrings.xml"]  // absolute path: never read as an option
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        while let chunk = try? out.fileHandleForReading.read(upToCount: 1 << 16), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maxXLSXText { p.terminate(); break }
        }
        p.waitUntilExit()
        return data.isEmpty ? nil : String(decoding: data.prefix(maxXLSXText), as: UTF8.self)
    }
}
