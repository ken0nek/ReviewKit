import SwiftUI

@main
struct ReviewKitExampleApp: App {
    @StateObject private var gate = ExampleReviewGate()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView(gate: gate)
            }
            .task {
                // Once per window, before anything reads the counters. An app
                // with several windows counts once per process instead.
                // `recordLaunch()` is `nonisolated` — counting never needs the
                // main actor, only presenting does.
                gate.counters.recordLaunch()
                gate.note("recordLaunch()")
            }
        }
    }
}
