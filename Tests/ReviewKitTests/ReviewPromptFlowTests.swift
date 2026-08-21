import Foundation
import Testing
@testable import ReviewKit

/// Isolated storage per test: **one** persistent domain for the whole run, with a
/// unique set of ``ReviewKeys`` handed to each caller.
///
/// The obvious design is a `UserDefaults(suiteName:)` per test, and that is what
/// this was. It leaks, permanently: a suite name registers a **persistent**
/// domain, and the first write leaves `~/Library/Preferences/<suite>.plist`
/// behind. Nearly two thousand of them had accumulated before anyone counted,
/// while the comment here claimed nothing leaked "onto the machine".
///
/// Teardown does not fix it, and the reason is worth writing down because the
/// fix looks like it should work: `removePersistentDomain(forName:)` empties the
/// file without unlinking it, and unlinking it as well *still* loses, because
/// `cfprefsd` is a separate daemon that flushes its pending domains roughly five
/// seconds **after** the test process has exited — recreating every file. No
/// in-process teardown can win that race. All of this is measured rather than
/// assumed. Re-measure the same way, by counting the plists ten seconds after a
/// run rather than immediately.
///
/// So the domain count is bounded at one instead. Isolation comes from unique
/// **keys**, which is the seam ReviewKit exposes anyway and exercises the
/// host-injects-the-keys design while it is at it. The single scratch file is
/// stable and never grows in number; ``deinit`` removes the keys each test made
/// so it does not grow in size either.
private final class ThrowawaySuites {
    /// One domain for the whole run. Deliberately *not* per-test — see above.
    /// `nonisolated(unsafe)` because `UserDefaults` is documented thread-safe but
    /// is not marked `Sendable` — the same idiom, for the same reason, that
    /// `ReviewCounters` uses on its own `defaults` property.
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

/// A fixed instant every counters test measures against. File-scope rather than
/// a stored property so the `@Sendable` clock closures below capture a constant
/// instead of the suite — which is not `Sendable`, because it holds the
/// throwaway-suite tracker.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("ReviewCounters")
struct ReviewCountersTests {
    private let suites = ThrowawaySuites()

    @Test("the first-use anchor is first-write-wins")
    func firstUseAnchorNeverMoves() {
        nonisolated(unsafe) var clock = t0
        let (counters, _, _) = suites.makeCounters(now: { clock })

        counters.recordLaunch()
        clock = t0.addingTimeInterval(.days(30))
        counters.recordLaunch()

        #expect(counters.state.firstUseAt == t0)
        #expect(counters.state.launchCount == 2)
    }

    @Test("a value moment alone still anchors first use")
    func valueMomentAnchors() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordValueMoment()

        #expect(counters.state.valueMomentCount == 1)
        #expect(counters.state.firstUseAt == t0)
    }

    @Test("marking prompted stamps the cooldown and clears value moments")
    func markPrompted() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordValueMoment()
        counters.recordValueMoment()
        counters.markPrompted()

        #expect(counters.state.lastPromptedAt == t0)
        #expect(counters.state.valueMomentCount == 0)
    }

    @Test("reset clears every key it owns")
    func reset() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordLaunch()
        counters.recordValueMoment()
        counters.markPrompted()

        counters.reset()

        #expect(counters.state == ReviewState())
    }

    @Test("absent timestamps read as nil, not as 1970")
    func absentTimestampsAreNil() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        #expect(counters.state.firstUseAt == nil)
        #expect(counters.state.lastPromptedAt == nil)
    }

    /// An injected key from a shipped app can hold a `Date` object rather than
    /// epoch seconds — a prior implementation of this gate persisted its
    /// last-prompt stamp exactly that way. `double(forKey:)` returns `0` for such
    /// a value, which would read as "never prompted" and re-ask a user who is
    /// mid-cooldown: the unrecoverable direction ``ReviewKeys`` warns about.
    @Test("a legacy Date-object timestamp is read, not discarded")
    func legacyDateObjectTimestamps() {
        let (counters, defaults, keys) = suites.makeCounters(now: { t0 })
        let stampedAt = Date(timeIntervalSince1970: 1_799_000_000)
        defaults.set(stampedAt, forKey: keys.lastPromptedAt)
        defaults.set(stampedAt, forKey: keys.firstUseAt)

        #expect(counters.state.lastPromptedAt == stampedAt)
        #expect(counters.state.firstUseAt == stampedAt)
    }

    @Test("a legacy Date-object anchor survives a later launch")
    func legacyDateObjectAnchorIsNotOverwritten() {
        let (counters, defaults, keys) = suites.makeCounters(now: { t0 })
        let realFirstUse = t0.addingTimeInterval(-.days(200))
        defaults.set(realFirstUse, forKey: keys.firstUseAt)

        counters.recordLaunch()

        // First-write-wins has to recognise the existing write to honour it.
        #expect(counters.state.firstUseAt == realFirstUse)
    }

    /// Unlike ``ReviewCounters/markPrompted()``, a setback must not spend the
    /// user's progress toward the ask. A bad day defers the prompt. It does not
    /// make them start over.
    @Test("a setback stamps the time and leaves the value moments alone")
    func setbackStampsWithoutClearingProgress() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordValueMoment()
        counters.recordValueMoment()

        counters.recordSetback()

        #expect(counters.state.lastSetbackAt == t0)
        #expect(counters.state.valueMomentCount == 2)
    }

    /// Opting out is a `nil` key and nothing else — no second flag, and no key
    /// name owned by the package for a host that never wanted the feature.
    @Test("with no setback key the stamp is never written and never read")
    func setbackIsInertWithoutAKey() {
        let (counters, defaults, keys) = suites.makeCounters(tracksSetbacks: false, now: { t0 })
        #expect(keys.lastSetbackAt == nil)

        counters.recordSetback()

        #expect(counters.state.lastSetbackAt == nil)
        // Nothing was written anywhere in this test's own key space — the shared
        // scratch domain holds other tests' keys, so the assertion has to be
        // scoped rather than global.
        let ownPrefix = keys.launchCount.prefix(36)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy {
            !($0.hasPrefix(ownPrefix) && $0.localizedCaseInsensitiveContains("setback"))
        })
    }

    @Test("reset clears the setback stamp as well")
    func resetClearsTheSetback() {
        let (counters, _, _) = suites.makeCounters(now: { t0 })
        counters.recordSetback()
        #expect(counters.state.lastSetbackAt != nil)

        counters.reset()

        #expect(counters.state == ReviewState())
    }
}

@MainActor
@Suite("ReviewPromptFlow")
struct ReviewPromptFlowTests {
    private let suites = ThrowawaySuites()

    /// Count and launch floors only, so flow mechanics can be exercised without
    /// the cooldown or the first-use age closing the gate as a side effect.
    private static let permissive = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(minimumValueMoments: 2, minimumLaunches: 5),
        launchFallback: LaunchFallbackPolicy(minimumLaunches: 20)
    )

    /// The same floors with a cooldown that can actually bite.
    ///
    /// Every test here once ran on ``permissive`` alone, whose `cooldown` defaults
    /// to `0` — which meant a stamped cooldown could not influence any assertion
    /// in this suite, and deleting `counters.markPrompted()` from the flow left
    /// all of it green. Anything asserting on the stamp must use this.
    private static let strict = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(minimumValueMoments: 2, minimumLaunches: 5, cooldownDays: 120),
        launchFallback: LaunchFallbackPolicy(minimumLaunches: 20, cooldownDays: 120)
    )

    /// Counters that already clear every floor of both configurations above.
    private func seededCounters() -> ReviewCounters {
        let (counters, _, _) = suites.makeCounters(now: { Date() })
        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0..<5 { counters.recordLaunch() }
        return counters
    }

    private func makeFlow(
        _ configuration: ReviewConfiguration = ReviewPromptFlowTests.permissive
    ) -> (ReviewPromptFlow, ReviewCounters, Recorder) {
        let counters = seededCounters()
        let recorder = Recorder()
        let flow = ReviewPromptFlow(
            counters: counters,
            configuration: configuration,
            events: { recorder.events.append($0) }
        )
        return (flow, counters, recorder)
    }

    /// A flow over storage with nothing recorded — ineligible by every floor.
    private func makeUnseededFlow() -> (ReviewPromptFlow, ReviewCounters, Recorder) {
        let (counters, _, _) = suites.makeCounters(now: { Date() })
        let recorder = Recorder()
        let flow = ReviewPromptFlow(
            counters: counters,
            configuration: ReviewPromptFlowTests.strict,
            events: { recorder.events.append($0) }
        )
        return (flow, counters, recorder)
    }

    final class Recorder {
        var events: [ReviewEvent] = []
    }

    @Test("committing stamps the cooldown before anything is presented")
    func commitStampsCooldown() {
        let (flow, counters, recorder) = makeFlow()
        #expect(counters.state.lastPromptedAt == nil)

        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))

        // The whole point of the type: persisted before the caller can present,
        // so a crash or a backgrounding in between cannot leave the gate armed.
        #expect(counters.state.lastPromptedAt != nil)
        #expect(counters.state.valueMomentCount == 0)
        #expect(recorder.events == [.promptShown(.valueMoment)])
    }

    /// The regression that matters: with the cooldown stamped, a flow built on the
    /// next launch has to find it. Persisted state is the only thing carrying the
    /// bound across instances, so this is what would catch `markPrompted()` going
    /// missing.
    @Test("the stamped cooldown closes the gate for a later flow")
    func stampedCooldownOutlivesTheFlow() {
        let counters = seededCounters()
        let first = ReviewPromptFlow(counters: counters, configuration: Self.strict)
        #expect(first.commitToPromptIfEligible(trigger: .valueMoment))

        // Rebuild the value-moment evidence, so the cooldown is the only thing
        // left that can close the gate on the next launch's flow.
        counters.recordValueMoment()
        counters.recordValueMoment()

        let next = ReviewPromptFlow(counters: counters, configuration: Self.strict)
        #expect(!next.commitToPromptIfEligible(trigger: .valueMoment))
    }

    @Test("a host-initiated ask bypasses the gate but is still stamped")
    func manualCommitStampsCooldown() {
        let (flow, counters, recorder) = makeUnseededFlow()

        // The gate refuses — nothing is recorded at all.
        #expect(!flow.commitToPromptIfEligible(trigger: .valueMoment))
        // The user went looking for it in Settings, so it is shown anyway.
        #expect(flow.commitToPrompt(trigger: .valueMoment))

        #expect(counters.state.lastPromptedAt != nil)
        #expect(recorder.events == [.promptShown(.valueMoment)])
        // And it hands off exactly like an automatic ask.
        flow.recordOutcome(.positive)
        #expect(flow.promptDidDismiss() == .positive)
    }

    @Test("a host-initiated ask is refused while a prompt is in flight")
    func manualCommitIsNotReentrant() {
        let (flow, _, _) = makeFlow()

        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))
        #expect(!flow.commitToPrompt(trigger: .valueMoment))
    }

    /// SwiftUI can deliver `onDisappear` more than once, and a host wiring both
    /// `.sheet(onDismiss:)` and `onDisappear` double-calls by construction.
    @Test("dismissal is idempotent")
    func dismissalIsIdempotent() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        _ = flow.promptDidDismiss()
        _ = flow.promptDidDismiss()
        _ = flow.promptDidDismiss()

        #expect(recorder.events == [.promptShown(.valueMoment), .dismissed])
    }

    @Test("dismissing with nothing committed drives nothing")
    func dismissalWithoutCommitment() {
        let (flow, counters, recorder) = makeUnseededFlow()

        #expect(flow.promptDidDismiss() == nil)
        #expect(recorder.events.isEmpty)
        #expect(counters.state.lastPromptedAt == nil)
    }

    /// Rating something never committed to would hand off to the platform's
    /// review request with no cooldown stamped. In a debug build that misuse trips
    /// an `assertionFailure`, which would abort the run — so the guard's return
    /// path is observable only under `swift test -c release`.
    @Test("rating with nothing committed drives nothing", .enabled(if: !isDebugBuild))
    func outcomeWithoutCommitment() {
        let (flow, counters, recorder) = makeUnseededFlow()

        flow.recordOutcome(.positive)

        #expect(flow.promptDidDismiss() == nil)
        #expect(recorder.events.isEmpty)
        #expect(counters.state.lastPromptedAt == nil)
    }

    @Test("an automatic ask is refused while a prompt is in flight")
    func eligibleCommitIsNotReentrant() {
        let (flow, _, _) = makeFlow()

        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))
        #expect(!flow.commitToPromptIfEligible(trigger: .valueMoment))
    }

    /// What bounds the cadence once the prompt is *gone*: the stamped cooldown,
    /// not a per-session flag. The flow carries no session cap — with any real
    /// cooldown one could never be the binding constraint, and its only effect
    /// would be on a `0` cooldown, which prompts on every value moment anyway.
    @Test("a second ask in the same flow is refused by the stamped cooldown")
    func secondAskIsRefusedByTheCooldown() {
        let (flow, counters, _) = makeFlow(Self.strict)

        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))
        #expect(flow.promptDidDismiss() == nil)  // dismissed unrated: back to idle

        // Rebuild the value-moment evidence markPrompted() zeroed, so the cooldown
        // is the only floor left that can refuse.
        counters.recordValueMoment()
        counters.recordValueMoment()

        #expect(!flow.commitToPromptIfEligible(trigger: .valueMoment))
    }

    @Test("a positive rating defers the system request to dismissal")
    func positiveDefersToDismiss() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.recordOutcome(.positive)
        // Crucially, nothing has asked for the system prompt yet.
        #expect(recorder.events == [.promptShown(.valueMoment), .rated(.positive)])

        #expect(flow.promptDidDismiss() == .positive)
        #expect(recorder.events.last == .systemPromptRequested)
    }

    @Test("a negative rating never reaches the system prompt")
    func negativeStopsHere() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.recordOutcome(.negative)
        #expect(flow.promptDidDismiss() == .negative)
        #expect(!recorder.events.contains(.systemPromptRequested))
        #expect(!recorder.events.contains(.dismissed))
    }

    /// The whole reason this returns `ReviewOutcome?` and not `Bool`.
    ///
    /// A host with a feedback composer has to tell "rated poorly" from "left
    /// without rating", because only the first is worth following up — and it has
    /// to learn that *here*, from the far side of the dismissal, rather than at
    /// star-selection time where presenting anything races the sheet that is
    /// still going away. Under the old `Bool` both of these read `false`, which is
    /// exactly what pushed hosts into acting from the star handler.
    @Test("rated poorly and left unrated are told apart, and only here")
    func negativeIsDistinguishableFromNoRating() {
        let (rated, _, ratedEvents) = makeFlow()
        _ = rated.commitToPromptIfEligible(trigger: .valueMoment)
        rated.recordOutcome(.negative)

        let (unrated, _, unratedEvents) = makeFlow()
        _ = unrated.commitToPromptIfEligible(trigger: .valueMoment)

        #expect(rated.promptDidDismiss() == .negative)
        #expect(unrated.promptDidDismiss() == nil)

        // And the distinction is in the return value alone: a poor rating is not
        // a dismissal, so the events do not carry it.
        #expect(!ratedEvents.events.contains(.dismissed))
        #expect(unratedEvents.events.contains(.dismissed))
    }

    /// The negative branch owes the same once-only guarantee the positive one
    /// has: a host wiring both `onDismiss` and `onDisappear` must not open its
    /// feedback composer twice.
    @Test("a negative outcome is handed back exactly once")
    func negativeIsHandedBackOnce() {
        let (flow, _, _) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)
        flow.recordOutcome(.negative)

        #expect(flow.promptDidDismiss() == .negative)
        #expect(flow.promptDidDismiss() == nil)
    }

    /// `nil` covers both "no rating given" and "no prompt in flight". Neither
    /// owes the host anything, so they are deliberately one return value — but a
    /// stray call must not manufacture a dismissal for a prompt that was already
    /// accounted for.
    @Test("a stray dismissal after an unrated one stays nil and counts nothing")
    func repeatedUnratedDismissalCountsOnce() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        #expect(flow.promptDidDismiss() == nil)
        #expect(flow.promptDidDismiss() == nil)

        #expect(recorder.events.filter { $0 == .dismissed }.count == 1)
    }

    @Test("leaving without rating counts as a dismissal")
    func dismissWithoutRating() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        #expect(flow.promptDidDismiss() == nil)
        #expect(recorder.events == [.promptShown(.valueMoment), .dismissed])
    }

    @Test("the system request fires once, not on every dismissal")
    func systemRequestIsNotRepeatable() {
        let (flow, _, _) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)
        flow.recordOutcome(.positive)

        #expect(flow.promptDidDismiss() == .positive)
        #expect(flow.promptDidDismiss() == nil)
    }

    /// A star row records on every tap, which the README's own idiom encourages.
    /// A user who taps five and corrects to two before dismissing must not be
    /// handed to the store — that is the whole premise of the two-stage ask.
    @Test("a rating corrected downwards does not hand off to the system prompt")
    func correctedRatingDoesNotHandOff() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.recordOutcome(.positive)
        flow.recordOutcome(.negative)

        #expect(flow.promptDidDismiss() == .negative)
        #expect(!recorder.events.contains(.systemPromptRequested))
    }

    @Test("a rating corrected upwards still hands off")
    func correctedRatingUpwardsHandsOff() {
        let (flow, _, _) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.recordOutcome(.negative)
        flow.recordOutcome(.positive)

        #expect(flow.promptDidDismiss() == .positive)
    }

    // MARK: - Abandonment

    /// The hole this closes: SwiftUI delivers no `onDismiss` when the presenting
    /// view is torn down, so without `abandon()` the flow stays mid-prompt and
    /// refuses every later ask — including the user-initiated one — until the
    /// process restarts.
    @Test("a commit after abandonment succeeds")
    func abandonUnblocksLaterAsks() {
        let (flow, _, _) = makeFlow()
        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))

        // The presenting view was popped. Without `abandon()`, this is where the
        // flow jams for the rest of the process.
        #expect(!flow.commitToPrompt(trigger: .valueMoment))
        flow.abandon()

        #expect(flow.commitToPrompt(trigger: .valueMoment))
    }

    @Test("abandoning with nothing in flight is a no-op")
    func abandonFromIdleIsInert() {
        let (flow, counters, recorder) = makeUnseededFlow()

        flow.abandon()
        flow.abandon()

        #expect(recorder.events.isEmpty)
        #expect(counters.state.lastPromptedAt == nil)
        // Still idle, so a commit is still possible.
        #expect(flow.commitToPrompt(trigger: .valueMoment))
    }

    @Test("abandonment is idempotent")
    func abandonIsIdempotent() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.abandon()
        flow.abandon()
        flow.abandon()

        #expect(recorder.events == [.promptShown(.valueMoment)])
    }

    /// The obvious "fix" that would be wrong: refunding the stamp re-arms the gate
    /// and lets the very next value moment ask again, against an allowance of
    /// roughly three prompts a year.
    @Test("abandonment does not refund the cooldown")
    func abandonDoesNotRefundTheCooldown() {
        let (flow, counters, _) = makeFlow(Self.strict)
        #expect(flow.commitToPromptIfEligible(trigger: .valueMoment))
        let stampedAt = counters.state.lastPromptedAt
        #expect(stampedAt != nil)

        flow.abandon()

        #expect(counters.state.lastPromptedAt == stampedAt)

        // And the stamp still bites: rebuild the value-moment evidence that
        // committing zeroed, so the cooldown is the only floor left to refuse.
        counters.recordValueMoment()
        counters.recordValueMoment()
        #expect(!flow.commitToPromptIfEligible(trigger: .valueMoment))
    }

    /// It says "the prompt died", so there is nothing to hand off and nothing to
    /// count — in particular not `.dismissed`, which means the user declined.
    @Test("abandonment yields no outcome, no hand-off and no event")
    func abandonHandsOffNothing() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)

        flow.abandon()

        #expect(recorder.events == [.promptShown(.valueMoment)])
        #expect(!recorder.events.contains(.systemPromptRequested))
        #expect(!recorder.events.contains(.dismissed))
        // Abandoned, so the later dismissal has nothing left to yield.
        #expect(flow.promptDidDismiss() == nil)
    }

    /// The race the guard exists for: one state change both dismisses the sheet
    /// and pops the presenting view, and SwiftUI does not define whether
    /// `onDismiss` or `onDisappear` lands first.
    ///
    /// Clearing unconditionally would let the teardown throw away a five-star
    /// rating and the review would never be requested — a fresh silent failure
    /// introduced by the fix for another one. `abandon()` discards a prompt, never
    /// an outcome, so the rating survives and the later call still delivers it.
    @Test("a teardown racing a real dismissal does not discard the rating")
    func abandonDoesNotDiscardARecordedOutcome() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)
        flow.recordOutcome(.positive)

        // `onDisappear` wins the race and lands first.
        flow.abandon()

        // …and `onDismiss` still hands off.
        #expect(flow.promptDidDismiss() == .positive)
        #expect(recorder.events.contains(.systemPromptRequested))
    }

    /// The same guarantee for the branch that has no platform hand-off: a host's
    /// own follow-up must not be silently cancelled by a teardown either.
    @Test("a teardown does not discard a negative outcome either")
    func abandonDoesNotDiscardANegativeOutcome() {
        let (flow, _, _) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)
        flow.recordOutcome(.negative)

        flow.abandon()

        #expect(flow.promptDidDismiss() == .negative)
    }

    /// Belt and braces on the ordering that is *not* a race — the normal one,
    /// where the prompt resolves first and the screen is left later.
    @Test("abandoning after a resolved prompt changes nothing")
    func abandonAfterDismissalIsInert() {
        let (flow, _, recorder) = makeFlow()
        _ = flow.commitToPromptIfEligible(trigger: .valueMoment)
        flow.recordOutcome(.positive)
        #expect(flow.promptDidDismiss() == .positive)

        let settled = recorder.events
        flow.abandon()

        #expect(recorder.events == settled)
        #expect(flow.commitToPrompt(trigger: .valueMoment))
    }

    /// ``ReviewCounters`` stamps `firstUseAt`/`lastPromptedAt` from its injected
    /// clock, so the gate has to read the same one — comparing those stamps
    /// against wall time makes any host that injects a clock get nonsense.
    @Test("the gate is evaluated on the counters' clock, not on wall time")
    func gateUsesTheCountersClock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000_000)
        nonisolated(unsafe) var clock = t0
        let (counters, _, _) = suites.makeCounters(now: { clock })
        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0..<5 { counters.recordLaunch() }

        let config = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(
                minimumValueMoments: 2, minimumLaunches: 5,
                minimumFirstUseAgeHours: 24, cooldownDays: 120
            ),
            launchFallback: LaunchFallbackPolicy(minimumLaunches: 20)
        )

        // On the injected clock no time has passed since first use. Wall time
        // would put it decades ago and wave it straight through.
        #expect(!ReviewPromptFlow(counters: counters, configuration: config)
            .commitToPromptIfEligible(trigger: .valueMoment))

        clock = t0.addingTimeInterval(.hours(25))
        #expect(ReviewPromptFlow(counters: counters, configuration: config)
            .commitToPromptIfEligible(trigger: .valueMoment))
    }

    /// The flow's setback door, end to end: a host stamps one, and the very next
    /// otherwise-eligible value moment is refused until the span has passed.
    @Test("a setback shuts the flow's own commit door")
    func setbackRefusesTheCommit() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000_000)
        let start = clock
        let (counters, _, _) = suites.makeCounters(now: { clock })
        counters.recordValueMoment()
        counters.recordValueMoment()
        for _ in 0 ..< 5 { counters.recordLaunch() }
        clock = start.addingTimeInterval(.hours(25))

        let config = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(
                minimumValueMoments: 2, minimumLaunches: 5,
                minimumFirstUseAgeHours: 24, cooldownDays: 120, setbackCooldownHours: 24
            ),
            launchFallback: LaunchFallbackPolicy(minimumLaunches: 20)
        )

        // Eligible right up until something goes wrong.
        ReviewPromptFlow(counters: counters, configuration: config).recordSetback()
        #expect(!ReviewPromptFlow(counters: counters, configuration: config)
            .commitToPromptIfEligible(trigger: .valueMoment))

        // …and eligible again once the silence is served. Nothing was spent in
        // between: a refused commit stamps no cooldown.
        clock = start.addingTimeInterval(.hours(50))
        #expect(counters.state.lastPromptedAt == nil)
        #expect(ReviewPromptFlow(counters: counters, configuration: config)
            .commitToPromptIfEligible(trigger: .valueMoment))
    }

    /// A setback must not spend the progress that got the user near the ask —
    /// unlike a commit, which zeroes the counter on purpose.
    @Test("a setback defers the ask without resetting it")
    func setbackDoesNotClearValueMoments() {
        let (flow, counters, _) = makeFlow()

        flow.recordSetback()

        #expect(counters.state.valueMomentCount == 2)
    }

    @Test("star ratings bucket at the conventional floor")
    func starBucketing() {
        #expect(ReviewOutcome.forStarRating(5) == .positive)
        #expect(ReviewOutcome.forStarRating(4) == .positive)
        #expect(ReviewOutcome.forStarRating(3) == .negative)
        #expect(ReviewOutcome.forStarRating(1) == .negative)
        #expect(ReviewOutcome.forStarRating(3, highRatingFloor: 3) == .positive)
    }
}
