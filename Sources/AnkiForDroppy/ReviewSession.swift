import Combine
import Foundation

package enum ReviewPhase: Equatable, Sendable {
    case disconnected, ready, question, answer, paused, ended, interrupted, uncertain
}

package struct PendingGrade: Codable, Equatable, Sendable {
    package let cardID: Int64
    package let ease: Int
    package let baselineReviewIDs: Set<Int64>
    package let port: Int
    package let createdAt: Date

    package init(cardID: Int64, ease: Int, baselineReviewIDs: Set<Int64>, port: Int, createdAt: Date) {
        self.cardID = cardID
        self.ease = ease
        self.baselineReviewIDs = baselineReviewIDs
        self.port = port
        self.createdAt = createdAt
    }
}

@MainActor
package final class ReviewSession: ObservableObject {
    @Published package private(set) var phase: ReviewPhase = .disconnected
    @Published package private(set) var decks: [AnkiDeck] = []
    @Published package private(set) var selectedDeck = ""
    @Published package private(set) var card: AnkiCard?
    @Published package private(set) var reviewedCount = 0
    @Published package private(set) var isBusy = false
    @Published package private(set) var isConnected = false
    @Published package private(set) var message: String?
    @Published package private(set) var pendingGrade: PendingGrade?
    package private(set) var client: any AnkiReviewing
    package var onChange: (() -> Void)?

    private var port: Int
    private var networkAllowed = false
    private var activated = false
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var pausedPhase: ReviewPhase = .question
    private let reconciliationAttempts: Int
    private let reconciliationDelay: Duration

    package init(client: any AnkiReviewing, port: Int = 8765,
                 reconciliationAttempts: Int = 12, reconciliationDelay: Duration = .milliseconds(250)) {
        self.client = client
        self.port = port
        self.reconciliationAttempts = max(1, reconciliationAttempts)
        self.reconciliationDelay = reconciliationDelay
    }

    package var isReviewing: Bool { activated && card != nil && (phase == .question || phase == .answer) }
    package var usesReviewHeight: Bool { card != nil || phase == .uncertain }
    package var canChooseDeck: Bool { !isBusy && card == nil && pendingGrade == nil }
    package var selectedDeckInfo: AnkiDeck? { decks.first { $0.name == selectedDeck } }

    package func activate(networkAllowed: Bool, selectedDeck: String, pendingGrade: PendingGrade?) {
        activated = true
        self.networkAllowed = networkAllowed
        self.selectedDeck = selectedDeck
        self.pendingGrade = pendingGrade
        phase = pendingGrade == nil ? .disconnected : .uncertain
        message = networkAllowed ? nil : AnkiError.permissionDenied.message
        changed()
    }

    package func replaceClient(_ client: any AnkiReviewing, port: Int) {
        cancelOperation()
        self.client.cancel()
        self.client = client
        self.port = port
        card = nil
        decks = []
        isConnected = false
        phase = pendingGrade == nil ? .disconnected : .uncertain
        message = pendingGrade == nil ? nil : AnkiError.uncertainGrade.message
        changed()
    }

    package func deactivate() {
        activated = false
        cancelOperation()
        client.cancel()
        card = nil
        isConnected = false
        phase = pendingGrade == nil ? .disconnected : .uncertain
        changed()
    }

    package func selectDeck(_ name: String) {
        guard canChooseDeck, decks.contains(where: { $0.name == name }) else { return }
        selectedDeck = name
        changed()
    }

    package func connect() {
        perform { session, token in
            do {
                let decks = try await session.client.decks()
                guard session.isCurrent(token) else { return }
                session.decks = decks
                session.isConnected = true
                if !decks.contains(where: { $0.name == session.selectedDeck }) {
                    session.selectedDeck = decks.first?.name ?? ""
                }
                if session.pendingGrade != nil {
                    try await session.resolvePending(token: token)
                } else {
                    session.card = nil
                    session.phase = .ready
                    session.message = decks.isEmpty ? "Create a deck in Anki, then refresh." : nil
                }
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func start() {
        guard canChooseDeck, !selectedDeck.isEmpty, isConnected else { return }
        perform { session, token in
            do {
                let card = try await session.client.start(deck: session.selectedDeck)
                guard session.isCurrent(token) else { return }
                session.reviewedCount = 0
                try await session.presentQuestion(card, token: token)
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func reveal() {
        guard phase == .question, let expected = card?.cardId, pendingGrade == nil else { return }
        perform { session, token in
            do {
                let card = try await session.client.showAnswer(cardID: expected)
                guard session.isCurrent(token) else { return }
                guard !card.ratings.isEmpty else { throw AnkiError.incompatible }
                session.card = card
                session.phase = .answer
                session.message = nil
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func grade(_ ease: Int) {
        guard phase == .answer, let card, card.ratings.contains(where: { $0.ease == ease }), pendingGrade == nil else { return }
        let cardID = card.cardId
        perform { session, token in
            do {
                let history = try await session.client.reviews(cardID: cardID)
                guard session.isCurrent(token) else { return }
                session.pendingGrade = PendingGrade(cardID: cardID, ease: ease,
                    baselineReviewIDs: Set(history.map(\.id)), port: session.port, createdAt: Date())
                session.changed()
                do {
                    try await session.client.answer(cardID: cardID, ease: ease)
                } catch AnkiError.uncertainGrade {
                } catch {
                    if session.isCurrent(token) { session.pendingGrade = nil }
                    throw error
                }
                guard session.isCurrent(token) else { return }
                try await session.resolvePending(token: token)
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func refreshReview() {
        perform { session, token in
            do {
                if session.pendingGrade != nil {
                    try await session.resolvePending(token: token)
                } else {
                    let card = try await session.client.currentCard()
                    guard session.isCurrent(token) else { return }
                    try await session.presentQuestion(card, token: token)
                }
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func pause() {
        guard isReviewing, !isBusy else { return }
        pausedPhase = phase
        phase = .paused
        changed()
    }

    package func resume() {
        guard phase == .paused, let expected = card?.cardId else { return }
        perform { session, token in
            do {
                let card: AnkiCard
                if session.pausedPhase == .answer {
                    card = try await session.client.showAnswer(cardID: expected)
                } else {
                    card = try await session.client.showQuestion(cardID: expected)
                    guard session.isCurrent(token) else { return }
                    try await session.client.resetTimer()
                }
                guard session.isCurrent(token) else { return }
                session.card = card
                session.phase = session.pausedPhase
                session.message = nil
            } catch {
                session.handle(error, token: token)
            }
        }
    }

    package func stop() {
        cancelOperation()
        card = nil
        phase = pendingGrade == nil ? (isConnected ? .ready : .disconnected) : .uncertain
        message = pendingGrade == nil ? nil : AnkiError.uncertainGrade.message
        changed()
    }

    package func acknowledgeCheckedInAnki() {
        guard !isBusy, pendingGrade != nil else { return }
        pendingGrade = nil
        card = nil
        phase = isConnected ? .ready : .disconnected
        message = "Start a new session only after checking the review in Anki."
        changed()
    }

    package func waitUntilIdle() async { await operation?.value }

    private func resolvePending(token: UUID) async throws {
        guard let pending = pendingGrade else { return }
        guard pending.port == port else {
            phase = .uncertain
            card = nil
            message = "Reconnect to local port \(pending.port) to check the pending rating, or check it in Anki."
            return
        }
        for attempt in 0..<reconciliationAttempts {
            let history = try await client.reviews(cardID: pending.cardID)
            guard isCurrent(token) else { return }
            let added = history.filter { !pending.baselineReviewIDs.contains($0.id) }
            if added.count == 1, added[0].ease == pending.ease {
                pendingGrade = nil
                reviewedCount += 1
                card = nil
                changed()
                let next = try await client.currentCard()
                guard isCurrent(token) else { return }
                try await presentQuestion(next, token: token)
                return
            }
            if !added.isEmpty { break }
            if attempt + 1 < reconciliationAttempts {
                try await Task.sleep(for: reconciliationDelay)
                guard isCurrent(token) else { return }
            }
        }
        phase = .uncertain
        card = nil
        message = AnkiError.uncertainGrade.message
    }

    private func presentQuestion(_ card: AnkiCard?, token: UUID) async throws {
        guard isCurrent(token) else { return }
        guard let card else {
            self.card = nil
            phase = .ended
            message = "Review ended in Anki. There may be learning cards due later."
            return
        }
        guard !card.ratings.isEmpty else { throw AnkiError.incompatible }
        let question = try await client.showQuestion(cardID: card.cardId)
        guard isCurrent(token) else { return }
        try await client.resetTimer()
        guard isCurrent(token) else { return }
        self.card = question
        phase = .question
        message = nil
    }

    private func perform(_ body: @escaping @MainActor (ReviewSession, UUID) async -> Void) {
        guard activated, !isBusy else { return }
        guard networkAllowed else {
            phase = pendingGrade == nil ? .disconnected : .uncertain
            message = AnkiError.permissionDenied.message
            changed()
            return
        }
        let token = UUID()
        generation = token
        isBusy = true
        changed()
        operation = Task { [weak self] in
            guard let self else { return }
            await body(self, token)
            guard self.isCurrent(token) else { return }
            self.isBusy = false
            self.changed()
        }
    }

    private func handle(_ error: any Error, token: UUID) {
        guard isCurrent(token) else { return }
        card = nil
        let failure = error as? AnkiError ?? .unavailable
        if pendingGrade != nil {
            phase = .uncertain
            message = "\(AnkiError.uncertainGrade.message) \(failure.message)"
        } else {
            if failure == .unavailable || failure == .authorization || failure == .permissionDenied {
                isConnected = false
            }
            phase = isConnected ? .interrupted : .disconnected
            message = failure.message
        }
    }

    private func cancelOperation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isBusy = false
    }

    private func isCurrent(_ token: UUID) -> Bool { activated && generation == token && !Task.isCancelled }
    private func changed() { onChange?() }
}
