import Foundation
import ReviewKit
import Testing
@testable import ReviewKitUI

/// Isolated storage per test: **one** persistent domain for the whole run, with a
/// unique set of ``ReviewKeys`` per flow.
///
/// A suite per test is the obvious design and it leaks a plist per test into
/// `~/Library/Preferences`, permanently — `cfprefsd` recreates the file seconds
/// after the process exits, so teardown cannot win. See the twin of this type in
/// `ReviewKitTests` for the full account.
private final class ThrowawaySuites {
    /// `nonisolated(unsafe)` for the same reason `ReviewCounters` is
    /// `@unchecked Sendable`: `UserDefaults` is thread-safe but unmarked.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "ReviewKitUITests.scratch")!

    private var made: [ReviewKeys] = []

    @MainActor
    func makeFlow(
        events: @escaping @MainActor (ReviewEvent) -> Void = { _ in }
    ) -> ReviewPromptFlow {
        let id = UUID().uuidString
        let keys = ReviewKeys(
            launchCount: "\(id).launchCount",
            valueMomentCount: "\(id).valueMomentCount",
            firstUseAt: "\(id).firstUseAt",
            lastPromptedAt: "\(id).lastPromptedAt"
        )
        made.append(keys)
        return ReviewPromptFlow(
            counters: ReviewCounters(defaults: Self.defaults, keys: keys),
            events: events
        )
    }

    deinit {
        for keys in made {
            for name in [
                keys.launchCount, keys.valueMomentCount,
                keys.firstUseAt, keys.lastPromptedAt,
            ] {
                Self.defaults.removeObject(forKey: name)
            }
        }
    }
}

/// The one behavior in this module worth proving: the sheet is gone, and only
/// now — and only for the branch that earned it — does anything happen. A good
/// rating reaches the platform's request. A poor one reaches the host's own
/// follow-up. Nothing else reaches either.
///
/// Every test here is a mutation test for the modifier's `onDismiss`. Collapse
/// `resolvePrompt`'s switch to an unconditional `requestReview()` and **nine of
/// the twelve** go red. The three survivors are the cases an unconditional call
/// gets right by accident — which is exactly why the other nine exist, and why
/// counting them is part of the house gate.
@MainActor
@Suite("ReviewKitUI hand-off")
struct ResolvePromptTests {
    private let suites = ThrowawaySuites()

    /// What a dismissal drove, counted rather than asserted one at a time — the
    /// interesting failures are "both ran" and "the wrong one ran".
    private final class Drove {
        var requests = 0
        var followUps = 0
    }

    private func resolve(_ flow: ReviewPromptFlow) -> Drove {
        let drove = Drove()
        resolvePrompt(
            flow: flow,
            requestReview: { drove.requests += 1 },
            onNegative: { drove.followUps += 1 }
        )
        return drove
    }

    // MARK: - The happy branch

    @Test("a good rating hands off once the sheet has gone")
    func goodRatingHandsOff() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(5))

        let drove = resolve(flow)

        #expect(drove.requests == 1)
        #expect(drove.followUps == 0)
        #expect(events.contains(.systemPromptRequested))
    }

    /// SwiftUI can deliver a dismissal more than once, and a host that wires both
    /// `onDismiss` and `onDisappear` double-calls by construction.
    @Test("a repeated dismissal hands off exactly once")
    func repeatedDismissalHandsOffOnce() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(5))

        let first = resolve(flow)
        let second = resolve(flow)

        #expect(first.requests == 1)
        #expect(second.requests == 0)
        #expect(events.filter { $0 == .systemPromptRequested }.count == 1)
    }

    // MARK: - The unhappy branch
    //
    // The half a modifier that only wires the happy path leaves out: it consumes
    // the dismissal, so a poor rating cannot reach a feedback composer, a
    // support link, or anything else. Presenting one of those from the star
    // handler instead is the *same* silent failure as requesting the review
    // there, so the follow-up has to be driven from here or not at all.

    @Test("a poor rating runs the host's follow-up and nothing else")
    func poorRatingRunsTheFollowUp() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(2))

        let drove = resolve(flow)

        #expect(drove.requests == 0)
        #expect(drove.followUps == 1)
        #expect(!events.contains(.systemPromptRequested))
    }

    @Test("a poor rating's follow-up runs exactly once")
    func poorRatingFollowUpIsNotRepeated() {
        let flow = suites.makeFlow()
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(1))

        let first = resolve(flow)
        let second = resolve(flow)

        #expect(first.followUps == 1)
        #expect(second.followUps == 0)
    }

    /// A poor rating is never a store rating, however the host wires its
    /// follow-up. This is the assertion the whole two-stage ask exists for.
    @Test("no poor rating reaches the platform request")
    func noPoorRatingReachesTheStore() {
        for stars in 1 ... 3 {
            let flow = suites.makeFlow()
            #expect(flow.commitToPrompt(trigger: .valueMoment))
            flow.recordOutcome(.forStarRating(stars))

            #expect(resolve(flow).requests == 0, "\(stars) stars reached the store")
        }
    }

    // MARK: - Neither branch

    @Test("leaving without rating drives nothing and counts as a dismissal")
    func dismissalDrivesNothing() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })
        #expect(flow.commitToPrompt(trigger: .valueMoment))

        let drove = resolve(flow)

        #expect(drove.requests == 0)
        #expect(drove.followUps == 0)
        #expect(events.contains(.dismissed))
    }

    @Test("a dismissal with no prompt in flight is inert")
    func noPromptInFlightIsInert() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })

        let drove = resolve(flow)

        #expect(drove.requests == 0)
        #expect(drove.followUps == 0)
        #expect(events.isEmpty)
    }

    /// Not reachable through `ReviewPromptSheet`, which dismisses on the first
    /// tap — this guards the contract for a host that presents its own sheet
    /// behind an explicit confirm, where the correction is reachable and has to
    /// win.
    @Test("five stars corrected to two takes the unhappy branch")
    func revokedGoodRatingTakesTheUnhappyBranch() {
        let flow = suites.makeFlow()
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(5))
        flow.recordOutcome(.forStarRating(2))

        let drove = resolve(flow)

        #expect(drove.requests == 0)
        #expect(drove.followUps == 1)
    }

    @Test("two stars corrected to five takes the happy branch")
    func revokedPoorRatingTakesTheHappyBranch() {
        let flow = suites.makeFlow()
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(2))
        flow.recordOutcome(.forStarRating(5))

        let drove = resolve(flow)

        #expect(drove.requests == 1)
        #expect(drove.followUps == 0)
    }

    // MARK: - Teardown

    /// A torn-down prompt owes nothing, so the far side of it must reach neither
    /// StoreKit nor the host — `abandon()` is not a back door to either branch.
    @Test("an abandoned prompt drives neither branch")
    func abandonedPromptDrivesNothing() {
        var events: [ReviewEvent] = []
        let flow = suites.makeFlow(events: { events.append($0) })
        #expect(flow.commitToPrompt(trigger: .valueMoment))

        flow.abandon()
        let drove = resolve(flow)

        #expect(drove.requests == 0)
        #expect(drove.followUps == 0)
        #expect(!events.contains(.systemPromptRequested))
        #expect(!events.contains(.dismissed))
    }

    /// The race, from the modifier's side: the automatic `abandon()` on the
    /// presenting view's `onDisappear` lands first, and the `onDismiss` behind it
    /// must still hand off. `abandon()` discards a prompt, never an outcome —
    /// which is what makes wiring it by default safe.
    @Test("a teardown racing the dismissal still hands off a good rating")
    func abandonBeforeDismissStillHandsOff() {
        let flow = suites.makeFlow()
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(5))

        flow.abandon()

        #expect(resolve(flow).requests == 1)
    }

    /// The same race on the unhappy side, which the old `Bool`-returning hand-off
    /// could not have expressed at all.
    @Test("a teardown racing the dismissal still runs the follow-up")
    func abandonBeforeDismissStillRunsTheFollowUp() {
        let flow = suites.makeFlow()
        #expect(flow.commitToPrompt(trigger: .valueMoment))
        flow.recordOutcome(.forStarRating(2))

        flow.abandon()

        #expect(resolve(flow).followUps == 1)
    }
}
