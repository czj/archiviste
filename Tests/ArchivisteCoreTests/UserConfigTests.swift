import Foundation
import Testing
@testable import ArchivisteCore

private func write(_ json: String, _ url: URL) throws { try Data(json.utf8).write(to: url) }

@Test func `config partielle : valeurs par défaut pour le reste`() throws {
    let json = #"{"backupDir": "~/Archives", "watchedFolders": [{"path": "~/Downloads"}]}"#
    let c = try JSONDecoder().decode(UserConfig.self, from: Data(json.utf8))
    #expect(c.backupDir == "~/Archives")
    #expect(c.backupURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Archives").path)
    #expect(c.watchedFolders == [UserConfig.Folder(path: "~/Downloads", enabled: true)])
    #expect(c.backupMaxAgeDays == 180)
    #expect(c.expireMaxAge == nil)  // trashing is opt-in
    #expect(!c.confirmBeforeRename)
}

@Test func `config.local.json remplace config.json clé par clé`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let shared = dir.appendingPathComponent("config.json"), local = dir.appendingPathComponent("config.local.json")
    try write(#"{"backupDir": "~/Archives", "expireMaxAgeDays": 548}"#, shared)
    try write(#"{"expireMaxAgeDays": 0, "watchedFolders": [{"path": "~/Scans"}]}"#, local)
    let c = try UserConfig.load(shared: shared, local: local)
    #expect(c.backupDir == "~/Archives")
    #expect(c.expireMaxAgeDays == 0)
    #expect(c.watchedFolders.map(\.path) == ["~/Scans"])
}

@Test func `l’app n’écrit que les différences et jamais config.json`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let shared = dir.appendingPathComponent("config.json"), local = dir.appendingPathComponent("config.local.json")
    let sharedText = #"{"backupDir": "~/Archives", "expireMaxAgeDays": 548}"#
    try write(sharedText, shared)

    var c = try UserConfig.load(shared: shared, local: local)
    c.watchedFolders = [UserConfig.Folder(path: FileManager.default.homeDirectoryForCurrentUser.path + "/Scans")]
    try c.saveLocal(shared: shared, local: local)

    #expect(try String(contentsOf: shared, encoding: .utf8) == sharedText)
    #expect(UserConfig.localKeys(at: local) == ["watchedFolders"])
    #expect(try String(contentsOf: local, encoding: .utf8).contains(#""path" : "~/Scans""#))
    #expect(try UserConfig.load(shared: shared, local: local) == c)

    c.watchedFolders = []  // back to the shared value: no override left
    try c.saveLocal(shared: shared, local: local)
    #expect(!FileManager.default.fileExists(atPath: local.path))
}

@Test func `sans fichier : valeurs par défaut`() throws {
    let none = URL(fileURLWithPath: "/nonexistent/config.json")
    #expect(try UserConfig.load(shared: none, local: none) == UserConfig())
}

@Test func `fichier invalide : erreur`() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bad = dir.appendingPathComponent("config.json")
    try write("{ oops", bad)
    #expect(throws: (any Error).self) { try UserConfig.load(shared: bad, local: dir.appendingPathComponent("x.json")) }
}

@Test func `migration PDF Namer : config déplacée, lien laissé, sauvegardes suivies`() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let config = root.appendingPathComponent("config"), docs = root.appendingPathComponent("Documents")
    let old = config.appendingPathComponent("pdf-namer")
    try fm.createDirectory(at: old, withIntermediateDirectories: true)
    try write(#"{"rules": []}"#, old.appendingPathComponent("rules.json"))
    try fm.createDirectory(at: docs.appendingPathComponent("PDF Namer/Originaux"), withIntermediateDirectories: true)

    UserConfig.migrateLegacyFolders(configBase: config, documents: docs)
    let new = config.appendingPathComponent("archiviste")
    #expect(fm.fileExists(atPath: new.appendingPathComponent("rules.json").path))
    #expect(try fm.destinationOfSymbolicLink(atPath: old.path) == new.path)
    #expect(fm.fileExists(atPath: old.appendingPathComponent("rules.json").path))  // through the link
    #expect(fm.fileExists(atPath: docs.appendingPathComponent("Archiviste/Originaux").path))

    UserConfig.migrateLegacyFolders(configBase: config, documents: docs)  // twice: nothing more happens
    #expect(fm.fileExists(atPath: new.appendingPathComponent("rules.json").path))
}

@Test func `migration PDF Namer : un dossier de sauvegarde choisi ne bouge pas`() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let config = root.appendingPathComponent("config"), docs = root.appendingPathComponent("Documents")
    let old = config.appendingPathComponent("pdf-namer")
    try fm.createDirectory(at: old, withIntermediateDirectories: true)
    try write(#"{"backupDir": "~/Documents/PDF Namer/Mes originaux"}"#, old.appendingPathComponent("config.local.json"))
    try fm.createDirectory(at: docs.appendingPathComponent("PDF Namer"), withIntermediateDirectories: true)

    UserConfig.migrateLegacyFolders(configBase: config, documents: docs)
    #expect(fm.fileExists(atPath: docs.appendingPathComponent("PDF Namer").path))
    #expect(!fm.fileExists(atPath: docs.appendingPathComponent("Archiviste").path))
}
