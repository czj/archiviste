import Foundation

/// Personal settings, shared by the app and the CLI, in `~/.config/archiviste/`
/// (or `$XDG_CONFIG_HOME/archiviste/`), as two layers:
///
/// - `config.json`: hand-written, can live in a dotfiles repo; the app never writes it.
/// - `config.local.json`: this Mac only; the settings window writes there just the
///   keys that differ from `config.json`. Its keys win, one by one.
///
/// Every key is optional; paths may start with `~`.
///
///     {
///       "backupDir": "~/Documents/Archives",
///       "backupMaxAgeDays": 180,
///       "expireMaxAgeDays": 548,
///       "watchedFolders": [{ "path": "~/Downloads", "enabled": true },
///                          { "path": "~/Scans inbox", "moveTo": "~/Desktop" },
///                          { "path": "~/Desktop", "rulesOnly": true }],
///       "confirmBeforeRename": false
///     }
public struct UserConfig: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var path: String
        public var enabled = true
        /// A relay folder (a scanner app's inbox, say): what lands here is only moved there,
        /// where the rules and the model take it if that folder is watched too.
        public var moveTo: String?
        /// Rules only: what no rule takes stays as it is, the model names nothing here (Downloads,
        /// the Desktop: full of files to keep under their name). Written only when set.
        public var rulesOnly: Bool?
        public var id: String { path }
        public var url: URL { UserConfig.expand(path) }
        public var name: String { url.lastPathComponent }
        public var relay: URL? { moveTo.flatMap { $0.isEmpty ? nil : UserConfig.expand($0) } }
        /// Files no rule takes are named by the model (PDFs and images), unless rules only.
        public var usesModel: Bool { rulesOnly != true }

        public init(path: String, enabled: Bool = true, moveTo: String? = nil) {
            self.path = UserConfig.abbreviate(path)
            self.enabled = enabled
            self.moveTo = moveTo.map(UserConfig.abbreviate)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            moveTo = try c.decodeIfPresent(String.self, forKey: .moveTo)
            rulesOnly = try c.decodeIfPresent(Bool.self, forKey: .rulesOnly)
        }
    }

    /// Where originals are copied ("RENAME BACKUP <date> - …") before a rename.
    public var backupDir = "~/Documents/Archiviste/Originaux"
    /// Backups older than this are deleted (0 = never).
    public var backupMaxAgeDays = 180
    /// Other files in backupDir added longer ago go to the Trash (0 = never).
    public var expireMaxAgeDays = 0
    /// Inboxes (Downloads, Desktop, a scanner's folder): each file arriving here goes through the
    /// rules (name, then content), else the model names it in place. Or a relay (`moveTo`).
    public var watchedFolders: [Folder] = []
    /// Dropped files: show the name and wait for "Renommer".
    public var confirmBeforeRename = false
    /// Classeurs, sorted by date: a file landing at the top, put there by hand or by a rule, goes
    /// to its year (or month) subfolder, dated. Watched like the inboxes; "Ranger maintenant" sorts
    /// the files already there. Only these: never a folder that is not listed.
    public var datedFolders: [DatedFolder] = []

    public struct DatedFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var path: String
        public var subfolder: Rule.Subfolder = .year
        public var datePrefix = true
        public var enabled = true
        public var id: String { path }
        public var url: URL { UserConfig.expand(path) }
        public var name: String { url.lastPathComponent }

        public init(path: String, subfolder: Rule.Subfolder = .year, datePrefix: Bool = true, enabled: Bool = true) {
            self.path = UserConfig.abbreviate(path)
            self.subfolder = subfolder
            self.datePrefix = datePrefix
            self.enabled = enabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            subfolder = try c.decodeIfPresent(Rule.Subfolder.self, forKey: .subfolder) ?? .year
            datePrefix = try c.decodeIfPresent(Bool.self, forKey: .datePrefix) ?? true
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }

        /// The rule that dates a loose file of this folder (matches any name).
        public var rule: Rule {
            Rule(name: "Classement par date", filename: ".", folder: path, subfolder: subfolder, datePrefix: datePrefix)
        }

        /// The classeur for `folder`, if it is one. Switched off or not: `enabled` only stops
        /// watching it, the rules filing there still use its subfolder.
        public static func find(_ folder: URL, in list: [DatedFolder]) -> DatedFolder? {
            let path = folder.standardizedFileURL.path
            return list.first { $0.url.standardizedFileURL.path == path }
        }
    }

    /// Rules used to carry the year or month subfolder themselves; it now belongs to the
    /// destination folder. Each rule's subfolder moves to a classeur for its folder (added with the
    /// rule's settings when there is none; an existing one keeps its own), then leaves the rule.
    /// A rule whose folder ends up with no enabled classeur keeps it, still honored. Lossless:
    /// every file goes where it went before. Returns whether anything changed.
    @discardableResult
    public mutating func migrateSubfolders(_ rules: inout [Rule]) -> Bool {
        var changed = false
        for i in rules.indices where rules[i].subfolder != .none && !rules[i].folder.isEmpty {
            let url = UserConfig.expand(rules[i].folder)
            if !datedFolders.contains(where: { UserConfig.same($0.url, url) }) {
                datedFolders.append(DatedFolder(path: rules[i].folder, subfolder: rules[i].subfolder,
                                                datePrefix: rules[i].datePrefix))
                changed = true
            }
            if DatedFolder.find(url, in: datedFolders) != nil {
                rules[i].subfolder = .none
                changed = true
            }
        }
        return changed
    }

    /// The folder's role, for the UI and the watchers: an inbox (or relay) wins over a classeur,
    /// as a folder can't be both. Disabled entries count: they still say what the folder is.
    public func isInbox(_ url: URL) -> Bool {
        watchedFolders.contains { UserConfig.same($0.url, url) }
    }

    /// Listed already, as an inbox or as a classeur (enabled or not).
    public func isListed(_ url: URL) -> Bool {
        isInbox(url) || datedFolders.contains { UserConfig.same($0.url, url) }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserConfig()
        backupDir = try c.decodeIfPresent(String.self, forKey: .backupDir) ?? d.backupDir
        backupMaxAgeDays = try c.decodeIfPresent(Int.self, forKey: .backupMaxAgeDays) ?? d.backupMaxAgeDays
        expireMaxAgeDays = try c.decodeIfPresent(Int.self, forKey: .expireMaxAgeDays) ?? d.expireMaxAgeDays
        watchedFolders = try c.decodeIfPresent([Folder].self, forKey: .watchedFolders) ?? d.watchedFolders
        confirmBeforeRename = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeRename) ?? d.confirmBeforeRename
        datedFolders = try c.decodeIfPresent([DatedFolder].self, forKey: .datedFolders) ?? d.datedFolders
    }

    public var backupURL: URL { Self.expand(backupDir) }
    public var backupMaxAge: Int? { backupMaxAgeDays > 0 ? backupMaxAgeDays : nil }
    public var expireMaxAge: Int? { expireMaxAgeDays > 0 ? expireMaxAgeDays : nil }

    public static var directory: URL {
        _ = migrated
        return configBase.appendingPathComponent("archiviste")
    }

    private static var configBase: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }

    /// Up to 1.0 the app was called PDF Namer: its folders move once, on first use by the app or the command.
    private static let migrated: Void = migrateLegacyFolders(
        configBase: configBase, documents: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))

    /// `<configBase>/pdf-namer` becomes `<configBase>/archiviste`, a link staying at the old place
    /// (for dotfiles or another Mac still on PDF Namer). The default backup folder,
    /// `~/Documents/PDF Namer`, follows when no config file names another one.
    /// Nothing moves when the new folder already exists.
    static func migrateLegacyFolders(configBase: URL, documents: URL) {
        let fm = FileManager.default
        let old = configBase.appendingPathComponent("pdf-namer"), new = configBase.appendingPathComponent("archiviste")
        let oldIsFolder = (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        if oldIsFolder, !fm.fileExists(atPath: new.path) {
            if (try? fm.moveItem(at: old, to: new)) != nil {
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
            }
        }
        let names = [new.appendingPathComponent("config.json"), new.appendingPathComponent("config.local.json")]
        let customBackup = names.contains { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["backupDir"] != nil
        }
        let oldBackups = documents.appendingPathComponent("PDF Namer"), newBackups = documents.appendingPathComponent("Archiviste")
        if !customBackup, fm.fileExists(atPath: oldBackups.path), !fm.fileExists(atPath: newBackups.path) {
            try? fm.moveItem(at: oldBackups, to: newBackups)
        }
    }

    /// Shared settings (dotfiles).
    public static var fileURL: URL { directory.appendingPathComponent("config.json") }
    /// This Mac's overrides, written by the app.
    public static var localFileURL: URL { directory.appendingPathComponent("config.local.json") }

    /// A JSON object file as a dictionary; [:] when missing. Malformed files throw (and are never overwritten).
    static func object(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt, userInfo: [NSFilePathErrorKey: url.path])
        }
        return obj
    }

    static func decode(_ obj: [String: Any]) throws -> UserConfig {
        try JSONDecoder().decode(UserConfig.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    /// config.json, then config.local.json over it, key by key; defaults for the rest.
    public static func load(shared: URL = fileURL, local: URL = localFileURL) throws -> UserConfig {
        try decode(try object(at: shared).merging(try object(at: local)) { $1 })
    }

    /// Keys this Mac overrides (from config.local.json).
    public static func localKeys(at url: URL = localFileURL) -> [String] {
        ((try? object(at: url)) ?? [:]).keys.sorted()
    }

    /// Write to config.local.json only what differs from config.json (removing the file if nothing does).
    public func saveLocal(shared: URL = fileURL, local: URL = localFileURL) throws {
        let base = try Self.object(at: shared)
        let effectiveBase = try Self.dictionary(Self.decode(base))
        var overrides: [String: Any] = [:]
        for (key, value) in try Self.dictionary(self) where !(effectiveBase[key].map { ($0 as AnyObject).isEqual(value) } ?? false) {
            overrides[key] = value
        }
        if overrides.isEmpty {
            try? FileManager.default.removeItem(at: local)
        } else {
            try Self.write(overrides, to: local)
        }
    }

    static func dictionary(_ c: UserConfig) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any] ?? [:]
    }

    static func write(_ obj: [String: Any], to url: URL) throws {
        try writeJSON(JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: url)
    }

    /// A JSON file as people read and version it: one atomic write, ending with a newline.
    static func writeJSON(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Same folder, however written ("/F/A/" and "/F/A": URLs differ, paths don't).
    public static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    public static func abbreviate(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).abbreviatingWithTildeInPath
    }
}
