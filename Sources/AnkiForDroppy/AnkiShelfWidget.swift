import DroppyKit
import SwiftUI

struct AnkiShelfWidget: View {
    @ObservedObject var droplet: AnkiForDroppyDroplet
    @ObservedObject var session: ReviewSession
    let context: ShelfWidgetContext
    @State private var renderingIssue: String?
    @State private var confirmChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isPaired {
                pairedBody
            } else if session.isReviewing, let card = session.card {
                reviewer(card)
            } else {
                statusBody
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .onChange(of: session.card?.cardId) { _, _ in renderingIssue = nil }
        .onChange(of: session.phase) { _, _ in renderingIssue = nil }
        .confirmationDialog("Have you checked this rating in Anki?", isPresented: $confirmChecked) {
            Button("I've checked Anki") { session.acknowledgeCheckedInAnki() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An uncertain rating will not be sent again. Verify whether it was saved before starting another session.")
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
            Text("Anki review").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if session.isBusy {
                ProgressView().controlSize(.mini).frame(width: 16)
                    .accessibilityLabel("Waiting for Anki")
            }
            if session.isReviewing {
                iconButton("Pause", symbol: "pause.fill") { session.pause() }
                    .disabled(session.isBusy)
            }
            if session.card != nil {
                iconButton("Stop review", symbol: "stop.fill") { session.stop() }
                if !context.isPaired {
                    iconButton("Open in Anki", symbol: "arrow.up.forward.app") { droplet.openAnki() }
                        .disabled(session.isBusy)
                }
            }
            iconButton("Settings", symbol: "gearshape") { droplet.openSettings() }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    @ViewBuilder
    private func reviewer(_ card: AnkiCard) -> some View {
        HStack {
            Text(card.deckName).lineLimit(1).help(card.deckName)
            Spacer(minLength: 0)
            reviewedLabel
        }
        .font(.system(size: 11))
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

        CardContentView(card: card, showsAnswer: session.phase == .answer, client: session.client) {
            renderingIssue = $0
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("\(card.cardId)-\(session.phase)")
        .accessibilityLabel(session.phase == .answer ? "Card answer" : "Card question")

        if let renderingIssue {
            HStack(spacing: DroppySpacing.xsm) {
                Text(renderingIssue).font(.system(size: 10)).lineLimit(1).help(renderingIssue)
                Spacer(minLength: 0)
                iconButton("Open in Anki", symbol: "arrow.up.forward.app") { droplet.openAnki() }
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }

        if session.phase == .question {
            HStack {
                Spacer(minLength: 0)
                Button("Show answer") { session.reveal() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                Spacer(minLength: 0)
            }
            .disabled(session.isBusy)
        } else {
            HStack(spacing: DroppySpacing.xsm) {
                ForEach(card.ratings) { rating in
                    Button { session.grade(rating.ease) } label: {
                        VStack(spacing: 2) {
                            Text(rating.title)
                            if !rating.interval.isEmpty {
                                Text(rating.interval).font(.system(size: 9)).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    .help("\(rating.title)\(rating.interval.isEmpty ? "" : ", \(rating.interval)")")
                }
            }
            .disabled(session.isBusy)
        }
    }

    @ViewBuilder
    private var pairedBody: some View {
        if session.isReviewing || session.phase == .paused {
            Text(session.card?.deckName ?? session.selectedDeck)
                .font(.system(size: 13, weight: .medium)).lineLimit(2)
            Text("\(session.reviewedCount)")
                .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(session.phase == .paused ? "Reviewed · paused" : "Reviewed this session")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text("Open the full widget to read and rate cards.")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            Button("Open review") { droplet.openSoloReview() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        } else if session.phase == .uncertain {
            statusBody
        } else {
            Text(session.selectedDeck.isEmpty ? "Ready when you are" : session.selectedDeck)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let deck = session.selectedDeckInfo {
                Text(deck.dueCountText)
                    .font(.system(size: deck.dueCount == nil ? 11 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if session.isConnected {
                Button("Open review") { droplet.openSoloReview() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            } else {
                Button("Set up") { droplet.openSettings() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
    }

    private var statusBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            switch session.phase {
            case .ready:
                HStack {
                    deckMenu
                    Spacer(minLength: 0)
                    if let deck = session.selectedDeckInfo {
                        Text(deck.dueCountText).monospacedDigit()
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                HStack {
                    Button("Start review") { session.start() }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        .disabled(session.isBusy || session.selectedDeck.isEmpty)
                    if session.reviewedCount > 0 { reviewedLabel }
                    Spacer(minLength: 0)
                    iconButton("Refresh decks", symbol: "arrow.clockwise") { session.connect() }
                        .disabled(session.isBusy)
                }
                if session.decks.isEmpty { statusText("Create a deck in Anki, then refresh.") }
            case .paused:
                Text("Review paused").font(.system(size: 18, weight: .semibold))
                statusText(session.card?.deckName ?? session.selectedDeck)
                reviewedLabel
                HStack {
                    Button("Resume") { session.resume() }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                        .disabled(session.isBusy)
                    Button("Stop") { session.stop() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .uncertain:
                Text("Check your last rating").font(.system(size: 15, weight: .semibold))
                statusText(session.message ?? AnkiError.uncertainGrade.message)
                HStack {
                    Button("Check status") { session.refreshReview() }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small)).disabled(session.isBusy)
                    Button("Open Anki") { droplet.openAnki() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                Button("I've checked Anki…") { confirmChecked = true }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(session.isBusy)
            case .ended, .interrupted:
                Text(session.phase == .ended ? "Review ended in Anki" : "Review interrupted")
                    .font(.system(size: 15, weight: .semibold))
                statusText(session.message ?? "Refresh the current review to continue.")
                HStack {
                    Button("Refresh") { session.refreshReview() }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small)).disabled(session.isBusy)
                    Button("Finish") { session.stop() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    reviewedLabel
                }
            case .disconnected:
                Text("Connect to Anki").font(.system(size: 18, weight: .semibold))
                statusText(session.message ?? "Review your flashcards without leaving the shelf.")
                HStack {
                    Button("Set up") { droplet.openSettings() }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Button("Open Anki") { droplet.openAnki() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .question, .answer:
                EmptyView()
            }
            if let message = droplet.workspaceMessage { statusText(message) }
        }
    }

    private var deckMenu: some View {
        Menu {
            ForEach(session.decks) { deck in
                Button(deck.name) { session.selectDeck(deck.name) }
            }
        } label: {
            Text(session.selectedDeck.isEmpty ? "Choose deck" : session.selectedDeck).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .font(.system(size: 14, weight: .medium))
        .disabled(!session.canChooseDeck)
        .help("Choose a deck")
    }

    private var reviewedLabel: some View {
        Text("\(session.reviewedCount) reviewed").font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private func statusText(_ text: String) -> some View {
        Text(text).font(.system(size: 11))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help(title).accessibilityLabel(title)
    }
}
