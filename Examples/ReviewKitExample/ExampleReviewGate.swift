import Foundation
import ReviewKit

/// Everything a host has to decide, in one place, so the views below stay about
/// the UI and this stays about the gate.
///
/// The point of this file is that it is the *whole* integration. Four key names,
/// one configuration, one flow — and the two orderings the package exists to
/// enforce are upheld by the call sites in `ContentView`, not by anything here.
@MainActor
final class ExampleReviewGate: ObservableObject {
    /// The host owns the key names, always. ReviewKit never picks them, because a
    /// package-owned key would force a migration on every app that already
    /// carries review state — and both directions of getting that wrong are
    /// unrecoverable. These are this example's names. Yours are yours.
    private static let keys = ReviewKeys(
        launchCount: "example.review.launchCount",
        valueMomentCount: "example.review.valueMomentCount",
        firstUseAt: "example.review.firstUseAt",
        lastPromptedAt: "example.review.lastPromptedAt",
        // Opting in to setbacks is exactly this line. Leave it `nil` (or omit it)
        // and `recordSetback()` writes nothing and blocks nothing — which is why
        // `ReviewPromptFlow.init` asserts if a policy sets a setback cooldown
        // without one.
        lastSetbackAt: "example.review.lastSetbackAt"
    )

    /// **A demo cadence, not a shipping one.** The floors are low so the gate
    /// opens within a few taps instead of a few days. The 120-day cooldown is
    /// real, because a cooldown of `0` would prompt on every value moment and
    /// this screen is meant to show you the cooldown working. Use `Reset` to
    /// test again rather than shortening it.
    ///
    /// A real app's numbers belong in its own source, as literals — which is why
    /// `ReviewConfiguration` is deliberately not `Codable`.
    static let configuration = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(
            minimumValueMoments: 2,
            minimumLaunches: 1,
            minimumFirstUseAgeHours: 0,
            cooldownDays: 120,
            setbackCooldownHours: 48
        ),
        launchFallback: LaunchFallbackPolicy(
            minimumLaunches: 8,
            minimumFirstUseAgeHours: 0,
            cooldownDays: 120,
            setbackCooldownHours: 48
        )
    )

    let counters = ReviewCounters(keys: ExampleReviewGate.keys)

    /// Newest first, so the ordering is readable without scrolling.
    @Published private(set) var log: [String] = []

    /// `lazy` only so the event handler can reference `self`. `ReviewPromptFlow.init`
    /// is itself `nonisolated`, so a background App Intent, a widget timeline or a
    /// share extension can build one of these locally rather than hopping to the
    /// main actor just to bump a counter.
    lazy var flow = ReviewPromptFlow(
        counters: counters,
        configuration: ExampleReviewGate.configuration,
        events: { [weak self] event in self?.record(event) }
    )

    /// `ReviewEvent` reports a *bucket*, never a star score — the host drew the
    /// stars, so handing them back would make the gate a channel for something it
    /// must not carry. Mapped explicitly rather than interpolated: `"\(event)"`
    /// would put Swift's reflected case names into your analytics wire format
    /// with nothing pinning them.
    private func record(_ event: ReviewEvent) {
        let description: String
        switch event {
        case .promptShown(let trigger):
            description = "promptShown(\(trigger == .valueMoment ? "valueMoment" : "launchFallback"))"
        case .rated(let outcome):
            description = "rated(\(outcome == .positive ? "positive" : "negative"))"
        case .systemPromptRequested:
            description = "systemPromptRequested  ← the hand-off actually happened"
        case .dismissed:
            description = "dismissed"
        }
        note(description)
    }

    func note(_ line: String) {
        log.insert(line, at: 0)
    }

    func reset() {
        counters.reset()
        log.removeAll()
        note("counters reset")
    }
}
