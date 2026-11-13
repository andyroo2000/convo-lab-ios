import SwiftUI

struct JournalTimeTracking: ViewModifier {
    let service: JournalService
    @Environment(StudyTimeStore.self) private var store: StudyTimeStore?
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var tracker = ReadingTimeTracker(activity: .journal)

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: scenePhase) { update() }
    }

    private func update() {
        let canTrack = visible && scenePhase == .active && (try? service.checkSession()) != nil
        tracker.update(title: canTrack ? "Journal" : nil, store: store)
    }
}
