import Foundation
import Testing
@testable import ReviewKit

/// Isolated storage per test: **one** persistent domain for the whole run, with a
/// unique set of ``ReviewKeys`` handed to each caller.
///
/// A second copy of the type in `ReviewPromptFlowTests.swift`, `private` to this
/// file the way Swift requires — see that file for the full account of why a
/// suite per test leaks a plist into `~/Library/Preferences` permanently, and why
/// isolating by unique keys on one shared domain is the fix instead. Same domain
/// name as that file's copy, deliberately: the isolation comes from the keys, not
/// from the suite, so both copies have to agree on which suite they share.
private final class ThrowawaySuites {
    /// `nonisolated(unsafe)` for the same reason `ReviewCounters` marks its own
    /// `defaults` that way: `UserDefaults` is thread-safe but unmarked.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "ReviewKitTests.scratch")!

    private var made: [ReviewKeys] = []

    /// - Parameter tracksSetbacks: `false` to hand back keys with a `nil`
    ///   `lastSetbackAt`, which is how a host opts out of setbacks entirely.
    func makeCounters(
        tracksSetbacks: Bool = true,
        now: @escaping @Sendable () -> Date
    ) -> (ReviewCounters, UserDefaults, ReviewKeys) {
        let id = UUID().uuidString
        let keys = ReviewKeys(
            launchCount: "\(id).launchCount",
            valueMomentCount: "\(id).valueMomentCount",
            firstUseAt: "\(id).firstUseAt",
            lastPromptedAt: "\(id).lastPromptedAt",
            lastSetbackAt: tracksSetbacks ? "\(id).lastSetbackAt" : nil
        )
        made.append(keys)
        let defaults = Self.defaults
        return (ReviewCounters(defaults: defaults, keys: keys, now: now), defaults, keys)
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

/// The seam no existing test touched: ``ReviewCounters`` paired with
/// ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)`` and
/// ``ReviewGate/diagnose(trigger:state:configuration:now:)`` on an *injected*
/// clock.
///
/// `ReviewGateDiagnosisTests` proves the pure function agrees with itself at a
/// shared `now` — every call there passes `now:` explicitly, and every state is
/// built by hand. It cannot catch a caller supplying the *wrong* `now`, which is
/// exactly what `ReviewDiagnosticsView` did: it judged a snapshot read from
/// counters on an injected clock against `Date()`, the default, while the stamps
/// in that snapshot were written by the injected clock. These tests pin the
/// paired accessors that close the gap —
/// ``ReviewCounters/shouldPrompt(trigger:configuration:)`` and
/// ``ReviewCounters/diagnose(trigger:configuration:)`` — so the gate and the
/// screen that explains it can no longer drift apart.
@Suite("ReviewCountersGate")
struct ReviewCountersGateTests {
    private let suites = ThrowawaySuites()

    #if DEBUG
    /// **The regression.** Before this plan's fix, ``ReviewCounters/diagnose(trigger:configuration:)``
    /// forwarded to ``ReviewGate/diagnose(trigger:state:configuration:now:)``
    /// without `now:`, which defaults to `Date()` — wall time, not the clock that
    /// wrote the stamps. `t0` here is fixed years in the past, so a diagnosis
    /// judged on wall time reads the 120-day cooldown as having elapsed decades
    /// ago and says "yes", while the gate — judged correctly on the counters' own
    /// clock, one day into that cooldown — says "no". This is the exact
    /// divergence this plan was written against: the live screen reported "Would
    /// show: yes" with the cooldown reading "2419d of 120d, elapsed" while
    /// `commitToPromptIfEligible` refused to commit.
    @Test("the diagnosis agrees with the gate on an injected clock")
    func diagnosisAgreesWithTheGateOnAnInjectedClock() {
        let t0 = Date(timeIntervalSince1970: 1_577_836_800)
        nonisolated(unsafe) var clock = t0
        let (counters, _, _) = suites.makeCounters(now: { clock })

        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0 ..< 5 { counters.recordLaunch() }
        counters.markPrompted()

        // One day into a 120-day cooldown — nowhere near elapsed on the counters'
        // own clock, but decades "elapsed" if read against wall time instead.
        clock = t0.addingTimeInterval(.days(1))
        counters.recordValueMoment()
        counters.recordValueMoment()

        #expect(
            counters.diagnose(trigger: .valueMoment, configuration: .default).wouldPrompt
                == counters.shouldPrompt(trigger: .valueMoment, configuration: .default)
        )
    }
    #endif

    /// The consolidation this plan makes: ``ReviewPromptFlow/commitToPromptIfEligible(trigger:)``
    /// now routes through ``ReviewCounters/shouldPrompt(trigger:configuration:)``
    /// rather than calling ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)``
    /// inline, so the two agree by construction. Pinned here anyway, the way this
    /// codebase pins a behavior even where it currently cannot fail: a future
    /// edit to either side can only be caught by a test that names the
    /// expectation.
    @Test("counters.shouldPrompt agrees with the flow's own commit door")
    @MainActor
    func shouldPromptMatchesTheFlowsOwnDoor() {
        let t0 = Date(timeIntervalSince1970: 1_577_836_800)
        // Floors only, no cooldown to bite — the same shape as
        // `ReviewPromptFlowTests.permissive`, so the state is eligible the moment
        // the floors are cleared rather than after also waiting out a span.
        let config = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(minimumValueMoments: 2, minimumLaunches: 5),
            launchFallback: LaunchFallbackPolicy(minimumLaunches: 20)
        )
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0 ..< 5 { counters.recordLaunch() }

        // Read before the commit: committing stamps the cooldown and zeroes the
        // value-moment counter, either of which would change the answer out from
        // under this comparison if read afterwards instead.
        let expected = counters.shouldPrompt(trigger: .valueMoment, configuration: config)
        #expect(expected)

        let flow = ReviewPromptFlow(counters: counters, configuration: config)
        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment) == expected)
    }

    #if DEBUG
    /// Isolates the one row the regression above turns on: the cooldown check,
    /// read immediately after `markPrompted()` stamps it. On the counters' own
    /// clock — fixed far in the past and never advanced in this test — the
    /// elapsed span is zero, so the row must read unmet. Read against wall time
    /// instead, the same stamp is years old and would read as met, which is the
    /// bug this plan fixes one layer up, in `ReviewDiagnosticsView`.
    @Test("diagnose reads the cooldown against the counters' clock, not wall time")
    func diagnoseSeesTheCountersClockNotWallTime() {
        let t0 = Date(timeIntervalSince1970: 1_577_836_800)
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0 ..< 5 { counters.recordLaunch() }
        counters.markPrompted()

        let diagnosis = counters.diagnose(trigger: .valueMoment, configuration: .default)
        let cooldown = diagnosis.checks.first { $0.requirement == .cooldown }

        #expect(cooldown?.isMet == false)
    }
    #endif
}
