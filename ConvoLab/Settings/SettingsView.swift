import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let user: CurrentUser

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
                    LabeledContent("WaniKani", value: "Fast-follow")
                    Text("Connection and manual sync will use the existing learning-os integration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Sync Now") {
                        Task {
                            await model.study.synchronize()
                            await model.dailyAudio.refresh()
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await model.auth.logout() }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
