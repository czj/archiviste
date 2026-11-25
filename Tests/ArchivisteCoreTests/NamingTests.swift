import Foundation
import Testing
@testable import ArchivisteCore

// The issuer cleanup the model's answer gets before `buildFilename` (which ParityTests pins
// to the Python script): seen on real files in ~/Downloads.

@Test(arguments: [
    ("Amazon EU S.à r.l.", "Amazon EU"),
    ("Amazon EU Sàrl", "Amazon EU"),
    ("SAS Le Petit Café", "Le Petit Café"),
    ("Orange SA", "Orange"),
    ("Shenzhen Ke Chuang Mao Yi You Xian Gong Si", "Shenzhen Ke Chuang Mao Yi"),
    ("Acme Co., Ltd.", "Acme"),
    ("Dr Martin", "Dr Martin"),
    ("Saint-Gobain", "Saint-Gobain"),  // "Sa…" inside a word is not a legal form
    ("Klein Charpentier S.A.", "Klein Charpentier"),
    ("Charrier Brunet S.A.R.L.", "Charrier Brunet"),
    ("LEBLANC SAS", "LEBLANC"),
    ("Leblanc S.A.S.U.", "Leblanc"),
    ("SIRET 247 428 493 19087", "aucun"),
    ("SA", "SA"),  // a form alone is left: nothing better to show
])
func `formes juridiques retirées de l’émetteur`(issuer: String, expected: String) {
    #expect(Naming.cleanFields(["issuer": issuer])["issuer"] == expected)
}

@Test func `mes noms ne sont jamais l’émetteur`() {
    let mine = ["Clémence Martin", "Martin Conseil Solutions"]
    #expect(Naming.cleanFields(["issuer": "MARTIN CONSEIL SOLUTIONS SAS"], myNames: mine)["issuer"] == "aucun")
    #expect(Naming.cleanFields(["issuer": "Martin Conseil"], myNames: mine)["issuer"] == "aucun")
    #expect(Naming.cleanFields(["issuer": "Clemence Martin"], myNames: mine)["issuer"] == "aucun")
    #expect(Naming.cleanFields(["issuer": "Kiné Durand"], myNames: mine)["issuer"] == "Kiné Durand")
    #expect(Naming.cleanFields(["issuer": "Orange"], myNames: ["Orangerie du Parc"])["issuer"] == "Orange")
}

@Test func `mes noms retirés du détail`() {
    let mine = ["Clémence Martin", "Martin Conseil Solutions"]
    #expect(Naming.cleanFields(["issuer": "Nuage", "detail": "Forfait mobile Martin Conseil"], myNames: mine)["detail"]
            == "Forfait mobile")
    #expect(Naming.cleanFields(["issuer": "Nuage", "detail": "Abonnement de Clémence MARTIN"], myNames: mine)["detail"]
            == "Abonnement de")
    // One word alone stays: "Conseil juridique" is about advice, not about the user.
    #expect(Naming.cleanFields(["issuer": "Cabinet Roux", "detail": "Conseil juridique"], myNames: mine)["detail"]
            == "Conseil juridique")
}

@Test(arguments: [
    ("Direction Générale des Finances Publiques", "Finances publiques"),
    ("SIP de Lyon 3e", "Finances publiques"),
    ("Caisse primaire d'assurance maladie du Rhône", "CPAM du Rhône"),
    ("Caisse d'allocations familiales du Rhône", "CAF du Rhône"),
    ("Sipelia Conseil", "Sipelia Conseil"),  // "Sip…" in a word is not the tax office
])
func `administrations sous leur nom usuel`(issuer: String, expected: String) {
    #expect(Naming.cleanFields(["issuer": issuer])["issuer"] == expected)
}

@Test func `fiche de paie et relevé : le mois comme détail`() {
    let pay = Naming.cleanFields(["type": "Bulletin de paie", "issuer": "Alpine", "date": "2026-09-30",
                                  "detail": "Salaire de base"], text: "Période du 01/09/2026 au 30/09/2026")
    #expect(pay["detail"] == "Septembre 2026")
    let bank = Naming.cleanFields(["type": "Relevé de compte", "issuer": "Banque", "date": "2026-11-02",
                                   "detail": "Solde précédent"], text: "Relevé du 01/10/26 au 31/10/26")
    #expect(bank["detail"] == "Octobre 2026")
    let noPeriod = Naming.cleanFields(["type": "Bulletin de paie", "issuer": "Alpine", "date": "2026-08-31",
                                       "detail": "Salaire"], text: "Net à payer")
    #expect(noPeriod["detail"] == "Août 2026")
    let invoice = Naming.cleanFields(["type": "Facture", "issuer": "Nuage", "date": "2026-08-31", "detail": "Fibre"])
    #expect(invoice["detail"] == "Fibre")
}

@Test func `un nom de fichier relu en champs (stratégie filename)`() {
    let f = Naming.parseName("2025-03-14 - Relevé de compte Banque Rhodanienne - Octobre 2025", types: Config.types)
    #expect(f["date"] == "2025-03-14")
    #expect(f["type"] == "Relevé de compte")
    #expect(f["issuer"] == "Banque Rhodanienne")
    #expect(f["detail"] == "Octobre 2025")
    #expect(f["amount"] == "aucun")
    let g = Naming.parseName("2026-11-18 - Facture Amazon - Stream Deck - 88.00 EUR", types: Config.types)
    #expect(g["amount"] == "88.00 EUR")
    #expect(g["detail"] == "Stream Deck")
}

@Test func `stratégies : lues depuis la ligne de commande`() {
    #expect(Strategy("baseline") == .baseline)
    #expect(Strategy("reasoning+twoPass")?.description == "reasoning+twoPass")
    #expect(Strategy("nimportequoi") == nil)
    #expect(Strategy.app.description == "reasoning+twoPass+headTail+guards+blend")
}

@Test func `nom complet : émetteur nettoyé, le reste intact`() {
    let fields = Naming.cleanFields(["type": "Facture", "issuer": "Amazon EU S.à r.l.", "date": "2026-11-18",
                                     "detail": "Elgato Stream Deck Neo", "amount": "88.00 EUR"])
    #expect(Naming.buildFilename(fields, original: "invoice3.pdf", today: Day(iso: "2026-11-25")!)
            == "2026-11-18 - Facture Amazon EU - Elgato Stream Deck Neo - 88.00 EUR")
}
