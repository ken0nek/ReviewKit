import ReviewKit
import StoreKit
import SwiftUI

/// Settles what a finished dismissal owes: the platform's review request for a
/// good rating, the host's own follow-up for a poor one, nothing otherwise.
///
/// Three lines with three ways to get them wrong, which is exactly why they live
/// here instead of in each app:
///
/// - Calling `requestReview()` **unconditionally** spends one of the platform's
///   roughly three prompts a year on somebody who just gave two stars.
/// - Calling it **before** `promptDidDismiss()` — or, worse, from the sheet's
///   rating handler — makes the system drop the request silently while the
///   `systemPromptRequested` signal is emitted anyway. The user taps five stars,
///   nothing happens, and the funnel records a success.
/// - Presenting the host's *own* follow-up from the rating handler is the same
///   mistake mirrored: a mail composer or a feedback form stacked onto a sheet
///   that is still going away, which on a good day animates badly and on a bad
///   one never appears.
///
/// Extracted as a plain function rather than left inline in the modifier so it
/// can be tested directly: a SwiftUI `onDismiss` closure cannot be, and this is
/// the one behavior in this module worth proving.
///
/// Deliberately **internal**. `promptDidDismiss()` returning `ReviewOutcome?` is
/// the single public seam for what a dismissal owes, and a host doing its own
/// presentation reads it there. Exporting this as well would make two public
/// answers to one question.
///
/// - Parameters:
///   - flow: the flow that tracks this prompt.
///   - requestReview: how to make the platform's request. Injected so a test can
///     watch for it.
///   - onNegative: the host's follow-up for a poor rating. Runs from the same
///     safe moment, and doing nothing here is a complete implementation.
@MainActor
func resolvePrompt(
    flow: ReviewPromptFlow,
    requestReview: () -> Void,
    onNegative: () -> Void
) {
    switch flow.promptDidDismiss() {
    case .positive?: requestReview()
    case .negative?: onNegative()
    case nil: break
    }
}

public extension View {
    /// Presents **your** rating sheet and owns the sequencing around it: the
    /// platform's review request afterwards for a good rating, your follow-up for
    /// a poor one, and the teardown case that otherwise jams the gate.
    ///
    /// This is the modifier to reach for. The sheet is the part every app gets
    /// differently — its layout, its copy, its dwell, whether a poor rating opens
    /// a mail composer — and the ordering is the part every app gets identically
    /// and is easy to get silently wrong. So it takes your view and keeps the
    /// ordering:
    ///
    /// ```swift
    /// SomeScreen()
    ///     .reviewPrompt(flow: flow, isPresented: $isShowingRating) {
    ///         MyOwnRatingSheet { stars in
    ///             flow.recordOutcome(.forStarRating(stars))   // record, never act
    ///         }
    ///     } onNegative: {
    ///         isShowingFeedback = true                        // safe: our UI is gone
    ///     }
    /// ```
    ///
    /// Your sheet's only obligation is to call `flow.recordOutcome(_:)` as the
    /// rating is chosen and to dismiss itself. It must not call `requestReview()`,
    /// present anything on the strength of the rating, or emit its own analytics —
    /// the first two are dropped by the system for being mid-dismissal, and the
    /// flow already emits `.rated` on every tap and `.dismissed` once the sheet is
    /// gone.
    ///
    /// The cooldown is **not** stamped here. It is stamped when you commit, which
    /// is the moment you flip `isPresented`:
    ///
    /// ```swift
    /// flow.recordValueMoment()
    /// if flow.commitToPromptIfEligible(trigger: .valueMoment) {
    ///     isShowingRating = true      // the cooldown is already recorded
    /// }
    /// ```
    ///
    /// Presenting the same sheet from a "Rate this app" row in Settings goes
    /// through `commitToPrompt(trigger:)` instead, so that ask is accounted for
    /// like any other rather than spending a system prompt with nothing recorded.
    ///
    /// - Note: available on every supported platform, because iOS and macOS both
    ///   have an in-app review request. This modifier carried a platform guard
    ///   while watchOS was supported, and would need one again the moment a
    ///   platform without `RequestReviewAction` is declared: an inert version
    ///   there would still emit `systemPromptRequested` for a request that can
    ///   never be made, which is the same lie it exists to prevent. Absent beats
    ///   present-and-inert.
    ///
    /// - Parameters:
    ///   - flow: the flow you committed to this prompt on.
    ///   - isPresented: set it to `true` only after a commit door returns `true`.
    ///   - abandonsOnDisappear: whether to call `abandon()` when the presenting
    ///     view goes away. See below for the one reason to turn it off.
    ///   - content: your rating sheet.
    ///   - onNegative: what a poor rating leads to, run once the sheet is gone.
    ///     Defaults to nothing, which is a complete implementation.
    ///
    /// ## `abandonsOnDisappear`
    ///
    /// SwiftUI does not deliver `onDismiss` when the *presenting* view is itself
    /// torn down — a navigation pop or a tab swap driven by the same state change
    /// — so without `abandon()` the flow stays mid-prompt and declines every
    /// later ask, including a user-initiated one, until the next launch. Nothing
    /// is spent either way: the cooldown was stamped at commit.
    ///
    /// That line is easy to forget, so it is wired here by default,
    /// on the presenting view, which is the only correct place for it. It is safe
    /// in both orderings of the race where a dismissal and a pop arrive together:
    /// `abandon()` discards a prompt but never a recorded outcome, so a teardown
    /// that wins cannot swallow the rating and the `onDismiss` behind it still
    /// hands off.
    ///
    /// Pass `false` only if you find a presentation context where SwiftUI calls
    /// the presenter's `onDisappear` while the sheet is still up and unrated —
    /// there the automatic `abandon()` would clear a live prompt, and the rating
    /// that followed would be dropped by `recordOutcome(_:)`'s guard.
    ///
    /// One accounting consequence, since it is on by default: the safety argument
    /// covers *ratings*, not events. In the race on an **unrated** prompt — a
    /// swipe-away and a pop driven by the same state change, with `onDisappear`
    /// landing first — `abandon()` resolves the prompt and the `promptDidDismiss()`
    /// behind it returns `nil`, so no `ReviewEvent.dismissed` is
    /// emitted. Nothing is spent and no rating is lost, but a host tuning its
    /// cadence off that number will undercount those cases by design:
    /// `abandon()` deliberately emits nothing, because a view going away is the
    /// host's own lifecycle rather than something the user did.
    ///
    /// What is **never** right is `onDisappear` on the *sheet's own content*:
    /// there it fires on every normal dismissal, mid-dismiss, which is precisely
    /// when a hand-off gets dropped on the floor.
    func reviewPrompt<Content: View>(
        flow: ReviewPromptFlow,
        isPresented: Binding<Bool>,
        abandonsOnDisappear: Bool = true,
        @ViewBuilder content: @escaping () -> Content,
        onNegative: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            ReviewPromptModifier(
                flow: flow,
                isPresented: isPresented,
                abandonsOnDisappear: abandonsOnDisappear,
                onNegative: onNegative,
                sheetContent: content
            )
        )
    }

    /// The same sequencing with ``ReviewPromptSheet`` as the content — a compact
    /// star sheet in your words and your tint.
    ///
    /// A convenience over
    /// ``reviewPrompt(flow:isPresented:abandonsOnDisappear:content:onNegative:)``
    /// and nothing more: it supplies the view and the star-to-outcome bucketing,
    /// and the ordering it performs is identical. Reach for the content-taking
    /// version the moment your sheet needs a layout of its own, which is usually
    /// sooner than it looks.
    ///
    /// ```swift
    /// SomeScreen()
    ///     .reviewPrompt(flow: flow, isPresented: $isShowingRating, copy: .myApp)
    ///     .tint(.yellow)
    /// ```
    ///
    /// - Parameters:
    ///   - flow: the flow you committed to this prompt on.
    ///   - isPresented: set it to `true` only after a commit door returns `true`.
    ///   - copy: every word on the sheet.
    ///   - highRatingFloor: the lowest star count treated as happy. The default
    ///     of 4 is the convention the two-stage ask is built on. Lower it and
    ///     you route more people to the public store rating.
    ///   - detents: the sheet's height. Overridable because the right value
    ///     depends on how long your copy is once it is translated. The content
    ///     centres within whatever you pass and scrolls if it cannot fit, so a
    ///     value that is too large reads as padding rather than as a broken
    ///     layout — but it is still worth tuning to your own copy.
    ///   - abandonsOnDisappear: as above.
    ///   - onNegative: what a poor rating leads to, run once the sheet is gone.
    func reviewPrompt(
        flow: ReviewPromptFlow,
        isPresented: Binding<Bool>,
        copy: ReviewPromptCopy,
        highRatingFloor: Int = 4,
        detents: Set<PresentationDetent> = [.height(280)],
        abandonsOnDisappear: Bool = true,
        onNegative: @escaping () -> Void = {}
    ) -> some View {
        // Trap rather than clamp, as the gate's own thresholds do: this is a
        // literal in your source, so a wrong one is a typo. It is also the most
        // expensive typo available here — a floor of 1 makes *every* rating
        // positive, so a single star hands off to the public store rating, which
        // is the precise outcome the two-stage ask exists to prevent. Above 5 it
        // silently never hands off at all.
        precondition(
            (1 ... 5).contains(highRatingFloor),
            "ReviewKit: highRatingFloor must be within 1...5, not \(highRatingFloor)."
        )

        return reviewPrompt(
            flow: flow,
            isPresented: isPresented,
            abandonsOnDisappear: abandonsOnDisappear,
            content: {
                ReviewPromptSheet(copy: copy) { rating in
                    // Recorded, not acted on — the hand-off waits for the
                    // dismissal. `recordOutcome` is last-write-wins, which the
                    // supplied sheet never exercises because it dismisses on the
                    // first tap. That matters for a host that presents
                    // `ReviewPromptSheet` itself behind an explicit confirm,
                    // where a five corrected to a two has to end up unhappy.
                    flow.recordOutcome(.forStarRating(rating, highRatingFloor: highRatingFloor))
                }
                .presentationDetents(detents)
                .presentationDragIndicator(.visible)
            },
            onNegative: onNegative
        )
    }
}

private struct ReviewPromptModifier<SheetContent: View>: ViewModifier {
    let flow: ReviewPromptFlow
    @Binding var isPresented: Bool
    let abandonsOnDisappear: Bool
    let onNegative: () -> Void
    let sheetContent: () -> SheetContent

    @Environment(\.requestReview) private var requestReview

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: $isPresented,
                onDismiss: {
                    // `onDismiss` rather than the sheet's `onDisappear`: this is
                    // the point at which our own UI is provably gone.
                    // `promptDidDismiss` absorbs a repeat call, so a host that
                    // also wires `onDisappear` cannot double-count, double-request
                    // or run its follow-up twice.
                    resolvePrompt(
                        flow: flow,
                        requestReview: { requestReview() },
                        onNegative: onNegative
                    )
                },
                content: sheetContent
            )
            // The *presenting* view's teardown, which is the case `onDismiss`
            // never covers. Inert unless a prompt is genuinely in flight and
            // unrated, so a screen that comes and goes without ever raising the
            // sheet pays nothing for this.
            .onDisappear {
                if abandonsOnDisappear { flow.abandon() }
            }
    }
}
