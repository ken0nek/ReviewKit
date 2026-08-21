#if DEBUG
import Foundation

/// Why the gate would or would not raise the prompt right now, requirement by
/// requirement — for a developer menu, not for production logic.
///
/// ## Why this exists
///
/// A debug screen that shows "launches 3 / 5" in green or red has to decide
/// *met* or *unmet* somehow, and the obvious way is to re-write the comparison
/// in the view. That copy can drift from the gate: the screen then reports a
/// state the app does not actually act on, which is worse than showing nothing,
/// because it is the screen you consult when the ask misbehaves.
///
/// So the verdicts come from here. ``wouldPrompt`` is
/// ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)`` itself rather
/// than a re-derivation, and a test binds it to the checks: if the two could
/// ever disagree, the suite fails.
///
/// ## What it is not
///
/// `DEBUG` only, and deliberately so — this is developer-facing English for a
/// menu behind a hidden row, not a supported way to ask the gate anything. Branch
/// production behavior on ``ReviewGate/shouldPrompt(trigger:state:configuration:now:)``
/// or ``ReviewPromptFlow/commitToPromptIfEligible(trigger:)``, never on this.
///
/// The package renders nothing: your developer menu draws ``checks`` as its own
/// rows, in its own style, the way it already draws every other diagnostic.
public struct ReviewGateDiagnosis: Sendable, Equatable {
    /// One requirement, and whether the current state clears it.
    public struct Check: Sendable, Equatable {
        /// Which floor this is. Note there is no `valueMoments` case in a
        /// ``ReviewTrigger/launchFallback`` diagnosis at all — that trigger has
        /// no such floor to fail, mirroring ``LaunchFallbackPolicy``.
        public enum Requirement: Sendable, Equatable, CaseIterable {
            case valueMoments
            case launches
            case sustainedUse
            case cooldown
            /// The silence owed to a recent setback. Reported by both triggers,
            /// unlike ``valueMoments`` — a setback is a silence rather than
            /// something to be earned, so it applies to the fallback too.
            case setback
            /// The trigger is configured at all — `nil`
            /// ``ReviewConfiguration/launchFallback`` switches it off.
            ///
            /// **Only ever reported unmet, and only ever alone.** A disabled
            /// trigger applies exactly one requirement, so this replaces the floor
            /// rows rather than joining them: there are no floors to report, and
            /// listing them against a policy that does not exist would be the
            /// screen inventing a cadence. Reporting it as a `Check` rather than as
            /// a separate flag on ``ReviewGateDiagnosis`` is what keeps
            /// ``ReviewGateDiagnosis/wouldPrompt`` equal to
            /// `checks.allSatisfy(\.isMet)` and ``ReviewGateDiagnosis/blockers``
            /// empty exactly when the gate is open — both of which a diagnosis
            /// carrying zero checks would have quietly broken.
            case enabled
        }

        public let requirement: Requirement
        public let isMet: Bool
        /// Current against required, already formatted — "3 / 5", "2h of 24h",
        /// "never prompted". Developer-facing English on purpose: a host
        /// otherwise writes this same formatting itself, and a debug menu has
        /// no localization to respect.
        public let detail: String
    }

    /// Which trigger was diagnosed.
    public let trigger: ReviewTrigger
    /// Every requirement this trigger applies, in the order the gate reads them.
    public let checks: [Check]
    /// The gate's actual answer — not a re-derivation from ``checks``.
    public let wouldPrompt: Bool

    /// The requirements standing in the way. Empty exactly when ``wouldPrompt``
    /// is `true`.
    public var blockers: [Check] { checks.filter { !$0.isMet } }
}

public extension ReviewGateDiagnosis.Check.Requirement {
    /// A short developer-facing name for a debug row.
    ///
    /// Here for the same reason ``ReviewGateDiagnosis/Check/detail`` is: without
    /// it each debug menu spells these five requirements its own way, and the
    /// raw case name is what a menu settles for. A debug menu has no
    /// localization to respect, so English is the whole API.
    var label: String {
        switch self {
        case .valueMoments: "Value moments"
        case .launches: "Launches"
        case .sustainedUse: "Sustained use"
        case .cooldown: "Cooldown"
        case .setback: "Setback"
        case .enabled: "Trigger"
        }
    }
}

public extension ReviewGate {
    /// Explains what the gate would decide right now, and why.
    ///
    /// Takes the same arguments as
    /// ``shouldPrompt(trigger:state:configuration:now:)`` and calls it for the
    /// verdict, so the two can never disagree.
    static func diagnose(
        trigger: ReviewTrigger,
        state: ReviewState,
        configuration: ReviewConfiguration = .default,
        now: Date = Date()
    ) -> ReviewGateDiagnosis {
        var checks: [ReviewGateDiagnosis.Check] = []

        let minimumLaunches: Int
        let minimumFirstUseAge: TimeInterval
        let cooldown: TimeInterval
        let setbackCooldown: TimeInterval

        switch trigger {
        case .valueMoment:
            let policy = configuration.valueMoment
            minimumLaunches = policy.minimumLaunches
            minimumFirstUseAge = policy.minimumFirstUseAge
            cooldown = policy.cooldown
            setbackCooldown = policy.setbackCooldown
            checks.append(.init(
                requirement: .valueMoments,
                isMet: state.valueMomentCount >= policy.minimumValueMoments,
                detail: "\(state.valueMomentCount) / \(policy.minimumValueMoments)"
            ))
        case .launchFallback:
            // Switched off. Return here rather than falling through to the floor
            // rows: with no policy there are no floors, and drawing them against
            // numbers that do not exist is the screen inventing a cadence — the
            // exact drift this type was built to stop. `wouldPrompt` still comes
            // from the gate, so the one unmet check and the verdict cannot
            // disagree.
            guard let policy = configuration.launchFallback else {
                return ReviewGateDiagnosis(
                    trigger: trigger,
                    checks: [.init(
                        requirement: .enabled,
                        isMet: false,
                        detail: "disabled"
                    )],
                    wouldPrompt: shouldPrompt(
                        trigger: trigger, state: state, configuration: configuration, now: now
                    )
                )
            }
            minimumLaunches = policy.minimumLaunches
            minimumFirstUseAge = policy.minimumFirstUseAge
            cooldown = policy.cooldown
            setbackCooldown = policy.setbackCooldown
        }

        checks.append(.init(
            requirement: .launches,
            isMet: state.launchCount >= minimumLaunches,
            detail: "\(state.launchCount) / \(minimumLaunches)"
        ))

        checks.append(sustainedUseCheck(
            firstUseAt: state.firstUseAt, minimum: minimumFirstUseAge, now: now
        ))
        checks.append(cooldownCheck(
            lastPromptedAt: state.lastPromptedAt, cooldown: cooldown, now: now
        ))
        checks.append(setbackCheck(
            lastSetbackAt: state.lastSetbackAt, cooldown: setbackCooldown, now: now
        ))

        return ReviewGateDiagnosis(
            trigger: trigger,
            checks: checks,
            // The real gate, not a re-derivation. `ReviewGateDiagnosisTests`
            // asserts this equals `checks.allSatisfy(\.isMet)` over a matrix of
            // states, so a future edit cannot let the menu and the app disagree.
            wouldPrompt: shouldPrompt(
                trigger: trigger, state: state, configuration: configuration, now: now
            )
        )
    }

    private static func sustainedUseCheck(
        firstUseAt: Date?, minimum: TimeInterval, now: Date
    ) -> ReviewGateDiagnosis.Check {
        guard let firstUseAt else {
            // Fails closed in the gate, so it reads as unmet here even when the
            // requirement is zero — there is no evidence of a span either way.
            return .init(requirement: .sustainedUse, isMet: false, detail: "not recorded")
        }
        let age = now.timeIntervalSince(firstUseAt)
        return .init(
            requirement: .sustainedUse,
            isMet: age >= minimum,
            detail: minimum == 0 ? "\(span(age)), no minimum" : "\(span(age)) of \(span(minimum))"
        )
    }

    private static func cooldownCheck(
        lastPromptedAt: Date?, cooldown: TimeInterval, now: Date
    ) -> ReviewGateDiagnosis.Check {
        guard let lastPromptedAt else {
            return .init(requirement: .cooldown, isMet: true, detail: "never prompted")
        }
        return .init(
            requirement: .cooldown,
            // The gate's own comparison, verbatim — deliberately not
            // short-circuited to "met" whenever `cooldown` is `0`. That is right
            // for every state except a stamp in the future — a device clock moved
            // backwards — where the gate shuts and the menu would say it was open.
            isMet: now.timeIntervalSince(lastPromptedAt) >= cooldown,
            detail: elapsedDetail(
                elapsed: now.timeIntervalSince(lastPromptedAt),
                cooldown: cooldown,
                noCooldown: "no cooldown"
            )
        )
    }

    private static func setbackCheck(
        lastSetbackAt: Date?, cooldown: TimeInterval, now: Date
    ) -> ReviewGateDiagnosis.Check {
        guard let lastSetbackAt else {
            // Also the answer for an app that records no setbacks at all, which
            // is most of them — nothing stamped, nothing owed.
            return .init(requirement: .setback, isMet: true, detail: "none recorded")
        }
        return .init(
            requirement: .setback,
            isMet: now.timeIntervalSince(lastSetbackAt) >= cooldown,
            detail: elapsedDetail(
                elapsed: now.timeIntervalSince(lastSetbackAt),
                cooldown: cooldown,
                noCooldown: "no setback cooldown"
            )
        )
    }

    private static func elapsedDetail(
        elapsed: TimeInterval, cooldown: TimeInterval, noCooldown: String
    ) -> String {
        // A stamp in the future — a device clock moved backwards — shuts the gate
        // even with no cooldown configured, because the elapsed span is negative.
        // The verdict handles that. This string has to as well, or the menu shows
        // a blocker whose explanation says the constraint does not exist.
        guard elapsed >= 0 else { return "stamped in the future" }
        guard cooldown > 0 else { return noCooldown }
        return elapsed >= cooldown
            ? "\(span(elapsed)) of \(span(cooldown)), elapsed"
            : "\(span(cooldown - elapsed)) remaining"
    }

    /// Coarse, deliberately locale-free: a debug row wants "26h", not
    /// "1 day, 2 hours", and a formatter would make these strings depend on the
    /// device's locale for no benefit to the one person reading them.
    private static func span(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 172_800 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}
#endif
