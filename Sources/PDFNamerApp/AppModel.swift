import AppKit
import Observation
import OSLog
import PDFNamerCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct RecentEntry: Codable, Identifiable {
    var id = UUID()
    var oldName: String
    var path: String
    var date: Date
    /// The rule that filed it; nil when the model named it.
    var rule: String?
    var newName: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// One file going through the pipeline.
@Observable
final class Item: Identifiable {
    enum Phase: Equatable {
        case waiting, reading, analyzing, proposed, done, unchanged, cancelled
        case skipped(String), failed(String)
        var isPending: Bool { [.waiting, .reading, .analyzing].contains(self) }
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
    var url: URL
    var phase: Phase = .waiting
    var suggestion: Suggestion?
    var took: TimeInterval?
    @ObservationIgnored var extraction: Task<Extracted, Error>?

    init(url: URL, source: String?, phase: Phase = .waiting, tidy: Bool = false, dating: Rule? = nil) {
        self.url = url
        self.phase = phase
        self.source = source
        self.tidy = tidy
        self.dating = dating
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
    /// ~/.config/pdf-namer/config.json, written back on every change from the settings window.
    var settings = UserConfig() {
        didSet {
            guard settings != oldValue, loaded else { return }  // loading the file must not rewrite it
            saveConfig()
            if oldValue.watchedFolders != settings.watchedFolders { syncWatchers() }
        }
    }
    /// Filing rules (rules.json), tried before the model; the Rules tab edits them.
    var rules: [Rule] = [] {
        didSet {
            guard rules != oldValue, loaded, rulesError == nil else { return }
            do { try Rules.save(rules) } catch { rulesError = "Enregistrement impossible : \(error.localizedDescription)" }
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
    @ObservationIgnored private let log = Logger(subsystem: "com.github.czj.pdf-namer", category: "app")

    /// Dropped files and arrivals; "Ranger maintenant" keeps its own list (`tidyItems`).
    var batch: [Item] { items.filter { !$0.tidy } }
    var isBusy: Bool { batch.contains { $0.phase.isPending } }
    var finishedCount: Int { batch.filter { !$0.phase.isPending }.count }
    var backupDir: URL { settings.backupURL }
    var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    init() {
        reloadConfig()
        watchConfig()
        recent = load("recent") ?? []
        do {
            engine = try Engine()
            engineState = .ready
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
        if hasBundle { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }

    // MARK: Queue

    /// Files dropped, chosen or pasted (folders: their files), or arriving in a watched folder.
    func add(_ urls: [URL], source: String? = nil) {
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
        for url in files where (Config.isSupported(url) || !rules.isEmpty) && Config.isFileForRules(url) {
            guard !isQueued(url) else { continue }
            if Marker.isMarked(url) {  // renamed or filed by PDF Namer before, whatever its name now
                if source == nil { items.append(Item(url: url, source: nil, phase: .skipped("déjà traité"))) }
                continue
            }
            items.append(Item(url: url, source: source))
        }
        startWorker()
    }

    /// The next file to read. "Ranger maintenant" only proposes, so its files go on even when paused.
    private func nextItem() -> Item? { items.first { $0.phase == .waiting && (!paused || $0.tidy) } }

    private func startWorker() {
        if worker == nil, nextItem() != nil { worker = Task { await drain() } }
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

    /// Each destination folder whose rules date files, with the settings of its first rule.
    private func datedFolders() -> [(URL, Rule)] {
        var seen = Set<String>(), found: [(URL, Rule)] = []
        for rule in rules where rule.enabled && !rule.folder.isEmpty && rule.usesDate {
            let url = UserConfig.expand(rule.folder).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            found.append((url, Rule(name: "Classement par date", filename: ".", folder: rule.folder,
                                    subfolder: rule.subfolder, datePrefix: rule.datePrefix)))
        }
        return found
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
        do {
            item.phase = .reading
            // 1. Filing rules, before any model call.
            if let m = await Rules.firstMatch(item.dating.map { [$0] } ?? rules, for: item.url, readDate: readDate) {
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
            guard Config.isSupported(item.url) else { leave(item, "aucune règle"); return }
            guard !Naming.isNamed(item.url.lastPathComponent) else {
                leave(item, "déjà nommé (« AAAA-MM-JJ - … »)"); return
            }
            let extraction = startExtraction(item)
            // Overlap the next file's OCR with this file's model call: one file ahead, never more.
            if let next = items.first(where: { $0.phase == .waiting }) { _ = startExtraction(next) }
            let ex = try await extraction.value
            guard let engine else { throw EngineError.unavailable("non chargé") }
            item.phase = .analyzing
            guard let s = try await Namer.suggest(item.url, ex, engine: engine) else {
                item.phase = .skipped("rien de lisible"); return
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
            recent.removeAll { $0.path == final.path || $0.oldName == item.originalName && !firstRename }
            recent.insert(RecentEntry(oldName: item.originalName, path: final.path, date: Date(),
                                      rule: item.suggestion?.match?.rule.label), at: 0)
            recent = Array(recent.prefix(500))
            if firstRename, !item.tidy, let source = item.source {
                notify(source, final.lastPathComponent, folder: item.suggestion?.match.map { _ in final.deletingLastPathComponent() })
            }
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    /// Put the original name and folder back (the backup copy stays in the backup folder).
    func undo(_ item: Item) {
        do {
            ignore(item.originalFolder.appendingPathComponent(item.originalName))
            item.url = try Files.move(item.url, to: item.originalName, in: item.originalFolder)
            Marker.clear(item.url)
            item.phase = .cancelled
            recent.removeAll { $0.oldName == item.originalName }
        } catch {
            item.phase = .failed(error.localizedDescription)
        }
    }

    func skip(_ item: Item) { item.phase = .skipped("ignoré") }

    /// Rules that date a file ask the model for the issue date (the file's date without it).
    var readDate: Rules.DateReader? {
        engine.map { engine in { @Sendable url in await Namer.issueDate(url, engine: engine) } }
    }

    // MARK: Pause

    /// Paused: dropped files and arrivals in watched folders wait, nothing is renamed or moved.
    var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "paused")
            if !paused { startWorker() }
        }
    }

    // MARK: Rules from a file

    /// The main window's page; set from outside (popover, a card) before opening it.
    var section: AppSection = .activity
    /// The rule the Rules page shows; set from outside to open one.
    var selectedRuleID: Rule.ID?
    /// A file the Rules window tests as soon as it appears.
    var pendingTest: URL?

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
    func makeRule(from url: URL, suggestion: Suggestion? = nil, originalName: String? = nil, undo: UndoManager? = nil) {
        var rule = Rule.draft(from: originalName ?? Marker.originalName(url) ?? url.lastPathComponent,
                              suggestedName: suggestion?.match == nil ? suggestion?.name : nil)
        if let match = suggestion?.match {  // filed by a rule: start from it
            rule = match.rule
            rule.name = rule.label + " (variante)"
        }
        rule.id = UUID()
        let at = suggestion?.match.map { $0.index + 1 } ?? rules.count
        changeRules("Nouvelle règle", undo: undo) { $0.insert(rule, at: min(at, $0.count)) }
        selectedRuleID = rule.id
        pendingTest = url
        section = .rules
    }

    func stop() {
        for item in items where item.phase == .waiting {
            item.extraction?.cancel()
            item.phase = .skipped("arrêté")
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

    func paste() {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        add(urls)
    }

    func showBackups() {
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(backupDir)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Watched folders

    private func syncWatchers() {
        let wanted = Set(settings.watchedFolders.filter(\.enabled).map(\.url.path))
        for path in watchers.keys where !wanted.contains(path) { watchers[path] = nil }
        for path in wanted where watchers[path] == nil {
            let url = URL(fileURLWithPath: path)
            watchers[path] = FolderWatcher(url, accepts: { [weak self] file in
                guard let self, Config.isFileForRules(file) else { return false }
                if self.relay(for: path) != nil { return true }  // a relay passes everything on
                guard !Marker.isMarked(file) else { return false }
                return Config.isSupported(file) || !self.rules.isEmpty  // any file may match a rule
            }) { [weak self] urls in
                guard let self else { return }
                if let relay = self.relay(for: path) { self.pass(urls, to: relay) } else { self.add(urls, source: url.lastPathComponent) }
            }
        }
    }

    /// Read at each arrival, so changing "Déplacer vers" needs no new watcher.
    private func relay(for path: String) -> URL? {
        settings.watchedFolders.first { $0.enabled && $0.url.path == path }?.relay
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

    func addFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watchedFolders.contains(where: { $0.url.path == url.path }) {
            settings.watchedFolders.append(UserConfig.Folder(path: url.path))
        }
    }

    private func notify(_ source: String, _ name: String, folder: URL?) {
        guard hasBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "PDF Namer · dossier \(source)"
        content.body = folder.map { "Rangé dans \($0.lastPathComponent) : « \(name) »" } ?? "Nouveau fichier renommé : « \(name) »"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Housekeeping, login item

    func runHousekeeping() async {
        let r = await Files.housekeeping(backupDir, backupMaxAgeDays: settings.backupMaxAge,
                                         expireMaxAgeDays: settings.expireMaxAge)
        lastHousekeeping = "\(r.purged.count) sauvegarde(s) supprimée(s), \(r.trashed.count) élément(s) mis à la corbeille"
        log.info("Ménage : \(r.purged.count) sauvegarde(s), \(r.trashed.count) élément(s) à la corbeille")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Ouverture au démarrage : \(error.localizedDescription, privacy: .public)")
            }
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
            configError = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    /// Reload both files (at launch, and whenever one changes, e.g. after `chezmoi apply`).
    func reloadConfig() {
        loaded = false
        defer { loaded = true }
        do {
            let fresh = try Rules.load()
            rulesError = nil
            if fresh != rules { rules = fresh }  // == ignores ids: unchanged rules keep theirs
        } catch {
            rulesError = "rules.json illisible : \(error.localizedDescription)"
        }
        do {
            let fresh = try UserConfig.load()
            configError = nil
            localKeys = UserConfig.localKeys()
            guard fresh != settings else { return }
            let foldersChanged = fresh.watchedFolders != settings.watchedFolders
            settings = fresh
            if foldersChanged { syncWatchers() }
        } catch {
            configError = "Configuration illisible : \(error.localizedDescription)"
        }
    }

    /// Drop this Mac's overrides: back to config.json.
    func resetLocalConfig() {
        try? FileManager.default.removeItem(at: UserConfig.localFileURL)
        reloadConfig()
    }

    func openConfigFolder() {
        try? FileManager.default.createDirectory(at: UserConfig.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(UserConfig.directory)
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
