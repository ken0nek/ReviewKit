# ReviewKit

[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fken0nek%2FReviewKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ken0nek/ReviewKit)
[![Platform](https://img.shields.io/badge/platform-iOS-lightgrey.svg)](#platforms)

<!-- The platform badge above is static on purpose. Swift Package Index's platform
     badge reports what SPI's builders compiled, not what this package claims, and
     it compiles in more places than it supports — including macOS, whose floor is
     a test-host requirement rather than a claim. The Platforms section is the
     claim. This badge restates it and nothing else. See CLAUDE.md. -->

Decide **when** to ask a user to rate your app — and get the ordering right, so
the ask is not silently thrown away.

The `ReviewKit` module is the gate, not the sheet: no UI, no StoreKit
dependency, no opinion about your design system. It answers one question — *may
I ask right now?* — and enforces the two orderings that are easy to get wrong
and expensive to get wrong, because both fail **silently**.

Bring your own sheet, or link the optional [`ReviewKitUI`](#reviewkitui)
product, which takes *your* rating view and owns the ordering around it — a
star modal is there too, if you do not have a sheet yet.

```swift
// A value moment just landed.
flow.recordValueMoment()
if flow.commitToPromptIfEligible(trigger: .valueMoment) {
    isShowingRatingSheet = true          // the cooldown is already stamped
}

// The user picked a rating.
flow.recordOutcome(.forStarRating(stars))

// Your sheet finished dismissing. Both branches are safe here, and only here.
switch flow.promptDidDismiss() {
case .positive?: requestReview()             // safe: your UI is gone
case .negative?: isShowingFeedback = true    // your follow-up, if you have one
case nil:        break                       // nothing is owed
}
```

## The two traps

**1. Stamp the cooldown when you commit to showing, not when the UI appears.**
If you stamp on `onAppear`, a crash or a backgrounding between the decision and
the appearance leaves the gate armed with nothing recorded — and the user is
asked again on next launch.

**2. Act on the rating only after your own UI is fully gone.**
Requesting the system prompt mid-dismiss makes the system drop it on the floor.
The user taps five stars, nothing happens, and your analytics still records a
success. This one has cost shipped apps months of reviews.

The same holds for whatever *you* present after a poor rating. A feedback
composer opened from the star handler is racing the dismissal of the sheet that
opened it — the mirror image of the same mistake, and it fails the same quiet
way. So `promptDidDismiss()` returns the **outcome**, not a `Bool`, and it is the
one correctly-sequenced slot for both branches.

`ReviewPromptFlow` makes all of that the default: `commitToPromptIfEligible`
stamps before it returns `true`, and nothing about the rating is handed back to
you anywhere but `promptDidDismiss()`.

**Both orderings are easier to watch than to read.** `open
Examples/ReviewKitExample.xcodeproj` — nothing to install — and tap five stars: the
event log prints `rated(positive)`, then `dismissed`, then `systemPromptRequested`,
in that order. See [`Examples/README.md`](Examples/README.md).

The platform allows roughly three review prompts per user per year, so spending
one on somebody who would have left two stars is the expensive mistake. Your own
lightweight ask goes in front of the system's: a positive rating hands off, a
negative one never reaches the store and stays silent for the full cooldown.
ReviewKit never sees a star count — only `ReviewOutcome`, a bucket rather than a
score.

## Install

```swift
.package(url: "https://github.com/ken0nek/ReviewKit", .upToNextMajor(from: "1.0.0"))
```

`.upToNextMajor` is what SwiftPM's `from:` already means, written out because the
major boundary is the one this package's compatibility promise rests on — the
paragraph below says why.

Or as a local path dependency:

```swift
.package(path: "../ReviewKit")
```

Two products. Depend on `ReviewKit` for the gate alone — it links no SwiftUI —
and add `ReviewKitUI` for the modifier that sequences your own sheet correctly
(the supplied star sheet is optional, and bringing your own is the common case):

```swift
.product(name: "ReviewKit", package: "ReviewKit"),
.product(name: "ReviewKitUI", package: "ReviewKit"),   // optional
```

**The public enums are not frozen**, and this README's own idiom is an exhaustive
`switch` over `ReviewEvent`, so a new case is a source break. A case is added
only in a version allowed to break — the **major** position, never a minor and
never a patch — which is what the pin above buys you. Add a `@unknown default:`
arm if you would rather not handle a new case, at the cost of silence when a new
signal arrives.

## Usage

### 1. Point the counters at your storage

```swift
guard let defaults = UserDefaults(suiteName: "group.com.example.app") else {
    preconditionFailure("Review suite unavailable — check the suite name")
}
let counters = ReviewCounters(defaults: defaults, keys: .standard)
```

An App Group suite lets extensions and widgets record value moments too. Resist
the urge to write `UserDefaults(suiteName:) ?? .standard` — it silently swallows
the failure, falling back to a store your extensions cannot see.

`UserDefaults(suiteName:)` returns `nil` for a name it cannot open *as a suite* —
`nil` itself, the app's own bundle identifier, or the global domain — which in
practice means a typo or a name that drifted from the entitlement. A missing
entitlement is a *different* failure the guard cannot see: the process still gets
a usable suite, just a private one, so the app and each extension write under the
same name without seeing each other's values. That undercount delays the ask
rather than hastening it, and so goes unnoticed.

> **Adopting in a shipped app?** Pass your *existing* key names rather than
> `.standard`, so adoption moves no persisted state and backing it out is just as
> cheap:
>
> ```swift
> keys: ReviewKeys(
>     launchCount: "app.launch.count",
>     valueMomentCount: "review.successCount",
>     firstUseAt: "review.firstUseAt",
>     lastPromptedAt: "review.lastPromptAt"
> )
> ```
>
> **Check what the key *holds*, not just what it is called.** Timestamps are
> written as epoch seconds and read as either epoch seconds or a `Date` object.
> Any *other* shape under a timestamp key reads as long-ago-or-never. Under
> `firstUseAt` that only delays the ask. Under `lastPromptedAt` it re-asks
> everyone who is mid-cooldown, which is the one mistake no later release can
> undo. Print `counters.state` against a real user's suite before you ship the
> switch.

### 2. Choose a cadence

`ReviewConfiguration.default` is a conservative cadence, and a reasonable place
to start:

| | value moment | launch fallback |
|---|---|---|
| value moments | 2 | — † |
| launches | 5 | 20 |
| first use at least | 24 h ago | 24 h ago |
| cooldown | 120 days | 120 days |
| setback cooldown | off | off |

† `LaunchFallbackPolicy` has no value-moment floor, and you cannot give it one.
Committing to a prompt zeroes the value-moment counter, and this path exists for
users who never rebuild it, so a floor here would not be a stricter gate but a
permanent one. Express "sustained launches *and* value moments" on the
value-moment policy instead, with a high `minimumLaunches`.

```swift
let config = ReviewConfiguration(
    valueMoment: ValueMomentPolicy(
        minimumValueMoments: 10,
        minimumFirstUseAgeHours: 24,
        cooldownDays: 120
    ),
    launchFallback: LaunchFallbackPolicy(minimumLaunches: 25, cooldownDays: 120)
)
```

Pass `launchFallback: nil` to switch that trigger off. There is no default
argument — do not simulate "off" with a floor you believe unreachable, because
that holds only until something starts counting launches.

`cooldownDays: 0` means *no cooldown*, not "short": it prompts on every value
moment. Round a sub-day cadence **up**.

#### Staying quiet after something goes wrong

The floors above measure *earned* progress. The one thing they cannot say is "not
right now — this user just had a bad experience". That is a setback:

```swift
let keys = ReviewKeys(
    launchCount: "app.launch.count",
    valueMomentCount: "review.successCount",
    firstUseAt: "review.firstUseAt",
    lastPromptedAt: "review.lastPromptAt",
    lastSetbackAt: "review.lastFailureAt"     // opting in is naming the key
)

let config = ReviewConfiguration(
    valueMoment: ValueMomentPolicy(
        minimumValueMoments: 10, cooldownDays: 180,
        setbackCooldownHours: 24
    ),
    launchFallback: LaunchFallbackPolicy(
        minimumLaunches: 20, cooldownDays: 180,
        setbackCooldownHours: 24    // both triggers, or the fallback ignores setbacks
    )
)

// …then, wherever something goes wrong for the user:
flow.recordSetback()
```

What counts as a setback is yours — a failed request, a sync that errored, a
purchase that did not go through. ReviewKit knows only the most recent
timestamp: a setback is a **silence, not a tally**, so two in a row extend the
window rather than deepening it, and unlike a prompt it does not reset the user's
progress. Setting `setbackCooldownHours` on only one policy is legal and silently
half-applied.

### 3. Wire the flow

```swift
let flow = ReviewPromptFlow(counters: counters, configuration: config) { event in
    switch event {
    case .promptShown(let trigger): analytics.log("review_shown", trigger.rawValue)
    case .rated(let outcome):
        analytics.log("review_rated", outcome == .positive ? "positive" : "negative")
    case .systemPromptRequested:    analytics.log("review_system_requested")
    case .dismissed:                analytics.log("review_dismissed")
    }
}
```

ReviewKit owns no analytics taxonomy — map `ReviewEvent` onto your own names. The
`ReviewTrigger` raw values become a wire contract the moment you log them as
event names, so renaming a case renames the event.

### 4. Present your own sheet, and act on the dismissal

> **Linking `ReviewKitUI`?** Its `reviewPrompt` modifier owns this whole block —
> the hand-off and the `abandon()` wiring below — so you likely do not need to
> hand-write either. Jump to [ReviewKitUI](#reviewkitui).

You own the sheet. ReviewKit owns *when* it can appear and *when* what happened
in it can be acted on.

```swift
.sheet(isPresented: $isShowingRatingSheet, onDismiss: {
    switch flow.promptDidDismiss() {
    case .positive?:
        requestReview()                  // StoreKit; your call to make
    case .negative?:
        isShowingFeedbackForm = true     // or a mail composer, or a support URL
    case nil:
        break                            // dismissed unrated — nothing is owed
    }
}) {
    MyRatingSheet { stars in
        // Recorded, not acted on. Last-write-wins, so a five corrected to a two
        // still ends up unhappy.
        flow.recordOutcome(.forStarRating(stars))
        isShowingRatingSheet = false
    }
}
```

**Do not act on the rating from the star handler.** Both branches fail there,
equally silently: `requestReview()` gets dropped by the system, and your own
follow-up races the dismissal of the sheet that triggered it. The negative branch
is a hand-back, not an instruction — doing nothing with it is a complete
implementation, and what it must never be is a route to the public store rating.

#### If the presenting view can disappear

SwiftUI does **not** deliver `onDismiss` when the *presenting* view is torn down —
a navigation pop or a tab swap driven by the same state change. Without a signal
the flow stays mid-prompt and refuses every later ask until the process restarts,
so call `abandon()` from the **presenting** view's `onDisappear`:

```swift
SomeScreen()
    .sheet(isPresented: $isShowingRatingSheet, onDismiss: { … }) { … }
    .onDisappear { flow.abandon() }
```

Not on the sheet's own content: there it fires on every normal dismissal,
mid-dismiss, which is exactly when the system drops the request. `abandon()`
discards a pending prompt but never a recorded outcome, and it does not refund
the cooldown — nothing is spent either way, because the cooldown was stamped at
commit.

### 5. A "Rate this app" row in Settings

The gate decides when *you* can interrupt. It has no business overruling someone
who went looking for the option — but that ask still has to be accounted for:

```swift
if flow.commitToPrompt(trigger: .valueMoment) {
    isShowingRatingSheet = true          // stamped exactly like an automatic ask
}
```

Everything downstream is identical. Route manual asks here rather than calling
`recordOutcome(_:)` on a flow that never committed — that does nothing at all,
and trips an assertion in debug builds to tell you so.

### Just the decision

If you already have your own storage and presentation, use the pure function:

```swift
let eligible = ReviewGate.shouldPrompt(
    trigger: .valueMoment,
    state: ReviewState(launchCount: 12, valueMomentCount: 3, firstUseAt: someDate),
    configuration: .default,
    now: Date()
)
```

No storage, no view state, no singleton, so the same inputs always give the same
answer.

## Debugging the gate

A developer menu wants to know *why* the ask is not showing. `ReviewGate.diagnose`
returns a verdict per requirement, from the same comparisons the gate itself uses:

```swift
#if DEBUG
let diagnosis = ReviewGate.diagnose(
    trigger: .valueMoment, state: counters.state, configuration: config
)
#endif
```

`ReviewDiagnosticsView` is that loop already drawn — both triggers with a verdict
per row, an `extras` slot for host-shaped rows, and a `forceShow` binding to a
flag **your app owns**. The package names no key for it, and the screen only
reports the flag. Your own commit site is what acts on it.

```swift
#if DEBUG
ReviewDiagnosticsView(
    counters: counters,
    configuration: config,
    forceShow: $forceShowReviewPrompt
)
#endif
```

The type does not exist in release builds, so guard your call site with
`#if DEBUG` — a `NavigationLink` to a missing type fails at build time, which is
the point.

In a release build where you cannot run debug code, `ReviewState` is `Codable`:

```swift
let json = try JSONEncoder().encode(counters.state)
```

That is the same state the debug screen renders, minus the verdicts.

## ReviewKitUI

A second, optional product. What it shares is **the sequencing, not the sheet**:
the modifier takes *your* rating view and owns the ordering around it.

```swift
import ReviewKit
import ReviewKitUI

// A value moment just landed.
flow.recordValueMoment()
if flow.commitToPromptIfEligible(trigger: .valueMoment) {
    isShowingRating = true          // the cooldown is already stamped
}

// …and somewhere up the view tree:
SomeScreen()
    .reviewPrompt(flow: flow, isPresented: $isShowingRating) {
        MyOwnRatingSheet { stars in
            flow.recordOutcome(.forStarRating(stars))   // record, never act
        }
    } onNegative: {
        isShowingFeedback = true                        // safe: our sheet is gone
    }
```

(`ReviewPromptFlow` and `ReviewCounters` live in `ReviewKit`. `ReviewKitUI`
depends on it but does not re-export it, so both imports are needed.)

It owns three things, each easy to hand-write and easy to get silently wrong:

1. **The hand-off**, on the far side of the dismissal, so a good rating reaches
   the platform's request and a poor one never can.
2. **The unhappy branch**, from the same safe moment. `onNegative` is a hand-back
   and not an instruction: ignoring it is a complete implementation.
3. **`abandon()`**, wired to the *presenting* view's `onDisappear`. Pass
   `abandonsOnDisappear: false` to opt out.

Your sheet's only obligation is to call `flow.recordOutcome(_:)` as the rating is
chosen and to dismiss itself. It must not call `requestReview()`, present
anything on the strength of the rating, or emit its own analytics — the first two
get dropped for being mid-dismissal, and the flow already emits `.rated` on every
tap and `.dismissed` once the sheet is gone.

### If you do not have a sheet yet

There is a `copy:` overload that supplies `ReviewPromptSheet` — a compact star
modal — with identical sequencing:

```swift
SomeScreen()
    .reviewPrompt(flow: flow, isPresented: $isShowingRating, copy: copy)
    .tint(.yellow)
```

`ReviewPromptCopy` takes four `Text` values. The module ships no strings and no
colors of its own: a rating sheet is entirely voice, and a shared one that
arrives with its own wording fits whichever app it was written for and no other.
Each slot takes a catalog key, a typed resource, or a string your server already
localized.

## Requirements

Swift 6 · iOS 18+ · Foundation only, no dependencies. `ReviewKitUI` adds SwiftUI
and StoreKit, still with no external dependencies.

Nothing in the `ReviewKit` module needs that version — the floor is set where the
package is actually built and tested rather than claiming a long tail that would
never be. Lowering a floor is not a breaking change, so if you need iOS 17,
open an issue rather than a fork.

## Platforms

**iOS 18** is the supported platform and the only one this package claims.
Supported here means built on every push and tested.

**macOS, watchOS, tvOS and visionOS are not supported.** Some of them compile.
That is not a claim of support, and it is not the bar. `Package.swift` does carry a
**macOS floor, and it is not a support claim** — `swift build` and `swift test`
run on a Mac host, and without that floor SwiftPM falls back to its own ancient
default deployment target and nothing compiles. Tooling that reads `platforms:`
will show macOS as a result; `platforms:` declares floors, not an allowlist, and
this section is the claim.

Two of the four are further away than merely untested. `reviewPrompt` hands off to
`RequestReviewAction`, which **watchOS and tvOS do not have** — so there the
modifier cannot exist, and one that existed and quietly skipped the request would
report `systemPromptRequested` for a request that can never be made, which is the
exact failure this package was written to prevent.

**Other platforms get support when there is demand.** If you want one, open an
issue — that is the signal this package acts on.

## Privacy

Each target ships its own `PrivacyInfo.xcprivacy`, because a manifest covers the
target it ships in. `ReviewKitUI`'s declares nothing at all — it reads no covered
API, and the star the user taps is bucketed before it reaches anything that can
record it.

`ReviewKit`'s declares **no tracking, no collected data, and one required-reason
API**: `UserDefaults`, under both `CA92.1` (the app's own defaults) and `1C8F.1`
(an App Group suite).

You still need your own manifest for your own use of covered API — Apple is
explicit that an SDK cannot rely on its host's manifest, and the reverse holds
too. Nothing leaves the device: the package makes no network call and has no
analytics of its own.

## Showcase

These are the apps I ship. If one of them is useful to you, a five-star rating
is what funds the next one.

<table>
  <tr>
    <th>App Icon</th>
    <th>App Name &amp; Description</th>
    <th>Supported Platforms</th>
  </tr>
  <tr>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6766441698?pt=10674868&ct=github&mt=8">
        <img src="https://raw.githubusercontent.com/ken0nek/ReviewKit/main/Images/Apps/Whyzard.webp" width="64" />
      </a>
    </td>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6766441698?pt=10674868&ct=github&mt=8">
        <strong>Whyzard – Learn Together</strong>
      </a>
      <br />
      Kids' why-questions answered twice over: a calm version to read together, and the real explanation underneath for the grown-up reading it.
    </td>
    <td>iPhone, iPad</td>
  </tr>
  <tr>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6745852921?pt=10674868&ct=github&mt=8">
        <img src="https://raw.githubusercontent.com/ken0nek/ReviewKit/main/Images/Apps/BrewSmart.webp" width="64" />
      </a>
    </td>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6745852921?pt=10674868&ct=github&mt=8">
        <strong>BrewSmart: Coffee Ratio</strong>
      </a>
      <br />
      Pour-over ratio calculator, guided brew timer, and a log that dials in the next cup. No ads, no subscriptions.
    </td>
    <td>iPhone, iPad, Watch</td>
  </tr>
  <tr>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6758604043?pt=10674868&ct=github&mt=8">
        <img src="https://raw.githubusercontent.com/ken0nek/ReviewKit/main/Images/Apps/LinkClean.webp" width="64" />
      </a>
    </td>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6758604043?pt=10674868&ct=github&mt=8">
        <strong>LinkClean – URL Cleaner</strong>
      </a>
      <br />
      Strips tracking parameters out of any link before you share it, and reads QR codes on the way in.
    </td>
    <td>iPhone, iPad</td>
  </tr>
  <tr>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6784029039?pt=10674868&ct=github&mt=8">
        <img src="https://raw.githubusercontent.com/ken0nek/ReviewKit/main/Images/Apps/Rondo.webp" width="64" />
      </a>
    </td>
    <td>
      <a href="https://apps.apple.com/app/apple-store/id6784029039?pt=10674868&ct=github&mt=8">
        <strong>Rondo – Prime Factorization</strong>
      </a>
      <br />
      Every counting number as a quiet, hypnotic dance of its own prime factors.
    </td>
    <td>iPhone, iPad, Watch</td>
  </tr>
</table>

## License

MIT — see [LICENSE](LICENSE).
