import Foundation
import Testing
@testable import ReviewKit

/// Isolated storage per test: one persistent domain for the whole run, with a
/// unique set of `ReviewKeys` handed to each caller. Second copy of the type
/// documented at length in `ReviewPromptFlowTests.swift` — `ThrowawaySuites` is
/// `private` to that file, so a suite in a different file needs its own. Same
/// domain name on purpose, so the domain count for this target stays bounded at
/// one either way.
private final class ThrowawaySuites {
    /// `nonisolated(unsafe)` because `UserDefaults` is documented thread-safe but
    /// is not marked `Sendable` — the same idiom, for the same reason, that
    /// `ReviewCounters` uses on its own `defaults` property.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "ReviewKitTests.scratch")!

    private var made: [ReviewKeys] = []

    func makeCounters(now: @escaping @Sendable () -> Date = { Date() }) -> ReviewCounters {
        let id = UUID().uuidString
        let keys = ReviewKeys(
            launchCount: "\(id).launchCount",
            valueMomentCount: "\(id).valueMomentCount",
            firstUseAt: "\(id).firstUseAt",
            lastPromptedAt: "\(id).lastPromptedAt",
            lastSetbackAt: "\(id).lastSetbackAt"
        )
        made.append(keys)
        return ReviewCounters(defaults: Self.defaults, keys: keys, now: now)
    }

    deinit {
        for keys in made {
            let names = [
                keys.launchCount, keys.valueMomentCount,
                keys.firstUseAt, keys.lastPromptedAt,
            ] + [keys.lastSetbackAt].compactMap { $0 }
            for name in names { Self.defaults.removeObject(forKey: name) }
        }
    }
}

/// Pins the isolation contract `ReviewPromptFlow.swift` calls load-bearing: that
/// a background context — a widget timeline, a share extension, a separate App
/// Intents extension process — can both build a flow and count on it, with no
/// hop to the main actor anywhere in that path.
///
/// Deliberately **not** `@MainActor`, unlike `ReviewPromptFlowTests` — adding it
/// would silently void every test below, since the whole point is exercising
/// `init` and the three recorders from somewhere with no main-actor flow to
/// reach.
///
/// The mutation gate here does not look like the rest of the package's. Every
/// other load-bearing invariant goes red as a failing assertion. An isolation
/// contract is enforced by the type system before any assertion runs, so its red
/// is a **failed build**, not a failed test. Remove `nonisolated` from `init`,
/// `recordLaunch()`, `recordValueMoment()` or `recordSetback()` and
/// `swift build --build-tests` fails to compile, naming this file — that compile
/// error is the pin, not a broken test suite.
@Suite("flow isolation")
struct FlowIsolationTests {
    private let suites = ThrowawaySuites()

    /// The gap this pins: `recordValueMoment()` is `nonisolated` so a background
    /// App Intent, a widget timeline or a share extension can count — but until
    /// the initializer was `nonisolated` too, such a caller could not build a
    /// flow at all. In a separate extension process there is no main-actor flow
    /// to reach, so the `nonisolated` recorders were only half a solution.
    @Test("a background context can build a flow and count on it")
    func backgroundConstructionAndCounting() async {
        let counters = suites.makeCounters()
        let counted = await Task.detached { () -> Int in
            let flow = ReviewPromptFlow(counters: counters)
            flow.recordValueMoment()
            flow.recordLaunch()
            return counters.state.valueMomentCount
        }.value

        #expect(counted == 1)
    }

    /// The plain forwarding contract, currently pinned by nothing: every
    /// `record*` reference elsewhere in the test target is on `counters`
    /// directly, never on a `flow`.
    @Test("the flow's recorders forward to the counters")
    func flowRecordersForwardToTheCounters() {
        let counters = suites.makeCounters()
        let flow = ReviewPromptFlow(counters: counters)

        flow.recordLaunch()
        flow.recordLaunch()
        flow.recordValueMoment()
        flow.recordValueMoment()
        flow.recordValueMoment()

        #expect(counters.state.launchCount == 2)
        #expect(counters.state.valueMomentCount == 3)
    }

    /// The counters-level equivalent exists (`ReviewPromptFlowTests.swift`'s "a
    /// value moment alone still anchors first use"). The flow-level one did not.
    @Test("counting through the flow stamps the first-use anchor")
    func flowRecordersStampTheFirstUseAnchor() {
        let counters = suites.makeCounters()
        let flow = ReviewPromptFlow(counters: counters)

        flow.recordValueMoment()

        #expect(counters.state.firstUseAt != nil)
    }

    /// Pins the documented "counting is not committing" property (see the
    /// counting section of `ReviewPromptFlow.swift`): a caller with no way to
    /// present anything can count freely without ever spending the cooldown a
    /// real ask would stamp.
    @Test("counting through the flow never stamps the cooldown")
    func countingDoesNotCommit() {
        let counters = suites.makeCounters()
        let flow = ReviewPromptFlow(counters: counters)

        flow.recordLaunch()
        flow.recordValueMoment()
        flow.recordSetback()

        #expect(counters.state.lastPromptedAt == nil)
    }
}
