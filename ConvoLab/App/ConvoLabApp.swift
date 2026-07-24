import SwiftUI
import SwiftData

@main
struct ConvoLabApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .modelContainer(model.container)
                .task {
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.applicationDidBecomeActive()
                    }
                }
        }
    }
}
