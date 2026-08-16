import SwiftUI

@main
struct HarmonyUpApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: PracticeAttempt.self)
    }
}
