import CoreText
import Foundation
import Testing
@testable import PDFNamerCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-namer-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A one-page PDF with real (selectable) text, one line per string.
private func writePDF(_ lines: [String], to url: URL) throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let consumer = try #require(CGDataConsumer(data: data))
    let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    for (i, line) in lines.enumerated() {
        let attr = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
        ctx.textPosition = CGPoint(x: 50, y: 780 - CGFloat(i) * 20)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
    ctx.endPDFPage()
    ctx.closePDF()
    try (data as Data).write(to: url)
}

// MARK: Already handled

@Test func `un fichier renommé sans date reste reconnu comme déjà traité`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let scan = dir.appendingPathComponent("Scan 20261109.pdf")
    try Data("x".utf8).write(to: scan)
    #expect(!Naming.isNamed(scan))

    let final = try Files.rename(scan, to: "Attestation Club de basket - Licence joueur.pdf",
                                 backupDir: dir.appendingPathComponent("backup"))
    #expect(!Naming.isNamed(final.lastPathComponent))  // the name alone says nothing
    #expect(Naming.isNamed(final))
    #expect(Marker.originalName(final) == "Scan 20261109.pdf")

    // A later edit or a second rename keeps the very first name.
    let edited = try Files.rename(final, to: "Licence.pdf", backupDir: dir.appendingPathComponent("backup"))
    #expect(Marker.originalName(edited) == "Scan 20261109.pdf")

    Marker.clear(edited)  // undo
    #expect(!Naming.isNamed(edited))
}

@Test func `la sauvegarde de l’original ne porte pas la marque`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.pdf"), backup = dir.appendingPathComponent("backup")
    try Data("x".utf8).write(to: file)
    try Files.rename(file, to: "b.pdf", backupDir: backup)
    let copies = try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
    #expect(copies.count == 1)
    #expect(!Marker.isMarked(copies[0]))
}

@Test func `un simple déplacement, même nom, ne copie pas l’original`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Réunion 2026-11-19.m4a"), backup = dir.appendingPathComponent("backup")
    try Data("x".utf8).write(to: file)
    let final = try Files.rename(file, to: file.lastPathComponent, in: dir.appendingPathComponent("inbox"), backupDir: backup)
    #expect(final.path == dir.appendingPathComponent("inbox/Réunion 2026-11-19.m4a").path)
    #expect(Marker.isMarked(final))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
}

// MARK: Matching

@Test func `règle sur le nom : expression ICU, Unicode composé`() {
    let rule = Rule(filename: "^Facture_EDF_")
    #expect(rule.matches(filename: "Facture_EDF_123.pdf", text: nil))
    #expect(!rule.matches(filename: "facture_edf_123.pdf", text: nil))
    #expect(Rule(filename: "(?i)^facture_edf_").matches(filename: "FACTURE_EDF_1.pdf", text: nil))
    // macOS hands out decomposed names (e + ◌́); patterns are written composed.
    #expect(Rule(filename: "Relevé").matches(filename: "Releve\u{301} CIC.pdf", text: nil))
}

@Test func `règle sur le contenu : toutes les expressions, sans casse ni accents`() {
    let rule = Rule(contains: ["idealo internet GmbH", "Italie"])
    #expect(rule.matches(filename: "x.pdf", text: "IDEALO INTERNET GMBH\nPays : ITALIE"))
    #expect(!rule.matches(filename: "x.pdf", text: "idealo internet GmbH\nAllemagne"))
    #expect(rule.missingPhrases(in: "idealo internet GmbH") == ["Italie"])
    #expect(Rule(contains: ["Relevés de compte"]).matches(filename: "x.pdf", text: "RELEVES DE COMPTE"))
    #expect(!rule.matches(filename: "x.pdf", text: nil))
}

@Test func `une règle sans condition, désactivée ou invalide ne prend rien`() {
    #expect(!Rule(folder: "~/Documents").matches(filename: "x.pdf", text: "tout"))
    #expect(!Rule(filename: "x", enabled: false).matches(filename: "x.pdf", text: nil))
    let broken = Rule(filename: "(")
    #expect(broken.patternError != nil)
    #expect(!broken.matches(filename: "(.pdf", text: nil))
}

// MARK: Destination

@Test func `destination : dossier, sous-dossier daté, nom et préfixe`() {
    let file = URL(fileURLWithPath: "/tmp/Downloads/Invoice-34E86D02-0001.PDF")
    let rule = Rule(filename: "^Invoice-34E86D02-", folder: "/Factures/Achats", subfolder: .yearMonth, rename: "Facture Anthropic API")
    let d = rule.destination(for: file, date: "2026-11-05")
    #expect(d.folder.path == "/Factures/Achats/2026-11")
    #expect(d.name == "2026-11-05 - Facture Anthropic API.pdf")

    let year = Rule(filename: "x", folder: "/F", subfolder: .year).destination(for: file, date: "2026-11-05")
    #expect(year.folder.path == "/F/2026")
    #expect(year.name == "2026-11-05 - Invoice-34E86D02-0001.pdf")  // no new name: keeps its own, dated

    let plain = Rule(filename: "x", folder: "", datePrefix: false).destination(for: file, date: "2026-11-05")
    #expect(plain.folder.path == "/tmp/Downloads")
    #expect(plain.name == "Invoice-34E86D02-0001.pdf")

    let dated = URL(fileURLWithPath: "/tmp/2025-01-02 - Facture.pdf")
    // An existing prefix takes the date chosen (firstMatch passes the name's own when nothing better).
    #expect(Rule(filename: "x").destination(for: dated, date: "2026-11-05").name == "2026-11-05 - Facture.pdf")
    #expect(Rule(filename: "x").destination(for: dated, date: "2025-01-02").name == "2025-01-02 - Facture.pdf")
    #expect(Rule(filename: "x", datePrefix: false).destination(for: dated, date: "2026-11-05").name == "2025-01-02 - Facture.pdf")
    #expect(Rule(filename: "x", rename: "A/B").destination(for: file, date: "2026-11-05").name == "2026-11-05 - A-B.pdf")
}

@Test func `la première règle qui correspond gagne, date lue par le lecteur de date`() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pdf = dir.appendingPathComponent("document.pdf")
    try writePDF(["Example Hosting SAS", "Facture du 14/03/2025", "Total 12,00 EUR"], to: pdf)
    let rules = [
        Rule(name: "Autre", contains: ["Example Hosting", "Introuvable"], folder: dir.appendingPathComponent("A").path),
        Rule(name: "Pas actif", contains: ["Example Hosting"], enabled: false),
        Rule(name: "Hébergement", contains: ["example hosting"], folder: dir.appendingPathComponent("B").path,
             subfolder: .year, rename: "Facture Example Hosting"),
        Rule(name: "Trop tard", filename: "document"),
    ]
    // The model picks the issue date in the app; here a stand-in.
    let m = try #require(await Rules.firstMatch(rules, for: pdf, readDate: { _ in "2025-03-14" }))
    #expect(m.index == 2)
    #expect(m.date == "2025-03-14")
    #expect(m.dateSource == .document)
    #expect(m.folder.path == dir.appendingPathComponent("B/2025").path)
    #expect(m.name == "2025-03-14 - Facture Example Hosting.pdf")

    let final = try Files.rename(pdf, to: m.name, in: m.folder, backupDir: dir.appendingPathComponent("backup"))
    #expect(final.path == dir.appendingPathComponent("B/2025/2025-03-14 - Facture Example Hosting.pdf").path)
    #expect(Marker.originalName(final) == "document.pdf")
}

@Test func `sans date lue, celle de création du fichier ; sans date utile, pas de lecture`() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("DSN_123.pdf")
    try Data("pas un pdf".utf8).write(to: file)
    let created = Day(try #require(try file.resourceValues(forKeys: [.creationDateKey]).creationDate)).iso

    let m = try #require(await Rules.firstMatch([Rule(filename: "^DSN_")], for: file, readDate: { _ in nil }))
    #expect(m.date == created && m.dateSource == .file)
    #expect(try #require(await Rules.firstMatch([Rule(filename: "^DSN_")], for: file)).dateSource == .file)

    // Neither prefix nor dated subfolder: the model is not asked.
    let plain = Rule(filename: "^DSN_", folder: "/F", datePrefix: false)
    let p = try #require(await Rules.firstMatch([plain], for: file, readDate: { _ in Issue.record("lu"); return nil }))
    #expect(p.dateSource == .unused && p.name == "DSN_123.pdf")
}

@Test func `nom déjà daté : la date du document d’abord, celle du nom à défaut`() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // An old renamer read the US 10/01/2026 (October 1) as January 10.
    let file = dir.appendingPathComponent("2026-01-10 - Facture Example.pdf")
    try Data("x".utf8).write(to: file)
    let dating = Rule(name: "Classement par date", filename: ".", folder: dir.path, subfolder: .yearMonth)

    let read = try #require(await Rules.firstMatch([dating], for: file, readDate: { _ in "2026-10-31" }))
    #expect(read.dateSource == .document)
    #expect(read.folder.path == dir.appendingPathComponent("2026-10").path)
    #expect(read.name == "2026-10-31 - Facture Example.pdf")  // the wrong prefix is replaced

    // Unreadable document: the name's date stands, the name is unchanged.
    let kept = try #require(await Rules.firstMatch([dating], for: file, readDate: { _ in nil }))
    #expect(kept.dateSource == .name && kept.date == "2026-01-10" && kept.name == file.lastPathComponent)
    #expect(Rules.nameDate("2025-13-40 - x.pdf") == nil)  // not a real date
}

@Test func `dates américaines : mois d’abord quand le document l’écrit ainsi`() {
    let today = Day(2026, 11, 19)!
    // solute-style English invoice: 10/31 can only be month first, so 10/01 is October 1.
    let us = "Date\n10/31/2026\nPeriod 10/01/2026 - 10/31/2026\nDue on 11/14/2026"
    #expect(Candidates.dates(us, today: today) == ["2026-10-31", "2026-10-01", "2026-11-14"])
    // French: 31/10 is day first; ambiguous 01/10 follows it.
    #expect(Candidates.dates("Facture du 01/10/2026, échéance 31/10/2026", today: today) == ["2026-10-01", "2026-10-31"])
    // No evidence either way: day first. Dots are always day first.
    #expect(Candidates.dates("03/04/2026 · 05.06.2026", today: today) == ["2026-04-03", "2026-06-05"])
    // Month names in English, both orders.
    #expect(Candidates.dates("Invoice date: October 31, 2026. Paid 1st Nov 2026", today: today) == ["2026-11-01", "2026-10-31"])
}

@Test func `dossier relais : moveTo lu, écrit seulement s’il existe`() throws {
    let relay = try JSONDecoder().decode(UserConfig.Folder.self, from: Data(#"{"path": "~/Scans", "moveTo": "~/Desktop"}"#.utf8))
    #expect(relay.relay?.path == UserConfig.expand("~/Desktop").path)
    let plain = UserConfig.Folder(path: "~/Downloads")
    #expect(plain.relay == nil)
    #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("moveTo"))
}

@Test func `classement par date : liste explicite, suggestions tirées des règles datées`() throws {
    var config = UserConfig()
    config.datedFolders = [UserConfig.DatedFolder(path: "/F/Achats", subfolder: .yearMonth)]
    let rules = [
        Rule(name: "Achats", filename: "a", folder: "/F/Achats", subfolder: .year),   // listed already
        Rule(name: "Ventes", filename: "v", folder: "/F/Ventes", subfolder: .year, datePrefix: false),
        Rule(name: "Ventes 2", filename: "w", folder: "/F/Ventes/", subfolder: .yearMonth),  // same folder: once
        Rule(name: "Réunions", filename: "r", folder: "/F/Meetings", datePrefix: false),  // no date: no
        Rule(name: "Off", filename: "o", folder: "/F/Off", enabled: false),
    ]
    let s = config.datedSuggestions(rules)
    #expect(s.map(\.folder.path) == ["/F/Ventes"])
    #expect(s[0].rule == "Ventes" && s[0].folder.subfolder == .year && !s[0].folder.datePrefix)

    let decoded = try JSONDecoder().decode(UserConfig.self, from: Data(#"{"datedFolders": [{"path": "~/X"}]}"#.utf8))
    #expect(decoded.datedFolders.first?.subfolder == .year && decoded.datedFolders.first?.datePrefix == true)
}

@Test func `règle tirée d’un fichier : nombres généralisés, type et émetteur du nom proposé`() {
    let r = Rule.draft(from: "Invoice-DE84E1D9-0026 (1).pdf",
                       suggestedName: "2026-09-17 - Facture Replicate - Calcul GPU - 12.40 USD.pdf")
    #expect(r.filename == #"^Invoice-DE84E1D9-\d+"#)
    #expect(r.rename == "Facture Replicate")
    #expect(r.name == "Facture Replicate")
    #expect(r.matches(filename: "Invoice-DE84E1D9-0031.pdf", text: nil))
    #expect(!r.matches(filename: "Invoice-AB12CD34-0031.pdf", text: nil))

    let bare = Rule.draft(from: "Facture_EDF_10260541684.pdf")
    #expect(bare.filename == #"^Facture_EDF_\d+"#)
    #expect(bare.rename.isEmpty && bare.name == "Facture_EDF_10260541684")
    #expect(Rule.draft(from: "a+b (x).pdf").filename == #"^a\+b \(x\)"#)  // regex characters stay literal
}

@Test func `xlsx : texte lu, nom de fichier pris tel quel`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let xl = dir.appendingPathComponent("xl")
    try FileManager.default.createDirectory(at: xl, withIntermediateDirectories: true)
    try Data("<sst><si><t>Carte Corporate Example</t></si></sst>".utf8).write(to: xl.appendingPathComponent("sharedStrings.xml"))
    let book = dir.appendingPathComponent("[releve].xlsx")  // brackets: a wildcard for unzip if not escaped
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = dir
    zip.arguments = ["-q", "-r", book.path, "xl"]
    try zip.run()
    zip.waitUntilExit()
    try #require(zip.terminationStatus == 0)
    #expect(RuleText.xlsxStrings(book)?.contains("Carte Corporate Example") == true)
    #expect(RuleText.xlsxStrings(dir.appendingPathComponent("absent.xlsx")) == nil)
}

// MARK: rules.json

@Test func `rules.json : aller-retour, clés facultatives, ids non stockés`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rules.json")
    #expect(try Rules.load(from: url).isEmpty)

    let rules = [Rule(name: "EDF", filename: "^Facture_EDF_", folder: "~/Factures", subfolder: .yearMonth, rename: "Facture EDF"),
                 Rule(contains: ["a", "b"], datePrefix: false, enabled: false)]
    try Rules.save(rules, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("\"id\""))
    #expect(text.contains("\"~/Factures\""))  // paths stay readable: no \/
    #expect(try Rules.load(from: url) == rules)  // == ignores the session ids

    try Data(#"{"rules": [{"filename": "x"}]}"#.utf8).write(to: url)
    let r = try #require(try Rules.load(from: url).first)
    #expect(r.enabled && r.datePrefix && r.subfolder == .none && r.folder.isEmpty)

    try Data("{ pas du json".utf8).write(to: url)
    #expect(throws: (any Error).self) { try Rules.load(from: url) }
}
