import Foundation
import FoundationModels

public enum EngineError: LocalizedError {
    case unavailable(String)
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Modèle Apple indisponible (\(reason)). Réglages → Apple Intelligence et Siri doit être activé."
        case .model(let msg): "modèle Apple : \(msg)"
        }
    }
}

/// Apple's on-device model (FoundationModels) filling a constrained form.
/// A plain value: each request gets its own session, so there is no shared state to protect.
public struct Engine: Sendable {
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 250)

    public init() throws(EngineError) {
        guard case .available = model.availability else { throw .unavailable("\(model.availability)") }
    }

    struct Field: Sendable { let name: String, description: String, choices: [String]? }

    enum Failure: Error {
        case context(String), guardrail(String), other(String)

        /// Worth retrying with less input (no image, shorter text).
        var isRetryable: Bool { if case .other = self { false } else { true } }
        var message: String {
            switch self { case .context(let m), .guardrail(let m), .other(let m): m }
        }
    }

    /// Types the model gives too readily: one of these words must be in the text for them to stand.
    static let typeWords: [String: [String]] = [
        "Avoir": ["avoir", "credit note", "rembours", "annul"],
        "Note de frais": ["note de frais", "frais professionnels", "état de frais", "expense"],
    ]

    /// The model's fields (type, issuer, date, detail, amount) for one extracted file.
    /// `myNames`: the user's own names, the recipient on their documents, never the issuer.
    /// `strategy`: how to ask (see Strategy); the app uses `.baseline`.
    public func ask(_ ex: Extracted, isImage: Bool, myNames: [String] = [],
                    strategy: Strategy = .baseline) async throws -> [String: String] {
        try await ask(ex, isImage: isImage, myNames: myNames, strategy: strategy, only: nil)
    }

    /// `only`: the baseline fields to ask for (the type always comes first, it guides the rest).
    func ask(_ ex: Extracted, isImage: Bool, myNames: [String], strategy: Strategy,
             only: Set<String>?) async throws -> [String: String] {
        // textOnly: the image is dropped here, once, so every path below works without it.
        let ex = strategy.textOnly && ex.text != nil ? Extracted(text: ex.text, captureDate: ex.captureDate) : ex
        var strategy = strategy
        strategy.textOnly = false
        if strategy.blend {
            var own = strategy
            own.blend = false
            // Both at once: the model serves concurrent sessions, so the amount comes almost free.
            async let base = try? ask(ex, isImage: isImage, myNames: myNames, strategy: .baseline, only: ["amount"])
            var fields = try await ask(ex, isImage: isImage, myNames: myNames, strategy: own)
            if let base = await base { fields["amount"] = base["amount"] }
            return fields
        }
        var imageURL: URL?
        if let png = ex.imagePNG {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("archiviste-\(UUID().uuidString).png")
            try png.write(to: url)
            imageURL = url
        }
        defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }

        if strategy != .baseline {
            // Same fallback as below: without the page image if the model refuses it or overflows.
            do {
                return try await ask(ex, isImage: isImage, myNames: myNames, strategy: strategy, imageURL: imageURL)
            } catch let failure as Failure where failure.isRetryable && imageURL != nil {
                return try await ask(ex, isImage: isImage, myNames: myNames, strategy: strategy, imageURL: nil)
            } catch let failure as Failure {
                throw EngineError.model(failure.message)
            }
        }

        let text = ex.text ?? ""
        let dates = Candidates.dates(text), amounts = Candidates.amounts(text)
        let fields = [
            Field(name: "type", description: "Nature du document",
                  choices: isImage ? Config.imageTypes : Config.types),
            Field(name: "issuer", description: "Qui a écrit le document, forme courte, ou aucun", choices: nil),
            Field(name: "date", description: "Date d'émission du document (AAAA-MM-JJ), ou aucun",
                  choices: dates.isEmpty ? nil : dates + ["aucun"]),
            Field(name: "detail", description: "2 à 6 mots sur l'objet précis", choices: nil),
            Field(name: "amount", description: "Montant total TTC (factures, reçus, devis...), ou aucun",
                  choices: amounts + ["aucun"]),
        ].filter { $0.name == "type" || only?.contains($0.name) != false }
        var instructions = isImage ? Config.imageInstructions : Config.instructions
        if !myNames.isEmpty {
            instructions += "\n\nLe destinataire de ces documents est \(myNames.joined(separator: ", ")) : "
                + "JAMAIS l'issuer, même s'il apparaît en haut de la page ; prends l'autre partie."
        }
        let body = ex.text?.pyStrip ?? "(aucun texte lisible, utilise l'image)"
        // Fallbacks: the model may refuse a page image or overflow its 8k context.
        let attempts: [(URL?, String)] = switch (imageURL, ex.text) {
        case (.some, nil): [(imageURL, body)]
        case (.some, _): [(imageURL, body), (nil, body), (nil, body.pySlice(nil, 2000))]
        case (nil, _): [(nil, body), (nil, body.pySlice(nil, 2000))]
        }

        var last = "?"
        for (image, txt) in attempts {
            do {
                let prompt = "Texte du document:\n---\n\(txt)\n---"
                let answer = try await respond(instructions: instructions, prompt: prompt, image: image, fields: fields)
                // A type whose own words are nowhere in the text (an attestation answered "Avoir"):
                // asked again without it. Only with a text to check against.
                guard let type = answer["type"], let words = Self.typeWords[type], ex.text != nil,
                      !words.contains(where: { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }),
                      let i = fields.firstIndex(where: { $0.name == "type" }), let choices = fields[i].choices
                else { return answer }
                var narrowed = fields
                narrowed[i] = Field(name: "type", description: fields[i].description, choices: choices.filter { $0 != type })
                return (try? await respond(instructions: instructions, prompt: prompt, image: image, fields: narrowed)) ?? answer
            } catch {
                last = error.message
                if !error.isRetryable { break }
            }
        }
        throw EngineError.model(last)
    }

    func respond(instructions: String, prompt: String, image: URL?, fields: [Field]) async throws(Failure) -> [String: String] {
        do {
            let properties = fields.map { f in
                DynamicGenerationSchema.Property(
                    name: f.name, description: f.description,
                    schema: f.choices.map { DynamicGenerationSchema(type: String.self, guides: [.anyOf($0)]) }
                        ?? DynamicGenerationSchema(type: String.self))
            }
            let schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "Document", properties: properties), dependencies: [])
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response: LanguageModelSession.Response<GeneratedContent>
            if let image {
                response = try await session.respond(schema: schema, options: options) {
                    Attachment(imageURL: image)
                    prompt
                }
            } else {
                response = try await session.respond(to: prompt, schema: schema, options: options)
            }
            return Dictionary(uniqueKeysWithValues: fields.map { f in
                (f.name, (try? response.content.value(String.self, forProperty: f.name)) ?? "aucun")
            })
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded: throw .context("\(error)")
            case .guardrailViolation, .refusal, .unsupportedTranscriptContent: throw .guardrail("\(error)")
            default: throw .other("\(error)")
            }
        } catch {
            throw .other("\(error)")
        }
    }
}
