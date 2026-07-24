import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let user: CurrentUser

    @State private var wanikaniAPIToken = ""
    @State private var confirmingWaniKaniDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: user.name)
                    LabeledContent("Email", value: user.email)
                }

                Section("Offline") {
                    LabeledContent(
                        "Downloaded media",
                        value: ByteCountFormatter.string(
                            fromByteCount: model.mediaCache.totalByteCount,
                            countStyle: .file
                        )
                    )
                    LabeledContent("Study window", value: "5 days")
                    LabeledContent(
                        "Changes needing attention",
                        value: model.study.quarantinedMutationCount.formatted()
                    )
                    Text("Playback positions are stored only on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Integrations") {
                    if model.study.wanikaniConnected {
                        LabeledContent("WaniKani", value: "Connected")
                        LabeledContent(
                            "Known kanji",
                            value: model.study.knownKanji.count.formatted()
                        )
                        if let lastSyncedAt = model.study.wanikaniLastSyncedAt {
                            LabeledContent(
                                "WaniKani synced",
                                value: lastSyncedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                        }
                        Button("Sync WaniKani") {
                            Task { await model.study.syncWaniKani() }
                        }
                        .disabled(model.study.isWaniKaniWorking)
                        Button("Disconnect WaniKani", role: .destructive) {
                            confirmingWaniKaniDisconnect = true
                        }
                        .disabled(model.study.isWaniKaniWorking)
                    } else {
                        SecureField("WaniKani API token", text: $wanikaniAPIToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        Button("Connect and Sync") {
                            let token = wanikaniAPIToken
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.study.connectWaniKani(apiToken: token)
                                if model.study.wanikaniConnected {
                                    wanikaniAPIToken = ""
                                }
                            }
                        }
                        .disabled(
                            wanikaniAPIToken
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                                || model.study.isWaniKaniWorking
                        )
                    }

                    if model.study.isWaniKaniWorking {
                        ProgressView("Updating WaniKani knowledge…")
                    }
                    if let error = model.study.wanikaniErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text(
                        "Furigana stays visible unless every kanji in a word is in your synced known-kanji set. The API token is sent to learning-os and is never saved on this device."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Button("Sync Now") {
                        Task {
                            await model.synchronize()
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await model.auth.logout() }
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Disconnect WaniKani?",
                isPresented: $confirmingWaniKaniDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task { await model.study.disconnectWaniKani() }
                }
                .disabled(model.study.isWaniKaniWorking)
            } message: {
                Text("Previously learned kanji remain known in learning-os.")
            }
        }
    }
}
