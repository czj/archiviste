import CoreText
import Foundation
@testable import ArchivisteCore
import Testing

/// A one-page PDF whose text layer holds `text`.
private func writePDF(_ text: String, to url: URL) throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    let consumer = try #require(CGDataConsumer(data: data))
    let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    ctx.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    try (data as Data).write(to: url)
}

@Test func `extraction relue quand le fichier change`() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("doc.pdf")
    try writePDF("Facture Alice", to: url)
    #expect(try await Extractor.extract(url).text == "Facture Alice")
    #expect(try await Extractor.extract(url).text == "Facture Alice")  // from the cache
    try writePDF("Reçu Bob, autre contenu", to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    #expect(try await Extractor.extract(url).text == "Reçu Bob, autre contenu")
}
