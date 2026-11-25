import Foundation
import ArchivisteCore

// archiviste — same flags as ~/bin/pdf_namer.py, plus filing rules (rules.json):
//   archiviste <file> [--json]
//   archiviste --rename [--dry-run] [--force] [--backup-dir <dir>] <files...>
//   archiviste --rules <files...>        which rule each file matches, and why the others don't

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = "usage: archiviste <fichier> [--json] | --rename [--dry-run] [--force] [--backup-dir <dir>] <fichiers…> | --rules <fichiers…>"

let config: UserConfig
do { config = try UserConfig.load() } catch {
    err("✗ \(UserConfig.fileURL.path) illisible : \(error.localizedDescription)"); exit(1)
}
let rules: [Rule]
do { rules = try Rules.load() } catch {
    err("✗ \(Rules.fileURL.path) illisible : \(error.localizedDescription)"); exit(1)
}
var files: [String] = [], json = false, rename = false, dryRun = false, force = false, rulesTest = false
var backupDir = config.backupURL
var customBackupDir = false  // trashing expired files only ever runs on the configured folder
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--json": json = true
    case "--text":  // debug: what the model is given (text, date and amount candidates)
        for f in args {
            let ex = try await Extractor.extract(URL(fileURLWithPath: f))
            let t = ex.text ?? ""
            print("── \(f)\n\(t)\n── dates: \(Candidates.dates(t))\n── montants: \(Candidates.amounts(t))")
        }
        exit(0)
    case "--audit-dates":  // read-only: dated names whose date is a US date read day first
        var found = 0, seen = 0
        for f in args {
            let root = UserConfig.expand(f)
            let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            while let url = walk?.nextObject() as? URL {
                let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
                guard url.pathExtension.lowercased() == "pdf", Naming.isNamed(name),
                      let text = RuleText.pdfText(url) else { continue }
                seen += 1
                if let right = Candidates.misreadDates(text)[String(name.prefix(10))] {
                    found += 1
                    print("✗ \(name.prefix(10)) → \(right)  \(UserConfig.abbreviate(url.path))")
                }
            }
        }
        print("\(found) nom(s) mal daté(s) sur \(seen) PDF datés lus")
        exit(0)
    case "--rules": rulesTest = true
    case "--rename": rename = true
    case "--dry-run": dryRun = true; rename = true
    case "--force": force = true
    case "--backup-dir":
        guard let d = args.popFirst() else { err("--backup-dir: dossier manquant"); exit(1) }
        backupDir = UserConfig.expand(d)
        customBackupDir = true
    case "-h", "--help":
        err(usage)
        exit(0)
    default: files.append(a)
    }
}
guard !files.isEmpty else { err(usage); exit(1) }

let batch = rename || rulesTest || files.count > 1
func say(_ s: String) { if batch { print(s) } else { err(s) } }
func short(_ url: URL) -> String { UserConfig.abbreviate(url.path) }

/// Any file can match a rule; only PDFs and images can be named by the model.
let anyFile = (rename || rulesTest) && !rules.isEmpty
var urls: [URL] = []
for f in files {
    let url = UserConfig.expand(f)
    if !FileManager.default.fileExists(atPath: url.path) { say("⚠ Introuvable : \(f)") }
    else if !Config.isSupported(url) && !anyFile { say("⚠ Ni PDF ni image : \(f)") }
    else if !Config.isFileForRules(url) { say("⚠ Dossier ou téléchargement en cours, ignoré : \(f)") }
    else { urls.append(url) }
}

/// Rules that date a file ask the model for the issue date (file date if the model is unavailable).
let dateEngine = rules.isEmpty ? nil : try? Engine()
let readDate = dateEngine.map(Namer.dateReader)
func dateNote(_ m: Rules.Match) -> String {
    switch m.dateSource {
    case .document: " · date du document"
    case .name: " · date du nom"
    case .file: " · date du fichier"
    case .unused: ""
    }
}

if rulesTest {
    if rules.isEmpty { say("Aucune règle dans \(short(Rules.fileURL))"); exit(0) }
    for url in urls {
        print("── \(url.lastPathComponent)")
        if Marker.isMarked(url), let original = Marker.originalName(url) { print("   déjà traité par Archiviste (avant : « \(original) »)") }
        for (i, rule, missing) in await Rules.nearMisses(rules, for: url) {
            print("   · règle \(i + 1) « \(rule.label) » : manque \(missing.map { "« \($0) »" }.joined(separator: ", "))")
        }
        if let m = await Rules.firstMatch(rules, for: url, readDate: readDate, sorted: config.datedFolders) {
            print("   ✓ règle \(m.index + 1) « \(m.rule.label) » → \(short(m.folder))/\(m.name)\(dateNote(m))")
        } else {
            print("   – aucune règle\(Config.isSupported(url) ? " : nommé par le modèle" : "")")
        }
    }
    exit(0)
}

if rename && !force {
    // Marked by Archiviste: never touched again, whatever its name.
    let marked = urls.filter(Marker.isMarked)
    urls.removeAll(where: Marker.isMarked)
    if !marked.isEmpty {
        say("\(marked.count) fichier(s) déjà traité(s) par Archiviste laissé(s) tel(s) quel(s) · --force pour les reprendre")
    }
    if urls.isEmpty { say("✓ Rien à renommer"); exit(0) }
}
guard !urls.isEmpty else { say("✗ Aucun PDF ni image valide"); exit(2) }

if batch { say("── Archiviste · \(urls.count) fichier(s)\(dryRun ? " · simulation" : "") ──") }

var renamed = 0, filed = 0, unchanged = 0, skipped = 0, errors = 0
let start = Date()

if rename {
    let report = await Files.housekeeping(backupDir, dryRun: dryRun, backupMaxAgeDays: config.backupMaxAge,
                                          expireMaxAgeDays: customBackupDir ? nil : config.expireMaxAge)
    let would = dryRun ? "seraient " : ""
    if !report.purged.isEmpty {
        print("✓ \(report.purged.count) sauvegarde(s) de plus de \(config.backupMaxAgeDays) jours \(would)supprimée(s)")
    }
    if !report.trashed.isEmpty {
        print("✓ \(report.trashed.count) élément(s) de plus de \(config.expireMaxAgeDays / 30) mois \(would)mis à la corbeille :")
        for t in report.trashed { print("    · \(t)") }
    }
    print()

    // 1. Filing rules, before any model call.
    var left: [URL] = []
    for url in urls {
        guard let m = await Rules.firstMatch(rules, for: url, readDate: readDate, sorted: config.datedFolders) else { left.append(url); continue }
        print("règle     « \(m.rule.label) »\(dateNote(m))\n  avant    \(url.lastPathComponent)")
        do {
            if dryRun {
                print("  ○ irait  \(short(m.folder))/\(m.name)\n")
            } else {
                let final = try Files.rename(url, to: m.name, in: m.folder, backupDir: backupDir)
                print("  ✓ rangé  \(short(final))\n")
            }
            filed += 1
        } catch {
            print("  ✗ erreur   \(error.localizedDescription)\n"); errors += 1
        }
    }
    // 2. The model, for PDFs and images no rule took, unless already named "AAAA-MM-JJ - …".
    let named = left.filter { Config.isSupported($0) && !force && Naming.isNamed($0.lastPathComponent) }
    if !named.isEmpty {
        print("\(named.count) fichier(s) déjà nommé(s) (« AAAA-MM-JJ - … ») laissé(s) tel(s) quel(s) · --force pour les renommer quand même")
    }
    let other = left.filter { !Config.isSupported($0) }
    if !other.isEmpty { print("\(other.count) fichier(s) ni PDF ni image sans règle, laissé(s) tel(s) quel(s)") }
    skipped += named.count + other.count
    urls = left.filter { Config.isSupported($0) && (force || !Naming.isNamed($0.lastPathComponent)) }
}

func summary() {
    let stats = [(filed, dryRun ? "à ranger par règle" : "rangé(s) par règle"),
                 (renamed, dryRun ? "à renommer" : "renommé(s)"), (unchanged, "inchangé(s)"),
                 (skipped, "ignoré(s)"), (errors, "erreur(s)")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    print(String(repeating: "─", count: 60))
    print("\(stats.isEmpty ? "Rien à faire" : stats.joined(separator: " · "))  · \(files.count) fichier(s) en \(Int(Date().timeIntervalSince(start).rounded()))s\(dryRun ? " · simulation, rien n’a été modifié" : "")")
}
if urls.isEmpty { summary(); exit(errors > 0 ? 2 : 0) }

// One file, no renaming: a matching rule gives the name, as --rename would.
/// One file's suggested name: as JSON with `--json`, else the name without its extension.
func emit(_ name: String, _ extra: [String: String] = [:]) throws {
    if json {
        let out = extra.merging(["original": urls[0].lastPathComponent, "suggested": name, "path": urls[0].path]) { $1 }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print((name as NSString).deletingPathExtension)
    }
}

if !batch, let m = await Rules.firstMatch(rules, for: urls[0], readDate: readDate, sorted: config.datedFolders) {
    try emit(m.name, ["folder": m.folder.path, "rule": m.rule.label])
    exit(0)
}

/// Reading a file (OCR) overlaps the model's work on the previous one: one file ahead, never more.
func prefetch(_ i: Int) -> Task<Extracted, Error>? {
    i < urls.count ? Task { [url = urls[i]] in try await Extractor.extract(url) } : nil
}
var nextExtraction = prefetch(0)

let engine: Engine
do { engine = try dateEngine ?? Engine() } catch { say("✗ \(error.localizedDescription)"); exit(3) }
say("✓ Modèle Apple prêt")

if !batch {
    do {
        guard let s = try await Namer.suggest(urls[0], try await nextExtraction!.value, engine: engine) else {
            err("✗ Rien de lisible dans ce fichier"); exit(2)
        }
        try emit(s.name)
    } catch {
        err("✗ \(error.localizedDescription)"); exit(2)
    }
    exit(0)
}

for (n, url) in urls.enumerated() {
    let filename = url.lastPathComponent, t0 = Date()
    print("\(n + 1)/\(urls.count) avant    \(filename)")
    let extraction = nextExtraction!
    nextExtraction = prefetch(n + 1)
    do {
        guard let s = try await Namer.suggest(url, try await extraction.value, engine: engine) else {
            print("  – ignoré   rien de lisible\n"); skipped += 1; continue
        }
        let took = String(format: "%.1fs", Date().timeIntervalSince(t0))
        if s.name == filename {
            if !dryRun { Marker.set(url, originalName: filename) }  // don't ask the model again next time
            print("  = inchangé déjà bien nommé \(took)\n"); unchanged += 1; continue
        }
        if dryRun {
            print("  ○ proposé  \(s.name) \(took)\n")
        } else {
            let final = try Files.rename(url, to: s.name, backupDir: backupDir)
            print("  ✓ après    \(final.lastPathComponent) \(took)\n")
        }
        renamed += 1
    } catch {
        print("  ✗ erreur   \(error.localizedDescription)\n"); errors += 1
    }
}
summary()
