import Foundation

/// Scores the model's fields against a labelled corpus (`archiviste --eval <dossier>`), to see
/// whether a change to the prompt or the cleanup helps or hurts.
///
/// A corpus is a folder with its files and a `corpus.json`:
///
///     { "myNames": ["Camille Martin"],          // optional: the recipient, never the issuer
///       "documents": [
///         { "file": "facture-lumen.pdf",
///           "type": "Facture", "issuer": "Lumen", "date": "2026-10-03", "amount": "84.20 EUR",
///           "detail": ["électricité"],          // one of these words in the detail
///           "lines": ["…"] }                    // the text, for tools/make_corpus.swift
///       ] }
///
/// A field left out is not scored; "aucun" expects nothing. "A|B" accepts either (type, issuer).
public enum Evaluation {
    public struct Corpus: Decodable, Sendable {
        public var myNames: [String]?
        public var documents: [Expected]
    }

    public struct Expected: Decodable, Sendable {
        public var file: String
        public var type: String?
        public var issuer: String?
        public var date: String?
        public var amount: String?
        public var detail: [String]?
    }

    public struct Score: Sendable {
        public var field: String
        public var ok: Bool
        public var got: String
        public var expected: String
    }

    public static func load(_ folder: URL) throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: folder.appendingPathComponent("corpus.json")))
    }

    /// One score per labelled field, from the fields as they go into the name (cleaned).
    public static func score(_ e: Expected, _ fields: [String: String]) -> [Score] {
        let f = Naming.normalize(fields)
        var out: [Score] = []
        func add(_ field: String, _ expected: String?, _ got: String, _ match: (String) -> Bool) {
            guard let expected else { return }
            let none = Naming.nullValues.contains(expected.lowercased())
            out.append(Score(field: field, ok: none ? got.isEmpty : match(expected), got: got.isEmpty ? "—" : got,
                             expected: none ? "—" : expected))
        }
        let type = Naming.value(f, "type"), issuer = Naming.doctor.sub(Naming.value(f, "issuer"), "Dr ")
        let date = (f["date"] ?? "").pyStrip, detail = Naming.value(f, "detail")
        // As in the name: only the types that carry an amount (not a payslip, a statement…).
        let carries = Naming.amountTypes.contains { type.lowercased().contains($0) }
        let amount = carries ? Naming.parseAmount(f["amount"] ?? "") ?? "" : ""
        add("type", e.type, type) { $0.split(separator: "|").contains { fold(String($0)) == fold(type) } }
        // The expected words, and at most one more ("Amazon" ~ "Amazon EU", not a whole address).
        add("issuer", e.issuer, issuer) { exp in
            let have = words(issuer)
            return exp.split(separator: "|").contains { alt in
                // Cleaned like the answer: "Klein Charpentier S.A." expects "Klein Charpentier".
                let want = words(Naming.cleanFields(["issuer": String(alt)])["issuer"] ?? String(alt))
                return want.isSubset(of: have) && have.count <= want.count + 1
            }
        }
        add("date", e.date, Naming.dateISO.test(date) ? date : "") { $0 == date }
        add("amount", e.amount, amount) { Naming.parseAmount($0) == amount }
        if let keys = e.detail {
            out.append(Score(field: "detail", ok: keys.contains { fold(detail).contains(fold($0)) },
                             got: detail.isEmpty ? "—" : detail, expected: keys.joined(separator: " | ")))
        }
        return out
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ s: String) -> Set<String> {
        Set(fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
