import SwiftUI

enum JournalPlaybackAction: String {
    case listen = "Listen", loading = "Loading…", pause = "Pause", resume = "Resume", replay = "Replay"

    static func current(preparing: Bool, playing: Bool, position: Double, duration: Double) -> Self {
        if preparing { return .loading }
        if playing { return .pause }
        if duration > 0, position >= duration { return .replay }
        return position > 0 ? .resume : .listen
    }

    var icon: String {
        switch self {
        case .listen, .loading: "speaker.wave.2"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .replay: "arrow.counterclockwise"
        }
    }
}

struct JournalListenButton: View {
    let player: JournalAudioPlayer
    let label: String
    var disabled = false
    let toggle: () -> Void
    @FocusState private var keyboardFocused: Bool

    private var action: JournalPlaybackAction {
        .current(preparing: player.preparing, playing: player.isPlaying, position: player.position, duration: player.duration)
    }

    var body: some View {
        Button { toggle(); keyboardFocused = true } label: {
            HStack(spacing: 6) {
                if player.preparing { ProgressView().controlSize(.small) }
                else { Image(systemName: action.icon).font(.caption) }
                Text(action.rawValue).font(.subheadline)
            }.padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(Color(red: 0.19, green: 0.36, blue: 0.52))
                .background(.white, in: .capsule)
                .overlay(Capsule().stroke(Color(red: 0.74, green: 0.81, blue: 0.89)))
        }.buttonStyle(.plain).disabled(disabled || player.preparing)
            .accessibilityLabel("\(action.rawValue) \(label)")
            .accessibilityAction(named: "Previous sentence") { player.moveSentence(-1) }
            .accessibilityAction(named: "Next sentence") { player.moveSentence(1) }
            .focusable().focused($keyboardFocused).focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        guard !player.sentences.isEmpty else { return .ignored }
        player.moveSentence(direction)
        return .handled
    }
}

struct JournalRibbonProgress: View {
    let player: JournalAudioPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var progress: Double { player.duration > 0 ? min(1, max(0, player.position / player.duration)) : 0 }

    var body: some View {
        if player.duration > 0 {
            GeometryReader { geometry in
                Rectangle().fill(Color(red: 0.81, green: 0.87, blue: 0.93))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color(red: 0.13, green: 0.28, blue: 0.42))
                            .frame(width: geometry.size.width * progress)
                    }
            }.frame(height: 3).allowsHitTesting(false)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel("Playback progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
        }
    }
}
