import Foundation
import ReviewKit
import SwiftUI
import Testing
@testable import ReviewKitUI

/// The modifier's one fail-fast, proven to actually fail.
///
/// `highRatingFloor` is the most expensive typo the module offers. A floor of `1`
/// makes *every* rating positive, so a single star hands off to the public store
/// rating — the precise outcome the two-stage ask exists to prevent. Above `5` it
/// silently never hands off at all. Both are why it traps rather than clamps, and
/// this is the test that keeps it trapping.
@Suite("ReviewKitUI traps")
struct UITrapTests {
    @Test("a high-rating floor below 1 traps rather than routing every rating to the store")
    func floorBelowOneTraps() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run { applyModifier(highRatingFloor: 0) }
        }
    }

    @Test("a high-rating floor above 5 traps rather than never handing off")
    func floorAboveFiveTraps() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run { applyModifier(highRatingFloor: 6) }
        }
    }

    @Test("the legal range is accepted", arguments: 1 ... 5)
    @MainActor
    func legalFloorsAreAccepted(floor: Int) {
        applyModifier(highRatingFloor: floor)
    }
}

/// Builds the modifier and throws the result away — the precondition runs before
/// the view is made, which is the whole of what these tests watch for.
///
/// Free rather than a method so the exit-test bodies, which capture nothing, can
/// reach it.
@MainActor
private func applyModifier(highRatingFloor: Int) {
    // Never written to, so nothing is left on disk when the child process dies.
    let defaults = UserDefaults(suiteName: "ReviewKitUITests.trap")!
    let flow = ReviewPromptFlow(counters: ReviewCounters(defaults: defaults, keys: .standard))
    let blank = Text(verbatim: "")
    _ = Text(verbatim: "host").reviewPrompt(
        flow: flow,
        isPresented: .constant(false),
        copy: ReviewPromptCopy(
            title: blank, subtitle: blank, dismiss: blank,
            starAccessibilityLabel: { _ in blank }
        ),
        highRatingFloor: highRatingFloor
    )
}
