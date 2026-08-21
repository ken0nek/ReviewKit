import Foundation

/// The rating prompt's decision logic: a pure function of state, configuration
/// and a clock.
///
/// No storage, no view state, no singleton — so it unit-tests in microseconds
/// without a simulator, and the same inputs always give the same answer.
public enum ReviewGate {
    /// Whether the prompt can be raised right now for `trigger`.
    ///
    /// Returns `true` only when all of these hold:
    /// - the trigger's floors are met — including the value-moment floor, which
    ///   only ``ReviewTrigger/valueMoment`` has,
    /// - a first use is recorded and is at least `minimumFirstUseAge` old,
    /// - the cooldown since the last prompt has elapsed (or none was ever shown),
    /// - the setback cooldown has elapsed (or no setback was ever recorded).
    ///
    /// - Parameters:
    ///   - trigger: which moment is asking.
    ///   - state: the persisted counters.
    ///   - configuration: the cadence to judge them against.
    ///   - now: the current time, injected so this stays testable.
    public static func shouldPrompt(
        trigger: ReviewTrigger,
        state: ReviewState,
        configuration: ReviewConfiguration = .default,
        now: Date = Date()
    ) -> Bool {
        switch trigger {
        case .valueMoment:
            let policy = configuration.valueMoment
            guard state.valueMomentCount >= policy.minimumValueMoments else { return false }
            return meetsSharedFloors(
                state: state,
                minimumLaunches: policy.minimumLaunches,
                minimumFirstUseAge: policy.minimumFirstUseAge,
                cooldown: policy.cooldown,
                setbackCooldown: policy.setbackCooldown,
                now: now
            )

        case .launchFallback:
            // No value-moment check here, and none is expressible: `markPrompted()`
            // zeroes that counter and this path serves the users who never rebuild
            // it. See ``LaunchFallbackPolicy``.
            //
            // A `nil` policy is the trigger switched off, and it fails closed
            // before any counter is read. The alternative — a floor believed
            // unreachable — stays true only until something starts writing that
            // counter.
            guard let policy = configuration.launchFallback else { return false }
            return meetsSharedFloors(
                state: state,
                minimumLaunches: policy.minimumLaunches,
                minimumFirstUseAge: policy.minimumFirstUseAge,
                cooldown: policy.cooldown,
                setbackCooldown: policy.setbackCooldown,
                now: now
            )
        }
    }

    /// The floors both triggers share: launches, sustained use, the cooldown, and
    /// the silence owed to a recent setback.
    private static func meetsSharedFloors(
        state: ReviewState,
        minimumLaunches: Int,
        minimumFirstUseAge: TimeInterval,
        cooldown: TimeInterval,
        setbackCooldown: TimeInterval,
        now: Date
    ) -> Bool {
        guard state.launchCount >= minimumLaunches else { return false }

        // Sustained use. A missing first-use stamp fails closed: without it there
        // is no evidence of a span, and asking too early is the costlier mistake.
        guard let firstUseAt = state.firstUseAt,
              now.timeIntervalSince(firstUseAt) >= minimumFirstUseAge
        else { return false }

        if let lastPromptedAt = state.lastPromptedAt,
           now.timeIntervalSince(lastPromptedAt) < cooldown {
            return false
        }

        // Read exactly like the cooldown above, including the direction it fails
        // in: a clock that moved backwards leaves the stamp in the future, the
        // elapsed span negative, and the gate shut. Staying quiet is the cheap
        // mistake in both cases.
        if let lastSetbackAt = state.lastSetbackAt,
           now.timeIntervalSince(lastSetbackAt) < setbackCooldown {
            return false
        }

        return true
    }
}
