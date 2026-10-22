import Foundation
import Testing
@testable import AnkiForDroppy

@Suite(.serialized)
struct AnkiConnectClientTests {
    @Test func handshakeUsesVersionSixAndOnlyFreshDeckNames() async throws {
        let fixture = ClientFixture([
            .json(#"{"result":{"permission":"granted","requireApikey":true},"error":null}"#),
            .json(#"{"result":6,"error":null}"#),
            reflection(),
            .json(#"{"result":["Deck 10","Deck 2"],"error":null}"#),
            .json(#"{"result":{"123":{"name":"Deck 10","new_count":2,"learn_count":3,"review_count":4},"456":{"name":"Deck 2","new_count":-1,"learn_count":5,"review_count":6}},"error":null}"#)
        ], key: "test-only-key", port: 9876)

        let decks = try await fixture.client.decks()

        #expect(decks == [
            AnkiDeck(name: "Deck 2", newCount: 0, learningCount: 5, reviewCount: 6),
            AnkiDeck(name: "Deck 10", newCount: 2, learningCount: 3, reviewCount: 4)
        ])
        #expect(decks.allSatisfy { !$0.countsAreFromSearch })
        let requests = try fixture.requests(count: 5)
        try expectRequest(requests[0], action: "requestPermission", key: "test-only-key", port: 9876)
        try expectRequest(requests[1], action: "version", key: "test-only-key", port: 9876)
        try expectRequest(requests[2], action: "apiReflect", params: ["scopes": ["actions"]], key: "test-only-key", port: 9876)
        try expectRequest(requests[3], action: "deckNames", key: "test-only-key", port: 9876)
        try expectRequest(requests[4], action: "getDeckStats", params: ["decks": ["Deck 10", "Deck 2"]], key: "test-only-key", port: 9876)
    }

    @Test func unavailableDeckCountsUseSeparateSearches() async throws {
        let fixture = ClientFixture(handshakePrefix() + [
            .json(#"{"result":["Deck 10","Deck 2"],"error":null}"#),
            .json(#"{"result":null,"error":"Deck counts unavailable."}"#),
            .json(#"{"result":{"Deck 10":10,"Deck 2":2},"error":null}"#),
            .json(#"{"result":[],"error":null}"#),
            .json(#"{"result":[],"error":null}"#),
            .json(#"{"result":[],"error":null}"#),
            .json(#"{"result":[201,202],"error":null}"#),
            .json(#"{"result":[301],"error":null}"#),
            .json(#"{"result":[401,402,403],"error":null}"#)
        ])

        let decks = try await fixture.client.decks()

        #expect(decks == [
            AnkiDeck(name: "Deck 2", newCount: 0, learningCount: 0, reviewCount: 0, countsAreFromSearch: true),
            AnkiDeck(name: "Deck 10", newCount: 2, learningCount: 1, reviewCount: 3, countsAreFromSearch: true)
        ])
        let requests = try fixture.requests(count: 12)
        try expectRequest(requests[4], action: "getDeckStats", params: ["decks": ["Deck 10", "Deck 2"]])
        try expectRequest(requests[5], action: "deckNamesAndIds")
        for (start, ids) in [(6, "2"), (9, "10")] {
            for (offset, filter) in ["is:new", "is:learn is:due", "is:review -is:learn is:due"].enumerated() {
                try expectRequest(requests[start + offset], action: "findCards",
                    params: ["query": "did:\(ids) -is:suspended -is:buried \(filter)"])
            }
        }
    }

    @Test(arguments: ["findCards", "deckNamesAndIds"])
    func unavailableCountsRemainUnknownWithoutSearchActions(_ action: String) async throws {
        let fixture = ClientFixture([permission(), .json(#"{"result":6,"error":null}"#), reflection(omitting: action),
            .json(#"{"result":["Existing"],"error":null}"#),
            .json(#"{"result":null,"error":"Deck counts unavailable."}"#)
        ])

        let decks = try await fixture.client.decks()

        #expect(decks == [AnkiDeck(name: "Existing")])
        #expect(decks.first?.newCount == nil)
        #expect(decks.first?.learningCount == nil)
        #expect(decks.first?.reviewCount == nil)
        _ = try fixture.requests(count: 5)
    }

    @Test func missingDeckStatisticsAreNotReportedAsZero() async throws {
        let fixture = ClientFixture(handshakePrefix() + [
            .json(#"{"result":["Available","Missing"],"error":null}"#),
            .json(#"{"result":{"123":{"name":"Available","new_count":0,"learn_count":0,"review_count":0}},"error":null}"#),
            .json(#"{"result":{"Available":123,"Missing":456},"error":null}"#),
            .json(#"{"result":[101,102],"error":null}"#),
            .json(#"{"result":[201],"error":null}"#),
            .json(#"{"result":[],"error":null}"#)
        ])

        let decks = try await fixture.client.decks()

        #expect(decks == [
            AnkiDeck(name: "Available", newCount: 0, learningCount: 0, reviewCount: 0),
            AnkiDeck(name: "Missing", newCount: 2, learningCount: 1, reviewCount: 0, countsAreFromSearch: true)
        ])
        let requests = try fixture.requests(count: 9)
        try expectRequest(requests[6], action: "findCards", params: ["query": "did:456 -is:suspended -is:buried is:new"])
        try expectRequest(requests[7], action: "findCards", params: ["query": "did:456 -is:suspended -is:buried is:learn is:due"])
        try expectRequest(requests[8], action: "findCards", params: ["query": "did:456 -is:suspended -is:buried is:review -is:learn is:due"])
    }

    @Test(arguments: ["current", "filtered", #"A * _ ? \ after"#, "Quoted \"deck\"", "日本語"])
    func scheduledDueSearchUsesLiteralDeckIDsAndDescendants(_ name: String) async throws {
        let names = String(decoding: try JSONEncoder().encode([name]), as: UTF8.self)
        let ids = String(decoding: try JSONEncoder().encode([
            name: 1, name + "::Child": 2, name + "::Child::Nested": 3, name + "ish": 4
        ]), as: UTF8.self)
        let fixture = ClientFixture(handshakePrefix() + [
            .json("{\"result\":\(names),\"error\":null}"),
            .json(#"{"result":null,"error":"Deck counts unavailable."}"#),
            .json("{\"result\":\(ids),\"error\":null}"),
            .json(#"{"result":[101],"error":null}"#),
            .json(#"{"result":[201],"error":null}"#),
            .json(#"{"result":[301],"error":null}"#)
        ], key: "test-only-key", port: 9876)

        let decks = try await fixture.client.decks()

        #expect(decks == [AnkiDeck(name: name, newCount: 1, learningCount: 1, reviewCount: 1, countsAreFromSearch: true)])
        let requests = try fixture.requests(count: 9)
        try expectRequest(requests[5], action: "deckNamesAndIds", key: "test-only-key", port: 9876)
        for (offset, filter) in ["is:new", "is:learn is:due", "is:review -is:learn is:due"].enumerated() {
            try expectRequest(requests[6 + offset], action: "findCards",
                params: ["query": "did:1,2,3 -is:suspended -is:buried \(filter)"], key: "test-only-key", port: 9876)
        }
    }

    @Test func deckRemovedBeforeIDLookupRemainsUnknown() async throws {
        let fixture = ClientFixture(handshakePrefix() + [
            .json(#"{"result":["Removed"],"error":null}"#),
            .json(#"{"result":null,"error":"Deck counts unavailable."}"#),
            .json(#"{"result":{"Other":2},"error":null}"#)
        ])

        #expect(try await fixture.client.decks() == [AnkiDeck(name: "Removed")])
        _ = try fixture.requests(count: 6)
    }

    @Test(arguments: [#"{"Existing":0}"#, #"{"Existing":-1}"#, #"{"Existing":1,"Other":1}"#])
    func invalidDeckIDsCannotProduceASearch(_ result: String) async throws {
        let fixture = ClientFixture(handshakePrefix() + [
            .json(#"{"result":["Existing"],"error":null}"#),
            .json(#"{"result":null,"error":"Deck counts unavailable."}"#),
            .json("{\"result\":\(result),\"error\":null}")
        ])

        await expectError(.invalidResponse) { _ = try await fixture.client.decks() }
        _ = try fixture.requests(count: 6)
    }

    @Test(arguments: ["[0]", "[-1]", "[1,1]", "null", "false"], [0, 1, 2])
    func malformedSearchResultsAreNotCounted(_ result: String, _ completedCounts: Int) async throws {
        let fixture = ClientFixture(searchCountsPrefix(completedCounts: completedCounts)
            + [.json("{\"result\":\(result),\"error\":null}")])

        await expectError(.invalidResponse) { _ = try await fixture.client.decks() }
        _ = try fixture.requests(count: 7 + completedCounts)
    }

    @Test(arguments: ["Invalid API key", "unsupported action", "other failure"], [0, 1, 2])
    func searchErrorsAreNotReportedAsZero(_ message: String, _ completedCounts: Int) async throws {
        let fixture = ClientFixture(searchCountsPrefix(completedCounts: completedCounts)
            + [.json("{\"result\":null,\"error\":\"\(message)\"}")])
        let expected: AnkiError = switch message {
        case "Invalid API key": .authorization
        case "unsupported action": .incompatible
        default: .server
        }

        await expectError(expected) { _ = try await fixture.client.decks() }
        _ = try fixture.requests(count: 7 + completedCounts)
    }

    @Test(arguments: [0, 1, 2])
    func searchPreservesCancellation(_ completedCounts: Int) async throws {
        let fixture = ClientFixture(searchCountsPrefix(completedCounts: completedCounts) + [.failure(.cancelled)])

        await #expect(throws: CancellationError.self) { _ = try await fixture.client.decks() }
        _ = try fixture.requests(count: 7 + completedCounts)
    }

    @Test(arguments: ["Invalid API key", "unsupported action", "other failure"])
    func unrelatedStatsErrorsStillFailConnection(_ message: String) async throws {
        let fixture = ClientFixture(handshakePrefix() + [
            .json(#"{"result":["Existing"],"error":null}"#),
            .json("{\"result\":null,\"error\":\"\(message)\"}")
        ])
        let expected: AnkiError = switch message {
        case "Invalid API key": .authorization
        case "unsupported action": .incompatible
        default: .server
        }

        await expectError(expected) { _ = try await fixture.client.decks() }

        _ = try fixture.requests(count: 5)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANKI_CONNECT_LIVE_TESTS"] == "1"))
    @MainActor func liveConnectionLoadsDecksWithoutStartingAReview() async {
        let session = ReviewSession(client: AnkiConnectClient())
        session.activate(networkAllowed: true, selectedDeck: "", pendingGrade: nil)
        defer { session.deactivate() }

        session.connect()
        await session.waitUntilIdle()

        #expect(session.isConnected)
        #expect(!session.decks.isEmpty)
        #expect(session.decks.allSatisfy { $0.newCount != nil && $0.learningCount != nil && $0.reviewCount != nil })
        #expect(session.phase == .ready)
        #expect(session.message == nil)
        #expect(session.card == nil)
        #expect(!session.isReviewing)
    }

    @Test func emptyDeckListDoesNotRequestStatsOrSendAnEmptyKey() async throws {
        let fixture = ClientFixture(handshakePrefix() + [.json(#"{"result":[],"error":null}"#)])

        #expect(try await fixture.client.decks().isEmpty)

        let requests = try fixture.requests(count: 4)
        for (request, action) in zip(requests, ["requestPermission", "version", "apiReflect", "deckNames"]) {
            try expectRequest(request, action: action, params: action == "apiReflect" ? ["scopes": ["actions"]] : [:])
        }
    }

    @Test(arguments: ["denied", "requireApikey", "requireApiKey", "old-version", "missing-action", "unauthorized"])
    func handshakeStopsBeforeDeckReadsWhenAccessIsNotReady(_ scenario: String) async throws {
        let replies: [ClientReply]
        let expected: AnkiError
        switch scenario {
        case "denied":
            replies = [.json(#"{"result":{"permission":"denied"},"error":null}"#)]
            expected = .authorization
        case "requireApikey", "requireApiKey":
            replies = [.json("{\"result\":{\"permission\":\"granted\",\"\(scenario)\":true},\"error\":null}")]
            expected = .authorization
        case "old-version":
            replies = [permission(), .json(#"{"result":5,"error":null}"#)]
            expected = .incompatible
        case "missing-action":
            replies = [permission(), .json(#"{"result":6,"error":null}"#), reflection(omitting: "guiAnswerCard")]
            expected = .incompatible
        default:
            replies = [.json(#"{"result":null,"error":"Invalid API key"}"#)]
            expected = .authorization
        }
        let fixture = ClientFixture(replies)

        await expectError(expected) { _ = try await fixture.client.decks() }

        let requests = try fixture.requests(count: replies.count)
        #expect(!requests.contains { $0.action == "deckNames" || $0.action == "getDeckStats" })
    }

    @Test(arguments: [
        #"{"result":null}"#,
        #"{"error":null}"#,
        #"{"result":null,"error":42}"#,
        #"{"result":{},"error":null}"#,
        #"{"result":false,"error":null}"#,
        "[]",
        "not JSON"
    ])
    func malformedEnvelopesAreRejected(_ response: String) async throws {
        let fixture = ClientFixture([.json(response)])

        await expectError(.invalidResponse) { _ = try await fixture.client.currentCard() }

        _ = try fixture.requests(count: 1)
    }

    @Test(arguments: [
        #"{"result":null,"error":null}"#,
        #"{"result":null,"error":"review is not currently active"}"#
    ])
    func absentReviewerReturnsNoCard(_ response: String) async throws {
        let fixture = ClientFixture([.json(response)])

        #expect(try await fixture.client.currentCard() == nil)
        try expectRequest(try fixture.requests(count: 1)[0], action: "guiCurrentCard")
    }

    @Test func startChecksExistenceBeforeDispatchingDeckReview() async throws {
        let fixture = ClientFixture([
            .json(#"{"result":["Existing"],"error":null}"#),
            .json(#"{"result":true,"error":null}"#),
            cardReply()
        ])

        #expect(try await fixture.client.start(deck: "Existing")?.cardId == 42)

        let requests = try fixture.requests(count: 3)
        try expectRequest(requests[0], action: "deckNames")
        try expectRequest(requests[1], action: "guiDeckReview", params: ["name": "Existing"])
        try expectRequest(requests[2], action: "guiCurrentCard")
    }

    @Test func staleDeckIsNotCreatedOrStarted() async throws {
        let fixture = ClientFixture([.json(#"{"result":["Existing"],"error":null}"#)])

        await expectError(.missingDeck) { _ = try await fixture.client.start(deck: "Removed") }

        try expectRequest(try fixture.requests(count: 1)[0], action: "deckNames")
    }

    @Test(arguments: ["question", "answer", "grade"])
    func changedCardPreventsMutation(_ operation: String) async throws {
        let fixture = ClientFixture([cardReply(id: 43)])

        await expectError(.changedCard) {
            switch operation {
            case "question": _ = try await fixture.client.showQuestion(cardID: 42)
            case "answer": _ = try await fixture.client.showAnswer(cardID: 42)
            default: try await fixture.client.answer(cardID: 42, ease: 3)
            }
        }

        try expectRequest(try fixture.requests(count: 1)[0], action: "guiCurrentCard")
    }

    @Test(arguments: ["guiShowQuestion", "guiShowAnswer"], [Int64(42), 43])
    func revealReturnsOnlyTheExpectedCardAfterRecheckingIdentity(_ action: String, _ nextCardID: Int64) async throws {
        let fixture = ClientFixture([cardReply(), .json(#"{"result":true,"error":null}"#), cardReply(id: nextCardID)])
        let reveal = {
            if action == "guiShowQuestion" {
                return try await fixture.client.showQuestion(cardID: 42)
            }
            return try await fixture.client.showAnswer(cardID: 42)
        }

        if nextCardID == 42 {
            #expect(try await reveal().cardId == 42)
        } else {
            await expectError(.changedCard) { _ = try await reveal() }
        }

        let requests = try fixture.requests(count: 3)
        try expectRequest(requests[0], action: "guiCurrentCard")
        try expectRequest(requests[1], action: action)
        try expectRequest(requests[2], action: "guiCurrentCard")
    }

    @Test(arguments: [
        RatingCase(buttons: [1, 2], titles: ["Again", "Good"]),
        RatingCase(buttons: [1, 2, 3], titles: ["Again", "Good", "Easy"]),
        RatingCase(buttons: [1, 2, 3, 4], titles: ["Again", "Hard", "Good", "Easy"])
    ])
    private func ratingsKeepRawEaseValuesAndMatchingIntervals(_ scenario: RatingCase) async throws {
        let fixture = ClientFixture([
            cardReply(buttons: scenario.buttons),
            cardReply(buttons: scenario.buttons),
            .json(#"{"result":true,"error":null}"#)
        ])
        let card = try #require(try await fixture.client.currentCard())

        #expect(card.ratings.map(\.title) == scenario.titles)
        #expect(card.ratings.map(\.ease) == scenario.buttons)
        #expect(card.ratings.map(\.interval) == Array(["1m", "10m", "1d", "4d"].prefix(scenario.buttons.count)))
        let ease = try #require(scenario.buttons.last)
        try await fixture.client.answer(cardID: 42, ease: ease)

        let requests = try fixture.requests(count: 3)
        try expectRequest(requests[2], action: "guiAnswerCard", params: ["ease": ease])
    }

    @Test(arguments: [[1, 3], [1, 2, 3, 4]])
    func unsupportedButtonsOrEaseDoNotDispatchGrade(_ buttons: [Int]) async throws {
        let fixture = ClientFixture([cardReply(buttons: buttons)])
        let ease = buttons == [1, 3] ? 3 : 5

        await expectError(.rejected) { try await fixture.client.answer(cardID: 42, ease: ease) }

        try expectRequest(try fixture.requests(count: 1)[0], action: "guiCurrentCard")
    }

    @Test(arguments: ["timeout", "cancelled", "http", "malformed", "server-error", "false"])
    func failedGradeIsNeverRetried(_ scenario: String) async throws {
        let reply: ClientReply
        switch scenario {
        case "timeout": reply = .failure(.timedOut)
        case "cancelled": reply = .failure(.cancelled)
        case "http": reply = .json("", status: 500)
        case "malformed": reply = .json(#"{"error":null}"#)
        case "server-error": reply = .json(#"{"result":null,"error":"failed to answer"}"#)
        default: reply = .json(#"{"result":false,"error":null}"#)
        }
        let fixture = ClientFixture([cardReply(), reply])

        await expectError(scenario == "false" ? .rejected : .uncertainGrade) {
            try await fixture.client.answer(cardID: 42, ease: 3)
        }

        let requests = try fixture.requests(count: 2)
        try expectRequest(requests[0], action: "guiCurrentCard")
        try expectRequest(requests[1], action: "guiAnswerCard", params: ["ease": 3])
    }

    @Test func reviewsUseDecimalCardKeyAndPreserveReviewIDs() async throws {
        let fixture = ClientFixture([.json(#"{"result":{"1700000000042":[{"id":1700000000101,"ease":1,"time":1234},{"id":1700000000102,"ease":3,"time":4567}],"99":[{"id":9,"ease":4}]},"error":null}"#)])

        let reviews = try await fixture.client.reviews(cardID: 1_700_000_000_042)

        #expect(reviews == [AnkiReview(id: 1_700_000_000_101, ease: 1), AnkiReview(id: 1_700_000_000_102, ease: 3)])
        try expectRequest(try fixture.requests(count: 1)[0], action: "getReviewsOfCards", params: ["cards": [Int64(1_700_000_000_042)]])
    }

    @Test func reviewsForAnotherCardAreNotMistakenForRequestedHistory() async throws {
        let fixture = ClientFixture([.json(#"{"result":{"43":[]},"error":null}"#)])

        await expectError(.invalidResponse) { _ = try await fixture.client.reviews(cardID: 42) }

        _ = try fixture.requests(count: 1)
    }

    @Test func namedMediaIsDecodedFromBase64() async throws {
        let fixture = ClientFixture([.json(#"{"result":"AP8BAg==","error":null}"#)])

        #expect(try await fixture.client.media(named: "写真 image 1.png") == Data([0, 255, 1, 2]))
        try expectRequest(try fixture.requests(count: 1)[0], action: "retrieveMediaFile", params: ["filename": "写真 image 1.png"])
    }

    @Test(arguments: ["", ".", "..", "../image.png", "a\\b.png", "https:image.png", "a\u{0}.png", String(repeating: "é", count: 513)])
    func invalidMediaNamesNeverReachTheTransport(_ filename: String) async throws {
        let fixture = ClientFixture([])

        #expect(!AnkiConnectClient.isSafeMediaName(filename))
        await expectError(.invalidMediaName) { _ = try await fixture.client.media(named: filename) }

        _ = try fixture.requests(count: 0)
    }

    @Test(arguments: ["false", "true", "\"not base64!\""])
    func missingOrMalformedMediaIsNotReturnedAsData(_ result: String) async throws {
        let fixture = ClientFixture([.json("{\"result\":\(result),\"error\":null}")])

        await expectError(result == "false" ? .missingMedia : .invalidResponse) {
            _ = try await fixture.client.media(named: "image.png")
        }

        _ = try fixture.requests(count: 1)
    }

    @Test(arguments: [1, 7])
    func oversizedMediaIsRejectedOnEitherSideOfTheBase64LengthGuard(_ extraBytes: Int) async throws {
        let encoded = Data(repeating: 0, count: AnkiConnectClient.maximumMediaBytes + extraBytes).base64EncodedString()
        let fixture = ClientFixture([.json("{\"result\":\"\(encoded)\",\"error\":null}")])

        await expectError(.oversizedContent) { _ = try await fixture.client.media(named: "large.png") }

        _ = try fixture.requests(count: 1)
    }

    @Test(arguments: [301, 302, 401, 403, 500, 204])
    func httpErrorsDoNotDecodeAsSuccessfulCards(_ status: Int) async throws {
        let fixture = ClientFixture([.json(#"{"result":null,"error":null}"#, status: status)])
        let expected: AnkiError = (300...399).contains(status) ? .redirected : ([401, 403].contains(status) ? .authorization : .server)

        await expectError(expected) { _ = try await fixture.client.currentCard() }

        _ = try fixture.requests(count: 1)
    }

    @Test func unexpectedFinalResponseURLIsRejected() async throws {
        let fixture = ClientFixture([.json(#"{"result":null,"error":null}"#, url: URL(string: "http://example.invalid/"))])

        await expectError(.redirected) { _ = try await fixture.client.currentCard() }

        _ = try fixture.requests(count: 1)
    }

    @Test func timerUsesExplicitActionWithoutADeckOrCardParameter() async throws {
        let fixture = ClientFixture([.json(#"{"result":true,"error":null}"#)])

        try await fixture.client.resetTimer()

        try expectRequest(try fixture.requests(count: 1)[0], action: "guiStartCardTimer")
    }
}

private struct RatingCase: Sendable {
    let buttons: [Int]
    let titles: [String]
}

private func permission() -> ClientReply {
    .json(#"{"result":{"permission":"granted","requireApikey":false},"error":null}"#)
}

private func reflection(omitting action: String? = nil) -> ClientReply {
    let actions: [String] = [
        "deckNames", "getDeckStats", "guiDeckReview", "guiCurrentCard", "guiShowQuestion",
        "guiShowAnswer", "guiAnswerCard", "guiStartCardTimer", "getReviewsOfCards", "retrieveMediaFile",
        "deckNamesAndIds", "findCards"
    ].filter { $0 != action }
    let list = actions.map { "\"\($0)\"" }.joined(separator: ",")
    return .json("{\"result\":{\"actions\":[\(list)]},\"error\":null}")
}

private func handshakePrefix() -> [ClientReply] {
    [permission(), .json(#"{"result":6,"error":null}"#), reflection()]
}

private func searchCountsPrefix(completedCounts: Int) -> [ClientReply] {
    handshakePrefix() + [
        .json(#"{"result":["Existing"],"error":null}"#),
        .json(#"{"result":null,"error":"Deck counts unavailable."}"#),
        .json(#"{"result":{"Existing":1},"error":null}"#)
    ] + Array(repeating: .json(#"{"result":[],"error":null}"#), count: completedCounts)
}

private func cardReply(id: Int64 = 42, buttons: [Int] = [1, 2, 3, 4]) -> ClientReply {
    .json("{\"result\":{\"cardId\":\(id),\"question\":\"Question\",\"answer\":\"Answer\",\"deckName\":\"Existing\",\"buttons\":\(buttons),\"nextReviews\":[\"1m\",\"10m\",\"1d\",\"4d\"]},\"error\":null}")
}

private func expectError(_ expected: AnkiError, operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected a typed Anki error")
    } catch {
        let actual = error as? AnkiError
        #expect(actual == expected)
    }
}

private func expectRequest(_ request: ClientRequest, action: String, params: [String: Any] = [:], key: String? = nil, port: Int = 8765) throws {
    #expect(request.method == "POST")
    #expect(request.url?.absoluteString == "http://127.0.0.1:\(port)/")
    #expect(request.contentType == "application/json")
    let envelope = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    #expect(Set(envelope.keys) == Set(key == nil ? ["action", "version", "params"] : ["action", "version", "params", "key"]))
    #expect(envelope["action"] as? String == action)
    #expect(envelope["version"] as? Int == 6)
    #expect(envelope["key"] as? String == key)
    let actual = try #require(envelope["params"] as? [String: Any])
    #expect((actual as NSDictionary).isEqual(to: params))
}

private enum ClientReply: Sendable {
    case json(String, status: Int = 200, url: URL? = nil)
    case failure(URLError.Code)
}

private struct ClientRequest: Sendable {
    let method: String?
    let url: URL?
    let contentType: String?
    let body: Data
    var action: String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["action"] as? String
    }
}

private final class ClientFixture: Sendable {
    let client: AnkiConnectClient
    private let session: URLSession

    init(_ replies: [ClientReply], key: String = "", port: Int = 8765) {
        ClientURLProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientURLProtocol.self]
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 1
        session = URLSession(configuration: configuration)
        client = AnkiConnectClient(port: port, key: key, session: session)
    }

    deinit { session.invalidateAndCancel() }

    func requests(count: Int) throws -> [ClientRequest] {
        let snapshot = ClientURLProtocol.state.snapshot()
        try #require(snapshot.requests.count == count)
        #expect(snapshot.remaining == 0)
        return snapshot.requests
    }
}

private final class ClientProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ClientReply] = []
    private var requests: [ClientRequest] = []

    func reset(_ replies: [ClientReply]) {
        lock.withLock {
            self.replies = replies
            requests = []
        }
    }

    func take(for request: URLRequest) -> ClientReply {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let captured = ClientRequest(method: request.httpMethod, url: request.url,
                                     contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body)
        return lock.withLock {
            requests.append(captured)
            return replies.isEmpty ? .failure(.badServerResponse) : replies.removeFirst()
        }
    }

    func snapshot() -> (requests: [ClientRequest], remaining: Int) {
        lock.withLock { (requests, replies.count) }
    }
}

private final class ClientURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ClientProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.state.take(for: request) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let text, let status, let url):
            guard let url = url ?? request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
