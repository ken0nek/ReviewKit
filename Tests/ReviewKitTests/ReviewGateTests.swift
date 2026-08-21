import Foundation
import Testing
@testable import ReviewKit

@Suite("ReviewGate")
struct ReviewGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let config = ReviewConfiguration.default

    /// State that clears every value-moment floor, so each test can spoil
    /// exactly one thing and prove that one thing is what closes the gate.
    private func eligibleState() -> ReviewState {
        ReviewState(
            launchCount: 5,
            valueMomentCount: 2,
            firstUseAt: now.addingTimeInterval(-.hours(25)),
            lastPromptedAt: nil
        )
    }

    private func shouldPrompt(
        _ state: ReviewState,
        trigger: ReviewTrigger = .valueMoment
    ) -> Bool {
        ReviewGate.shouldPrompt(trigger: trigger, state: state, configuration: config, now: now)
    }

    @Test("a state meeting every floor is eligible")
    func eligible() {
        #expect(shouldPrompt(eligibleState()))
    }

    @Test("too few value moments closes the gate")
    func belowValueMomentFloor() {
        var state = eligibleState()
        state.valueMomentCount = 1
        #expect(!shouldPrompt(state))
    }

    @Test("too few launches closes the gate")
    func belowLaunchFloor() {
        var state = eligibleState()
        state.launchCount = 4
        #expect(!shouldPrompt(state))
    }

    @Test("a burst of use inside the first-use window does not qualify")
    func withinFirstUseWindow() {
        var state = eligibleState()
        state.firstUseAt = now.addingTimeInterval(-.hours(23))
        #expect(!shouldPrompt(state))
    }

    @Test("a missing first-use stamp fails closed")
    func missingFirstUse() {
        var state = eligibleState()
        state.firstUseAt = nil
        #expect(!shouldPrompt(state))
    }

    @Test("the cooldown silences an otherwise-eligible state")
    func withinCooldown() {
        var state = eligibleState()
        state.lastPromptedAt = now.addingTimeInterval(-.days(119))
        #expect(!shouldPrompt(state))
    }

    @Test("the gate reopens once the cooldown has elapsed")
    func afterCooldown() {
        var state = eligibleState()
        state.lastPromptedAt = now.addingTimeInterval(-.days(121))
        #expect(shouldPrompt(state))
    }

    @Test("the launch fallback ignores value moments but demands more launches")
    func launchFallback() {
        var state = eligibleState()
        state.valueMomentCount = 0

        state.launchCount = 19
        #expect(!shouldPrompt(state, trigger: .launchFallback))

        state.launchCount = 20
        #expect(shouldPrompt(state, trigger: .launchFallback))
    }

    @Test("a zeroed policy gates on nothing but still needs a first use")
    func zeroedPolicy() {
        let permissive = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(),
            launchFallback: LaunchFallbackPolicy()
        )
        let state = ReviewState(firstUseAt: now)

        #expect(ReviewGate.shouldPrompt(
            trigger: .valueMoment, state: state, configuration: permissive, now: now
        ))
        #expect(!ReviewGate.shouldPrompt(
            trigger: .valueMoment, state: ReviewState(), configuration: permissive, now: now
        ))
    }

    /// The trap `LaunchFallbackPolicy`'s missing value-moment floor exists to
    /// close: ``ReviewCounters/markPrompted()`` zeroes `valueMomentCount`, and
    /// this path serves users who never rebuild it. A floor here would not be a
    /// stricter gate but a permanent one — so the type cannot express it, and
    /// the gate never reads that counter for this trigger.
    @Test("the launch fallback still fires after a prompt zeroed the value moments")
    func launchFallbackSurvivesAPrompt() {
        let longAfterAPrompt = ReviewState(
            launchCount: 500,
            valueMomentCount: 0,
            firstUseAt: now.addingTimeInterval(-.days(400)),
            lastPromptedAt: now.addingTimeInterval(-.days(300))
        )

        #expect(ReviewGate.shouldPrompt(
            trigger: .launchFallback,
            state: longAfterAPrompt,
            configuration: .default,
            now: now
        ))
    }

    // MARK: - Setbacks

    /// The same floors as `.default`, plus a day of silence after a setback.
    private static let setbackAware = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(
            minimumValueMoments: 2, minimumLaunches: 5,
            minimumFirstUseAgeHours: 24, cooldownDays: 120, setbackCooldownHours: 24
        ),
        launchFallback: LaunchFallbackPolicy(
            minimumLaunches: 20, minimumFirstUseAgeHours: 24,
            cooldownDays: 120, setbackCooldownHours: 24
        )
    )

    private func shouldPromptSetbackAware(
        _ state: ReviewState, trigger: ReviewTrigger = .valueMoment
    ) -> Bool {
        ReviewGate.shouldPrompt(
            trigger: trigger, state: state, configuration: Self.setbackAware, now: now
        )
    }

    @Test("a fresh setback silences an otherwise-eligible state")
    func recentSetbackClosesTheGate() {
        var state = eligibleState()
        #expect(shouldPromptSetbackAware(state))

        state.lastSetbackAt = now.addingTimeInterval(-.hours(23))
        #expect(!shouldPromptSetbackAware(state))
    }

    @Test("the gate reopens once the setback cooldown has elapsed")
    func elapsedSetbackReopensTheGate() {
        var state = eligibleState()
        state.lastSetbackAt = now.addingTimeInterval(-.hours(25))

        #expect(shouldPromptSetbackAware(state))
    }

    /// A setback is a silence, not something to be earned, so it applies to the
    /// path that has no value-moment floor as well — unlike `minimumValueMoments`,
    /// which `LaunchFallbackPolicy` cannot express at all.
    @Test("a fresh setback silences the launch fallback too")
    func recentSetbackClosesTheFallback() {
        var state = ReviewState(
            launchCount: 500,
            valueMomentCount: 0,
            firstUseAt: now.addingTimeInterval(-.days(400))
        )
        #expect(shouldPromptSetbackAware(state, trigger: .launchFallback))

        state.lastSetbackAt = now.addingTimeInterval(-.hours(1))
        #expect(!shouldPromptSetbackAware(state, trigger: .launchFallback))
    }

    /// The opt-out has to be total: an app that stamps setbacks and then removes
    /// the cooldown from its cadence must not stay silenced by history.
    @Test("a stamped setback is ignored when no setback cooldown is configured")
    func setbackIsIgnoredWithoutACooldown() {
        var state = eligibleState()
        state.lastSetbackAt = now.addingTimeInterval(-.hours(1))

        #expect(shouldPrompt(state))
    }
}
