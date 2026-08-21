import Foundation

/// The thresholds ``ReviewTrigger/valueMoment`` must clear before the prompt is
/// eligible.
///
/// Every field is a *floor*: the state must meet or exceed it. Set a field to
/// `0` to disable that particular check.
///
/// ## Units are in the labels
///
/// Spans are given as whole hours and whole days rather than as a
/// `TimeInterval`, because that is the unit a cadence is actually written in — a
/// policy says *24 hours* and *120 days*, and a `TimeInterval` parameter makes
/// the caller convert. Taking the unit here deletes that conversion, and it means ReviewKit no
/// longer has to add `hours`/`days` to `Double` — a public extension on a
/// standard-library typealias that every consumer inherits whether it wants it
/// or not.
///
/// A negative threshold is a programmer error and traps. It cannot arrive from
/// anywhere but your own source — these values are literals in the cadence you
/// ship — so failing on the spot beats clamping it to `0`, which would silently
/// mean *no floor and no cooldown*: exactly the fail-open worth catching.
public struct ValueMomentPolicy: Sendable, Equatable {
    /// Value moments required. More than one is deliberate — coming back for a
    /// second means the first was not a novelty tap.
    ///
    /// Counted **since the last prompt**, not over the app's lifetime — see
    /// ``ReviewState/valueMomentCount``. That reset is the point here: the next
    /// ask has to be earned again. It is also why ``LaunchFallbackPolicy`` has no
    /// such field at all.
    public let minimumValueMoments: Int
    /// Lifetime launches required.
    public let minimumLaunches: Int
    /// How old the first recorded use must be, so "opened it ten times in one
    /// sitting" does not read as sustained use.
    public let minimumFirstUseAge: TimeInterval
    /// How long to stay silent after a prompt was last shown.
    ///
    /// Keep this comfortably under the platform's own throttle (App Store review
    /// requests are limited to roughly three per user per year) so *your*
    /// cadence is the binding one and you never spend a system prompt you did not
    /// decide to spend.
    public let cooldown: TimeInterval
    /// How long to stay silent after a setback — see
    /// ``ReviewCounters/recordSetback()``.
    ///
    /// `0`, the default, means setbacks are not consulted at all.
    public let setbackCooldown: TimeInterval

    /// - Parameters:
    ///   - minimumValueMoments: value moments required since the last prompt.
    ///   - minimumLaunches: lifetime launches required.
    ///   - minimumFirstUseAgeHours: how old the first recorded use must be.
    ///   - cooldownDays: how long to stay silent after a prompt was shown.
    ///   - setbackCooldownHours: how long to stay silent after a setback. `0`
    ///     ignores setbacks entirely.
    /// - Precondition: every threshold is non-negative.
    public init(
        minimumValueMoments: Int = 0,
        minimumLaunches: Int = 0,
        minimumFirstUseAgeHours: Int = 0,
        cooldownDays: Int = 0,
        setbackCooldownHours: Int = 0
    ) {
        precondition(
            minimumValueMoments >= 0 && minimumLaunches >= 0
                && minimumFirstUseAgeHours >= 0 && cooldownDays >= 0
                && setbackCooldownHours >= 0,
            "ReviewKit: policy thresholds must not be negative."
        )
        self.minimumValueMoments = minimumValueMoments
        self.minimumLaunches = minimumLaunches
        minimumFirstUseAge = .hours(Double(minimumFirstUseAgeHours))
        cooldown = .days(Double(cooldownDays))
        setbackCooldown = .hours(Double(setbackCooldownHours))
    }
}

/// The thresholds ``ReviewTrigger/launchFallback`` must clear.
///
/// The same floors as ``ValueMomentPolicy`` **minus the value-moment one**, and
/// that absence is the whole design. A floor against `valueMomentCount` here
/// would not be a stricter gate but a permanent one: committing to a prompt
/// zeroes that counter, and this path exists precisely for users who never
/// rebuild it, so nothing would ever raise the prompt again — silently, months
/// later, with no error anywhere.
///
/// Express "sustained launches *and* value moments" with a ``ValueMomentPolicy``
/// and a high ``ValueMomentPolicy/minimumLaunches``, where the counter's reset is
/// what you want.
///
/// The setback cooldown *is* here, unlike the value-moment floor, because it is
/// a silence and not an earning: a user who hit a problem an hour ago must not
/// be asked by either path — which means setting it on ``ValueMomentPolicy``
/// alone leaves this one prompting them anyway. Set both or neither.
public struct LaunchFallbackPolicy: Sendable, Equatable {
    /// Lifetime launches required. Set this high — with no value moment to point
    /// at, sustained use has to carry the whole argument.
    public let minimumLaunches: Int
    /// How old the first recorded use must be.
    public let minimumFirstUseAge: TimeInterval
    /// How long to stay silent after a prompt was last shown.
    public let cooldown: TimeInterval
    /// How long to stay silent after a setback. `0` ignores setbacks entirely.
    public let setbackCooldown: TimeInterval

    /// - Parameters:
    ///   - minimumLaunches: lifetime launches required.
    ///   - minimumFirstUseAgeHours: how old the first recorded use must be.
    ///   - cooldownDays: how long to stay silent after a prompt was shown.
    ///   - setbackCooldownHours: how long to stay silent after a setback. `0`
    ///     ignores setbacks entirely.
    /// - Precondition: every threshold is non-negative.
    public init(
        minimumLaunches: Int = 0,
        minimumFirstUseAgeHours: Int = 0,
        cooldownDays: Int = 0,
        setbackCooldownHours: Int = 0
    ) {
        precondition(
            minimumLaunches >= 0 && minimumFirstUseAgeHours >= 0
                && cooldownDays >= 0 && setbackCooldownHours >= 0,
            "ReviewKit: policy thresholds must not be negative."
        )
        self.minimumLaunches = minimumLaunches
        minimumFirstUseAge = .hours(Double(minimumFirstUseAgeHours))
        cooldown = .days(Double(cooldownDays))
        setbackCooldown = .hours(Double(setbackCooldownHours))
    }
}

/// The cadence for every trigger, in one value.
///
/// Build one and hold it wherever your app's configuration lives. Nothing here
/// is read from disk or from a server by the package itself — an app with remote
/// config decodes its own payload and constructs one of these when that lands,
/// and the gate picks it up on the next evaluation. ReviewKit deliberately ships
/// no `Codable` conformance for that: merging a partial payload onto defaults is
/// a policy question about *your* config service.
public struct ReviewConfiguration: Sendable, Equatable {
    public let valueMoment: ValueMomentPolicy

    /// The launch-fallback cadence, or `nil` to switch that trigger **off**.
    ///
    /// `nil` means ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)``
    /// returns `false` for ``ReviewTrigger/launchFallback`` no matter what the
    /// counters say, and ``ReviewGate/diagnose(trigger:state:configuration:now:)``
    /// reports one unmet ``ReviewGateDiagnosis/Check/Requirement/enabled`` check
    /// instead of floors it does not apply.
    ///
    /// **Why this is optional.** The alternative is to *simulate* off by
    /// supplying floors you believe unreachable — typically a launch floor in an
    /// app that never calls ``ReviewCounters/recordLaunch()``. That works until it
    /// does not: the day anything starts counting launches, for any unrelated
    /// reason, the app silently acquires a second trigger nobody asked for and
    /// begins prompting on a path it never designed. Same argument as
    /// ``LaunchFallbackPolicy``'s missing value-moment floor — a state that must
    /// not happen is better made unrepresentable than pinned by a number someone
    /// has to keep true.
    ///
    /// There is deliberately **no default** for this parameter. Switching a
    /// trigger off is a cadence decision, and it must be a line someone wrote
    /// rather than one they inherited by omission.
    public let launchFallback: LaunchFallbackPolicy?

    public init(valueMoment: ValueMomentPolicy, launchFallback: LaunchFallbackPolicy?) {
        self.valueMoment = valueMoment
        self.launchFallback = launchFallback
    }

    /// Whether *either* trigger would consult a setback stamp.
    ///
    /// Used by ``ReviewPromptFlow`` to catch a cadence that asks for setbacks
    /// paired with keys that cannot store one — a mismatch that is otherwise
    /// silent everywhere, including in the diagnosis.
    ///
    /// A `nil` fallback contributes nothing here: a trigger that never fires
    /// cannot need a setback stamp, so its policy must not be what makes the
    /// pairing assert.
    var consultsSetbacks: Bool {
        valueMoment.setbackCooldown > 0 || (launchFallback?.setbackCooldown ?? 0) > 0
    }

    /// A conservative cadence, and a reasonable place to start.
    ///
    /// The value-moment launch floor is low on purpose — the value moment is the
    /// real signal, and the floor only exists to exclude a day-one user who
    /// succeeds immediately. The fallback's floor is high on purpose: with no
    /// value moment to point at, sustained use has to carry the whole argument.
    ///
    /// No setback cooldown. What counts as a setback is entirely yours — a
    /// failed sync, a crash, an ask that returned nothing — so a span picked here
    /// would be a cadence nobody chose, applied to an event ReviewKit cannot see.
    /// Opt in with ``ValueMomentPolicy/init(minimumValueMoments:minimumLaunches:minimumFirstUseAgeHours:cooldownDays:setbackCooldownHours:)``.
    public static let `default` = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(
            minimumValueMoments: 2,
            minimumLaunches: 5,
            minimumFirstUseAgeHours: 24,
            cooldownDays: 120
        ),
        launchFallback: LaunchFallbackPolicy(
            minimumLaunches: 20,
            minimumFirstUseAgeHours: 24,
            cooldownDays: 120
        )
    )
}

/// Readable spans for the package's own arithmetic and its tests.
///
/// **Internal on purpose.** Public, these would add `hours` and `days` to
/// `Double` — `TimeInterval` is a typealias for it — in every consumer that
/// imports ReviewKit, and in the whole app for anyone re-exporting the module.
/// Two names that generic on a standard-library type is a collision
/// waiting for the next package with the same idea. The policy initializers take
/// hours and days directly instead, which is the unit a cadence is written in
/// anyway.
extension TimeInterval {
    /// `count` hours as a `TimeInterval`.
    static func hours(_ count: Double) -> TimeInterval { count * 3_600 }
    /// `count` days as a `TimeInterval`.
    static func days(_ count: Double) -> TimeInterval { count * 86_400 }
}
