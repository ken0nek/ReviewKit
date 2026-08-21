import Foundation
import ReviewKit
import SwiftUI
import Testing
@testable import ReviewKitUI

// The view is `DEBUG` only, so this suite is too — a release run reports
// fewer tests rather than failing to compile.
#if DEBUG
/// What a developer menu actually *says*, which is the half of this screen worth
/// proving: the rows are `LabeledContent` over verdicts the gate already owns and
/// its own suite already tests, but the wording around them is new, and a footer
/// that names the wrong requirement sends someone to fix a floor that was never in
/// the way.
///
/// The helpers are `static` and internal for this reason alone — a SwiftUI body is
/// not something a test can read. Same shape as `resolvePrompt` in this module: no
/// protocol, no double, just the decision pulled out where it can be called.
/// `@MainActor` because the helpers are `static` members of a `View`, which makes
/// them main-actor isolated. A nonisolated suite calls them with a warning apiece.
/// Same annotation, for the same reason, as `ResolvePromptTests` in this target.
@MainActor
@Suite("ReviewDiagnosticsView")
struct ReviewDiagnosticsViewTests {
    /// Every requirement fails, so the value-moment floor is genuinely *first*
    /// among several rather than the only one.
    private let blocked = ReviewGate.diagnose(trigger: .valueMoment, state: ReviewState())
    /// Nothing fails: a first use from 1970 clears the sustained-use floor by
    /// decades, and never having prompted clears the cooldown rather than failing
    /// it — so this stays green whenever the suite is run.
    private let clear = ReviewGate.diagnose(
        trigger: .valueMoment,
        state: ReviewState(
            launchCount: 99, valueMomentCount: 99, firstUseAt: Date(timeIntervalSince1970: 0)
        )
    )

    @Test("each trigger gets its own section title")
    func triggerTitles() {
        #expect(ReviewDiagnosticsView<EmptyView>.title(for: .valueMoment) == "Value moment")
        #expect(ReviewDiagnosticsView<EmptyView>.title(for: .launchFallback) == "Launch fallback")
    }

    /// The priority that matters: with the bypass on, every red row below is
    /// advisory, and a footer still reporting a blocker would have someone chasing
    /// a floor that is not what the prompt is coming from.
    @Test("force show outranks a blocker in the footer")
    func forceShowOutranksABlocker() {
        #expect(!blocked.blockers.isEmpty)
        #expect(
            ReviewDiagnosticsView<EmptyView>.footerText(diagnosis: blocked, isForceShowOn: true)
                == "Force show is on, so the host bypasses the gate whatever this says."
        )
    }

    /// Names the **first** blocker, not any of them: the gate reads the
    /// requirements in order, so the first is the one to go and fix. "Value
    /// moments" is also the case that proves the label is lowercased as a phrase
    /// rather than as a single word.
    @Test("the footer names the first blocker, lowercased")
    func footerNamesTheFirstBlocker() {
        #expect(blocked.blockers.count > 1)
        #expect(blocked.blockers.first?.requirement == .valueMoments)
        #expect(
            ReviewDiagnosticsView<EmptyView>.footerText(diagnosis: blocked, isForceShowOn: false)
                == "Blocked by value moments."
        )
    }

    /// A trigger switched off, in a state that clears everything it would have
    /// asked for — so the footer has to be about configuration, not about floors.
    private let disabled = ReviewGate.diagnose(
        trigger: .launchFallback,
        state: ReviewState(
            launchCount: 9_999, valueMomentCount: 9_999,
            firstUseAt: Date(timeIntervalSince1970: 0)
        ),
        configuration: ReviewConfiguration(
            valueMoment: ReviewConfiguration.default.valueMoment,
            launchFallback: nil
        )
    )

    /// Going through the blocker branch would render "Blocked by trigger." —
    /// grammatical and useless. It also has to say *not configured* rather than
    /// *not met*: one is a cadence someone chose, the other is a floor to wait out,
    /// and they send you to different places.
    @Test("a disabled trigger gets its own footer, not a blocker sentence")
    func footerReportsADisabledTrigger() {
        #expect(disabled.blockers.map(\.requirement) == [.enabled])
        #expect(
            ReviewDiagnosticsView<EmptyView>.footerText(diagnosis: disabled, isForceShowOn: false)
                == "This trigger is off — no policy is configured for it, so it never fires."
        )
    }

    /// Force-show still outranks it: the bypass is the host calling
    /// `commitToPrompt(trigger:)`, which does not consult a policy at all, so it
    /// works on a trigger whose automatic path is switched off.
    @Test("force show outranks a disabled trigger too")
    func forceShowOutranksADisabledTrigger() {
        #expect(
            ReviewDiagnosticsView<EmptyView>.footerText(diagnosis: disabled, isForceShowOn: true)
                == "Force show is on, so the host bypasses the gate whatever this says."
        )
    }

    @Test("with nothing in the way the footer says so")
    func footerReportsTheAllClear() {
        #expect(clear.wouldPrompt)
        #expect(
            ReviewDiagnosticsView<EmptyView>.footerText(diagnosis: clear, isForceShowOn: false)
                == "Every requirement is met."
        )
    }

    /// An unset stamp is a fact about the app, not a formatting failure — most
    /// apps record no setback ever, and a blank or a dash on that row reads as
    /// missing data on the screen you open when you suspect data is missing.
    @Test("an absent stamp reads as never")
    func absentStampReadsAsNever() {
        #expect(ReviewDiagnosticsView<EmptyView>.formatted(nil) == "never")
    }
}
#endif
