// Builds the PDFs of a synthetic corpus from the "lines" of its corpus.json (see Evaluation.swift):
//
//     swift tools/make_corpus.swift corpus/synthetique
//
// One A4 page per document, real text (selectable, as in a born-digital PDF). A line starting
// with "# " is a heading, larger and bold; "> " is pushed to the right (the recipient's block);
// an empty line leaves a gap.
import CoreText
import Foundation

struct Corpus: Decodable { var documents: [Doc] }
struct Doc: Decodable { var file: String; var lines: [String]? }

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "corpus/synthetique")
let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: folder.appendingPathComponent("corpus.json")))
let regular = CTFontCreateWithName("Helvetica" as CFString, 10.5, nil)
let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)

func draw(_ text: String, _ font: CTFont, at point: CGPoint, in ctx: CGContext) {
    let attr = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
    ctx.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
}

var made = 0
for doc in corpus.documents {
    guard let lines = doc.lines else { continue }
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { continue }
    ctx.beginPDFPage(nil)
    var y: CGFloat = 790
    for line in lines {
        if line.hasPrefix("# ") {
            y -= 8
            draw(String(line.dropFirst(2)), bold, at: CGPoint(x: 50, y: y), in: ctx)
            y -= 24
        } else if line.hasPrefix("> ") {
            draw(String(line.dropFirst(2)), regular, at: CGPoint(x: 340, y: y), in: ctx)
            y -= 15
        } else if line.isEmpty {
            y -= 10
        } else {
            draw(line, regular, at: CGPoint(x: 50, y: y), in: ctx)
            y -= 15
        }
    }
    ctx.endPDFPage()
    ctx.closePDF()
    try (data as Data).write(to: folder.appendingPathComponent(doc.file))
    made += 1
}
print("✓ \(made) PDF dans \(folder.path)")
