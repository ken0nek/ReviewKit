# The two orderings

Two orderings ``ReviewPromptFlow`` enforces so a rating ask is never silently
thrown away.

## Overview

The gate itself is ninety-some lines of arithmetic. What makes it worth
depending on is getting two orderings right — both are easy to get wrong and
expensive to get wrong, because both fail **silently**.

## Stamp the cooldown when you commit to showing, not when the UI appears

If you stamp the cooldown on `onAppear` instead of on the commit itself, a
crash or a backgrounding between the decision and the appearance leaves the
gate armed with nothing recorded — and the user is asked again on next
launch.

``ReviewPromptFlow/commitToPromptIfEligible(trigger:)`` stamps before it
returns `true`:

```swift
// A value moment just landed.
flow.recordValueMoment()
if flow.commitToPromptIfEligible(trigger: .valueMoment) {
    isShowingRatingSheet = true          // the cooldown is already stamped
}
```

## Act on the rating only after your own UI is fully gone

Requesting the system prompt mid-dismiss makes the system drop it on the
floor. The user taps five stars, nothing happens, and your analytics still
records a success. This has cost shipped apps months of reviews.

The same holds for whatever *you* present after a poor rating. A feedback
composer opened from the star handler is racing the dismissal of the sheet
that opened it — the mirror image of the same mistake, and it fails the same
quiet way. So ``ReviewPromptFlow/promptDidDismiss()`` returns the
**outcome**, not a `Bool`, and it is the one correctly-sequenced slot for
both branches:

```swift
// Your sheet finished dismissing. Both branches are safe here, and only here.
switch flow.promptDidDismiss() {
case .positive?: requestReview()             // safe: your UI is gone
case .negative?: isShowingFeedback = true    // your follow-up, if you have one
case nil:        break                       // nothing is owed
}
```

## Both, by default

``ReviewPromptFlow`` makes both of these the default:
`commitToPromptIfEligible` stamps before it returns `true`, and nothing about
the rating is handed back to you anywhere but `promptDidDismiss()`.
