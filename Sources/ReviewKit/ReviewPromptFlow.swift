import Foundation

/// What the user did with your in-app rating prompt.
public enum ReviewOutcome: Sendable, Equatable {
    /// Happy — hand off to the platform's review request.
    case positive
    /// Unhappy — stay silent for the full cooldown as far as the *store* is
    /// concerned. Never route this to the public store rating. Your own follow-up
    /// is yours to choose, and ``ReviewPromptFlow/promptDidDismiss()`` hands this
    /// back so you can present it from the one moment that is safe to.
    case negative

    /// Buckets a star rating. The default floor of 4-of-5 is the convention the
    /// two-stage ask is built on.
    public static func forStarRating(_ rating: Int, highRatingFloor: Int = 4) -> ReviewOutcome {
        rating >= highRatingFloor ? .positive : .negative
    }
}

/// Signals worth recording, emitted as the flow progresses.
///
/// ReviewKit deliberately owns no analytics taxonomy — map these onto your own
/// event names. Note that a star count never appears here: bucket, not score, so
/// the prompt cannot become a channel for personal data.
///
/// `Hashable` so a host bucketing or de-duplicating events by kind can put them
/// in a `Set` or use one as a dictionary key. The conformance synthesises
/// automatically and costs nothing to carry.
public enum ReviewEvent: Sendable, Hashable {
    /// The prompt was committed to being shown.
    case promptShown(ReviewTrigger)
    /// The user rated.
    case rated(ReviewOutcome)
    /// A positive rating handed off to the platform's review request. The end of
    /// the funnel you control — whether the system then shows its own prompt is
    /// deliberately invisible to you.
    case systemPromptRequested
    /// The prompt was dismissed without a rating.
    case dismissed
}

/// Orchestrates one in-app rating prompt end to end: eligibility, cooldown
/// stamping, and the hand-off to the platform's review request.
///
/// ## Why this type exists
///
/// The ordering it enforces is the part that is easy to get wrong and expensive
/// to get wrong, because both failures are **silent**:
///
/// 1. **Stamp the cooldown when you commit to showing, not when the UI appears.**
///    A crash or a backgrounding between those two moments otherwise leaves the
///    gate armed with nothing recorded, and the user is asked again next launch.
/// 2. **Act on the rating only after your own UI is fully gone.**
///    Requesting the system prompt mid-dismiss makes the system drop it on the
///    floor. The user taps five stars, nothing happens, and your analytics still
///    records a success. This has cost shipped apps months of reviews. The same
///    holds for whatever *you* present after a poor rating, which is why
///    ``promptDidDismiss()`` returns the outcome rather than a `Bool`.
///
/// ## Usage
///
/// ```swift
/// // A value moment just landed.
/// flow.recordValueMoment()
/// if flow.commitToPromptIfEligible(trigger: .valueMoment) {
///     isShowingRatingSheet = true          // cooldown is already stamped
/// }
///
/// // The user picked a rating.
/// flow.recordOutcome(.forStarRating(stars))
///
/// // Your sheet finished dismissing. Both branches are safe here, and only here.
/// switch flow.promptDidDismiss() {
/// case .positive?: requestReview()             // safe: your UI is gone
/// case .negative?: isShowingFeedback = true    // your follow-up, if you have one
/// case nil:        break                       // nothing is owed
/// }
/// ```
///
/// Presenting the same sheet from somewhere the gate has no say over — a
/// "Rate this app" row in Settings — goes through ``commitToPrompt(trigger:)``
/// instead, so that ask is stamped like any other rather than silently spending a
/// system prompt with no cooldown recorded.
@MainActor
public final class ReviewPromptFlow {
    private let counters: ReviewCounters
    private let configuration: ReviewConfiguration
    private let events: @MainActor (ReviewEvent) -> Void

    /// Where this prompt is in its life.
    ///
    /// One value rather than a set of flags, so the combinations that must never
    /// occur cannot be written down: "rated, but nothing in flight" and "a
    /// hand-off pending with no prompt" are unrepresentable rather than guarded
    /// against.
    private enum State {
        /// Nothing committed to.
        case idle
        /// Committed, and not yet finished dismissing. `outcome` is the last
        /// rating recorded — `nil` until the user picks one.
        case presenting(outcome: ReviewOutcome?)
    }

    private var state: State = .idle

    /// - Parameters:
    ///   - counters: the persisted counters.
    ///   - configuration: the cadence to judge them against.
    ///   - events: where to send ``ReviewEvent`` values. Defaults to discarding.
    ///
    /// `nonisolated`, like the three recorders below and for the same reason.
    /// Constructing a flow touches no `state`: it stores four `Sendable` values
    /// and checks one pairing. Requiring the main actor here would undo what
    /// those recorders buy — a background App Intent or a widget extension that
    /// has no main-actor flow to reach has to build one locally, and would
    /// otherwise have to hop just to start counting.
    public nonisolated init(
        counters: ReviewCounters,
        configuration: ReviewConfiguration = .default,
        events: @escaping @MainActor (ReviewEvent) -> Void = { _ in }
    ) {
        self.counters = counters
        self.configuration = configuration
        self.events = events

        // A setback cooldown with nowhere to stamp is inert in every direction
        // and says so nowhere: `recordSetback()` writes nothing,
        // ``ReviewState/lastSetbackAt`` stays `nil`, the gate never blocks, and
        // ``ReviewGateDiagnosis`` reports the `.setback` row as *met* with
        // "none recorded" — so even the screen built to explain the gate agrees
        // with the misconfiguration. That is the fail-open shape this package
        // exists to catch, and both halves are literals in the host's own source,
        // exactly like a negative threshold.
        //
        // `assertionFailure` rather than `precondition`, unlike the thresholds:
        // getting this wrong disables a feature rather than corrupting anything,
        // so it must not take a shipped app down. Same severity, and the same
        // reasoning, as ``recordOutcome(_:)``'s guard.
        assert(
            !(configuration.consultsSetbacks && counters.keys.lastSetbackAt == nil),
            """
            ReviewKit: a policy sets a setback cooldown but ReviewKeys.lastSetbackAt \
            is nil, so setbacks are never recorded and the cooldown never applies. \
            Supply the key, or set setbackCooldownHours back to 0.
            """
        )
    }

    // MARK: - Counting
    //
    // The three recorders below are `nonisolated`, unlike everything after them.
    // They touch `counters` and nothing else — a `Sendable` struct over a
    // thread-safe store — so none of them needs the main actor, and requiring it
    // pushed the isolation onto callers that had no other reason for it: a
    // background App Intent, a widget timeline, a share extension, the completion
    // of a network call. Every one of those is a legitimate place to count, and
    // annotating a background `perform()` `@MainActor` purely to reach one of
    // these is the wrong fix for an isolation error this should never raise.
    //
    // The presentation doors below stay `@MainActor`, because they read and write
    // `state` — and because deciding to present is a main-actor thing to do.

    /// Counts one launch. Call once per app launch.
    public nonisolated func recordLaunch() {
        counters.recordLaunch()
    }

    /// Counts one value moment — the app's core action completing.
    ///
    /// Safe to call from anywhere, including a background App Intent or an
    /// extension writing a shared App Group suite. Counting is not committing:
    /// a caller with no way to present anything must call this and stop, so the
    /// next in-app moment arrives sooner rather than a cooldown being spent on a
    /// prompt nobody can see.
    public nonisolated func recordValueMoment() {
        counters.recordValueMoment()
    }

    /// Stamps a setback, keeping the gate quiet for the configured span.
    ///
    /// See ``ReviewCounters/recordSetback()`` for what belongs here. Also
    /// `nonisolated`, and for a sharper reason than the other two: the things
    /// that go wrong — a failed request, a rejected purchase, a sync error —
    /// almost never fail on the main actor.
    public nonisolated func recordSetback() {
        counters.recordSetback()
    }

    /// Whether to present your rating UI right now, **stamping the cooldown if
    /// so**.
    ///
    /// Committing stamps the cooldown before this returns, so **the configured
    /// cooldown is what bounds how often this can return `true`** — there is no
    /// separate per-session cap, because with any real cooldown one could never
    /// be the binding constraint. It also returns `false` while a prompt is
    /// already in flight, so two asks cannot overlap.
    ///
    /// Present as soon as it returns `true`. If you want to let a success
    /// animation land first, delay your own presentation — the cooldown is
    /// already safely recorded either way.
    ///
    /// - Important: Treat a `true` return as a commitment. Not presenting after
    ///   one costs the user a full cooldown of silence.
    public func commitToPromptIfEligible(trigger: ReviewTrigger) -> Bool {
        guard case .idle = state,
              counters.shouldPrompt(trigger: trigger, configuration: configuration)
        else { return false }

        commit(to: trigger)
        return true
    }

    /// Commits to showing your rating UI **without consulting the gate**, for an
    /// ask the user themselves initiated — a "Rate this app" row in Settings.
    ///
    /// The gate exists to decide when *you* can interrupt. It has no business
    /// overruling someone who went looking for the option. What this does keep is
    /// the accounting: the cooldown is stamped exactly as it is for an automatic
    /// ask, so a manual rating cannot hand off to the platform's review request
    /// with nothing recorded, and the next automatic ask still respects it.
    ///
    /// Route manual asks here rather than calling ``recordOutcome(_:)`` directly
    /// on an uncommitted flow, which does nothing at all.
    ///
    /// - Returns: `false` only when a prompt is already in flight — you are
    ///   showing one. Do not show a second.
    public func commitToPrompt(trigger: ReviewTrigger) -> Bool {
        guard case .idle = state else { return false }
        commit(to: trigger)
        return true
    }

    /// Records the rating the user gave.
    ///
    /// Nothing is acted on here. A positive outcome does **not** request the
    /// system prompt, and a negative one does not trigger your follow-up either.
    /// Both are deferred to ``promptDidDismiss()``, which is the only call that
    /// runs from the far side of the dismissal.
    ///
    /// Safe to call more than once for one prompt: the **last** outcome wins. A
    /// star row records on every tap, so a user who picks five and corrects to two
    /// before dismissing must end up treated as unhappy — a positive rating that
    /// is later revoked must not still hand off to the store. Storing the outcome
    /// rather than latching a flag is what makes that fall out for free.
    ///
    /// Each call emits its own ``ReviewEvent/rated(_:)``, so a per-tap host sees
    /// one event per tap rather than one per prompt. That is deliberate — the
    /// corrections are real telemetry, and suppressing them would mean either
    /// dropping the user's final answer or delaying the event to dismissal. If
    /// your funnel counts ratings against prompts shown, record on your sheet's
    /// commit action instead of on each tap.
    ///
    /// Does nothing unless a prompt is in flight. Rating something that was never
    /// committed to would otherwise hand off to the platform's review request
    /// with no cooldown stamped — the first of the two silent failures this type
    /// exists to prevent, arrived at from the far end. In a debug build the
    /// misuse trips an assertion rather than passing quietly.
    public func recordOutcome(_ outcome: ReviewOutcome) {
        guard case .presenting = state else {
            assertionFailure(
                """
                ReviewKit: recordOutcome(_:) with no prompt in flight — ignored. \
                Present only after commitToPromptIfEligible(trigger:) returns true, \
                or use commitToPrompt(trigger:) for an ask the user initiated.
                """
            )
            return
        }

        state = .presenting(outcome: outcome)
        events(.rated(outcome))
    }

    /// Call when your rating UI has finished dismissing, and act on what it
    /// returns.
    ///
    /// This is the one correctly-sequenced slot in the whole flow, and it serves
    /// **both** outcomes rather than only the happy one. The reason is the second
    /// silent failure, read symmetrically: acting on a rating at star-selection
    /// time means presenting UI while the rating sheet is still dismissing. For a
    /// positive rating that is the platform dropping `requestReview()` on the
    /// floor. For a negative one it is your own follow-up — a mail composer, a
    /// support URL, an in-app feedback form — racing the dismissal of the sheet
    /// that triggered it, which on a good day merely animates badly and on a bad
    /// one never presents at all. Both are the same mistake. Both are avoided by
    /// waiting for this call.
    ///
    /// ```swift
    /// switch flow.promptDidDismiss() {
    /// case .positive?: requestReview()            // safe: your UI is gone
    /// case .negative?: isShowingFeedback = true   // equally safe, same reason
    /// case nil:        break                      // nothing is owed
    /// }
    /// ```
    ///
    /// A negative outcome is a hand-back, not an instruction: doing nothing with
    /// it is a complete implementation, and the flow neither knows nor cares. What
    /// it must never become is a route to the public store rating.
    ///
    /// Counts a dismissal when the user left without rating, so an explicit
    /// "Not now" and a swipe-away are counted alike.
    ///
    /// Idempotent, and inert unless a prompt is in flight: SwiftUI can deliver
    /// `onDisappear` more than once, and a host wiring both `.sheet(onDismiss:)`
    /// and `onDisappear` double-calls by construction. Extra calls are absorbed
    /// rather than asserted on, so neither ``ReviewEvent/dismissed`` nor
    /// ``ReviewEvent/systemPromptRequested`` can be emitted twice for one prompt —
    /// and only the first call of the pair returns an outcome.
    ///
    /// The outcome is a bucket and never a star count, exactly as
    /// ``ReviewEvent/rated(_:)`` is. You rendered the stars, so you already know
    /// the score. ReviewKit handing it back would only make the prompt a channel
    /// for something it has no business carrying.
    ///
    /// - Returns: ``ReviewOutcome/positive`` when the platform's review request
    ///   is now safe to make. ``ReviewOutcome/negative`` when the user rated
    ///   poorly and your own follow-up, if you have one, is now safe to present.
    ///   `nil` when nothing is owed — the prompt was dismissed unrated, or there
    ///   was none in flight.
    ///
    ///   Deliberately not `@discardableResult`: dropping it is exactly how the
    ///   second silent failure happens — the user taps five stars and nothing
    ///   ever asks for the review.
    public func promptDidDismiss() -> ReviewOutcome? {
        guard case let .presenting(outcome) = state else { return nil }
        state = .idle

        switch outcome {
        case .none:
            events(.dismissed)
            return nil
        case .negative:
            return .negative
        case .positive:
            events(.systemPromptRequested)
            return .positive
        }
    }

    /// Call when the prompt died without ever finishing a dismissal — the view
    /// that was presenting it went away, and no outcome will ever arrive.
    ///
    /// This exists because SwiftUI does **not** deliver `.sheet(onDismiss:)` when
    /// the *presenting* view is torn down: a navigation pop or a tab swap driven
    /// by the same state change takes the sheet with it and calls nothing. Without
    /// this the flow would stay mid-prompt for the rest of the process, and every
    /// later ask — including a user-initiated "Rate this app" row, which is the
    /// one that reads as broken — would be refused until the next launch.
    ///
    /// Attach it to the **presenting** view, not to the sheet's content:
    ///
    /// ```swift
    /// SomeScreen()
    ///     .sheet(isPresented: $isShowingRating, onDismiss: { … }) { … }
    ///     .onDisappear { flow.abandon() }
    /// ```
    ///
    /// On the sheet's own content `onDisappear` fires on every normal dismissal,
    /// mid-dismiss, racing the `onDismiss` that carries the result.
    ///
    /// Idempotent and safe from any state, so a teardown path never has to guard.
    ///
    /// ## It does not refund the cooldown, and that is not a bug
    ///
    /// The stamp was spent at commit, and abandoning does not give it back. This
    /// is the thing that will later look like one, so: refunding it would re-arm
    /// the gate, and the very next value moment could ask again — a double-ask
    /// against a platform allowance of roughly three prompts a year, which is
    /// precisely the failure this package exists to prevent. A prompt the user
    /// never resolved costs one cooldown of silence. That is the cheap direction,
    /// and it is deliberate.
    ///
    /// ## Not a substitute for ``promptDidDismiss()``
    ///
    /// The two say opposite things and are not interchangeable:
    ///
    /// - ``promptDidDismiss()`` says *our UI finished* — so it yields the outcome,
    ///   and that outcome is what the hand-off to the platform's review request
    ///   depends on.
    /// - This says *the prompt died* — nothing is owed, nothing is yielded, and
    ///   the platform's review request is never made. It yields no value at all,
    ///   so it cannot be mistaken for the call that drives the hand-off.
    ///
    /// Wiring this where ``promptDidDismiss()`` belonged means no rating ever
    /// reaches the App Store.
    ///
    /// ## A recorded outcome outlives it
    ///
    /// It discards a *prompt*, never an *outcome*: once the user has rated, this
    /// does nothing and the flow keeps owing that rating to ``promptDidDismiss()``.
    ///
    /// That matters for the one case where both callbacks fire — a dismissal and a
    /// pop driven by the same state change, where SwiftUI does not define which of
    /// `onDismiss` and `onDisappear` lands first. Clearing unconditionally would
    /// let a teardown that arrives first throw away a five-star rating, and the
    /// review would never be requested: a fresh silent failure introduced by the
    /// fix for another one. Declining to means the rating survives the race and is
    /// delivered by whichever call comes second.
    ///
    /// The cost of that choice is the mirror case — rated, then torn down with no
    /// `onDismiss` ever — where the flow does stay mid-prompt until relaunch. That
    /// is the behavior you already had, it spends nothing, and it self-heals on
    /// the next launch. Losing a good review outright does not.
    ///
    /// ## It emits no ``ReviewEvent``
    ///
    /// Every event describes something the user did or something done on their
    /// behalf. A view going away is neither, and it is *your* lifecycle — you are
    /// calling this from your own teardown, so log it there if you want it.
    /// ``ReviewEvent/dismissed`` deliberately does not cover this: it means the
    /// user declined, and inflating it with prompts nobody ever decided on
    /// corrupts the one number you would tune your cadence from.
    public func abandon() {
        // `.presenting(outcome: .none)` and not `.presenting`: a rating
        // already recorded is still owed to `promptDidDismiss()`. See above.
        guard case .presenting(outcome: .none) = state else { return }
        state = .idle
    }

    private func commit(to trigger: ReviewTrigger) {
        state = .presenting(outcome: nil)
        counters.markPrompted()
        events(.promptShown(trigger))
    }
}
