import SwiftUI

// DocC catalogs a cross-module extension under the module that *defines* the
// extended type, not the module that adds the extension — `View` now lives in
// `SwiftUICore`, so the link below resolves through `SwiftUICore/View/...`.
// Do not "correct" this back to `SwiftUI/View/...`. It will silently stop
// resolving again.
/// A compact star sheet: a question, five stars, and a way out.
///
/// The view is deliberately inert. It never stamps the cooldown, never calls the
/// platform's review request, and never emits an analytics event — those belong
/// to `ReviewPromptFlow`, which is watching from the other side of the
/// ``SwiftUICore/View/reviewPrompt(flow:isPresented:copy:highRatingFloor:detents:abandonsOnDisappear:onNegative:)``
/// modifier. All this does is report which star was tapped and get out of the
/// way.
///
/// It also does not decide what a *good* rating is. The star count goes out raw
/// and `ReviewOutcome.forStarRating(_:highRatingFloor:)` buckets it, so the
/// threshold lives in exactly one place rather than being duplicated into a
/// host's own copy of this view, where the gate and the sheet can end up
/// disagreeing about what a good rating is.
///
/// Present it through the modifier, which owns the ordering that is easy to get
/// wrong. Reach for this directly only if you present it yourself, in which case
/// the two orderings in `ReviewPromptFlow`'s documentation are yours to uphold.
public struct ReviewPromptSheet: View {
    private let copy: ReviewPromptCopy
    private let onRating: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRating = 0

    /// - Parameters:
    ///   - copy: every word on the sheet.
    ///   - onRating: called with the star tapped, `1` through `5`, immediately
    ///     before the sheet dismisses itself.
    public init(copy: ReviewPromptCopy, onRating: @escaping (Int) -> Void) {
        self.copy = copy
        self.onRating = onRating
    }

    public var body: some View {
        // Natural layout while the content fits — the common case — so the sheet
        // centres it. Only at the larger accessibility text sizes does it outgrow
        // any fixed detent, and then it scrolls rather than putting the way out
        // below the fold.
        //
        // A bare `ScrollView` does the accessibility half on its own, and it is
        // the wrong tool: a scroll view fills the detent and top-aligns its
        // content, so every normal-sized sheet bunches under the grabber with
        // dead space beneath it. That fixes the rare case and breaks the common
        // one.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            copy.title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            copy.subtitle
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Localized copy is routinely longer than the English it was
                // written against. Without this the second line is truncated
                // rather than wrapped.
                .fixedSize(horizontal: false, vertical: true)

            stars

            // No signal is emitted here. The dismissal is counted once the sheet
            // has finished leaving, so this tap and a swipe-away are recorded by
            // the same code and cannot drift apart.
            Button {
                dismiss()
            } label: {
                copy.dismiss
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // A subheadline label is about 20 pt tall, and `.plain` makes
                    // the hit rect exactly the label. Same 44 pt floor as the
                    // stars, and for a sharper reason: this is the way out.
                    .frame(minHeight: Self.minimumTapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// The HIG's floor for a control you are expected to hit.
    ///
    /// A large-scale SF Symbol at body size draws about 22 pt, and `.plain` makes
    /// a button's hit rect exactly its label — so an unpadded star is a ~22 pt
    /// target with a gap to the next one, on the one screen whose entire purpose
    /// is being tapped and where a slip costs a star. Padding out to 44 pt does not
    /// change how any of it looks: the glyphs and the spacing between them are
    /// unchanged, the frames around them just stop being invisible to a thumb.
    private static let minimumTapTarget: CGFloat = 44

    private var stars: some View {
        // Most of the visible gap comes from the slack inside the two 44 pt
        // frames, so this is much smaller than the 14 it replaced. It is not
        // zero, and that is the accessibility case: `.imageScale(.large)` tracks
        // Dynamic Type, so at the larger sizes the glyph itself passes 44 pt, the
        // frames stop padding, and stars separated only by that slack would meet
        // edge to edge — on the one screen with a `ViewThatFits` branch written
        // for exactly those sizes.
        HStack(spacing: 4) {
            ForEach(1 ... 5, id: \.self) { rating in
                Button {
                    select(rating)
                } label: {
                    Image(systemName: rating <= selectedRating ? "star.fill" : "star")
                        .imageScale(.large)
                        // The ambient tint, so theming the sheet is one
                        // `.tint()` on the presenting view and the package
                        // never picks a brand color.
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: rating <= selectedRating)
                        .frame(
                            minWidth: Self.minimumTapTarget,
                            minHeight: Self.minimumTapTarget
                        )
                        // Without this the hit rect stays the glyph's bounds even
                        // inside the larger frame — the frame alone is not a
                        // target.
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy.starAccessibilityLabel(rating))
            }
        }
        // Stars that fill with no feedback read as inert on the one screen that
        // asks for something. Silent on platforms with no haptics.
        .sensoryFeedback(.selection, trigger: selectedRating)
    }

    private func select(_ rating: Int) {
        selectedRating = rating
        onRating(rating)
        dismiss()
    }
}

#if DEBUG
#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReviewPromptSheet(
                copy: ReviewPromptCopy(
                    title: Text(verbatim: "Enjoying the app?"),
                    subtitle: Text(verbatim: "Tap a star to let us know how it is going."),
                    dismiss: Text(verbatim: "Not now"),
                    starAccessibilityLabel: { Text(verbatim: "\($0) stars") }
                ),
                onRating: { _ in }
            )
            .presentationDetents([.height(280)])
        }
        .tint(.yellow)
}
#endif
