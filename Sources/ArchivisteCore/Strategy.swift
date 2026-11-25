import Foundation

/// Ways of asking the model, to compare with `archiviste --strategy a+b --eval <corpus>`.
/// `.baseline` is the one the app uses until another one wins on the corpora.
///
/// - reasoning: the model first copies the document's title and the line that shows who wrote
///   it (header, "Vendu par", footer…), then answers type and issuer: with guided generation
///   the fields are filled in order, so these act as a short chain of thought.
/// - other: "Autre" among the types, with a free 1-3 word type, instead of forcing a list entry.
/// - twoPass: the type alone first (short prompt), then the other fields with hints for that type.
/// - headTail: the start and the end of a long text (issuers sit in footers) instead of its start.
/// - filename: the whole file name in one field, parsed back into fields.
/// - guards: more types must find one of their own words in the text, or are asked again without.
public struct Strategy: Sendable, Hashable, CustomStringConvertible {
    public var reasoning = false
    public var other = false
    public var twoPass = false
    public var headTail = false
    public var filename = false
    public var guards = false
    /// The amount from the baseline (which picks the total TTC, not a subtotal), asked at the same
    /// time with the type alone before it: everything else from this strategy.
    public var blend = false
    /// No page image when the file has a text: about 15 % faster, but the type, the issuer and above
    /// all the amount of invoices drop on the held-out corpora. Only for the issue date alone.
    public var textOnly = false

    public static let baseline = Strategy()
    /// The issue date for dated rules: the type then the date, read in the text (its dates are the choices).
    static let dateOnly = Strategy("textOnly")!
    /// What the app and the command use: on the corpora it finds the issuer, the date and the amount
    /// more often than the baseline, for less than twice the time (three calls, two at once).
    public static let app = Strategy("twoPass+reasoning+guards+headTail+blend")!
    static let names = ["reasoning", "other", "twoPass", "headTail", "filename", "guards", "blend", "textOnly"]

    public init() {}

    /// "reasoning+other+headTail"; "baseline" for none.
    public init?(_ spec: String) {
        for part in spec.split(separator: "+").map(String.init) where part != "baseline" {
            switch part.lowercased() {
            case "reasoning": reasoning = true
            case "other": other = true
            case "twopass": twoPass = true
            case "headtail": headTail = true
            case "filename": filename = true
            case "guards": guards = true
            case "blend": blend = true
            case "textonly": textOnly = true
            default: return nil
            }
        }
    }

    public var description: String {
        let on = [reasoning, other, twoPass, headTail, filename, guards, blend, textOnly]
        let parts = zip(Self.names, on).filter(\.1).map(\.0)
        return parts.isEmpty ? "baseline" : parts.joined(separator: "+")
    }
}

/// The prompt's sections, cut from `Config.rules` (blank-line separated) so that every strategy
/// says the same rules: type, issuer, date, detail, amount, style, then the examples.
enum PromptParts {
    static let sections = Config.rules.components(separatedBy: "\n\n")
    static var type: String { sections[0] }
    static var issuer: String { sections[1] }
    static var date: String { sections[2] }
    static var detail: String { sections[3] }
    static var amount: String { sections[4] }
    static var style: String { sections[5] }
    static var examples: String { sections[6...].joined(separator: "\n\n") }

    static let other = "- Autre: rien dans cette liste ne convient (rapport d'étude, guide, étiquette…): mets alors la nature du document dans type_libre."

    static let reasoning = """
        Remplis d'abord titre (les mots qui disent ce qu'est le document, tels qu'écrits) et auteur (la ligne qui montre qui l'a écrit: en-tête, logo, « Vendu par », signature, pied de page avec SIRET). Ils servent à choisir type et issuer.
        """

    /// What to look for once the type is known (second pass).
    static let hints: [String: String] = [
        "Facture": "Plusieurs factures: prends la première. « Vendu par » ou « Vendeur » est l'émetteur, pas la plateforme qui l'héberge. detail = l'article ou le service principal.",
        "Bulletin de paie": "issuer = l'employeur (en haut à gauche). detail = le mois payé (Octobre 2026).",
        "Relevé de compte": "issuer = la banque. detail = le mois ou la période (Octobre 2026).",
        "Relevé de prestations": "issuer = la mutuelle ou la caisse. detail = le mois ou les soins.",
        "Ordonnance": "issuer = Dr + nom du prescripteur. detail = les médicaments ou examens prescrits.",
        "Compte rendu": "issuer = le médecin, le laboratoire ou l'organisateur. detail = l'examen ou la réunion.",
        "Avis d'imposition": "issuer = Finances publiques ou la collectivité. detail = l'impôt et l'année.",
        "Lettre": "issuer = l'expéditeur. detail = l'objet du courrier.",
        "Contrat": "issuer = l'assureur, le bailleur ou le prestataire. detail = ce qui est couvert ou loué.",
        "Avenant": "issuer = l'assureur ou le prestataire. detail = ce que l'avenant change.",
        "Devis": "issuer = l'artisan ou l'entreprise qui propose. detail = les travaux ou le produit.",
        "Reçu de paiement": "issuer = l'enseigne, sans la ville. detail = les articles principaux.",
        "Attestation": "issuer = l'organisme qui atteste. detail = ce qui est attesté.",
    ]
}

extension Engine {
    /// Types the model gives too readily, with `guards`: one of these words must be in the text.
    static let strictTypeWords: [String: [String]] = typeWords.merging([
        "Devis": ["devis", "estimation", "proposition commerciale", "quote", "offre de prix"],
        "Ordonnance": ["ordonnance", "prescri", "posologie", "comprimé", "gélule", " mg"],
        "Bulletin de paie": ["bulletin de paie", "bulletin de salaire", "net à payer", "salaire brut"],
        "Quittance": ["quittance", "loyer"],
        "Contrat": ["contrat", "conditions particulières", "bail", "police", "souscri", "adhésion"],
    ]) { a, _ in a }

    /// Start and end of a long text: issuers often sit in the footer, past where it is cut.
    static func headTail(_ text: String, head: Int = 2200, tail: Int = 800) -> String {
        guard text.count > head + tail + 200 else { return text }
        return String(text.prefix(head)) + "\n[…]\n" + String(text.suffix(tail))
    }

    func ask(_ ex: Extracted, isImage: Bool, myNames: [String], strategy s: Strategy,
             imageURL: URL?) async throws -> [String: String] {
        let full = (ex.text ?? "").pyStrip
        let text = s.headTail ? Self.headTail(full) : full
        let body = ex.text == nil ? "(aucun texte lisible, utilise l'image)" : text
        let dates = Candidates.dates(full), amounts = Candidates.amounts(full)
        let mine = myNames.isEmpty ? "" : "\n\nLe destinataire de ces documents est \(myNames.joined(separator: ", ")) : "
            + "JAMAIS l'issuer, même s'il apparaît en haut de la page ; prends l'autre partie."
        let intro = isImage ? Config.imageInstructions.components(separatedBy: PromptParts.type)[0] : Config.intro
        let types = (isImage ? Config.imageTypes : Config.types) + (s.other ? ["Autre"] : [])

        let titre = Field(name: "titre", description: "Les mots qui disent ce qu'est le document, tels qu'écrits, ou aucun", choices: nil)
        let auteur = Field(name: "auteur", description: "La ligne qui montre qui a écrit le document (en-tête, « Vendu par », signature, pied de page), jamais le destinataire", choices: nil)
        let type = Field(name: "type", description: "Nature du document", choices: types)
        let typeLibre = Field(name: "type_libre", description: "Si type = Autre: la nature du document en 1 à 3 mots; sinon aucun", choices: nil)
        let issuer = Field(name: "issuer", description: "Qui a écrit le document, forme courte, ou aucun", choices: nil)
        let date = Field(name: "date", description: "Date d'émission du document (AAAA-MM-JJ), ou aucun",
                         choices: dates.isEmpty ? nil : dates + ["aucun"])
        let detail = Field(name: "detail", description: "2 à 6 mots sur l'objet précis", choices: nil)
        let amount = Field(name: "amount", description: "Montant total TTC (factures, reçus, devis...), ou aucun",
                           choices: amounts + ["aucun"])

        let typeRules = PromptParts.type + (s.other ? "\n" + PromptParts.other : "")
        let rest = [PromptParts.issuer, PromptParts.date, PromptParts.detail, PromptParts.amount, PromptParts.style]
        let prompt = "Texte du document:\n---\n\(body)\n---"

        if s.filename {
            let instructions = intro.replacingOccurrences(of: "Remplis chaque champ en suivant ces règles.",
                                                          with: "Donne son nom de fichier, sans extension, au format AAAA-MM-JJ - Type Émetteur - Détail - Montant DEVISE (date d'émission; montant seulement pour factures, reçus, devis, avoirs, quittances, notes de frais; omets une partie absente).")
                + ([typeRules] + rest).joined(separator: "\n\n").replacingOccurrences(of: "issuer =", with: "Émetteur =")
                    .replacingOccurrences(of: "detail =", with: "Détail =").replacingOccurrences(of: "amount =", with: "Montant =")
                    .replacingOccurrences(of: "type =", with: "Type =").replacingOccurrences(of: "date =", with: "Date =")
                + "\n\nExemples:\n2025-03-14 - Facture Kiné Durand - Séances de rééducation genou - 180.00 EUR\n"
                + "2025-08-29 - Avis d'imposition Finances publiques - Impôt sur le revenu 2024\n"
                + "2024-11-02 - Contrat Free - Abonnement fibre Freebox Pop"
                + (s.reasoning ? "\n\n" + PromptParts.reasoning : "") + mine
            let fields = (s.reasoning ? [titre, auteur] : [])
                + [Field(name: "nom", description: "Nom du fichier sans extension", choices: nil)]
            let answer = try await respond(instructions: instructions, prompt: prompt, image: imageURL, fields: fields)
            return Naming.parseName(answer["nom"] ?? "", types: types)
        }

        if s.twoPass {
            var first = try await respond(
                instructions: intro + typeRules + (s.reasoning ? "\n\n" + PromptParts.reasoning : ""),
                prompt: prompt, image: imageURL, fields: (s.reasoning ? [titre] : []) + [type] + (s.other ? [typeLibre] : []))
            first = try await guarded(first, s, text: full, choices: types) { narrowed in
                try await respond(instructions: intro + typeRules, prompt: prompt, image: imageURL,
                                  fields: [Field(name: "type", description: type.description, choices: narrowed)] + (s.other ? [typeLibre] : []))
            }
            let known = Self.resolvedType(first)
            let hint = PromptParts.hints[known].map { "\n" + $0 } ?? ""
            var second = try await respond(
                instructions: intro + "Ce document est: \(known).\(hint)\n\n" + rest.joined(separator: "\n\n")
                    + (s.reasoning ? "\n\n" + PromptParts.reasoning : "") + mine,
                prompt: prompt, image: imageURL, fields: (s.reasoning ? [auteur] : []) + [issuer, date, detail, amount])
            second["type"] = known
            return second
        }

        let instructions = intro + ([typeRules] + rest + [PromptParts.examples]).joined(separator: "\n\n")
            + (s.reasoning ? "\n\n" + PromptParts.reasoning : "") + mine
        let fields = (s.reasoning ? [titre] : []) + [type] + (s.other ? [typeLibre] : [])
            + (s.reasoning ? [auteur] : []) + [issuer, date, detail, amount]
        var answer = try await respond(instructions: instructions, prompt: prompt, image: imageURL, fields: fields)
        answer = try await guarded(answer, s, text: full, choices: types) { narrowed in
            var f = fields
            if let i = f.firstIndex(where: { $0.name == "type" }) { f[i] = Field(name: "type", description: type.description, choices: narrowed) }
            return try await respond(instructions: instructions, prompt: prompt, image: imageURL, fields: f)
        }
        answer["type"] = Self.resolvedType(answer)
        return answer
    }

    /// "Autre" gives way to the free type.
    static func resolvedType(_ answer: [String: String]) -> String {
        let type = answer["type"] ?? ""
        guard type == "Autre" else { return type }
        let free = (answer["type_libre"] ?? "").trimmingCharacters(in: .whitespaces)
        return free.isEmpty || Naming.nullValues.contains(free.lowercased()) ? "Document" : free
    }

    /// Asks again without the type when none of its words is in the text (always for Avoir and
    /// Note de frais, for more types with `guards`).
    func guarded(_ answer: [String: String], _ s: Strategy, text: String, choices: [String],
                 again: ([String]) async throws -> [String: String]) async throws -> [String: String] {
        let table = s.guards ? Self.strictTypeWords : Self.typeWords
        guard !text.isEmpty, let type = answer["type"], let words = table[type],
              !words.contains(where: { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil })
        else { return answer }
        return (try? await again(choices.filter { $0 != type })) ?? answer
    }
}

extension Naming {
    /// "2025-03-14 - Facture Kiné Durand - Séances de rééducation - 180.00 EUR" back into fields.
    static func parseName(_ name: String, types: [String]) -> [String: String] {
        var parts = name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out = ["type": "aucun", "issuer": "aucun", "date": "aucun", "detail": "aucun", "amount": "aucun"]
        if let first = parts.first, let m = datePrefix.first(first + " - ") {
            out["date"] = m.group(1, in: first + " - ")
            parts.removeFirst()
        }
        if let last = parts.last, parts.count > 1, parseAmount(last) != nil {
            out["amount"] = last
            parts.removeLast()
        }
        guard !parts.isEmpty else { return out }
        let head = parts.removeFirst()
        if let t = types.sorted(by: { $0.count > $1.count })
            .first(where: { head.lowercased().hasPrefix($0.lowercased()) }) {
            out["type"] = t
            let rest = String(head.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { out["issuer"] = rest }
        } else {
            let words = head.split(separator: " ")
            out["type"] = words.first.map(String.init) ?? "aucun"
            if words.count > 1 { out["issuer"] = words.dropFirst().joined(separator: " ") }
        }
        if !parts.isEmpty { out["detail"] = parts.joined(separator: " - ") }
        return out
    }
}
