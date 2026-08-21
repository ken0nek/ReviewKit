import Foundation

/// `UserDefaults`-backed storage for ``ReviewState``.
///
/// Holds the counters and nothing else — the decision stays in ``ReviewGate``,
/// the presentation stays in your app. Point it at whichever suite your app
/// already uses. An App Group suite lets extensions and widgets record value
/// moments too.
///
/// Both dependencies are injectable, so tests use a throwaway suite and a fixed
/// clock and need no global stubbing.
///
/// Plain `Sendable`, not `@unchecked`: `UserDefaults` is documented as
/// thread-safe but is not itself marked `Sendable`, so only the `defaults`
/// property carries the exemption, spelled `nonisolated(unsafe)` at its
/// declaration. Every other stored property is compiler-checked rather than
/// asserted in a comment.
///
/// ## Timestamp storage
///
/// Timestamps are written as epoch seconds and read as *either* epoch seconds or
/// a `Date` object, so a key injected from a shipped app that persisted a `Date`
/// is understood rather than silently discarded. See ``ReviewKeys`` for why that
/// case is worth the four extra lines.
///
/// ## Shared suites
///
/// Increments are read-modify-write, so an app and an extension writing the same
/// App Group suite in the same instant can lose one. The direction is the safe
/// one — an undercount delays the ask and never hastens it — and the first-use
/// anchor races to the same value either way, so no locking is worth its cost
/// here. What is *not* protected is wall-clock movement: a device clock jumped
/// far forward reads the cooldown as expired. Backwards movement fails closed.
public struct ReviewCounters: Sendable {
    /// `nonisolated(unsafe)` rather than `@unchecked Sendable` on the whole
    /// type. `UserDefaults` is documented as thread-safe but is not marked
    /// `Sendable`, so exactly one property needs the exemption — and spelling it
    /// that way leaves the compiler checking every other one. `@unchecked` on
    /// the type checks none of them: "every other stored property here is
    /// immutable" becomes an assertion nothing enforces, and a later `var`, or a
    /// genuinely unsafe reference type, compiles silently. Same idiom the test
    /// helpers use for the same reason.
    nonisolated(unsafe) private let defaults: UserDefaults
    /// Internal rather than private so ``ReviewPromptFlow`` can check, at
    /// construction, that a configuration asking for a setback cooldown has a key
    /// to stamp it under. Without that check the mismatch is silent in every
    /// direction — see the assertion there.
    let keys: ReviewKeys
    /// Internal rather than private so ``ReviewPromptFlow`` can judge the gate on
    /// the same clock that wrote the stamps. Comparing timestamps written here
    /// against wall time would make any host that injects a clock — the advertised
    /// way to test its own review wiring — get nonsense answers.
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - defaults: the suite to read and write. Defaults to `.standard`.
    ///   - keys: the key names to use — see ``ReviewKeys`` on why you supply them.
    ///   - now: the clock, injected for tests.
    public init(
        defaults: UserDefaults = .standard,
        keys: ReviewKeys = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.keys = keys
        self.now = now
    }

    /// The counters as they stand.
    public var state: ReviewState {
        ReviewState(
            launchCount: defaults.integer(forKey: keys.launchCount),
            valueMomentCount: defaults.integer(forKey: keys.valueMomentCount),
            firstUseAt: date(forKey: keys.firstUseAt),
            lastPromptedAt: date(forKey: keys.lastPromptedAt),
            lastSetbackAt: keys.lastSetbackAt.flatMap(date(forKey:))
        )
    }

    /// Counts one launch, stamping the first-use anchor on the very first call.
    ///
    /// The anchor is first-write-wins: the sustained-use clock starts at genuine
    /// first use and never restarts, so a user cannot reset their way to an
    /// earlier ask.
    public func recordLaunch() {
        defaults.set(defaults.integer(forKey: keys.launchCount) + 1, forKey: keys.launchCount)
        stampFirstUseIfNeeded()
    }

    /// Counts one value moment — the app's core action completing.
    ///
    /// Also stamps the first-use anchor if nothing has yet, so an app that never
    /// calls ``recordLaunch()`` still has a span to measure.
    public func recordValueMoment() {
        defaults.set(defaults.integer(forKey: keys.valueMomentCount) + 1, forKey: keys.valueMomentCount)
        stampFirstUseIfNeeded()
    }

    /// Starts the cooldown and clears the value-moment counter, so the next ask
    /// needs fresh evidence rather than riding the same successes forever.
    ///
    /// Call this the instant you **commit** to showing the prompt — not when the
    /// UI appears. Backgrounding or a crash between those two moments would
    /// otherwise leave the gate armed with no cooldown recorded, and the user
    /// gets asked again on next launch.
    public func markPrompted() {
        defaults.set(now().timeIntervalSince1970, forKey: keys.lastPromptedAt)
        defaults.set(0, forKey: keys.valueMomentCount)
    }

    /// Stamps a setback: something went wrong for this user just now, so the gate
    /// stays quiet for ``ValueMomentPolicy/setbackCooldown``.
    ///
    /// What counts is yours to decide — a sync that failed, a purchase that
    /// errored, a request that came back empty, a crash caught on the previous
    /// launch. ReviewKit only knows the timestamp, and only the most recent one:
    /// this is a silence, not a tally, so repeated setbacks extend the window
    /// rather than deepening it.
    ///
    /// Unlike ``markPrompted()`` this never zeroes the value-moment counter. The
    /// user's earned progress toward the ask is not forfeited by a bad day. It is
    /// only deferred.
    ///
    /// A no-op when ``ReviewKeys/lastSetbackAt`` is `nil`, which is the whole of
    /// opting out.
    public func recordSetback() {
        guard let key = keys.lastSetbackAt else { return }
        defaults.set(now().timeIntervalSince1970, forKey: key)
    }

    /// Removes every key this store owns. Useful for a debug menu or a test.
    public func reset() {
        var owned = [keys.launchCount, keys.valueMomentCount, keys.firstUseAt, keys.lastPromptedAt]
        if let setback = keys.lastSetbackAt { owned.append(setback) }
        for key in owned {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether the gate would raise `trigger` for *these* counters right now.
    ///
    /// Prefer this over calling ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)``
    /// with ``state``: that overload takes `now` separately and defaults it to
    /// `Date()`, so a caller holding counters on an injected clock can measure
    /// their stamps against wall time and get an answer the app will not act on.
    /// Here the two cannot come apart.
    public func shouldPrompt(
        trigger: ReviewTrigger,
        configuration: ReviewConfiguration = .default
    ) -> Bool {
        ReviewGate.shouldPrompt(
            trigger: trigger, state: state, configuration: configuration, now: now()
        )
    }

    #if DEBUG
    /// Explains what the gate would decide for *these* counters, and why.
    ///
    /// The paired form of ``ReviewGate/diagnose(trigger:state:configuration:now:)``,
    /// and the one a developer menu wants: it judges on the clock that wrote the
    /// stamps, so the screen cannot report a verdict the app disagrees with. The
    /// unpaired overload is for a host with its own storage, whose stamps come
    /// from wall time anyway.
    public func diagnose(
        trigger: ReviewTrigger,
        configuration: ReviewConfiguration = .default
    ) -> ReviewGateDiagnosis {
        ReviewGate.diagnose(
            trigger: trigger, state: state, configuration: configuration, now: now()
        )
    }
    #endif

    /// The clock these counters stamp with, so a caller rendering a captured
    /// ``state`` can judge it on the same clock rather than on wall time.
    ///
    /// Public because ``ReviewGateDiagnosis`` is rendered from a snapshot
    /// taken once — see `ReviewDiagnosticsView` — so the paired
    /// ``diagnose(trigger:configuration:)`` above, which re-reads `state`,
    /// is the wrong shape there.
    public var clock: @Sendable () -> Date { now }

    private func stampFirstUseIfNeeded() {
        guard date(forKey: keys.firstUseAt) == nil else { return }
        defaults.set(now().timeIntervalSince1970, forKey: keys.firstUseAt)
    }

    /// Timestamps are written as epoch seconds; `0` and absent both mean never.
    ///
    /// A `Date` object is also accepted, because an injected key from a shipped
    /// app can hold one — `double(forKey:)` returns `0` for such a value, which
    /// would read as "never prompted" and re-ask a user who is mid-cooldown.
    /// Reading is all this does: the value is left as it is until the next write,
    /// so adopting the package still migrates nothing.
    private func date(forKey key: String) -> Date? {
        if let date = defaults.object(forKey: key) as? Date { return date }
        let epoch = defaults.double(forKey: key)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }
}
