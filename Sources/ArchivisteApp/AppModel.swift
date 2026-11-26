import AppKit
import Observation
import OSLog
import ArchivisteCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct RecentEntry: Codable, Identifiable {
    var id = UUID()
    var oldName: String
    /// Where it was before; nil in entries saved before this was kept (then: its current folder).
    var oldFolder: String?
    var path: String
    var date: Date
    /// The rule that filed it; nil when the model named it.
    var rule: String?
    var newName: String { url.lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
}

/// One file going through the pipeline.
@Observable
final class Item: Identifiable {
    enum Phase: Equatable {
        case waiting, reading, analyzing, proposed, done, unchanged, cancelled
        case skipped(String), failed(String)
        var isPending: Bool {
            switch self {
            case .waiting, .reading, .analyzing: true
            default: false
            }
        }
    }

    let id = UUID()
    let originalName: String
    /// Where the file was before anything happened to it (a rule may move it elsewhere).
    let originalFolder: URL
    let source: String?  // watched folder name, nil for a drop
    /// Found by "Ranger maintenant" among the files already there: rules only, always proposed first.
    let tidy: Bool
    /// Set for a loose file in a dated destination folder: this one rule instead of all of them.
    let dating: Rule?
    /// From an inbox set to "rules only": no rule, no change (the model is not asked).
    let rulesOnly: Bool
    var url: URL
    var phase: Phase = .waiting
    var suggestion: Suggestion?
    var took: TimeInterval?
    @ObservationIgnored var extraction: Task<Extracted, Error>?

    init(url: URL, source: String?, phase: Phase = .waiting, tidy: Bool = false, dating: Rule? = nil,
         rulesOnly: Bool = false) {
        self.url = url
        self.phase = phase
        self.source = source
        self.tidy = tidy
        self.dating = dating
        self.rulesOnly = rulesOnly
        originalName = url.lastPathComponent
        originalFolder = url.deletingLastPathComponent()
    }
}

enum EngineState: Equatable { case loading, ready, unavailable(String) }

@Observable
final class AppModel {
    var engineState: EngineState = .loading
    var items: [Item] = []
    var recent: [RecentEntry] = [] { didSet { save(recent, "recent") } }
    /// ~/.config/archiviste/config.json and config.local.json; changes from the settings window
    /// are written back to config.local.json.
    var settings = UserConfig() {
        didSet {
            guard settings != oldValue else { return }
            if oldValue.watchedFolders != settings.watchedFolders || oldValue.datedFolders != settings.datedFolders {
                syncWatchers()
            }
            if loaded { saveConfig() }  // loading the file must not rewrite it
        }
    }
    /// Filing rules (rules.json), tried before the model; the Rules tab edits them.
    var rules: [Rule] = [] {
        didSet {
            guard rules != oldValue, loaded, rulesError == nil else { return }
            do { try Rules.save(rules) } catch { rulesError = String(localized: "Enregistrement impossible : \(error.localizedDescription)") }
        }
    }
    /// rules.json exists but can't be read: shown, and nothing is written.
    var rulesError: String?
    /// A config file exists but can't be read: shown, and nothing is written.
    var configError: String?
    /// Settings this Mac overrides in config.local.json.
    var localKeys: [String] = []
    @ObservationIgnored private var configSource: DispatchSourceFileSystemObject?
    var lastHousekeeping: String?

    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchers: [String: FolderWatcher] = [:]
    @ObservationIgnored private var housekeepingLoop: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.github.czj.archiviste", category: "app")

    /// Dropped files and arrivals; "Ranger maintenant" keeps its own list (`tidyItems`).
    var batch: [Item] { items.filter { !$0.tidy } }
    var isBusy: Bool { batch.contains { $0.phase.isPending } }
    var backupDir: URL { settings.backupURL }
    var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }
    @ObservationIgnored private let notifications = Notifications()

    init() {
        reloadConfig()
        watchConfig()
        recent = load("recent") ?? []
        do {
            engine = try Engine()
            engineState = .ready
        } catch EngineError.unavailable(let reason) {
            // ArchivisteCore's message stays French (the CLI's); this one follows the app's language.
            engineState = .unavailable(String(localized: "Modèle Apple indisponible (\(reason)). Activez Apple Intelligence dans Réglages Système › Apple Intelligence et Siri."))
        } catch {
            engineState = .unavailable(error.localizedDescription)
        }
        syncWatchers()
        housekeepingLoop = Task { [weak self] in  // at launch, then daily
            while !Task.isCancelled {
                await self?.runHousekeeping()
                try? await Task.sleep(for: .seconds(86400))
            }
        }
        if hasBundle { notifications.start(model: self) }
    }

    // MARK: Queue

    /// Files arriving at the top of a classeur, by hand or from elsewhere: to their year or month
    /// subfolder. No marker check: a file renamed earlier still has to be sorted (and a cloud drive
    /// drops the marker anyway). Only loose files at the top get here; the subfolders are not watched.
    /// A name already dated is left as it is (only moved): no preview here, and others may drop
    /// files in a shared folder. "Ranger maintenant", with its preview, may still correct it.
    private func sort(_ urls: [URL], into folder: UserConfig.DatedFolder) {
        var rule = folder.rule
        rule.keepsNameDate = true
        for url in urls where Config.isFileForRules(url) && !isQueued(url) {
            items.append(Item(url: url, source: folder.name, dating: rule))
        }
        trimFinished()
        startWorker()
    }

    /// Files dropped, chosen or pasted (folders: their files), or arriving in a watched folder.
    func add(_ urls: [URL], source: String? = nil, rulesOnly: Bool = false) {
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                           options: .skipsHiddenFiles)) ?? []
                files += inside.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                files.append(url)
            }
        }
        // Any file may match a rule; only PDFs and images can be named by the model.
        for url in files where (Config.isSupported(url) && !rulesOnly || !rules.isEmpty) && Config.isFileForRules(url) {
            guard !isQueued(url) else { continue }
            if Marker.isMarked(url) {  // renamed or filed by Archiviste before, whatever its name now
                if source == nil { items.append(Item(url: url, source: nil, phase: .skipped(String(localized: "déjà traité")))) }
                continue
            }
            items.append(Item(url: url, source: source, rulesOnly: rulesOnly))
        }
        trimFinished()
        startWorker()
    }

    /// The next file to read. "Ranger maintenant" only proposes, so its files go on even when paused.
    private func nextItem() -> Item? { items.first { $0.phase == .waiting && (!paused || $0.tidy) } }

    private func startWorker() {
        if worker == nil, nextItem() != nil { worker = Task { await drain() } }
    }

    /// A watched folder adds cards for as long as the app runs (days, weeks): the oldest finished
    /// ones go past this many (they stay in the history). Files still to read or to confirm stay.
    static let keptCards = 100

    private func trimFinished() {
        var extra = items.count { !$0.tidy && !$0.phase.isPending && $0.phase != .proposed } - Self.keptCards
        guard extra > 0 else { return }
        items.removeAll { item in
            guard extra > 0, !item.tidy, !item.phase.isPending, item.phase != .proposed else { return false }
            extra -= 1
            return true
        }
    }

    // MARK: Ranger maintenant

    /// What the last "Ranger maintenant" found besides the files to file.
    struct TidyScan: Equatable {
        var folders: [String]
        var scanned = 0
        var alreadyHandled = 0
        var noRule = 0
        /// Files a relay folder passed on (they are then among the scanned ones of their new folder).
        var relayed = 0
        /// Destination folders whose loose files were looked at for dating.
        var dated: [String] = []
    }

    var tidyScan: TidyScan?
    var tidyItems: [Item] { items.filter(\.tidy) }
    var tidyReady: [Item] { tidyItems.filter { $0.phase == .proposed } }
    var isTidying: Bool { tidyItems.contains { $0.phase.isPending } }

    /// Runs the rules over the files already in the watched folders, like the old Raycast script,
    /// and proposes each match. Nothing moves before "Tout ranger"; the model renames nothing here.
    func tidyNow() {
        guard !tidyScanning else { return }
        tidyScanning = true
        items.removeAll { $0.tidy && !$0.phase.isPending && $0.phase != .proposed }  // last pass's leftovers
        let folders = settings.watchedFolders.filter(\.enabled)
        Task {
            var scan = TidyScan(folders: folders.filter { $0.relay == nil }.map(\.name))
            // 1. Relay folders (a scanner's inbox): their files join the folder they feed, as on arrival.
            for folder in folders {
                if let relay = folder.relay { scan.relayed += pass(await Self.files(in: folder.url), to: relay) }
            }
            // 2. Watched folders: the rules.
            for folder in folders where folder.relay == nil {
                for url in await Self.files(in: folder.url) {
                    scan.scanned += 1
                    if Marker.isMarked(url) { scan.alreadyHandled += 1; continue }
                    if !isQueued(url) { items.append(Item(url: url, source: folder.name, tidy: true)) }
                }
            }
            // 3. Destinations dated by their rules: loose files at the top go to their year (or month)
            //    subfolder, with the date prefix, like the files the rules file there.
            let watched = Set(folders.map { $0.url.standardizedFileURL.path })
            for (folder, rule) in datedFolders() where !watched.contains(folder.path) {
                let files = await Self.files(in: folder)
                guard !files.isEmpty else { continue }
                scan.dated.append(folder.lastPathComponent)
                for url in files where !isQueued(url) {
                    scan.scanned += 1
                    items.append(Item(url: url, source: folder.lastPathComponent, tidy: true, dating: rule))
                }
            }
            tidyScan = scan
            tidyScanning = false
            startWorker()
        }
    }

    var tidyScanning = false

    private func isQueued(_ url: URL) -> Bool {
        items.contains { $0.url == url && ($0.phase.isPending || $0.phase == .proposed) }
    }

    /// The folders listed under "Classement par date", and only those.
    private func datedFolders() -> [(URL, Rule)] {
        settings.datedFolders.filter(\.enabled).map { ($0.url.standardizedFileURL, $0.rule) }
    }

    /// The files directly in a folder (no subfolders, nothing hidden or still downloading).
    /// Off the main actor: a cloud drive can be slow to list.
    @concurrent private static func files(in folder: URL) async -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                options: .skipsHiddenFiles)) ?? []
        return all.filter(Config.isFileForRules).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Files every proposal as previewed (same folder, name and date: nothing is read again).
    func tidyAll() {
        for item in tidyReady { if let name = item.suggestion?.name { apply(item, name: name) } }
    }

    /// Drops the proposals not filed yet; the files stay where they are.
    func tidyDismiss() {
        for item in tidyItems where item.phase.isPending { item.extraction?.cancel() }
        items.removeAll { $0.tidy && ($0.phase.isPending || $0.phase == .proposed) }
        tidyScan = nil
    }

    /// Nothing to do for this file: say so for a drop, stay silent for a watched folder.
    private func leave(_ item: Item, _ why: String) {
        if item.source == nil { item.phase = .skipped(why) } else { items.removeAll { $0 === item } }
    }

    private func drain() async {
        while let item = nextItem() {
            await process(item)
        }
        worker = nil
    }

    /// Start reading a file (render + OCR, off the main actor) if it isn't already.
    private func startExtraction(_ item: Item) -> Task<Extracted, Error> {
        if let task = item.extraction { return task }
        let task = Task { [url = item.url] in try await Extractor.extract(url) }
        item.extraction = task
        return task
    }

    private func process(_ item: Item) async {
        let t0 = Date()
        defer { item.extraction = nil }  // its page image is no longer needed: don't keep it with the card
        do {
            item.phase = .reading
            // 1. Filing rules, before any model call.
            if let m = await Rules.firstMatch(item.dating.map { [$0] } ?? rules, for: item.url, readDate: readDate,
                                              sorted: settings.datedFolders) {
                item.suggestion = Suggestion(m)
                item.took = Date().timeIntervalSince(t0)
                if m.folder.appendingPathComponent(m.name).standardizedFileURL == item.url.standardizedFileURL {
                    // Already where and how the rule wants it: mark it, so it is not read again.
                    Marker.set(item.url, originalName: item.originalName)
                    if item.tidy { items.removeAll { $0 === item }; tidyScan?.alreadyHandled += 1 } else { item.phase = .unchanged }
                    return
                }
                if item.tidy || settings.confirmBeforeRename && item.source == nil { item.phase = .proposed } else { apply(item, name: m.name) }
                return
            }
            if item.tidy {  // no rule: left alone, counted, no card
                items.removeAll { $0 === item }
                tidyScan?.noRule += 1
                return
            }
            // 2. The model, for PDFs and images not named "AAAA-MM-JJ - …" yet.
            guard Config.isSupported(item.url), !item.rulesOnly else { leave(item, String(localized: "aucune règle")); return }
            guard !Naming.isNamed(item.url.lastPathComponent) else {
                leave(item, String(localized: "déjà nommé (« AAAA-MM-JJ - … »)")); return
            }
            let extraction = startExtraction(item)
            // Overlap the next file's OCR with this file's model call: one file ahead, never more.
            if let next = items.first(where: { $0.phase == .waiting }) { _ = startExtraction(next) }
            let ex = try await extraction.value
            guard let engine else { throw EngineError.unavailable("non chargé") }
            item.phase = .analyzing
            guard let s = try await Namer.suggest(item.url, ex, engine: engine, myNames: settings.myNames) else {
                item.phase = .skipped(String(localized: "rien de lisible")); return
            }
            item.suggestion = s
            item.took = Date().timeIntervalSince(t0)
            if s.name == item.url.lastPathComponent {
                Marker.set(item.url, originalName: item.originalName)  // don't ask the model again next time
                item.phase = .unchanged
            } else if settings.confirmBeforeRename && item.source == nil {
                item.phase = .proposed
            } else {
                apply(item, name: s.name)
            }
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Actions

    /// First rename (with backup), or a later edit of the name.
    func apply(_ item: Item, name rawName: String) {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        let ext = "." + item.url.pathExtension.lowercased()
        if !name.lowercased().hasSuffix(ext) { name += ext }
        let firstRename = item.phase != .done
        // Same name is fine when a rule files it elsewhere (a move, no rename).
        let moves = firstRename && item.suggestion?.match.map { $0.folder.standardizedFileURL != item.url.deletingLastPathComponent().standardizedFileURL } == true
        guard name != item.url.lastPathComponent || moves, !name.contains("/") else { return }
        do {
            let final = firstRename
                ? try Files.rename(item.url, to: name, in: item.suggestion?.match?.folder, backupDir: backupDir)
                : try Files.move(item.url, to: name)
            ignore(final)
            item.url = final
            item.phase = .done
            var history = recent  // one change, so one write to UserDefaults
            history.removeAll { $0.path == final.path || $0.oldName == item.originalName && !firstRename }
            let entry = RecentEntry(oldName: item.originalName, oldFolder: item.originalFolder.path, path: final.path,
                                    date: Date(), rule: item.suggestion?.match?.rule.label)
            history.insert(entry, at: 0)
            recent = Array(history.prefix(500))
            if firstRename, !item.tidy, let source = item.source {
                notify(entry, source: source, filed: item.suggestion?.match != nil)
            }
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    /// Put the original name and folder back (the backup copy stays in the backup folder).
    func undo(_ item: Item) {
        do {
            item.url = try restore(item.url, to: item.originalName, in: item.originalFolder)
            item.phase = .cancelled
            recent.removeAll { $0.oldName == item.originalName }
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    /// Undo from the history or a notification: the file may have left its batch long ago.
    func undo(_ entry: RecentEntry) {
        let folder = entry.oldFolder.map { URL(fileURLWithPath: $0) } ?? entry.url.deletingLastPathComponent()
        do {
            let restored = try restore(entry.url, to: entry.oldName, in: folder)
            if let item = items.first(where: { $0.url == entry.url }) {
                item.url = restored
                item.phase = .cancelled
            }
            recent.removeAll { $0.id == entry.id }
        } catch {
            NSApp.presentError(error)
        }
    }

    private func restore(_ url: URL, to name: String, in folder: URL) throws -> URL {
        let restored = try Files.move(url, to: name, in: folder)
        // The name actually given (`… - 1` if the original is taken), or a watched folder
        // would take the restored file, now unmarked, for a new arrival. Watcher events run on
        // the main actor after this returns, so ignoring after the move is in time.
        ignore(restored)
        Marker.clear(restored)
        return restored
    }

    func skip(_ item: Item) { item.phase = .skipped(String(localized: "ignoré")) }

    /// Rules that date a file ask the model for the issue date (the file's date without it).
    var readDate: Rules.DateReader? { engine.map(Namer.dateReader) }

    // MARK: Pause

    /// Paused: dropped files and arrivals in watched folders wait, nothing is renamed or moved.
    var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            if !paused { startWorker() }
        }
    }

    // MARK: Rules from a file

    /// The main window's page; set from outside (menu bar icon, a card) before opening it.
    var section: AppSection = .activity
    /// The rule the Rules page shows; set from outside to open one.
    var selectedRuleID: Rule.ID?
    /// A file the Rules window tests as soon as it appears.
    var pendingTest: URL?
    /// Fichier › Nouvelle règle from another page: the Rules page adds one as it appears.
    var pendingNewRule = false

    /// Fichier › Tester un fichier sur les règles: the Rules page shows the result.
    func chooseTestFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Tester")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        section = .rules
        pendingTest = url
    }

    /// "Ranger maintenant" found files to file: Tout ranger (⌘↩) can run.
    var canTidyAll: Bool { tidyScan != nil && tidyItems.contains { $0.phase == .proposed } && !tidyItems.contains { $0.phase.isPending } }

    /// Changes the rules as one undoable step (⌘Z puts the whole list back, ⇧⌘Z redoes).
    func changeRules(_ action: String, undo: UndoManager?, _ change: (inout [Rule]) -> Void) {
        let before = rules
        change(&rules)
        if before != rules || before.map(\.id) != rules.map(\.id) { registerRestore(before, action, undo) }
    }

    private func registerRestore(_ old: [Rule], _ action: String, _ undo: UndoManager?) {
        guard let undo else { return }
        undo.registerUndo(withTarget: self) { model in
            let now = model.rules
            model.rules = old
            if let id = model.selectedRuleID, !old.contains(where: { $0.id == id }) { model.selectedRuleID = nil }
            model.registerRestore(now, action, undo)
        }
        undo.setActionName(action)
    }

    /// A new rule drafted from a file ("files named like this go there, named so"), selected in the
    /// Rules window with the file under test, for the user to adjust.
    /// `dated`: the suggestion comes from "Classement par date", not from one of the rules.
    func makeRule(from url: URL, suggestion: Suggestion? = nil, originalName: String? = nil, dated: Bool = false,
                  undo: UndoManager? = nil) {
        var rule = Rule.draft(from: originalName ?? Marker.originalName(url) ?? url.lastPathComponent,
                              suggestedName: suggestion?.match == nil ? suggestion?.name : nil)
        var at = rules.count
        if let match = suggestion?.match, !dated {  // filed by one of the rules: start from it, right after it
            rule = match.rule
            rule.name = String(localized: "\(rule.label) (variante)")
            at = match.index + 1
        } else if let match = suggestion?.match {
            // Sorted by a classeur, whose inner rule takes any name: keep only where it files and
            // its prefix, with a name pattern drafted from this file. The subfolder stays the folder's.
            rule.folder = match.rule.folder
            rule.datePrefix = match.rule.datePrefix
        }
        rule.id = UUID()
        changeRules(String(localized: "Nouvelle règle"), undo: undo) { $0.insert(rule, at: min(at, $0.count)) }
        selectedRuleID = rule.id
        pendingTest = url
        section = .rules
    }

    /// Stops the batch only: "Ranger maintenant" has its own way out (`tidyDismiss`).
    func stop() {
        for item in items where !item.tidy && item.phase == .waiting {
            item.extraction?.cancel()
            item.phase = .skipped(String(localized: "arrêté"))
        }
    }

    func clear() { items.removeAll { !$0.tidy && !$0.phase.isPending } }

    func chooseFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .image]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func paste() { add(NSPasteboard.general.fileURLs) }

    func showBackups() { openFolder(backupDir) }

    func openConfigFolder() { openFolder(UserConfig.directory) }

    /// Shows a folder in the Finder, creating it if needed.
    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Watched folders

    /// Until when each watched folder was watched (path → date), kept across launches so that
    /// what arrived while the app was not running is caught up at the next launch. A folder
    /// added or switched back on starts afresh: its files already there stay as they are.
    private static let watchedUntilKey = "watchedUntil"
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    private func markWatched() {
        let now = Date()
        let dates = Dictionary(uniqueKeysWithValues: watchers.keys.map { ($0, now) })
        UserDefaults.standard.set(dates, forKey: Self.watchedUntilKey)
    }

    /// What a watched folder does with what arrives at its top.
    private enum Role {
        /// Rules (name, then content), else the model names it in place (unless rules only).
        case inbox(usesModel: Bool)
        /// Moved as is to another folder.
        case relay(URL)
        /// A classeur: to its year or month subfolder.
        case classeur(UserConfig.DatedFolder)
    }

    /// Read at each arrival, so changing a folder's settings needs no new watcher. An inbox wins
    /// over a classeur for the same folder (the Dossiers page doesn't let a folder be both).
    private func role(for path: String) -> Role? {
        if let inbox = settings.watchedFolders.first(where: { $0.enabled && $0.url.path == path }) {
            return inbox.relay.map(Role.relay) ?? .inbox(usesModel: inbox.usesModel)
        }
        return UserConfig.DatedFolder.find(URL(fileURLWithPath: path), in: settings.datedFolders.filter(\.enabled))
            .map(Role.classeur)
    }

    private func syncWatchers() {
        let inboxes = settings.watchedFolders.filter(\.enabled).map(\.url.path)
        let classeurs = settings.datedFolders.filter(\.enabled).map(\.url.path)
        let wanted = Set(inboxes + classeurs)
        let until = UserDefaults.standard.dictionary(forKey: Self.watchedUntilKey) as? [String: Date] ?? [:]
        // Only at launch: later, a new watcher is a folder just added or switched on.
        let launching = heartbeat == nil
        for path in watchers.keys where !wanted.contains(path) { watchers[path] = nil }
        for path in wanted where watchers[path] == nil {
            let url = URL(fileURLWithPath: path)
            watchers[path] = FolderWatcher(url, since: launching ? until[path] : nil, accepts: { [weak self] file in
                guard let self, Config.isFileForRules(file) else { return false }
                switch self.role(for: path) {
                case .relay, .classeur: return true  // passed on, or sorted, whoever renamed it before
                case .inbox(let usesModel):
                    guard !Marker.isMarked(file) else { return false }
                    return usesModel && Config.isSupported(file) || !self.rules.isEmpty  // any file may match a rule
                case nil: return false
                }
            }) { [weak self] urls in
                guard let self else { return }
                switch self.role(for: path) {
                case .relay(let to): self.pass(urls, to: to)
                case .classeur(let folder): self.sort(urls, into: folder)
                case .inbox(let usesModel): self.add(urls, source: url.lastPathComponent, rulesOnly: !usesModel)
                case nil: break
                }
            }
        }
        markWatched()
        // Every minute, so a crash or a forced quit loses at most a minute of "watched until".
        // Overlap is harmless: what was already handled carries the marker and is skipped.
        if heartbeat == nil {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.markWatched()
                }
            }
        }
    }

    /// Relay folder: move as is; the destination's own watcher (if any) takes it from there.
    @discardableResult
    private func pass(_ urls: [URL], to folder: URL) -> Int {
        var moved = 0
        for url in urls {
            do {
                try Files.move(url, to: url.lastPathComponent, in: folder)
                moved += 1
            } catch {
                log.error("Relais \(url.lastPathComponent, privacy: .public) : \(error.localizedDescription, privacy: .public)")
            }
        }
        return moved
    }

    /// A file we just renamed or restored must not look like a new arrival.
    private func ignore(_ url: URL) {
        watchers[url.deletingLastPathComponent().path]?.ignore(url)
    }

    /// Adds inboxes. A folder already listed (as an inbox or a classeur) stays as it is: the
    /// names of those left out come back, for the page to say why.
    @discardableResult
    func addFolder() -> [String] {
        addFolders { settings.watchedFolders.append(UserConfig.Folder(path: $0.path)) }
    }

    /// Adds classeurs, by year by default; same rule as `addFolder` for folders already listed.
    @discardableResult
    func addClasseur() -> [String] {
        addFolders { settings.datedFolders.append(UserConfig.DatedFolder(path: $0.path)) }
    }

    private func addFolders(_ add: (URL) -> Void) -> [String] {
        var already: [String] = []
        for url in chooseFolders(multiple: true) {
            if settings.isListed(url) { already.append(url.lastPathComponent) } else { add(url) }
        }
        return already
    }

    /// A file from a watched folder was renamed: say so, with Annuler and Afficher dans le Finder.
    private func notify(_ entry: RecentEntry, source: String, filed: Bool) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Archiviste · dossier \(source)")
        content.body = filed
            ? String(localized: "Rangé dans \(entry.url.deletingLastPathComponent().lastPathComponent) : « \(entry.newName) »")
            : String(localized: "Nouveau fichier renommé : « \(entry.newName) »")
        content.categoryIdentifier = Notifications.renamed
        content.userInfo = [Notifications.entry: entry.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Housekeeping, login item

    func runHousekeeping() async {
        let r = await Files.housekeeping(backupDir, backupMaxAgeDays: settings.backupMaxAge,
                                         expireMaxAgeDays: settings.expireMaxAge)
        lastHousekeeping = String(localized: "\(r.purged.count) sauvegarde(s) supprimée(s)") + ", "
            + String(localized: "\(r.trashed.count) élément(s) mis à la corbeille")
        log.info("Ménage : \(r.purged.count) sauvegarde(s), \(r.trashed.count) élément(s) à la corbeille")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Ouverture au démarrage : \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Persistence

    /// The settings window only ever writes this Mac's overrides (config.local.json).
    private func saveConfig() {
        guard configError == nil else { return }
        do {
            try settings.saveLocal()
            localKeys = UserConfig.localKeys()
        } catch {
            configError = String(localized: "Enregistrement impossible : \(error.localizedDescription)")
        }
    }

    /// Reload both files (at launch, and whenever one changes, e.g. after `chezmoi apply`).
    func reloadConfig() {
        loaded = false
        defer {
            loaded = true
            migrateSubfolders()
        }
        do {
            let fresh = try Rules.load()
            rulesError = nil
            if fresh != rules { rules = fresh }  // == ignores ids: unchanged rules keep theirs
        } catch {
            rulesError = String(localized: "rules.json illisible : \(error.localizedDescription)")
        }
        do {
            let fresh = try UserConfig.load()
            configError = nil
            localKeys = UserConfig.localKeys()
            if fresh != settings { settings = fresh }  // its didSet follows a change of watched folders
        } catch {
            configError = String(localized: "Configuration illisible : \(error.localizedDescription)")
        }
    }

    /// Old rules.json files give rules their own year or month subfolder: it moves to the
    /// destination folders (classeurs), written to rules.json and config.local.json. Once.
    private func migrateSubfolders() {
        guard rulesError == nil, configError == nil else { return }
        var newRules = rules, newSettings = settings
        guard newSettings.migrateSubfolders(&newRules) else { return }
        // The old file, as it was, in case an older Archiviste (or another Mac) still needs it.
        let copy = Rules.fileURL.deletingLastPathComponent().appendingPathComponent("rules.before-classeurs.json")
        if !FileManager.default.fileExists(atPath: copy.path) { try? FileManager.default.copyItem(at: Rules.fileURL, to: copy) }
        log.info("Sous-dossiers des règles déplacés vers les classeurs")
        settings = newSettings  // config.local.json first: no rule loses its subfolder meanwhile
        rules = newRules
    }

    /// Drop this Mac's overrides: back to config.json.
    func resetLocalConfig() {
        try? FileManager.default.removeItem(at: UserConfig.localFileURL)
        reloadConfig()
    }

    private func watchConfig() {
        try? FileManager.default.createDirectory(at: UserConfig.directory, withIntermediateDirectories: true)
        let fd = open(UserConfig.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reloadConfig() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        configSource = src
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
