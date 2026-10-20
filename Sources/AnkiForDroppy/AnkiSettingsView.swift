import DroppyKit
import SwiftUI

struct AnkiSettingsView: View {
    @ObservedObject var droplet: AnkiForDroppyDroplet
    @ObservedObject var session: ReviewSession

    var body: some View {
        DropletSettingsPane {
            DropletSettingsSection {
                Text("Connection")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Local address", icon: "network") {
                        Text("127.0.0.1").foregroundStyle(.secondary).monospaced()
                    }
                    DropletControlRow(title: "Port") {
                        TextField("Port", text: $droplet.portText, prompt: Text("8765"))
                            .labelsHidden().frame(width: 90).disabled(session.isBusy)
                            .accessibilityLabel("AnkiConnect port")
                    }
                    DropletStackedRow(title: "API key", infoTip: "Optional. Only needed if configured in AnkiConnect.") {
                        SecureField("API key", text: $droplet.apiKey, prompt: Text("Optional · not saved"))
                            .labelsHidden().disabled(session.isBusy).accessibilityLabel("AnkiConnect API key")
                        Text("Kept in memory only. Re-enter after restarting or re-enabling the droplet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DropletControlRow(title: "Status") {
                        HStack {
                            Text(session.isBusy ? "Working…" : (session.isConnected ? "Connected" : "Not connected"))
                                .foregroundStyle(.secondary)
                            Button("Connect") { droplet.connect() }
                                .buttonStyle(.borderedProminent).disabled(session.isBusy)
                        }
                    }
                    if let message = session.message {
                        DropletStackedRow(title: "Connection details") {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }
                    if let message = droplet.workspaceMessage {
                        DropletStackedRow(title: "Action needed") {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            DropletSettingsSection {
                Text("Review")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Default deck", icon: "rectangle.on.rectangle") {
                        if session.decks.isEmpty {
                            Text("Connect to load decks").foregroundStyle(.secondary)
                        } else {
                            Picker("Default deck", selection: Binding(get: { session.selectedDeck }, set: { session.selectDeck($0) })) {
                                ForEach(session.decks) { deck in Text(deck.name).tag(deck.name) }
                            }
                            .labelsHidden().disabled(!session.canChooseDeck)
                        }
                    }
                    DropletToggleRow(title: "Session progress in the notch",
                        subtitle: "Only while actively reviewing. Other Droppy activities may take its place.",
                        isOn: $droplet.showsLiveProgress)
                    DropletStackedRow(title: "One reviewer at a time") {
                        Text("Droppy shares Anki's active reviewer. Do not rate cards in Anki and Droppy at the same time. Anki owns scheduling and saves every review.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DropletSettingsSection {
                Text("Setup and compatibility")
            } content: {
                DropletSettingsCard {
                    DropletStackedRow(title: "Install AnkiConnect") {
                        Text("In Anki, choose Tools → Add-ons → Get Add-ons and enter 2055492159. Restart Anki, keep it running, then connect here. The connection stays on this Mac.")
                            .foregroundStyle(.secondary)
                        Button("Open Anki") { droplet.openAnki() }.buttonStyle(.bordered)
                    }
                    DropletStackedRow(title: "Card support") {
                        Text("HTML, cloze formatting and supported collection media are displayed without scripts or remote resources. Interactive templates, typed answers, MathJax and some Anki audio/TTS need Anki's own reviewer. Use Open in Anki when content is missing.")
                            .foregroundStyle(.secondary)
                    }
                    DropletStackedRow(title: "If a rating is uncertain") {
                        Text("The rating is never automatically sent again. Check status to look for a saved review, or check it in Anki before acknowledging and starting another session. Pausing or stopping does not undo a saved review.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
