import Foundation
import Testing
@testable import ReviewKit

/// `true` when compiled without optimisation, where `assertionFailure` is live.
let isDebugBuild: Bool = {
    var debug = false
    assert({ debug = true; return true }())
    return debug
}()

/// The package's four deliberate fail-fasts, each proven to actually fail.
///
/// Every one of them is documented as load-bearing — "negative thresholds trap
/// rather than clamp", "a floor of 1 makes every rating positive", "rating
/// something that was never committed to would hand off with no cooldown
/// stamped" — and until now not one was covered. Someone replacing a
/// `precondition` with a clamp would have turned a documented fail-fast into the
/// exact silent fail-open the documentation warns about, and the suite would have
/// stayed green.
///
/// Exit tests are the only way to assert this: the process is *supposed* to die,
/// so the assertion has to be made from outside it. Each body runs in a fresh
/// child process and must capture nothing.
///
/// The `highRatingFloor` trap lives in `ReviewKitUITests`, next to the modifier
/// that raises it.
@Suite("Traps")
struct TrapTests {
    @Test("a negative value-moment threshold traps rather than clamping")
    func negativeValueMomentThresholdTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = ValueMomentPolicy(minimumValueMoments: -1)
        }
    }

    /// The most dangerous one to clamp. `-1` clamped to `0` reads as "no
    /// cooldown", which is not a stricter gate but no gate at all — a prompt on
    /// every value moment, against a platform allowance of roughly three a year.
    @Test("a negative cooldown traps rather than becoming no cooldown")
    func negativeCooldownTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = ValueMomentPolicy(cooldownDays: -1)
        }
    }

    @Test("a negative setback cooldown traps")
    func negativeSetbackCooldownTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = ValueMomentPolicy(setbackCooldownHours: -1)
        }
    }

    @Test("a negative fallback threshold traps too")
    func negativeFallbackThresholdTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = LaunchFallbackPolicy(minimumLaunches: -1)
        }
    }

    /// A policy built entirely from zeroes is *not* an error — it is the "gate on
    /// nothing" cadence a test or a debug build legitimately wants. Only a
    /// negative is a typo.
    @Test("zeroed thresholds are legal, so the trap is on the sign and not on emptiness")
    func zeroedThresholdsAreLegal() {
        _ = ValueMomentPolicy()
        _ = LaunchFallbackPolicy()
    }

    /// A cadence that consults setbacks paired with keys that cannot store one.
    /// Inert in every direction and silent in every direction — including in the
    /// diagnosis, which reports the `.setback` row as *met*, so the screen built
    /// to explain the gate agrees with the misconfiguration.
    @Test(
        "a setback cooldown with no key to stamp trips in a debug build",
        .enabled(if: isDebugBuild)
    )
    func setbackCooldownWithoutAKeyTrips() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                let defaults = UserDefaults(suiteName: "ReviewKitTests.trap")!
                let keys = ReviewKeys(
                    launchCount: "k.launch",
                    valueMomentCount: "k.value",
                    firstUseAt: "k.first",
                    lastPromptedAt: "k.prompt"
                    // lastSetbackAt deliberately absent.
                )
                _ = ReviewPromptFlow(
                    counters: ReviewCounters(defaults: defaults, keys: keys),
                    configuration: ReviewConfiguration(
                        valueMoment: ValueMomentPolicy(setbackCooldownHours: 24),
                        launchFallback: LaunchFallbackPolicy()
                    )
                )
            }
        }
    }

    /// The same cadence with the key supplied is the supported shape and must not
    /// trip — otherwise the assertion above is just "setbacks are unusable".
    @Test("a setback cooldown with a key to stamp is fine")
    @MainActor
    func setbackCooldownWithAKeyIsFine() {
        let defaults = UserDefaults(suiteName: "ReviewKitTests.scratch")!
        _ = ReviewPromptFlow(
            counters: ReviewCounters(defaults: defaults, keys: .standard),
            configuration: ReviewConfiguration(
                valueMoment: ValueMomentPolicy(setbackCooldownHours: 24),
                launchFallback: LaunchFallbackPolicy()
            )
        )
    }

    /// The far end of the first silent failure: a rating recorded against a
    /// prompt nobody committed to would hand off to the platform's request with
    /// no cooldown stamped. In release it is inert and returns — the assertion
    /// covering *that* half is in `ReviewPromptFlowTests`, enabled only there.
    @Test(
        "rating with nothing committed traps in a debug build",
        .enabled(if: isDebugBuild)
    )
    func recordOutcomeWithNothingInFlightTraps() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                // A suite name that is never written to, so the child process
                // leaves no plist behind when it dies.
                let defaults = UserDefaults(suiteName: "ReviewKitTests.trap")!
                let flow = ReviewPromptFlow(
                    counters: ReviewCounters(defaults: defaults, keys: .standard)
                )
                flow.recordOutcome(.positive)
            }
        }
    }
}
