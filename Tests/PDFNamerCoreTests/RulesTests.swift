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
    #expect(Rule(filename: "x").destination(for: dated, date: "2026-11-05").name == "2025-01-02 - Facture.pdf")
    #expect(Rule(filename: "x", rename: "A/B").destination(for: file, date: "2026-11-05").name == "2026-11-05 - A-B.pdf")
}

@Test func `la première règle qui correspond gagne, date lue dans le PDF`() async throws {
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
    let m = try #require(await Rules.firstMatch(rules, for: pdf))
    #expect(m.index == 2)
    #expect(m.date == "2025-03-14")
    #expect(m.folder.path == dir.appendingPathComponent("B/2025").path)
    #expect(m.name == "2025-03-14 - Facture Example Hosting.pdf")

    let final = try Files.rename(pdf, to: m.name, in: m.folder, backupDir: dir.appendingPathComponent("backup"))
    #expect(final.path == dir.appendingPathComponent("B/2025/2025-03-14 - Facture Example Hosting.pdf").path)
    #expect(Marker.originalName(final) == "document.pdf")
}

@Test func `sans date dans le texte, celle de création du fichier`() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("DSN_123.pdf")
    try Data("pas un pdf".utf8).write(to: file)
    let m = try #require(await Rules.firstMatch([Rule(filename: "^DSN_\\d+\\.pdf")], for: file))
    #expect(m.date == Day.today().iso)
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
