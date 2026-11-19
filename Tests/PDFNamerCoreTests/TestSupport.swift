import Foundation
import PDFKit

/// A fresh empty folder under the temporary directory; the test removes it.
func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-namer-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A one-page PDF of the given size in points, built in memory.
enum PDFKitTestPage {
    static func make(width: CGFloat, height: CGFloat) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
