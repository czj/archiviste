import Foundation

/// Turns the model's fields into "DATE - Type Émetteur - Détail - MONTANT" (port of build_filename).
public enum Naming {
    static let allowedChars = Rx(#"[^\w\s\-'.,]"#)
    static let multiSpace = Rx(#"\s{2,}"#)
    static let strayPunct = Rx(#"(?<!\d)[.,]|[.,](?!\d)"#)  // keep only decimal marks: 0.5 mg, 1,5 L
    static let innerDash = Rx(#"\s+-+\s+"#)
    static let datePrefix = Rx(#"^(\d{4}-\d{2}-\d{2})\s*-\s*"#)
    static let named = Rx(#"^\d{4}-\d{2}-\d{2} - "#)
    static let dateISO = Rx(#"^\d{4}-\d{2}-\d{2}$"#)
    static let nonLetters = Rx(#"[^\w]|\d"#)
    static let doctor = Rx(#"^(Docteur|Doctor|Dr\.?)\s+"#, [.caseInsensitive])
    static let amountRe = Rx(#"-?\d[\d\s.,']*"#)
    static let currencyRe = Rx(#"\b[A-Z]{3}\b"#)
    static let decimalTail = Rx(#"[.,](\d{1,2})$"#)
    static let amountJunk = Rx(#"[\s']"#)
    static let dotsCommas = Rx(#"[.,]"#)

    static let nullValues: Set<String> = ["none", "aucun", "aucune", "inconnu", "unknown", "n/a", "na", "-"]
    static let maxName = 110  // macOS allows 255; long enough to never cut a useful detail

    /// Document types that carry a total amount worth putting in the filename (substring match).
    static let amountTypes = ["factur", "avoir", "reçu", "devis", "quittance", "note de frais", "bon de commande",
                              "invoice", "receipt", "rechnung", "quittung"]
    /// Image types whose printed date is trusted over the shot date.
    static let documentTypes = amountTypes + [
        "relevé", "avis", "attestation", "certificat", "contrat", "avenant", "lettre", "courrier",
        "bulletin", "récépissé", "déclaration", "ticket", "ordonnance", "compte rendu", "convocation",
        "procès", "bilan", "rapport", "billet", "échéancier", "conditions"]
    static let currencySymbols: [(String, String)] = [("€", "EUR"), ("$", "USD"), ("£", "GBP"), ("¥", "JPY")]

    static let acronyms = Set("""
        APHP AP-HP URSSAF CPAM CAF DGFIP SNCF RATP IKEA FNAC BNP LCL CIC HSBC MAIF MAAF MACIF MATMUT
        AXA GMF SFR OVH IBAN RIB TVA CFE CVAE DSN DADS SIRET SIREN EURL SARL SASU CDI CDD RTT IRM
        PDF USB HDMI TTC HT ISBN AGIRC ARRCO PRAS ASSR BTS DELF TOEIC CESU PAJE APL ANTS ORIAS
        DREETS INPI INSEE AMELI MGEN EDF GRDF ENGIE BOUYGUES ORANGE
        """.pySplit)
    static let brands: Set<String> = ["ORANGE", "BOUYGUES", "ENGIE", "AMELI"]  // better as Orange, Engie...
    static let smallWords = Set("de du des d la le les l et à a au aux en pour par sur sous avec sans un une ou".pySplit)

    /// "2026-11-05 - …": already named by a previous run or by hand.
    public static func isNamed(_ filename: String) -> Bool { named.test(filename) }

    static func letters(_ w: String) -> String { nonLetters.sub(w, "") }

    static func recaseWord(_ w: String, first: Bool, sentence: Bool, allCaps: Bool = false) -> String {
        if let q = w.firstIndex(of: "'") {  // D'ENTRETIEN → d'Entretien / d'entretien
            var pre = String(w[..<q]), post = String(w[w.index(after: q)...])
            pre = first ? pre.pyCapitalize : pre.lowercased()
            if post.isEmpty { return pre }
            post = recaseWord(post, first: false, sentence: sentence, allCaps: allCaps)
            return "\(pre)'\(post)"
        }
        if w.pyStrip("-").contains("-") {
            return w.pySplit("-").enumerated()
                .map { recaseWord($1, first: first && $0 == 0, sentence: sentence, allCaps: allCaps) }
                .joined(separator: "-")
        }
        let l = letters(w)
        if l.isEmpty || !l.pyIsUpper || l.pyLen == 1 { return w }  // mixed case, lower case, numbers: trust as is
        if smallWords.contains(l.lowercased()) && !first { return w.lowercased() }
        if (acronyms.contains(l) && !brands.contains(l)) || (l.pyLen <= 3 && !(allCaps && sentence)) { return w }
        return first || !sentence ? w.pyCapitalize : w.lowercased()
    }

    /// Un-shout all-caps words. sentence: "Contrat d'entretien"; else "Pixel Up Studio".
    static func fixCase(_ s: String, sentence: Bool = false) -> String {
        let words = s.pySplit(" ")
        let shouty = words.contains { w in
            let l = letters(w)
            return l.pyLen >= 4 && l.pyIsUpper && !acronyms.contains(l)
        }
        guard shouty else { return s }
        let allCaps = letters(s).pyIsUpper  // whole field shouted: short words (UP, DU) are shouting too
        return words.enumerated()
            .map { recaseWord($1, first: $0 == 0, sentence: sentence, allCaps: allCaps) }
            .joined(separator: " ")
    }

    /// "1 234,50 €" / "EUR 2.99" / "2,99EUR" → "1234.50 EUR"; nil if unusable.
    static func parseAmount(_ raw: String) -> String? {
        let raw = raw.pyStrip
        guard let m = amountRe.first(raw) else { return nil }
        let num = amountJunk.sub((raw as NSString).substring(with: m.range), "").pyRStrip(".,")
        // Last separator followed by 1-2 digits is the decimal mark; others group thousands.
        let dec = decimalTail.first(num)
        let wholePart = dec.map { num.pySlice(nil, $0.range.location) } ?? num
        let whole = dotsCommas.sub(wholePart, "")
        let literal = dec.map { "\(whole).\($0.group(1, in: num)!)" } ?? whole
        guard isPyFloat(literal), let value = Double(literal), value != 0 else { return nil }
        var cur = currencySymbols.first { raw.contains($0.0) }?.1
        if cur == nil, let cm = currencyRe.first(raw.uppercased()) { cur = cm.group(0, in: raw.uppercased()) }
        guard let cur else { return nil }
        return String(format: "%.2f", value) + " " + cur
    }

    /// Only what Python's float() accepts from these digit runs: [-]digits[.digits].
    static func isPyFloat(_ s: String) -> Bool { pyFloat.test(s) && s.contains(where: \.isNumber) }
    static let pyFloat = Rx(#"^-?[0-9]*\.?[0-9]*$"#)

    /// Strip special chars and normalize whitespace for filename use.
    static func sanitize(_ s: String) -> String {
        var s = s.pyStrip.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "/", with: " ")
        s = allowedChars.sub(s, "")
        s = strayPunct.sub(s, "").replacingOccurrences(of: ",", with: ".")
        s = innerDash.sub(s, " ")  // " - " is our field separator: never inside a field
        return multiSpace.sub(s, " ").pyStrip(" -'").pySlice(nil, 80)
    }

    static func value(_ fields: [String: String], _ key: String) -> String {
        let v = sanitize(fields[key] ?? "")
        return nullValues.contains(v.lowercased()) ? "" : v
    }

    /// Cut at a word boundary, never ending on 'de', 'pour', 'et'...
    static func trimWords(_ s: String, _ limit: Int) -> String {
        var words = s.pySplit
        while !words.isEmpty && words.joined(separator: " ").pyLen > limit { words.removeLast() }
        while let last = words.last,
              smallWords.contains(last.lowercased().pyStrip("'")) || last.pyStrip("-").isEmpty {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// The model's raw answer, normalized like the Python "key: value" round trip: first line, trimmed.
    public static func normalize(_ raw: [String: String]) -> [String: String] {
        raw.mapValues { v in (v.components(separatedBy: .newlines).first ?? "").pyStrip }
    }

    /// File name without extension. captureDate (images only) wins for photos/screenshots
    /// and is the fallback otherwise.
    public static func buildFilename(_ raw: [String: String], original: String, captureDate: String? = nil,
                                     today: Day = .today()) -> String {
        let fields = normalize(raw)
        var docType = value(fields, "type")
        if docType.lowercased().hasPrefix("photo ou") { docType = "Photo" }  // model echoed "Photo ou Capture écran"
        docType = fixCase(docType, sentence: true).upperFirst
        var issuer = fixCase(value(fields, "issuer"))
        issuer = doctor.sub(issuer, "Dr ")
        issuer = issuer.pySplit.map { w in
            acronyms.contains(w.uppercased()) && !brands.contains(w.uppercased()) ? w.uppercased() : w
        }.joined(separator: " ")
        var detail = fixCase(value(fields, "detail"), sentence: true).upperFirst
        let lowerType = docType.lowercased()
        let amount = amountTypes.contains { lowerType.contains($0) } ? parseAmount(fields["amount"] ?? "") : nil

        // Don't repeat what is already said: "Facture EDF - EDF".
        if !detail.isEmpty && "\(docType) \(issuer)".lowercased().contains(detail.lowercased()) { detail = "" }

        let rawDate = (fields["date"] ?? "").pyStrip
        var modelDate: String? = dateISO.test(rawDate) ? rawDate : nil
        if let md = modelDate {
            // An issue date can't be in the future: deadline or misread.
            if let day = Day(iso: md) { if day > today { modelDate = nil } } else { modelDate = nil }
        }
        let date: String?
        let stem = original.pySplitExt.0
        if let m = datePrefix.first(stem) {
            date = m.group(1, in: stem)  // already dated by hand or a previous run: keep it
        } else if let captureDate, !documentTypes.contains(where: { lowerType.contains($0) }) {
            date = captureDate  // photo/screenshot: printed dates (posters, ads) aren't the file's date
        } else {
            date = modelDate ?? captureDate
        }

        let prefix = date.map { "\($0) - " } ?? ""
        let suffix = amount.map { " - \($0)" } ?? ""
        var head = [docType, issuer].filter { !$0.isEmpty }.joined(separator: " ")
        if head.isEmpty { head = "Document" }

        let room = maxName - prefix.pyLen - suffix.pyLen
        if head.pyLen > room - 10 {
            let t = trimWords(head, room - 10)
            head = t.isEmpty ? head.pySlice(nil, room - 10) : t
        }
        if !detail.isEmpty && head.pyLen + 3 + detail.pyLen > room {  // shorten the detail first, never mid-word
            detail = trimWords(detail, room - head.pyLen - 3)
        }
        var name = detail.isEmpty ? head : "\(head) - \(detail)"
        if name.pyLen > room { name = trimWords(name, room) }
        return prefix + name + suffix
    }

    // MARK: Issuer cleanup (before buildFilename, which stays the Python script's port)

    /// A legal form at either end of a company name: "Amazon EU S.à r.l.", "SAS Le Petit Café",
    /// "Shenzhen … Mao Yi You Xian Gong Si" (pinyin for "Trading Co., Ltd.").
    static let legalForm = #"(?:s\.?\s?à\.?\s?r\.?\s?l\.?|sàrl|s\.?a\.?(?:s\.?(?:u\.?)?|r\.?l\.?)?|e\.?u\.?r\.?l\.?|s\.?n\.?c\.?|s\.?c\.?i\.?|selarl|s\.?c\.?p\.?|gmbh|ag|ltd\.?|limited|inc\.?|llc|plc|b\.?v\.?|n\.?v\.?|s\.?p\.?a\.?|s\.?l\.?|co\.?|corp\.?|you xian gong si|gong si|co\.?,? ltd\.?)"#
    static let trailingForm = Rx(#"(?:[\s,&]+"# + legalForm + #")+\s*$"#, [.caseInsensitive])
    static let leadingForm = Rx(#"^\s*"# + legalForm + #"\s+(?=\S)"#, [.caseInsensitive])
    /// A registration number taken for a name: "SIRET 247 428 493 19087".
    static let registration = Rx(#"^\s*(?:siret|siren|tva|n°|rcs)\b"#, [.caseInsensitive])

    /// Administrations by their usual short name: "Direction générale des finances publiques" is
    /// "Finances publiques", "Caisse primaire d'assurance maladie du Rhône" is "CPAM du Rhône".
    static let administrations: [(Rx, String)] = [
        (Rx(#"^(?:direction g[ée]n[ée]rale des finances publiques|dgfip|centre des finances publiques|service des imp[ôo]ts des (?:particuliers|entreprises)|sip|sie)\b.*"#, [.caseInsensitive]), "Finances publiques"),
        (Rx(#"^caisse primaire d.assurance maladie"#, [.caseInsensitive]), "CPAM"),
        (Rx(#"^caisse d.allocations familiales"#, [.caseInsensitive]), "CAF"),
        (Rx(#"^union de recouvrement des cotisations.*"#, [.caseInsensitive]), "URSSAF"),
        (Rx(#"^caisse d.assurance retraite et de la sant[ée] au travail"#, [.caseInsensitive]), "CARSAT"),
    ]

    /// Monthly documents (payslip, statement) named by their month: the model tends to pick a
    /// line ("Salaire de base", "Solde précédent"). The month of the period's end ("du 01/09/2026
    /// au 30/09/2026"), else of the date.
    static let monthly = ["Bulletin de paie", "Relevé de compte", "Relevé de prestations"]
    static let period = Rx(#"\bdu\s+\d{1,2}[/.]\d{1,2}[/.]\d{2,4}\s+au\s+(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})"#, [.caseInsensitive])
    static let months = ["Janvier", "Février", "Mars", "Avril", "Mai", "Juin", "Juillet", "Août",
                         "Septembre", "Octobre", "Novembre", "Décembre"]

    static func monthDetail(date: String?, text: String?) -> String? {
        if let text, let m = period.first(text), let mo = Int(m.group(2, in: text) ?? ""), (1...12).contains(mo),
           var y = Int(m.group(3, in: text) ?? "") {
            if y < 100 { y += 2000 }
            return "\(months[mo - 1]) \(y)"
        }
        guard let date, let day = Day(iso: date) else { return nil }
        let parts = day.iso.split(separator: "-")
        guard let mo = Int(parts[1]) else { return nil }
        return "\(months[mo - 1]) \(parts[0])"
    }

    /// The model's fields with a cleaner issuer: no legal form, an administration's usual name,
    /// and never one of the user's own names (on their documents they are the recipient). A
    /// monthly document's detail is its month (`text`: the document's, to read the period).
    public static func cleanFields(_ raw: [String: String], myNames: [String] = [], text: String? = nil) -> [String: String] {
        var fields = raw
        if let type = raw["type"], monthly.contains(type),
           let month = monthDetail(date: raw["date"].flatMap { dateISO.test($0) ? $0 : nil }, text: text) {
            fields["detail"] = month
        }
        guard var issuer = raw["issuer"]?.trimmingCharacters(in: .whitespacesAndNewlines), !issuer.isEmpty else { return fields }
        issuer = leadingForm.sub(trailingForm.sub(issuer, ""), "").trimmingCharacters(in: .whitespaces)
        for (re, short) in administrations {
            if let m = re.first(issuer) {
                let rest = (issuer as NSString).substring(from: m.range.location + m.range.length)
                issuer = short == "Finances publiques" ? short : short + rest
                break
            }
        }
        if isOneOf(issuer, myNames) { issuer = "aucun" }
        if registration.test(issuer) { issuer = "aucun" }
        fields["issuer"] = issuer.isEmpty ? "aucun" : issuer
        if let detail = fields["detail"] { fields["detail"] = without(myNames, in: detail) }
        return fields
    }

    /// "Forfait mobile Level UP" → "Forfait mobile": two words or more in a row from one of the
    /// user's names (or one alone if it is the whole name) say who received it, not what it is.
    static func without(_ names: [String], in detail: String) -> String {
        func fold(_ s: Substring) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
        }
        var words = detail.split(separator: " ")
        for name in names {
            let mine = Set(name.split { !$0.isLetter && !$0.isNumber }.map(fold))
            guard !mine.isEmpty else { continue }
            var i = 0
            while i < words.count {
                var j = i
                while j < words.count, mine.contains(fold(words[j])), !fold(words[j]).isEmpty { j += 1 }
                if j - i >= min(2, mine.count) { words.removeSubrange(i..<j) } else { i = max(j, i + 1) }
            }
        }
        return words.joined(separator: " ")
    }

    /// "Martin Conseil" is also "MARTIN CONSEIL SAS" and "Martin conseil": the words of one are all
    /// among the other's, case and accents aside. Whole words: "Orange" is not "Orangerie".
    static func isOneOf(_ issuer: String, _ names: [String]) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let i = words(issuer)
        guard !i.isEmpty else { return false }
        return names.map(words).contains { n in !n.isEmpty && (n.isSubset(of: i) || i.isSubset(of: n)) }
    }

    /// Short labels for the UI chips: type, date, amount.
    public static func chips(_ raw: [String: String]) -> [String] {
        let f = normalize(raw)
        var out: [String] = []
        let t = value(f, "type")
        if !t.isEmpty { out.append(fixCase(t, sentence: true).upperFirst) }
        if let d = f["date"], let day = Day(iso: d) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "fr_FR")
            fmt.dateFormat = "d MMM yyyy"
            out.append(fmt.string(from: day.date()))
        }
        if amountTypes.contains(where: { t.lowercased().contains($0) }), let a = parseAmount(f["amount"] ?? "") {
            out.append(a)
        }
        return out
    }
}
