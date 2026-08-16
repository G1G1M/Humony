import SwiftUI

@main
struct HarmonyUpApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: PracticeAttempt.self)
    }
}
