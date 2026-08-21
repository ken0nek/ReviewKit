import SwiftUI

/// Every word on the rating sheet, supplied by you.
///
/// ## Why the package ships no strings
///
/// This module contains no String Catalog, no default copy, and no colors of
/// its own. That is the whole reason it can be shared at all: a rating sheet is
/// the one screen that is *entirely* voice, and voice does not survive being
/// packaged — an app's wording may live in a String Catalog, in a typed
/// resource, or on a server that resolved it before the sheet ever opened. A
/// package that shipped its own would be adopted by whichever app happened to
/// share its tone, and by nobody else.
///
/// So the sheet owns the *ordering* — the part every app gets identically —
/// and you own the words. Each slot is a `Text`, which accepts all
/// three shapes without adapting anything:
///
/// ```swift
/// // A String Catalog key:
/// ReviewPromptCopy(title: Text("review.title"), ...)
///
/// // A typed resource:
/// ReviewPromptCopy(title: Text(.reviewGateTitle), ...)
///
/// // Copy that arrived from your server, already localized:
/// ReviewPromptCopy(title: Text(verbatim: remote.title), ...)
/// ```
///
/// Styling is yours too: the stars draw in the ambient tint, so `.tint(.yellow)`
/// on the presenting view is the whole of theming.
/// `Sendable` so a host can hoist its copy into a plain `static let` — which is
/// the shape a host reaches for, and which Swift 6 rejects outright for a
/// non-`Sendable` type. `Text` is already `Sendable`. Only the label closure has
/// to say so.
public struct ReviewPromptCopy: Sendable {
    /// The headline — the question itself.
    public var title: Text
    /// One supporting line under the title. Keep it short. The sheet is small.
    public var subtitle: Text
    /// The label on the "no thanks" button.
    ///
    /// Tapping it is not a distinct outcome. It dismisses, and a dismissal with
    /// no rating is counted exactly like a swipe-away — one code path for both,
    /// so the two can never diverge.
    public var dismiss: Text
    /// The VoiceOver label for the *n*th star, called with `1` through `5`.
    ///
    /// A closure rather than a format string because plural rules are the
    /// host's business: "1 star" and "2 stars" is an English-only assumption,
    /// and your catalog already knows how to say it properly.
    public var starAccessibilityLabel: @Sendable (Int) -> Text

    /// - Parameters:
    ///   - title: the headline.
    ///   - subtitle: one supporting line.
    ///   - dismiss: the "no thanks" button's label.
    ///   - starAccessibilityLabel: the VoiceOver label for star `1` through `5`.
    public init(
        title: Text,
        subtitle: Text,
        dismiss: Text,
        starAccessibilityLabel: @escaping @Sendable (Int) -> Text
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dismiss = dismiss
        self.starAccessibilityLabel = starAccessibilityLabel
    }
}
