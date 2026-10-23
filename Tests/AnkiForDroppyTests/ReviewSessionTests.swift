import Foundation
import Testing
import AnkiForDroppy

@MainActor
@Suite("Review session")
struct ReviewSessionTests {
    @Test func explicitReviewFlowConfirmsHistoryBeforePresentingNextQuestion() async {
        let first = sessionCard(10)
        let next = sessionCard(20)
        let fake = ScriptedReviewer(questionSteps(first) + [
            Step(.showAnswer(10), .card(first)),
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .card(next)),
            Step(.showQuestion(20), .card(next)),
            Step(.resetTimer, .ok)
        ])
        let session = activatedSession(fake)

        #expect(session.phase == .disconnected)
        #expect(await fake.calls.isEmpty)
        session.connect()
        await session.waitUntilIdle()
        #expect(session.phase == .ready)
        #expect(session.isConnected)
        #expect(session.selectedDeck == "Study")
        #expect(session.card == nil)
        #expect(await fake.calls == [.decks])

        session.start()
        await session.waitUntilIdle()
        #expect(session.phase == .question)
        #expect(session.card == first)
        #expect(session.isReviewing)
        #expect(session.reviewedCount == 0)

        session.reveal()
        await session.waitUntilIdle()
        #expect(session.phase == .answer)
        session.grade(99)
        #expect(!session.isBusy)
        session.grade(3)
        await session.waitUntilIdle()

        #expect(session.phase == .question)
        #expect(session.card == next)
        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(!session.isBusy)
        #expect(session.message == nil)
        #expect(await fake.calls == [
            .decks, .start("Study"), .showQuestion(10), .resetTimer,
            .showAnswer(10), .reviews(10), .answer(10, 3), .reviews(10),
            .currentCard, .showQuestion(20), .resetTimer
        ])
        await fake.expectFinished()
    }

    @Test(arguments: [false, true])
    func replayPreservesTheCardPhaseAndConfirmedCount(_ showsAnswer: Bool) async {
        let card = sessionCard(20)
        var steps = answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .card(card)),
            Step(.showQuestion(20), .card(card)),
            Step(.resetTimer, .ok)
        ]
        if showsAnswer { steps.append(Step(.showAnswer(20), .card(card))) }
        steps.append(Step(.replayAudio(20, showsAnswer), .ok))
        let fake = ScriptedReviewer(steps)
        let session = activatedSession(fake)
        await openAnswer(session)
        session.grade(3)
        await session.waitUntilIdle()
        if showsAnswer {
            session.reveal()
            await session.waitUntilIdle()
        }
        let beforeReplay = await fake.calls

        session.replayAudio()
        #expect(session.isBusy)
        await session.waitUntilIdle()

        #expect(session.phase == (showsAnswer ? .answer : .question))
        #expect(session.card == card)
        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(session.isReviewing)
        #expect(!session.isBusy)
        #expect(session.message == nil)
        #expect(await fake.calls == beforeReplay + [.replayAudio(20, showsAnswer)])
        await fake.expectFinished()
    }

    @Test(arguments: [AnkiError.changedCard, .rejected, .server, .unavailable])
    func replayUsesExistingErrorHandlingWithoutGrading(_ error: AnkiError) async {
        let fake = ScriptedReviewer(questionSteps() + [Step(.replayAudio(10, false), .failure(error))])
        let session = activatedSession(fake)
        await openQuestion(session)

        session.replayAudio()
        await session.waitUntilIdle()

        #expect(session.phase == (error == .unavailable ? .disconnected : .interrupted))
        #expect(session.card == nil)
        #expect(session.reviewedCount == 0)
        #expect(session.pendingGrade == nil)
        #expect(session.message == error.message)
        #expect(!session.isBusy)
        #expect(!session.isReviewing)
        await fake.expectFinished()
    }

    @Test func busyReplayBlocksDuplicateReplayAndOtherReviewActions() async {
        let gate = SessionReplyGate()
        let fake = ScriptedReviewer(answerSteps() + [Step(.replayAudio(10, true), .ok, gate: gate)])
        let session = activatedSession(fake)
        await openAnswer(session)
        session.replayAudio()
        #expect(await gate.waitUntilReached())
        let calls = await fake.calls

        session.replayAudio()
        session.grade(3)
        session.refreshReview()
        session.pause()
        #expect(session.isBusy)
        #expect(session.phase == .answer)
        #expect(session.pendingGrade == nil)
        #expect(await fake.calls == calls)
        await gate.release()
        await session.waitUntilIdle()

        #expect(!session.isBusy)
        #expect(session.phase == .answer)
        #expect(session.card == sessionCard())
        await fake.expectFinished()
    }

    @Test func replayDoesNothingOutsideAnActiveReview() async {
        let fake = ScriptedReviewer(questionSteps() + [Step(.currentCard, .card(nil))])
        let session = activatedSession(fake)
        session.replayAudio()
        session.connect()
        await session.waitUntilIdle()
        session.replayAudio()
        session.start()
        await session.waitUntilIdle()
        session.pause()
        session.replayAudio()
        #expect(session.phase == .paused)
        #expect(session.card == sessionCard())
        session.stop()
        session.replayAudio()
        session.refreshReview()
        await session.waitUntilIdle()
        session.replayAudio()
        #expect(session.phase == .ended)
        session.deactivate()
        session.replayAudio()
        #expect(!session.isBusy)
        #expect(session.phase == .disconnected)
        await fake.expectFinished()
    }

    @Test(arguments: SessionCancellation.allCases, [false, true])
    func cancellationSuppressesLateReplaySuccessAndFailure(_ cancellation: SessionCancellation, _ fails: Bool) async {
        let gate = SessionReplyGate()
        let fake = ScriptedReviewer(questionSteps() + [
            Step(.replayAudio(10, false), fails ? .failure(.server) : .ok, gate: gate)
        ])
        let session = activatedSession(fake)
        await openQuestion(session)
        session.replayAudio()

        await cancelSuspendedOperation(session, gate: gate) {
            cancellation.apply(to: session)
        }

        #expect(session.phase == cancellation.phaseWithoutPendingGrade)
        #expect(session.card == nil)
        #expect(session.reviewedCount == 0)
        #expect(session.pendingGrade == nil)
        #expect(session.message == nil)
        #expect(!session.isBusy)
        #expect(!session.isReviewing)
        await fake.expectFinished()
    }

    @Test func sameCardCanImmediatelyRepeatAfterAConfirmedReview() async {
        let first = sessionCard(10)
        let fake = ScriptedReviewer(answerSteps(first) + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 1), .ok),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 1)])),
            Step(.currentCard, .card(first)),
            Step(.showQuestion(10), .card(first)),
            Step(.resetTimer, .ok)
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(1)
        await session.waitUntilIdle()

        #expect(session.phase == .question)
        #expect(session.card?.cardId == 10)
        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(await fake.calls.filter { $0 == .resetTimer }.count == 2)
        #expect(await fake.calls.filter { $0 == .answer(10, 1) }.count == 1)
        await fake.expectFinished()
    }

    @Test func delayedPersistedReviewIsConfirmedUsingReadOnlyPolling() async {
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([])),
            Step(.reviews(10), .history([])),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .card(nil))
        ])
        let session = activatedSession(fake, attempts: 3)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()

        #expect(session.reviewedCount == 1)
        #expect(session.phase == .ended)
        #expect(session.pendingGrade == nil)
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        #expect(await fake.calls.filter { $0 == .reviews(10) }.count == 4)
        await fake.expectFinished()
    }

    @Test func acceptedMutationWithoutPersistedReviewStaysUncertain() async {
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([])),
            Step(.reviews(10), .history([]))
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()
        session.grade(3)
        session.start()
        session.pause()
        session.replayAudio()

        #expect(session.phase == .uncertain)
        #expect(session.reviewedCount == 0)
        #expect(session.card == nil)
        #expect(session.pendingGrade?.cardID == 10)
        #expect(session.pendingGrade?.ease == 3)
        #expect(session.message == AnkiError.uncertainGrade.message)
        #expect(!session.canChooseDeck)
        #expect(!session.isReviewing)
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        await fake.expectFinished()
    }

    @Test func lostMutationResponseStillConfirmsSavedReviewWithoutResending() async {
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .failure(.uncertainGrade)),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .card(nil))
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()

        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(session.phase == .ended)
        #expect(session.message?.contains("Review ended in Anki") == true)
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        await fake.expectFinished()
    }

    @Test func existingReviewIDsAreExcludedAndRefreshNeverResendsGrade() async {
        let existing = AnkiReview(id: 100, ease: 3)
        let saved = AnkiReview(id: 101, ease: 3)
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([existing])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([existing])),
            Step(.reviews(10), .history([existing, saved])),
            Step(.currentCard, .card(nil))
        ])
        let session = activatedSession(fake, attempts: 1)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()
        #expect(session.phase == .uncertain)
        #expect(session.reviewedCount == 0)
        #expect(session.pendingGrade?.baselineReviewIDs == Set([100]))

        session.refreshReview()
        await session.waitUntilIdle()
        #expect(session.phase == .ended)
        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        await fake.expectFinished()
    }

    @Test(arguments: HistoryConflict.allCases)
    func conflictingHistoryDoesNotConfirmGrade(_ conflict: HistoryConflict) async {
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history(conflict.reviews))
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()

        #expect(session.phase == .uncertain)
        #expect(session.reviewedCount == 0)
        #expect(session.pendingGrade != nil)
        await fake.expectFinished()
    }

    @Test(arguments: [false, true])
    func changedCardRejectsRevealOrGradeWithoutIncrementing(_ grading: Bool) async {
        let steps = if grading {
            answerSteps() + [
                Step(.reviews(10), .history([])),
                Step(.answer(10, 3), .failure(.changedCard))
            ]
        } else {
            questionSteps() + [Step(.showAnswer(10), .failure(.changedCard))]
        }
        let fake = ScriptedReviewer(steps)
        let session = activatedSession(fake)
        await openQuestion(session)
        if grading {
            session.reveal()
            await session.waitUntilIdle()
            session.grade(3)
        } else {
            session.reveal()
        }
        await session.waitUntilIdle()

        #expect(session.phase == .interrupted)
        #expect(session.reviewedCount == 0)
        #expect(session.card == nil)
        #expect(session.pendingGrade == nil)
        #expect(session.message == AnkiError.changedCard.message)
        #expect(!session.isReviewing)
        await fake.expectFinished()
    }

    @Test func nextFetchFailureRetainsConfirmedCountAndDoesNotEnableRegrading() async {
        let next = sessionCard(20)
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .failure(.server)),
            Step(.currentCard, .card(next)),
            Step(.showQuestion(20), .card(next)),
            Step(.resetTimer, .ok)
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(3)
        await session.waitUntilIdle()
        #expect(session.phase == .interrupted)
        #expect(session.reviewedCount == 1)
        #expect(session.pendingGrade == nil)
        #expect(session.card == nil)

        session.grade(3)
        session.refreshReview()
        await session.waitUntilIdle()
        #expect(session.phase == .question)
        #expect(session.card == next)
        #expect(session.reviewedCount == 1)
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        await fake.expectFinished()
    }

    @Test func duplicateGradeTapWhileWaitingDispatchesOnlyOnce() async {
        let gate = SessionReplyGate()
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([])),
            Step(.answer(10, 3), .ok, gate: gate),
            Step(.reviews(10), .history([AnkiReview(id: 100, ease: 3)])),
            Step(.currentCard, .card(nil))
        ])
        let session = activatedSession(fake)
        await openAnswer(session)

        session.grade(3)
        #expect(await gate.waitUntilReached())
        #expect(session.isBusy)
        #expect(session.pendingGrade != nil)
        session.grade(3)
        session.grade(4)
        session.replayAudio()
        session.refreshReview()
        #expect(await fake.calls.filter { $0 == .answer(10, 3) }.count == 1)
        await gate.release()
        await session.waitUntilIdle()

        #expect(session.reviewedCount == 1)
        #expect(session.phase == .ended)
        #expect(!session.isBusy)
        await fake.expectFinished()
    }

    @Test(arguments: [false, true])
    func pauseAndResumeRevalidateTheCardAndRestoreLocalPhase(_ revealed: Bool) async {
        let card = sessionCard(10)
        let resumeSteps = if revealed {
            [Step(.showAnswer(10), .card(card))]
        } else {
            [Step(.showQuestion(10), .card(card)), Step(.resetTimer, .ok)]
        }
        let fake = ScriptedReviewer((revealed ? answerSteps(card) : questionSteps(card)) + resumeSteps)
        let session = activatedSession(fake)
        if revealed { await openAnswer(session) } else { await openQuestion(session) }
        let beforePause = await fake.calls

        session.start()
        await session.waitUntilIdle()
        #expect(session.phase == (revealed ? .answer : .question))
        #expect(await fake.calls == beforePause)
        session.pause()
        #expect(session.phase == .paused)
        #expect(session.card == card)
        #expect(!session.isReviewing)
        session.start()
        await session.waitUntilIdle()
        #expect(session.phase == .paused)
        #expect(await fake.calls == beforePause)
        session.grade(3)
        session.reveal()
        #expect(await fake.calls == beforePause)

        session.resume()
        await session.waitUntilIdle()
        #expect(session.phase == (revealed ? .answer : .question))
        #expect(session.card == card)
        #expect(session.isReviewing)
        #expect(session.reviewedCount == 0)
        #expect(await fake.calls.filter { $0 == .resetTimer }.count == (revealed ? 1 : 2))
        await fake.expectFinished()
    }

    @Test func resumeRejectsAnExternallyChangedCard() async {
        let fake = ScriptedReviewer(questionSteps() + [
            Step(.showQuestion(10), .failure(.changedCard))
        ])
        let session = activatedSession(fake)
        await openQuestion(session)
        session.pause()

        session.resume()
        await session.waitUntilIdle()

        #expect(session.phase == .interrupted)
        #expect(session.card == nil)
        #expect(session.reviewedCount == 0)
        #expect(session.message == AnkiError.changedCard.message)
        await fake.expectFinished()
    }

    @Test(arguments: SessionCancellation.allCases)
    func cancellationSuppressesLateResumeRepliesAndTimerMutations(_ cancellation: SessionCancellation) async {
        let gate = SessionReplyGate()
        let fake = ScriptedReviewer(questionSteps() + [
            Step(.showQuestion(10), .card(sessionCard(10)), gate: gate)
        ])
        let session = activatedSession(fake)
        await openQuestion(session)
        session.pause()
        session.resume()

        await cancelSuspendedOperation(session, gate: gate) {
            cancellation.apply(to: session)
        }

        #expect(session.phase == cancellation.phaseWithoutPendingGrade)
        #expect(session.card == nil)
        #expect(!session.isBusy)
        #expect(!session.isReviewing)
        #expect(session.reviewedCount == 0)
        #expect(await fake.calls.filter { $0 == .resetTimer }.count == 1)
        await fake.expectFinished()
    }

    @Test(arguments: SessionCancellation.allCases)
    func cancelledDispatchedGradeSurvivesAndIsReconciledOnRestoredActivation(_ cancellation: SessionCancellation) async {
        let gate = SessionReplyGate()
        let fake = ScriptedReviewer(answerSteps() + [
            Step(.reviews(10), .history([AnkiReview(id: 99, ease: 1)])),
            Step(.answer(10, 3), .ok, gate: gate)
        ])
        let session = activatedSession(fake)
        await openAnswer(session)
        session.grade(3)

        await cancelSuspendedOperation(session, gate: gate) {
            cancellation.apply(to: session)
        }
        #expect(session.phase == .uncertain)
        #expect(session.pendingGrade?.cardID == 10)
        #expect(session.pendingGrade?.ease == 3)
        #expect(session.pendingGrade?.baselineReviewIDs == Set([99]))
        #expect(session.pendingGrade?.port == 8765)
        #expect(session.reviewedCount == 0)
        #expect(session.card == nil)
        await fake.expectFinished()

        let restoredFake = ScriptedReviewer([
            Step(.decks, .decks([AnkiDeck(name: "Study")])),
            Step(.reviews(10), .history([
                AnkiReview(id: 99, ease: 1), AnkiReview(id: 100, ease: 3)
            ])),
            Step(.currentCard, .card(nil))
        ])
        let restored = activatedSession(restoredFake, pending: session.pendingGrade)
        #expect(restored.phase == .uncertain)
        #expect(await restoredFake.calls.isEmpty)
        restored.start()
        restored.grade(3)
        #expect(await restoredFake.calls.isEmpty)

        restored.connect()
        await restored.waitUntilIdle()
        #expect(restored.phase == .ended)
        #expect(restored.reviewedCount == 1)
        #expect(restored.pendingGrade == nil)
        #expect(await restoredFake.calls == [.decks, .reviews(10), .currentCard])
        await restoredFake.expectFinished()
    }

    @Test(arguments: [false, true])
    func deniedNetworkMakesNoRequestsAndPreservesPendingEvidence(_ hasPendingGrade: Bool) async {
        let pending = hasPendingGrade ? PendingGrade(
            cardID: 10, ease: 3, baselineReviewIDs: [99], port: 8765, createdAt: .distantPast
        ) : nil
        let fake = ScriptedReviewer([])
        let session = ReviewSession(client: fake, reconciliationDelay: .zero)
        session.activate(networkAllowed: false, selectedDeck: "Study", pendingGrade: pending)

        session.connect()
        await session.waitUntilIdle()
        session.start()
        session.refreshReview()
        await session.waitUntilIdle()
        session.reveal()
        session.grade(3)

        #expect(await fake.calls.isEmpty)
        #expect(session.phase == (hasPendingGrade ? .uncertain : .disconnected))
        #expect(session.pendingGrade == pending)
        #expect(!session.isConnected)
        #expect(!session.isBusy)
        #expect(session.message == AnkiError.permissionDenied.message)
        await fake.expectFinished()
    }

    @Test func missingSelectedDeckFallsBackWithoutAutomaticallyStartingReview() async {
        let decks = [AnkiDeck(name: "Available"), AnkiDeck(name: "Other")]
        let fake = ScriptedReviewer([Step(.decks, .decks(decks))])
        let session = activatedSession(fake, selectedDeck: "Removed")
        #expect(await fake.calls.isEmpty)

        session.connect()
        await session.waitUntilIdle()

        #expect(session.decks == decks)
        #expect(session.selectedDeck == "Available")
        #expect(session.selectedDeckInfo == decks[0])
        #expect(session.phase == .ready)
        #expect(session.card == nil)
        #expect(session.reviewedCount == 0)
        #expect(session.canChooseDeck)
        #expect(await fake.calls == [.decks])
        session.selectDeck("Removed")
        #expect(session.selectedDeck == "Available")
        session.selectDeck("Other")
        #expect(session.selectedDeck == "Other")
        #expect(await fake.calls == [.decks])
        await fake.expectFinished()
    }
}

private func sessionCard(_ id: Int64 = 10) -> AnkiCard {
    AnkiCard(cardId: id, question: "Question \(id)", answer: "Answer \(id)", deckName: "Study")
}

private func questionSteps(_ card: AnkiCard = sessionCard()) -> [Step] {
    [
        Step(.decks, .decks([AnkiDeck(name: "Study")])),
        Step(.start("Study"), .card(card)),
        Step(.showQuestion(card.cardId), .card(card)),
        Step(.resetTimer, .ok)
    ]
}

private func answerSteps(_ card: AnkiCard = sessionCard()) -> [Step] {
    questionSteps(card) + [Step(.showAnswer(card.cardId), .card(card))]
}

@MainActor
private func activatedSession(
    _ fake: ScriptedReviewer, attempts: Int = 2, selectedDeck: String = "Study", pending: PendingGrade? = nil
) -> ReviewSession {
    let session = ReviewSession(client: fake, reconciliationAttempts: attempts, reconciliationDelay: .zero)
    session.activate(networkAllowed: true, selectedDeck: selectedDeck, pendingGrade: pending)
    return session
}

@MainActor
private func openQuestion(_ session: ReviewSession) async {
    session.connect()
    await session.waitUntilIdle()
    session.start()
    await session.waitUntilIdle()
}

@MainActor
private func openAnswer(_ session: ReviewSession) async {
    await openQuestion(session)
    session.reveal()
    await session.waitUntilIdle()
}

@MainActor
private func cancelSuspendedOperation(
    _ session: ReviewSession, gate: SessionReplyGate, cancel: () -> Void
) async {
    #expect(await gate.waitUntilReached())
    var waiterStarted = false
    let completion = Task {
        waiterStarted = true
        await session.waitUntilIdle()
    }
    for _ in 0..<10_000 {
        if waiterStarted { break }
        await Task.yield()
    }
    #expect(waiterStarted)
    cancel()
    await gate.release()
    await completion.value
}

enum SessionCancellation: CaseIterable, Sendable {
    case stop, deactivate

    @MainActor func apply(to session: ReviewSession) {
        switch self {
        case .stop: session.stop()
        case .deactivate: session.deactivate()
        }
    }

    var phaseWithoutPendingGrade: ReviewPhase {
        switch self {
        case .stop: .ready
        case .deactivate: .disconnected
        }
    }
}

enum HistoryConflict: CaseIterable, Sendable {
    case wrongEase, multipleNewReviews

    var reviews: [AnkiReview] {
        switch self {
        case .wrongEase: [AnkiReview(id: 100, ease: 1)]
        case .multipleNewReviews: [AnkiReview(id: 100, ease: 3), AnkiReview(id: 101, ease: 3)]
        }
    }
}

private enum SessionCall: Equatable, Sendable {
    case decks, start(String), currentCard, showQuestion(Int64), showAnswer(Int64)
    case resetTimer, replayAudio(Int64, Bool), answer(Int64, Int), reviews(Int64), media(String)
}

private enum SessionReply: Sendable {
    case decks([AnkiDeck]), card(AnkiCard?), history([AnkiReview]), ok, failure(AnkiError)
}

private struct Step: Sendable {
    let call: SessionCall
    let reply: SessionReply
    let gate: SessionReplyGate?

    init(_ call: SessionCall, _ reply: SessionReply, gate: SessionReplyGate? = nil) {
        self.call = call
        self.reply = reply
        self.gate = gate
    }
}

private actor ScriptedReviewer: AnkiReviewing {
    private let steps: [Step]
    private var index = 0
    private(set) var calls: [SessionCall] = []

    init(_ steps: [Step]) { self.steps = steps }

    func decks() async throws -> [AnkiDeck] {
        guard case .decks(let decks) = try await respond(to: .decks) else { throw AnkiError.invalidResponse }
        return decks
    }

    func start(deck: String) async throws -> AnkiCard? {
        try await cardReply(to: .start(deck))
    }

    func currentCard() async throws -> AnkiCard? {
        try await cardReply(to: .currentCard)
    }

    func showQuestion(cardID: Int64) async throws -> AnkiCard {
        guard let card = try await cardReply(to: .showQuestion(cardID)) else { throw AnkiError.invalidResponse }
        return card
    }

    func showAnswer(cardID: Int64) async throws -> AnkiCard {
        guard let card = try await cardReply(to: .showAnswer(cardID)) else { throw AnkiError.invalidResponse }
        return card
    }

    func replayAudio(cardID: Int64, showsAnswer: Bool) async throws {
        guard case .ok = try await respond(to: .replayAudio(cardID, showsAnswer)) else {
            throw AnkiError.invalidResponse
        }
    }

    func resetTimer() async throws {
        guard case .ok = try await respond(to: .resetTimer) else { throw AnkiError.invalidResponse }
    }

    func answer(cardID: Int64, ease: Int) async throws {
        guard case .ok = try await respond(to: .answer(cardID, ease)) else { throw AnkiError.invalidResponse }
    }

    func reviews(cardID: Int64) async throws -> [AnkiReview] {
        guard case .history(let history) = try await respond(to: .reviews(cardID)) else {
            throw AnkiError.invalidResponse
        }
        return history
    }

    func media(named filename: String) async throws -> Data {
        _ = try await respond(to: .media(filename))
        throw AnkiError.missingMedia
    }

    nonisolated func cancel() {}

    func expectFinished() {
        #expect(index == steps.count)
    }

    private func cardReply(to call: SessionCall) async throws -> AnkiCard? {
        guard case .card(let card) = try await respond(to: call) else { throw AnkiError.invalidResponse }
        return card
    }

    private func respond(to call: SessionCall) async throws -> SessionReply {
        calls.append(call)
        guard index < steps.count else {
            Issue.record("Unexpected request: \(call)")
            throw AnkiError.invalidResponse
        }
        let step = steps[index]
        index += 1
        guard call == step.call else {
            Issue.record("Expected \(step.call), received \(call)")
            throw AnkiError.invalidResponse
        }
        if let gate = step.gate { await gate.wait() }
        if case .failure(let error) = step.reply { throw error }
        return step.reply
    }
}

private actor SessionReplyGate {
    private var reached = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        reached = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilReached() async -> Bool {
        for _ in 0..<10_000 {
            if reached { return true }
            await Task.yield()
        }
        return false
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
