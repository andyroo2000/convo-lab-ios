import SwiftUI

struct JournalCompactAudioHeader: View {
    let player: JournalAudioPlayer
    let voice: JournalVoiceSelection
    let toggle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            JournalAvatar(url: voice.voices.first(where: { $0.id == voice.selected })?.avatarUrl)
                .frame(width: 38, height: 38).clipShape(Circle()).accessibilityHidden(true)
            JournalListenButton(player: player, label: "corrected version", disabled: !voice.isReady, toggle: toggle)
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color(red: 0.898, green: 0.933, blue: 0.984), in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
            .overlay(alignment: .bottom) { JournalSeekRibbon(player: player).offset(y: 20) }
            .zIndex(1)
    }
}

struct JournalSeekRibbon: View {
    let player: JournalAudioPlayer
    @GestureState private var dragFraction: Double?
    private var fraction: Double { dragFraction ?? (player.duration > 0 ? min(1, max(0, player.playbackPosition / player.duration)) : 0) }
    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(red: 0.81, green: 0.87, blue: 0.93)).frame(height: 3)
                    Rectangle().fill(JournalToolbarButtonStyle.blue).frame(width: geometry.size.width * fraction, height: 3)
                    Circle().fill(JournalToolbarButtonStyle.blue).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: max(0, min(geometry.size.width - 10, geometry.size.width * fraction - 5)))
                }.frame(height: 44).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).updating($dragFraction) { value, preview, _ in
                        guard player.duration > 0, geometry.size.width > 0 else { return }
                        preview = min(1, max(0, value.location.x / geometry.size.width))
                    }.onEnded { value in
                        guard geometry.size.width > 0 else { return }
                        player.seek(min(1, max(0, value.location.x / geometry.size.width)) * player.duration)
                    })
            }.frame(height: 44)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Corrected version audio position")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
                player.seek(player.playbackPosition + (direction == .increment ? 5 : -5))
            }
    }
}
