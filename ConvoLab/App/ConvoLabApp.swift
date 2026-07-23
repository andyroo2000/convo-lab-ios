import SwiftUI
import SwiftData

@main
struct ConvoLabApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .modelContainer(model.container)
                .task {
                    await model.start()
                }
        }
    }
}
