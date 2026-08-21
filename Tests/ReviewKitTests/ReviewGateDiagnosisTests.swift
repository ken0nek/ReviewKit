import Foundation
import Testing
@testable import ReviewKit

/// The diagnosis is `DEBUG`-only, so this whole suite is too — a release test run
/// reports fewer tests rather than failing to compile.
#if DEBUG
@Suite("ReviewGateDiagnosis")
struct ReviewGateDiagnosisTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3_600) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func diagnose(
        _ trigger: ReviewTrigger, _ state: ReviewState
    ) -> ReviewGateDiagnosis {
        ReviewGate.diagnose(trigger: trigger, state: state, configuration: .default, now: now)
    }

    /// **The test the type exists for.** A debug menu that re-derives met/unmet in
    /// the view can drift from the gate. These verdicts must be the same answer,
    /// decomposed. Run over a matrix rather than a happy path, because drift shows
    /// up in the corners.
    @Test("every check agreeing is exactly the gate's own answer")
    func checksAgreeWithTheGate() {
        let launches = [0, 4, 5, 19, 20, 500]
        let valueMoments = [0, 1, 2, 50]
        let firstUses: [Date?] = [nil, hoursAgo(1), hoursAgo(23), hoursAgo(25), daysAgo(400)]
        // The future stamp is the corner most at risk: with a cooldown of `0` it
        // is the one state where a diagnosis that short-circuits to "met" would
        // disagree with the gate, which compares a negative elapsed span and
        // shuts. A device clock moved backwards is the
        // only way to reach it, and a debug menu is exactly where you would go to
        // find out why the prompt had stopped appearing.
        let lastPrompts: [Date?] = [nil, daysAgo(1), daysAgo(119), daysAgo(121), daysAgo(-5)]
        let lastSetbacks: [Date?] = [nil, hoursAgo(1), hoursAgo(25), daysAgo(-5)]

        // Both a cadence that consults setbacks and one that does not, because
        // the checks have to line up with the gate under either.
        let configurations = [ReviewConfiguration.default, Self.setbackAware]

        for configuration in configurations {
            for trigger in [ReviewTrigger.valueMoment, .launchFallback] {
                for launch in launches {
                    for moments in valueMoments {
                        for firstUse in firstUses {
                            for lastPrompt in lastPrompts {
                                for lastSetback in lastSetbacks {
                                    let state = ReviewState(
                                        launchCount: launch, valueMomentCount: moments,
                                        firstUseAt: firstUse, lastPromptedAt: lastPrompt,
                                        lastSetbackAt: lastSetback
                                    )
                                    let diagnosis = ReviewGate.diagnose(
                                        trigger: trigger, state: state,
                                        configuration: configuration, now: now
                                    )

                                    #expect(
                                        diagnosis.wouldPrompt == diagnosis.checks.allSatisfy(\.isMet),
                                        """
                                        \(trigger) disagreed: wouldPrompt=\(diagnosis.wouldPrompt) \
                                        but checks=\(diagnosis.checks.map(\.isMet)) for \(state)
                                        """
                                    )
                                    #expect(diagnosis.blockers.isEmpty == diagnosis.wouldPrompt)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `.default`'s floors plus a day of silence after a setback.
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

    /// The fallback has no value-moment floor to fail, so it must not report one —
    /// the same invariant `LaunchFallbackPolicy` enforces in the type system.
    @Test("the launch fallback reports no value-moment requirement")
    func fallbackHasNoValueMomentCheck() {
        let state = ReviewState(launchCount: 20, valueMomentCount: 0, firstUseAt: hoursAgo(25))
        let requirements = diagnose(.launchFallback, state).checks.map(\.requirement)

        #expect(!requirements.contains(.valueMoments))
        // `.setback` *is* here, unlike `.valueMoments`: a setback is a silence
        // owed to both paths rather than something the fallback cannot earn.
        #expect(requirements == [.launches, .sustainedUse, .cooldown, .setback])
        // …and the value-moment path does report the one the fallback cannot.
        #expect(diagnose(.valueMoment, state).checks.map(\.requirement)
                == [.valueMoments, .launches, .sustainedUse, .cooldown, .setback])
    }

    /// A cadence with the fallback switched off, in a state that clears every
    /// floor the fallback would have applied. The point is that clearing them
    /// changes nothing.
    private static let fallbackOff = ReviewConfiguration(
        valueMoment: ValueMomentPolicy(
            minimumValueMoments: 2, minimumLaunches: 5,
            minimumFirstUseAgeHours: 24, cooldownDays: 120
        ),
        launchFallback: nil
    )

    /// `nil` is off, and off has to be *reported* as off rather than as floors
    /// nobody configured. A screen that drew "0 / 0" here would be inventing a
    /// cadence, which is the drift `ReviewGateDiagnosis` exists to prevent.
    @Test("a disabled fallback reports one unmet enabled check and nothing else")
    func disabledFallbackReportsItself() {
        // Everything the fallback would ask for is satisfied — so if the nil check
        // were missing, this state would prompt.
        let state = ReviewState(
            launchCount: 9_999, valueMomentCount: 9_999, firstUseAt: daysAgo(400)
        )
        let diagnosis = ReviewGate.diagnose(
            trigger: .launchFallback, state: state,
            configuration: Self.fallbackOff, now: now
        )

        #expect(diagnosis.checks.map(\.requirement) == [.enabled])
        #expect(diagnosis.checks.first?.isMet == false)
        #expect(diagnosis.checks.first?.detail == "disabled")
        #expect(diagnosis.wouldPrompt == false)
        // The two invariants a zero-check diagnosis would have broken silently.
        #expect(diagnosis.wouldPrompt == diagnosis.checks.allSatisfy(\.isMet))
        #expect(diagnosis.blockers.isEmpty == diagnosis.wouldPrompt)
    }

    /// Switching the fallback off must not touch the other trigger — the whole
    /// point is asking on one path only, not asking less on both.
    @Test("a disabled fallback leaves the value-moment path untouched")
    func disabledFallbackDoesNotAffectValueMoment() {
        let state = ReviewState(
            launchCount: 9_999, valueMomentCount: 9_999, firstUseAt: daysAgo(400)
        )

        #expect(ReviewGate.shouldPrompt(
            trigger: .launchFallback, state: state,
            configuration: Self.fallbackOff, now: now
        ) == false)
        #expect(ReviewGate.shouldPrompt(
            trigger: .valueMoment, state: state,
            configuration: Self.fallbackOff, now: now
        ) == true)

        let diagnosis = ReviewGate.diagnose(
            trigger: .valueMoment, state: state,
            configuration: Self.fallbackOff, now: now
        )
        #expect(diagnosis.checks.map(\.requirement)
                == [.valueMoments, .launches, .sustainedUse, .cooldown, .setback])
        #expect(diagnosis.wouldPrompt)
    }

    /// An app that records no setbacks — most of them — must not see a row that
    /// is permanently red, or permanently meaningless.
    @Test("with nothing recorded the setback check is met and says so")
    func absentSetbackIsMet() {
        let state = ReviewState(launchCount: 99, valueMomentCount: 99, firstUseAt: daysAgo(400))
        let check = diagnose(.valueMoment, state).checks.first { $0.requirement == .setback }

        #expect(check?.isMet == true)
        #expect(check?.detail == "none recorded")
    }

    @Test("a running setback cooldown reports what is left of it")
    func runningSetbackReportsRemaining() {
        let configuration = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(
                minimumFirstUseAgeHours: 24, setbackCooldownHours: 24
            ),
            launchFallback: LaunchFallbackPolicy()
        )
        let state = ReviewState(
            launchCount: 99, valueMomentCount: 99,
            firstUseAt: daysAgo(400), lastSetbackAt: hoursAgo(6)
        )
        let diagnosis = ReviewGate.diagnose(
            trigger: .valueMoment, state: state, configuration: configuration, now: now
        )
        let check = diagnosis.checks.first { $0.requirement == .setback }

        #expect(check?.isMet == false)
        #expect(check?.detail == "18h remaining")
        #expect(diagnosis.blockers.map(\.requirement) == [.setback])
    }

    @Test("blockers name what is actually standing in the way")
    func blockersNameTheFailingRequirement() {
        // Everything cleared except the launch floor.
        let state = ReviewState(
            launchCount: 4, valueMomentCount: 2, firstUseAt: hoursAgo(25), lastPromptedAt: nil
        )
        let diagnosis = diagnose(.valueMoment, state)

        #expect(!diagnosis.wouldPrompt)
        #expect(diagnosis.blockers.map(\.requirement) == [.launches])
        #expect(diagnosis.blockers.first?.detail == "4 / 5")
    }

    /// An unrecorded first use fails the gate closed, so it must read unmet rather
    /// than as a zero-length span that trivially passes.
    @Test("an unrecorded first use reads as unmet, not as zero")
    func unrecordedFirstUseIsUnmet() {
        let state = ReviewState(launchCount: 99, valueMomentCount: 99, firstUseAt: nil)
        let check = diagnose(.valueMoment, state).checks.first { $0.requirement == .sustainedUse }

        #expect(check?.isMet == false)
        #expect(check?.detail == "not recorded")
    }

    @Test("a cooldown still running reports what is left of it")
    func runningCooldownReportsRemaining() {
        let state = ReviewState(
            launchCount: 99, valueMomentCount: 99,
            firstUseAt: daysAgo(400), lastPromptedAt: daysAgo(100)
        )
        let check = diagnose(.valueMoment, state).checks.first { $0.requirement == .cooldown }

        #expect(check?.isMet == false)
        #expect(check?.detail == "20d remaining")
    }

    /// The same corner as the `isMet` matrix above, asserted on the *detail* too.
    /// A stamp in the future shuts the gate even with no cooldown configured, so
    /// the row is a blocker — and it must not explain itself as "no cooldown",
    /// which is the constraint it is failing on.
    @Test("a future-dated stamp is a blocker whose detail does not deny the constraint")
    func futureStampReportsItself() {
        let state = ReviewState(
            launchCount: 99, valueMomentCount: 99,
            firstUseAt: daysAgo(400), lastPromptedAt: daysAgo(-5)
        )
        let permissive = ReviewConfiguration(
            valueMoment: ValueMomentPolicy(), launchFallback: LaunchFallbackPolicy()
        )
        let diagnosis = ReviewGate.diagnose(
            trigger: .valueMoment, state: state, configuration: permissive, now: now
        )
        let check = diagnosis.checks.first { $0.requirement == .cooldown }

        #expect(check?.isMet == false)
        #expect(check?.detail == "stamped in the future")
        #expect(diagnosis.blockers.map(\.requirement) == [.cooldown])
    }

    @Test("never having prompted clears the cooldown rather than failing it")
    func neverPromptedClearsTheCooldown() {
        let state = ReviewState(launchCount: 99, valueMomentCount: 99, firstUseAt: daysAgo(400))
        let check = diagnose(.valueMoment, state).checks.first { $0.requirement == .cooldown }

        #expect(check?.isMet == true)
        #expect(check?.detail == "never prompted")
    }

    /// The spellings are the whole point of ``ReviewGateDiagnosis/Check/Requirement/label``,
    /// so they are asserted literally. A distinct-and-non-empty check would pass
    /// with two of them swapped, which is exactly the divergence between
    /// hand-written menus that the property exists to end.
    @Test("every requirement has its own settled label")
    func requirementLabels() {
        #expect(ReviewGateDiagnosis.Check.Requirement.valueMoments.label == "Value moments")
        #expect(ReviewGateDiagnosis.Check.Requirement.launches.label == "Launches")
        #expect(ReviewGateDiagnosis.Check.Requirement.sustainedUse.label == "Sustained use")
        #expect(ReviewGateDiagnosis.Check.Requirement.cooldown.label == "Cooldown")
        #expect(ReviewGateDiagnosis.Check.Requirement.setback.label == "Setback")
        #expect(ReviewGateDiagnosis.Check.Requirement.enabled.label == "Trigger")
        // CaseIterable so a new case fails here rather than being silently skipped.
        #expect(ReviewGateDiagnosis.Check.Requirement.allCases.count == 6)
    }
}
#endif
