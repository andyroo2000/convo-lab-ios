import SwiftUI

struct JournalMinimalAudioControls: View {
    let player: JournalAudioPlayer
    let label: String
    var disabled = false
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Group {
                    if player.preparing { ProgressView().tint(.white) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold)) }
                }.foregroundStyle(.white).frame(width: 34, height: 34).background(Color.accentColor, in: .circle)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled || player.preparing)
                .accessibilityLabel("\(player.isPlaying ? "Pause" : "Play") \(label)")
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(player.duration, 1), onEditingChanged: { player.setSeeking($0) })
                .disabled(player.duration == 0).accessibilityLabel("\(label) audio position")
                .accessibilityValue(clock(player.position))
                .accessibilityAction(named: "Previous sentence") { player.moveSentence(-1) }
                .accessibilityAction(named: "Next sentence") { player.moveSentence(1) }
            Text(clock(player.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 30)
        }.focusable()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        guard !player.sentences.isEmpty else { return .ignored }
        player.moveSentence(direction)
        return .handled
    }
    private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
