import Foundation
import PDFKit
import Synchronization

/// A filing rule, tried before the model: when a file's name and/or text match, it is renamed
/// and moved as the rule says, with no model call. Rules on the name alone are tried first, then
/// those that read the text, each group in its order; the first match wins.
///
///     {
///       "name": "OVH",
///       "filename": "",                           // ICU regex on the file name, "" = any name
///       "contains": ["OVH", "Roubaix"],           // all of them in the text (case and accents ignored)
///       "folder": "~/Documents/Factures",         // "" = stays where it is
///       "rename": "Facture OVH cloud",            // "" = keeps its name
///       "datePrefix": true                        // "2026-11-05 - …"
///     }
///
/// The year or month subfolder is not the rule's: it belongs to the destination folder, when it
/// is listed under `datedFolders` (a "classeur"), and applies to whatever lands there. Older files
/// may still carry a `subfolder` key: it is read, used only for a folder that is not a classeur,
/// and moved to `datedFolders` by the app (`UserConfig.migrateSubfolders`).
public struct Rule: Codable, Equatable, Sendable, Identifiable {
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

    /// `subfolder` is written only while a rule still has one (the old format).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(filename, forKey: .filename)
        try c.encode(contains, forKey: .contains)
        try c.encode(folder, forKey: .folder)
        if subfolder != .none { try c.encode(subfolder, forKey: .subfolder) }
        try c.encode(rename, forKey: .rename)
        try c.encode(datePrefix, forKey: .datePrefix)
    }

    // MARK: Conditions

    var phrases: [String] { contains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var namePattern: String { filename.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping }

    /// A rule with no condition would take every file: it never matches.
    public var hasCondition: Bool { !namePattern.isEmpty || !phrases.isEmpty }
    /// Content conditions need the file's text.
    public var needsText: Bool { !phrases.isEmpty }
    /// The new name or the subfolder depends on the document's date.
    public func usesDate(for url: URL, sorted: [UserConfig.DatedFolder] = []) -> Bool {
        datePrefix || subfolder(for: url, sorted: sorted) != .none
    }

    /// Where a matching file goes, before any year or month subfolder.
    public func targetFolder(for url: URL) -> URL {
        folder.isEmpty ? url.deletingLastPathComponent() : UserConfig.expand(folder)
    }

    /// The subfolder of the destination: the classeur's setting when the destination is one
    /// (enabled), else what an old rule still says.
    public func subfolder(for url: URL, sorted: [UserConfig.DatedFolder] = []) -> Subfolder {
        UserConfig.DatedFolder.find(targetFolder(for: url), in: sorted)?.subfolder ?? subfolder
    }

    /// Compiled filename patterns (nil: invalid), shared: every file is tried against every rule,
    /// and the rule list checks them at each redraw.
    private static let compiled = Mutex<[String: NSRegularExpression?]>([:])

    /// The compiled filename pattern; nil when it is invalid (or empty).
    private func nameRegex(_ pattern: String) -> NSRegularExpression? {
        Self.compiled.withLock { cache in
            if let re = cache[pattern] { return re }
            let re = try? NSRegularExpression(pattern: pattern)
            cache[pattern] = re
            return re
        }
    }

    /// Why the filename pattern can't be used, nil when it is fine (or empty).
    public var patternError: String? {
        let pattern = namePattern
        return pattern.isEmpty || nameRegex(pattern) != nil ? nil : "Expression invalide"
    }

    /// It has a condition, and a valid one: it can take files.
    public var isUsable: Bool { hasCondition && patternError == nil }

    public func matchesName(_ filename: String) -> Bool {
        let pattern = namePattern
        guard !pattern.isEmpty else { return true }
        guard let re = nameRegex(pattern) else { return false }
        let s = filename.precomposedStringWithCanonicalMapping
        return re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }

    /// The phrases missing from `text` (all present → matches).
    public func missingPhrases(in text: String?) -> [String] {
        phrases.filter { text?.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
    }

    public func matches(filename: String, text: String?) -> Bool {
        enabled && isUsable && matchesName(filename) && missingPhrases(in: text).isEmpty
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

    /// Where and under which name a matching file goes. `date` is the document's (AAAA-MM-JJ);
    /// `sorted`, the classeurs, which give the destination its year or month subfolder.
    public func destination(for url: URL, date: String, sorted: [UserConfig.DatedFolder] = []) -> (folder: URL, name: String) {
        var dir = targetFolder(for: url)
        switch subfolder(for: url, sorted: sorted) {
        case .none: break
        case .year: dir.appendPathComponent(String(date.prefix(4)))
        case .yearMonth: dir.appendPathComponent(String(date.prefix(7)))
        }
        let original = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let ext = original.pySplitExt.1.lowercased()
        let newStem = rename.trimmingCharacters(in: .whitespaces)
        var stem = newStem.isEmpty ? original.pySplitExt.0 : newStem.replacingOccurrences(of: "/", with: "-")
        if datePrefix {
            // A name already dated gets the date chosen here: the document's when the model read
            // one (an old prefix may be wrong, 10/01 read as January 10), else the same one.
            stem = Naming.isNamed(stem + ext) ? date + String(stem.dropFirst(10)) : "\(date) - \(stem)"
        }
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
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try UserConfig.writeJSON(enc.encode(File(rules: rules)), to: url)
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
        /// The year or month subfolder `folder` ends with (the classeur's), `.none` if none.
        public let subfolder: Rule.Subfolder
    }

    /// The order rules are tried in: those on the name alone first (no text to read), then those
    /// that look into the text, each group in the list's order. With their index in the list.
    public static func tryOrder(_ rules: [Rule]) -> [(index: Int, rule: Rule)] {
        let all = rules.enumerated().map { (index: $0.offset, rule: $0.element) }
        return all.filter { !$0.rule.needsText } + all.filter { $0.rule.needsText }
    }

    public enum DateSource: Sendable { case document, name, file, unused }

    /// The date a name starts with ("2025-03-14 - …"), if it is a real one.
    static func nameDate(_ filename: String) -> String? {
        guard Naming.isNamed(filename) else { return nil }
        let iso = String(filename.prefix(10))
        return Day(iso: iso) == nil ? nil : iso
    }

    /// Reads a document's issue date (AAAA-MM-JJ), nil if it can't tell: see `Namer.issueDate`.
    public typealias DateReader = @Sendable (URL) async -> String?

    /// The first enabled rule matching `url`, reading its text only if a content rule needs it.
    /// When the rule dates the file (prefix or dated subfolder), `readDate` picks the issue date
    /// (the model, choosing among the dates written in the document); the file's creation date otherwise.
    /// `sorted`: the classeurs (`UserConfig.datedFolders`); a rule filing into one gets its subfolder.
    public static func firstMatch(_ rules: [Rule], for url: URL, readDate: DateReader? = nil,
                                  sorted: [UserConfig.DatedFolder] = []) async -> Match? {
        let filename = url.lastPathComponent
        var text: String?? = .none  // read once, lazily
        for (i, rule) in tryOrder(rules) where rule.enabled && rule.hasCondition && rule.matchesName(filename) {
            if rule.needsText && text == nil { text = .some(await RuleText.read(url)) }
            // Enabled, with a condition and a matching name (so a valid pattern): only the phrases are left.
            guard rule.missingPhrases(in: text ?? nil).isEmpty else { continue }
            var date = fileDate(url), source = DateSource.file
            if !rule.usesDate(for: url, sorted: sorted) {
                source = .unused
            } else if let read = await readDate?(url) {  // the document first: a name's date may be wrong
                date = read
                source = .document
            } else if let named = nameDate(filename) {  // "2025-03-14 - …": unreadable, keep its date
                date = named
                source = .name
            }
            let (folder, name) = rule.destination(for: url, date: date, sorted: sorted)
            return Match(rule: rule, index: i, folder: folder, name: name, date: date, dateSource: source,
                         subfolder: rule.subfolder(for: url, sorted: sorted))
        }
        return nil
    }

    /// Rules tried before the match (or all, if none) that almost took the file: name fits and
    /// some of their phrases are in the text, but not all. The tester's "why not" list.
    public static func nearMisses(_ rules: [Rule], for url: URL) async -> [(index: Int, rule: Rule, missing: [String])] {
        var out: [(Int, Rule, [String])] = []
        var text: String??
        for (i, rule) in tryOrder(rules) where rule.enabled && rule.hasCondition && rule.matchesName(url.lastPathComponent) {
            if rule.needsText && text == nil { text = .some(await RuleText.read(url)) }
            let missing = rule.missingPhrases(in: text ?? nil)
            if missing.isEmpty { break }
            if missing.count < rule.phrases.count { out.append((i, rule, missing)) }
        }
        return out
    }

    /// The file's creation date (what the Ruby script used), today if unknown.
    static func fileDate(_ url: URL) -> String {
        Day((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()).iso
    }
}

/// The text the content conditions look into: a PDF's whole text (OCR for scans), an image's OCR,
/// an Excel sheet's strings. nil for other files.
public enum RuleText {
    @concurrent
    public static func read(_ url: URL) async -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            if let text = pdfText(url) { return text }
            return try? await Extractor.extract(url).text  // a scan: OCR
        case "xlsx":
            return xlsxStrings(url)
        default:
            return Config.isImage(url) ? try? await Extractor.extract(url).text : nil
        }
    }

    /// A PDF's own text layer, nil for a scan (no OCR: fast enough to sweep whole folders).
    public static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
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
