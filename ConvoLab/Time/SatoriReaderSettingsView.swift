import SwiftUI

struct SatoriReaderSettingsView: View {
    let tracking: SatoriReaderTrackingStore

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: SatoriReaderTrackingSnapshot
    @State private var showingSetupInstructions: Bool

    init(tracking: SatoriReaderTrackingStore) {
        self.tracking = tracking
        let snapshot = tracking.snapshot()
        _snapshot = State(initialValue: snapshot)
        _showingSetupInstructions = State(
            initialValue: snapshot.detectionStatus != .detected
        )
    }

    var body: some View {
        Form {
            Section("Status") {
                statusLabel
                if let lastStartedAt = snapshot.lastStartedAt {
                    LabeledContent("Last start detected") {
                        Text(lastStartedAt, format: .dateTime.month().day().hour().minute())
                    }
                }
                if let lastStoppedAt = snapshot.lastStoppedAt {
                    LabeledContent("Last stop detected") {
                        Text(lastStoppedAt, format: .dateTime.month().day().hour().minute())
                    }
                }
                Text(
                    "ConvoLab cannot read your personal automations. It marks tracking as detected after both actions have run on this iPhone."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if showingSetupInstructions {
                Section("1. Track opening Satori Reader") {
                    setupStep(1, "In Shortcuts, open Automation and tap +.")
                    setupStep(2, "Choose App, select Satori Reader, then choose Is Opened.")
                    setupStep(3, "Choose Run Immediately and continue.")
                    setupStep(
                        4,
                        "Add the ConvoLab action Start Satori Reader Session, then save."
                    )
                }

                Section("2. Track closing Satori Reader") {
                    setupStep(1, "Create another App automation for Satori Reader.")
                    setupStep(2, "Choose Is Closed and Run Immediately.")
                    setupStep(
                        3,
                        "Add the ConvoLab action Stop Satori Reader Session, then save."
                    )
                }
            } else {
                Section {
                    Button("View Setup Instructions") {
                        showingSetupInstructions = true
                    }
                }
            }

            Section("Test Tracking") {
                verificationLabel
                Button("Start Test") {
                    tracking.beginVerification()
                    refresh()
                }
                Text(
                    "After starting the test, open Satori Reader and then return here. ConvoLab should detect both automation actions."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("Satori Reader")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refresh()
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch snapshot.detectionStatus {
        case .notDetected:
            Label("Tracking not detected", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .partiallyDetected:
            Label("One action detected", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .detected:
            Label("Tracking detected on this iPhone", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var verificationLabel: some View {
        switch snapshot.verificationStatus {
        case .notStarted:
            Text("Run a quick test after creating both automations.")
                .foregroundStyle(.secondary)
        case .waiting:
            Label("Waiting for both actions", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .partiallyDetected:
            Label("One test action detected", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .succeeded:
            Label("Test passed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        snapshot = tracking.snapshot()
    }
}
