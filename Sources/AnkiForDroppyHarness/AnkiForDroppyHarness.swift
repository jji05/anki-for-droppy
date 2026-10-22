import AnkiForDroppy
import DroppyKit
import DroppyKitHarness
import Foundation

@main
struct AnkiForDroppyHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario: String
        if let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) {
            scenario = arguments[index + 1]
        } else {
            scenario = "question"
        }
        let fixture = PreviewAnkiClient(scenario: scenario)
        return AnkiForDroppyDroplet(clientFactory: { _, _ in fixture }) { session in
            session.connect()
            Task { @MainActor in
                await session.waitUntilIdle()
                guard !["offline", "ready", "counts-unavailable", "search-counts", "counts-zero", "counts-large"]
                    .contains(scenario) else { return }
                session.start()
                await session.waitUntilIdle()
                if scenario == "answer" || scenario == "uncertain" {
                    session.reveal()
                    await session.waitUntilIdle()
                }
                if scenario == "paused" { session.pause() }
                if scenario == "uncertain" {
                    session.grade(3)
                    await session.waitUntilIdle()
                }
            }
        }
    }
}

private actor PreviewAnkiClient: AnkiReviewing {
    private let scenario: String
    private var index = 0
    private var attemptedGrade = false
    private var history: [Int64: [AnkiReview]] = [:]
    private var reviewID: Int64 = 1_700_000_000_000

    init(scenario: String) { self.scenario = scenario }

    func decks() async throws -> [AnkiDeck] {
        if scenario == "offline" { throw AnkiError.unavailable }
        if scenario == "counts-unavailable" { return [AnkiDeck(name: "Japanese"), AnkiDeck(name: "Biology")] }
        if scenario == "ready" {
            return [AnkiDeck(name: "Core 2000", newCount: 8, learningCount: 0, reviewCount: 163),
                    AnkiDeck(name: "Biology", newCount: 0, learningCount: 1, reviewCount: 8)]
        }
        if scenario == "search-counts" {
            return [AnkiDeck(name: "Japanese", learningCount: 4, reviewCount: 280, countsAreFromSearch: true),
                    AnkiDeck(name: "Biology", learningCount: 0, reviewCount: 0, countsAreFromSearch: true)]
        }
        if scenario == "counts-zero" {
            return [AnkiDeck(name: "Japanese", newCount: 0, learningCount: 0, reviewCount: 0)]
        }
        if scenario == "counts-large" {
            return [AnkiDeck(name: "A very long deck name with many nested study topics",
                newCount: 1_000_000_000, learningCount: 1_000_000_000, reviewCount: 1_000_000_000)]
        }
        return [AnkiDeck(name: "Japanese", newCount: 3, learningCount: 2, reviewCount: 7),
                AnkiDeck(name: "Biology", newCount: 0, learningCount: 1, reviewCount: 8)]
    }

    func start(deck: String) async throws -> AnkiCard? {
        index = 0
        if scenario == "ended" { return nil }
        return makeCard()
    }

    func currentCard() async throws -> AnkiCard? { makeCard() }

    func showQuestion(cardID: Int64) async throws -> AnkiCard { try requireCard(cardID) }
    func showAnswer(cardID: Int64) async throws -> AnkiCard { try requireCard(cardID) }
    func resetTimer() async throws {}

    func answer(cardID: Int64, ease: Int) async throws {
        _ = try requireCard(cardID)
        attemptedGrade = true
        if scenario == "uncertain" { throw AnkiError.uncertainGrade }
        reviewID += 1
        history[cardID, default: []].append(AnkiReview(id: reviewID, ease: ease))
        index += 1
    }

    func reviews(cardID: Int64) async throws -> [AnkiReview] {
        if scenario == "uncertain" && attemptedGrade { throw AnkiError.unavailable }
        return history[cardID] ?? []
    }

    func media(named filename: String) async throws -> Data {
        guard filename == "sample.png", let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jz1kAAAAASUVORK5CYII=") else {
            throw AnkiError.missingMedia
        }
        return data
    }

    nonisolated func cancel() {}

    private func requireCard(_ id: Int64) throws -> AnkiCard {
        guard let card = makeCard(), card.cardId == id else { throw AnkiError.changedCard }
        return card
    }

    private func makeCard() -> AnkiCard? {
        guard index < 3 else { return nil }
        let words = [("食べる", "たべる", "To eat"), ("読む", "よむ", "To read"), ("歩く", "あるく", "To walk")]
        let word = words[index]
        var question = "<div class=term>\(word.0)</div><div class=hint>What does this word mean?</div>"
        if scenario == "long" {
            question = "<p>Explain the difference between recognition and recall.</p>" + String(repeating: "<p>Consider a concrete example from something you learned recently.</p>", count: 20)
        } else if scenario == "image" {
            question += "<img src='sample.png' width='56' height='28' alt='Sample card image'>"
        } else if scenario == "unsupported" {
            question += "<script>window.example = true;</script><p>\\(x^2\\)</p>"
        }
        return AnkiCard(cardId: 1_700_000_001_000 + Int64(index), question: question,
            answer: "<div class=term>\(word.0)</div><hr id=answer><div class=meaning>\(word.2)</div><div class=reading>\(word.1)</div>",
            css: ".card { font-family: -apple-system; text-align: center; } .term { font-size: 32px; font-weight: 500; margin: 10px 0; } .hint { font-size: 12px; color: #999; } .meaning { font-size: 20px; margin: 8px 0; } .reading { color: #aaa; font-size: 14px; } hr { border: 0; height: 1px; background: #333; margin: 10px 20%; }",
            deckName: "Japanese", nextReviews: ["<1m", "<6m", "10m", "4d"])
    }
}
