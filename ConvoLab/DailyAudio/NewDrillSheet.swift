import SwiftUI

struct NewDrillSheet: View {
    let capabilities: StudyCapabilities.DailyAudio
    let replacing: Bool
    let generate: (DailyAudioEditionDuration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edition: DailyAudioEditionDuration
    @State private var confirming = false

    init(capabilities: StudyCapabilities.DailyAudio, replacing: Bool, generate: @escaping (DailyAudioEditionDuration) -> Void) {
        self.capabilities = capabilities
        self.replacing = replacing
        self.generate = generate
        _edition = State(initialValue: DailyAudioEditionDuration.preferred(for: capabilities))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(confirming ? "Replace today’s recording?" : "New audio drill")
                    .font(StudyTimePaper.type(30, .title)).accessibilityAddTraits(.isHeader)
                if confirming {
                    Text("This will replace today’s drill with a new recording.")
                } else {
                    Text("Drill length").font(.subheadline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                        ForEach(DailyAudioEditionDuration.available(for: capabilities)) { option in
                            Button { edition = option } label: {
                                Text(option.label).frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(option == edition ? .white : DrillPaper.ink)
                                    .background(option == edition ? DrillPaper.accent : StudyTimePaper.paper, in: Capsule())
                                    .overlay { Capsule().stroke(DrillPaper.rule) }
                            }.buttonStyle(.plain).accessibilityAddTraits(option == edition ? .isSelected : [])
                        }
                    }
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
            }
            .font(StudyTimePaper.type(19)).padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.top, 12).foregroundStyle(DrillPaper.ink).presentationBackground(DrillPaper.surface)
    }

    @ViewBuilder private var actions: some View {
        Button {
            if replacing && !confirming { confirming = true }
            else { generate(edition) }
        } label: {
            Text(confirming ? "Replace recording" : "Generate \(edition.rawValue)-min drill")
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(.white).background(DrillPaper.accent, in: Capsule())
        }.buttonStyle(.plain)
        Button("Cancel") { dismiss() }.padding(.horizontal, 8).frame(minHeight: 44)
    }
}
