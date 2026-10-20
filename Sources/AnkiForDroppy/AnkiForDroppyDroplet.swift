import AppKit
import Combine
import DroppyKit
import SwiftUI

@objc(AnkiForDroppyPrincipal)
public final class AnkiForDroppyPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { AnkiForDroppyDroplet() }
}

@MainActor
public final class AnkiForDroppyDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "anki-for-droppy"
    package static let widgetID: ShelfWidgetID = "anki-for-droppy"

    package let session: ReviewSession
    @Published package var portText = "8765"
    @Published package var apiKey = ""
    @Published package var showsLiveProgress = true {
        didSet { syncHost() }
    }
    @Published package private(set) var workspaceMessage: String?

    private var host: DropletHost?
    private var connectionPort = 8765
    private var lastHold = false
    private var lastHeight = 150
    private var isActivating = false
    private let clientFactory: @Sendable (Int, String) -> any AnkiReviewing
    private let onActivation: (@MainActor (ReviewSession) -> Void)?
    private let activity = CurrentValueSubject<LiveActivityState?, Never>(nil)

    public override convenience init() {
        self.init(clientFactory: { AnkiConnectClient(port: $0, key: $1) })
    }

    package init(clientFactory: @escaping @Sendable (Int, String) -> any AnkiReviewing,
                 onActivation: (@MainActor (ReviewSession) -> Void)? = nil) {
        self.clientFactory = clientFactory
        self.onActivation = onActivation
        session = ReviewSession(client: clientFactory(8765, ""))
        super.init()
        session.onChange = { [weak self] in self?.syncHost() }
    }

    public func activate(host: DropletHost) throws {
        isActivating = true
        defer { isActivating = false; syncHost() }
        self.host = host
        connectionPort = host.preferences.value(forKey: "port", default: 8765)
        if !(1...65535).contains(connectionPort) { connectionPort = 8765 }
        portText = String(connectionPort)
        showsLiveProgress = host.preferences.value(forKey: "liveProgress", default: true)
        let selected: String = host.preferences.value(forKey: "deck", default: "")
        let pending = host.preferences.value(forKey: "pendingGrade", as: PendingGrade.self)
        session.replaceClient(clientFactory(connectionPort, apiKey), port: connectionPort)
        session.activate(networkAllowed: host.isGranted(.networkClient), selectedDeck: selected, pendingGrade: pending)
        if let onActivation {
            onActivation(session)
        } else if host.preferences.value(forKey: "hasConnected", default: false) {
            session.connect()
        }
        host.log.info("Anki review widget activated")
    }

    public func deactivate() {
        session.deactivate()
        activity.send(nil)
        if lastHold { host?.shelf.setHoldsOpen(false) }
        lastHold = false
        apiKey = ""
        host = nil
    }

    package func connect() {
        guard let port = Int(portText), (1...65535).contains(port) else {
            workspaceMessage = "Enter a local port between 1 and 65535."
            return
        }
        workspaceMessage = nil
        connectionPort = port
        portText = String(port)
        session.replaceClient(clientFactory(port, apiKey), port: port)
        session.connect()
    }

    package func openSettings() {
        if host?.workspace.openSettings() != true {
            workspaceMessage = "Open this droplet's settings in Droppy."
        }
    }

    package func openAnki() {
        guard !session.isBusy else {
            workspaceMessage = "Wait for the current Anki action to finish before switching reviewers."
            return
        }
        session.pause()
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.ankiweb.dtop")
            ?? ["/Applications/Anki.app", NSHomeDirectory() + "/Applications/Anki.app"]
                .first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
        guard let url else {
            workspaceMessage = "Anki was not found. Install or open Anki, then connect again."
            return
        }
        if host?.workspace.open(url) != true { workspaceMessage = "Open Anki manually to continue." }
    }

    package func openSoloReview() {
        guard let host, host.isGranted(.shelfWrite), host.shelf.open(revealing: Self.widgetID) else {
            workspaceMessage = "Open this widget alone from Droppy's shelf to review cards."
            return
        }
    }

    private func syncHost() {
        guard let host, !isActivating else { return }
        host.preferences.setValue(connectionPort, forKey: "port")
        host.preferences.setValue(session.selectedDeck, forKey: "deck")
        host.preferences.setValue(showsLiveProgress, forKey: "liveProgress")
        host.preferences.setValue(session.pendingGrade, forKey: "pendingGrade")
        if session.isConnected { host.preferences.setValue(true, forKey: "hasConnected") }
        let holds = session.isReviewing
        if holds != lastHold {
            if host.isGranted(.shelfWrite) { host.shelf.setHoldsOpen(holds) }
            lastHold = holds
        }
        let height = session.usesReviewHeight ? 260 : 150
        if height != lastHeight {
            lastHeight = height
            if host.isGranted(.shelfWrite) { host.shelf.invalidateLayout(for: Self.widgetID) }
        }
        if session.isReviewing && showsLiveProgress {
            activity.send(LiveActivityState(priority: 100,
                accessibilityTitle: "Anki review, \(session.reviewedCount) reviewed", isInteractive: false))
        } else {
            activity.send(nil)
        }
    }
}

extension AnkiForDroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: Self.widgetID, title: "Anki review", systemImage: "rectangle.on.rectangle",
            layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 420, preferredPairedWidth: 210,
                contentHeight: .fixed(session.usesReviewHeight ? 260 : 150)),
            searchKeywords: ["Anki", "flashcards", "study", "review"])]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(AnkiShelfWidget(droplet: self, session: session, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension AnkiForDroppyDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(AnkiSettingsView(droplet: self, session: session))
    }
}

extension AnkiForDroppyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> { activity.eraseToAnyPublisher() }

    public func makeCompactLeading() -> AnyView {
        AnyView(Image(systemName: "rectangle.on.rectangle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.trailing, DroppySpacing.sm))
    }

    public func makeCompactTrailing() -> AnyView { AnyView(AnkiCompactProgress(session: session)) }
    public func makeExpanded(context: LiveActivityContext) -> AnyView { AnyView(EmptyView()) }
}

private struct AnkiCompactProgress: View {
    @ObservedObject var session: ReviewSession
    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
            Text("\(session.reviewedCount)").monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.leading, DroppySpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.reviewedCount) reviewed")
    }
}
