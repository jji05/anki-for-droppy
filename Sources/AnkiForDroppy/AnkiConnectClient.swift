import Foundation

package struct AnkiDeck: Identifiable, Equatable, Sendable {
    package var id: String { name }
    package let name: String
    package let newCount: Int?
    package let learningCount: Int?
    package let reviewCount: Int?
    package let countsAreFromSearch: Bool

    package init(name: String, newCount: Int? = nil, learningCount: Int? = nil, reviewCount: Int? = nil,
                 countsAreFromSearch: Bool = false) {
        self.name = name
        self.newCount = newCount.map { min(1_000_000_000, max(0, $0)) }
        self.learningCount = learningCount.map { min(1_000_000_000, max(0, $0)) }
        self.reviewCount = reviewCount.map { min(1_000_000_000, max(0, $0)) }
        self.countsAreFromSearch = countsAreFromSearch
    }
}

package struct AnkiRating: Identifiable, Equatable, Sendable {
    package var id: Int { ease }
    package let ease: Int
    package let title: String
    package let interval: String
}

package struct AnkiCard: Decodable, Equatable, Sendable {
    package let cardId: Int64
    package let question: String
    package let answer: String
    package let css: String
    package let deckName: String
    package let buttons: [Int]
    package let nextReviews: [String]
    package let fields: [String: Field]

    package struct Field: Decodable, Equatable, Sendable {
        package let value: String
        package init(value: String) { self.value = value }
    }

    package init(cardId: Int64, question: String, answer: String, css: String = "", deckName: String,
                 buttons: [Int] = [1, 2, 3, 4], nextReviews: [String] = [], fields: [String: Field] = [:]) {
        self.cardId = cardId
        self.question = question
        self.answer = answer
        self.css = css
        self.deckName = deckName
        self.buttons = buttons
        self.nextReviews = nextReviews
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case cardId, question, answer, css, deckName, buttons, nextReviews, fields
    }

    package init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cardId = try values.decode(Int64.self, forKey: .cardId)
        question = try values.decode(String.self, forKey: .question)
        answer = try values.decode(String.self, forKey: .answer)
        css = try values.decodeIfPresent(String.self, forKey: .css) ?? ""
        deckName = try values.decode(String.self, forKey: .deckName)
        buttons = try values.decode([Int].self, forKey: .buttons)
        nextReviews = try values.decodeIfPresent([String].self, forKey: .nextReviews) ?? []
        fields = try values.decodeIfPresent([String: Field].self, forKey: .fields) ?? [:]
        guard cardId > 0 else { throw AnkiError.invalidResponse }
    }

    package var ratings: [AnkiRating] {
        let titles: [String]
        switch buttons {
        case [1, 2]: titles = ["Again", "Good"]
        case [1, 2, 3]: titles = ["Again", "Good", "Easy"]
        case [1, 2, 3, 4]: titles = ["Again", "Hard", "Good", "Easy"]
        default: return []
        }
        return zip(buttons, titles).enumerated().map { index, pair in
            AnkiRating(ease: pair.0, title: pair.1, interval: nextReviews.indices.contains(index) ? nextReviews[index] : "")
        }
    }
}

package struct AnkiReview: Decodable, Equatable, Sendable {
    package let id: Int64
    package let ease: Int
    package init(id: Int64, ease: Int) { self.id = id; self.ease = ease }
}

package enum AnkiError: Error, Equatable, Sendable {
    case unavailable
    case authorization
    case permissionDenied
    case incompatible
    case invalidResponse
    case rejected
    case changedCard
    case missingDeck
    case uncertainGrade
    case missingMedia
    case oversizedContent
    case invalidMediaName
    case redirected
    case server

    package var message: String {
        switch self {
        case .unavailable: "Open Anki with AnkiConnect installed, then connect again."
        case .authorization: "Enter the API key from your AnkiConnect configuration in settings."
        case .permissionDenied: "Allow network access for this droplet in Droppy, then connect again."
        case .incompatible: "Update AnkiConnect. This version is missing required review actions."
        case .invalidResponse: "AnkiConnect returned an unexpected response. Check the add-on and reconnect."
        case .rejected: "Anki did not accept that action. Refresh the review or continue in Anki."
        case .changedCard: "The active card changed in Anki. Refresh before continuing; use only one reviewer at a time."
        case .missingDeck: "That deck no longer exists. Refresh and choose an existing deck."
        case .uncertainGrade: "Your rating may have been saved. Check its status before reviewing again."
        case .missingMedia: "Some card media is unavailable. Open this card in Anki."
        case .oversizedContent: "This card or media is too large to display here. Open it in Anki."
        case .invalidMediaName: "This media reference is not supported. Open the card in Anki."
        case .redirected: "The local connection redirected unexpectedly. Check your AnkiConnect port."
        case .server: "Anki could not complete that action. Check Anki and try refreshing."
        }
    }
}

package protocol AnkiReviewing: Sendable {
    func decks() async throws -> [AnkiDeck]
    func start(deck: String) async throws -> AnkiCard?
    func currentCard() async throws -> AnkiCard?
    func showQuestion(cardID: Int64) async throws -> AnkiCard
    func showAnswer(cardID: Int64) async throws -> AnkiCard
    func resetTimer() async throws
    func answer(cardID: Int64, ease: Int) async throws
    func reviews(cardID: Int64) async throws -> [AnkiReview]
    func media(named filename: String) async throws -> Data
    func cancel()
}

package actor AnkiConnectClient: AnkiReviewing {
    package static let requiredActions: Set<String> = [
        "deckNames", "getDeckStats", "guiDeckReview", "guiCurrentCard", "guiShowQuestion",
        "guiShowAnswer", "guiAnswerCard", "guiStartCardTimer", "getReviewsOfCards", "retrieveMediaFile"
    ]
    package static let maximumMediaBytes = 12 * 1_024 * 1_024
    private static let maximumResponseBytes = 20 * 1_024 * 1_024

    private let endpoint: URL
    private let key: String
    private nonisolated let session: URLSession
    private let redirectDelegate: RedirectBlocker

    package init(port: Int = 8765, key: String = "", session: URLSession? = nil) {
        endpoint = URL(string: "http://127.0.0.1:\((1...65535).contains(port) ? port : 8765)/")!
        self.key = key
        let delegate = RedirectBlocker()
        redirectDelegate = delegate
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 8
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    package nonisolated func cancel() { session.invalidateAndCancel() }

    package func decks() async throws -> [AnkiDeck] {
        let permission: Permission = try await request("requestPermission")
        guard permission.permission == "granted" else { throw AnkiError.authorization }
        if permission.needsKey && key.isEmpty { throw AnkiError.authorization }
        let version: Int = try await request("version")
        guard version >= 6 else { throw AnkiError.incompatible }
        let reflection: Reflection = try await request("apiReflect", parameters: .reflect)
        guard Self.requiredActions.isSubset(of: Set(reflection.actions)) else { throw AnkiError.incompatible }
        let names: [String] = try await request("deckNames")
        guard names.count <= 5_000, Set(names).count == names.count else { throw AnkiError.invalidResponse }
        guard !names.isEmpty else { return [] }
        let stats: [String: DeckStats]
        do {
            stats = try await request("getDeckStats", parameters: .decks(names))
        } catch RequestFailure.unavailableDeckCounts {
            stats = [:]
        }
        var statsByName = Dictionary(stats.values.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        if names.count > 1 {
            for name in names where statsByName[name] == nil {
                do {
                    let recovered: [String: DeckStats] = try await request("getDeckStats", parameters: .decks([name]))
                    if let counts = recovered.values.first(where: { $0.name == name }) {
                        statsByName[name] = counts
                    }
                } catch RequestFailure.unavailableDeckCounts {}
            }
        }
        let deckIDs: [String: Int64]
        if names.contains(where: { statsByName[$0] == nil }),
           Set(["deckNamesAndIds", "findCards"]).isSubset(of: Set(reflection.actions)) {
            deckIDs = try await request("deckNamesAndIds")
            guard deckIDs.count <= 5_000, deckIDs.values.allSatisfy({ $0 > 0 }),
                  Set(deckIDs.values).count == deckIDs.count else { throw AnkiError.invalidResponse }
        } else {
            deckIDs = [:]
        }
        var decks: [AnkiDeck] = []
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if let counts = statsByName[name] {
                decks.append(AnkiDeck(name: name, newCount: counts.new_count,
                    learningCount: counts.learn_count, reviewCount: counts.review_count))
            } else if deckIDs[name] != nil {
                let ids = deckIDs.filter { $0.key == name || $0.key.hasPrefix(name + "::") }
                    .values.sorted().map(String.init).joined(separator: ",")
                let scope = "did:\(ids) -is:suspended -is:buried"
                let learningCount = try await cardCount(query: "\(scope) is:learn is:due")
                let reviewCount = try await cardCount(query: "\(scope) is:review -is:learn is:due")
                decks.append(AnkiDeck(name: name,
                    learningCount: learningCount, reviewCount: reviewCount, countsAreFromSearch: true))
            } else {
                decks.append(AnkiDeck(name: name))
            }
        }
        return decks
    }

    private func cardCount(query: String) async throws -> Int {
        let cards: [Int64] = try await request("findCards", parameters: .query(query))
        guard cards.allSatisfy({ $0 > 0 }), Set(cards).count == cards.count else {
            throw AnkiError.invalidResponse
        }
        return cards.count
    }

    package func start(deck: String) async throws -> AnkiCard? {
        let names: [String] = try await request("deckNames")
        guard names.contains(deck) else { throw AnkiError.missingDeck }
        let started: Bool = try await request("guiDeckReview", parameters: .name(deck))
        guard started else { throw AnkiError.rejected }
        return try await currentCard()
    }

    package func currentCard() async throws -> AnkiCard? {
        do {
            return try await request("guiCurrentCard") as AnkiCard?
        } catch RequestFailure.inactiveReviewer {
            return nil
        }
    }

    package func showQuestion(cardID: Int64) async throws -> AnkiCard {
        try await requireCard(cardID)
        let accepted: Bool = try await request("guiShowQuestion")
        guard accepted else { throw AnkiError.rejected }
        return try await requireCard(cardID)
    }

    package func showAnswer(cardID: Int64) async throws -> AnkiCard {
        try await requireCard(cardID)
        let accepted: Bool = try await request("guiShowAnswer")
        guard accepted else { throw AnkiError.rejected }
        return try await requireCard(cardID)
    }

    package func resetTimer() async throws {
        let accepted: Bool = try await request("guiStartCardTimer")
        guard accepted else { throw AnkiError.rejected }
    }

    package func answer(cardID: Int64, ease: Int) async throws {
        let card = try await requireCard(cardID)
        guard card.ratings.contains(where: { $0.ease == ease }) else { throw AnkiError.rejected }
        try Task.checkCancellation()
        do {
            let accepted: Bool = try await request("guiAnswerCard", parameters: .ease(ease))
            guard accepted else { throw AnkiError.rejected }
        } catch AnkiError.rejected {
            throw AnkiError.rejected
        } catch {
            throw AnkiError.uncertainGrade
        }
    }

    package func reviews(cardID: Int64) async throws -> [AnkiReview] {
        let history: [String: [AnkiReview]] = try await request("getReviewsOfCards", parameters: .cards([cardID]))
        guard let reviews = history[String(cardID)] else { throw AnkiError.invalidResponse }
        return reviews
    }

    package func media(named filename: String) async throws -> Data {
        guard Self.isSafeMediaName(filename) else { throw AnkiError.invalidMediaName }
        let response: MediaResponse = try await request("retrieveMediaFile", parameters: .filename(filename))
        guard let data = response.data else { throw AnkiError.missingMedia }
        guard data.count <= Self.maximumMediaBytes else { throw AnkiError.oversizedContent }
        return data
    }

    package nonisolated static func isSafeMediaName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1_024 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    @discardableResult
    private func requireCard(_ id: Int64) async throws -> AnkiCard {
        guard let card = try await currentCard(), card.cardId == id else { throw AnkiError.changedCard }
        return card
    }

    private func request<Value: Decodable & Sendable>(_ action: String, parameters: Parameters = .empty) async throws -> Value {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(action: action, params: parameters, key: key.isEmpty ? nil : key))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AnkiError.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AnkiError.invalidResponse }
        if (300...399).contains(http.statusCode) { throw AnkiError.redirected }
        if http.statusCode == 401 || http.statusCode == 403 { throw AnkiError.authorization }
        guard http.statusCode == 200 else { throw AnkiError.server }
        guard response.url == endpoint else { throw AnkiError.redirected }
        guard data.count <= Self.maximumResponseBytes else { throw AnkiError.oversizedContent }
        let envelope: Envelope<Value>
        do { envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data) }
        catch let error as AnkiError { throw error }
        catch { throw AnkiError.invalidResponse }
        if let error = envelope.error {
            let message = error.lowercased()
            if message.contains("review is not currently active") { throw RequestFailure.inactiveReviewer }
            if message.contains("key") || message.contains("permission") || message.contains("unauthorized") {
                throw AnkiError.authorization
            }
            if message.contains("unsupported action") { throw AnkiError.incompatible }
            if action == "getDeckStats", message == "deck counts unavailable." {
                throw RequestFailure.unavailableDeckCounts
            }
            throw AnkiError.server
        }
        guard envelope.hasResult else { throw AnkiError.invalidResponse }
        return try envelope.value()
    }

    private enum RequestFailure: Error { case inactiveReviewer, unavailableDeckCounts }

    private struct Request: Encodable {
        let action: String
        let version = 6
        let params: Parameters
        let key: String?
    }

    private enum Parameters: Encodable {
        case empty, reflect, decks([String]), name(String), ease(Int), cards([Int64]), filename(String), query(String)
        private enum Keys: String, CodingKey { case scopes, decks, name, ease, cards, filename, query }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: Keys.self)
            switch self {
            case .empty: break
            case .reflect: try values.encode(["actions"], forKey: .scopes)
            case .decks(let names): try values.encode(names, forKey: .decks)
            case .name(let name): try values.encode(name, forKey: .name)
            case .ease(let ease): try values.encode(ease, forKey: .ease)
            case .cards(let cards): try values.encode(cards, forKey: .cards)
            case .filename(let filename): try values.encode(filename, forKey: .filename)
            case .query(let query): try values.encode(query, forKey: .query)
            }
        }
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let result: Value?
        let error: String?
        let hasResult: Bool
        private enum Keys: String, CodingKey { case result, error }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Keys.self)
            guard values.contains(.error) else { throw AnkiError.invalidResponse }
            error = try values.decodeIfPresent(String.self, forKey: .error)
            hasResult = values.contains(.result)
            if error == nil && hasResult {
                result = .some(try values.decode(Value.self, forKey: .result))
            } else {
                result = nil
            }
        }
        func value() throws -> Value {
            guard let result else { throw AnkiError.invalidResponse }
            return result
        }
    }

    private struct Permission: Decodable, Sendable {
        let permission: String
        let requireApikey: Bool?
        let requireApiKey: Bool?
        var needsKey: Bool { requireApikey == true || requireApiKey == true }
    }
    private struct Reflection: Decodable, Sendable { let actions: [String] }
    private struct DeckStats: Decodable, Sendable {
        let name: String
        let new_count: Int
        let learn_count: Int
        let review_count: Int
    }
    private struct MediaResponse: Decodable, Sendable {
        let data: Data?
        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let missing = try? value.decode(Bool.self), !missing { data = nil; return }
            let text = try value.decode(String.self)
            guard text.utf8.count <= AnkiConnectClient.maximumMediaBytes * 4 / 3 + 8 else {
                throw AnkiError.oversizedContent
            }
            guard let bytes = Data(base64Encoded: text) else { throw AnkiError.invalidResponse }
            data = bytes
        }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
