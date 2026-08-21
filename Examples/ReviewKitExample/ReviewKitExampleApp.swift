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
                // Once per launch, before anything reads the counters.
                // `recordLaunch()` is `nonisolated` — counting never needs the
                // main actor, only presenting does.
                gate.counters.recordLaunch()
                gate.note("recordLaunch()")
            }
        }
    }
}
