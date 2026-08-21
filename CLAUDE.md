# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ReviewKit decides **when** to ask a user to rate an app. The `ReviewKit` module is the gate, not the
sheet: no UI, no StoreKit, no analytics taxonomy, no dependencies — pure Foundation. `ReviewKitUI` is
an additive second target and `.library` product holding a star sheet and the StoreKit hand-off. An
app that brings its own sheet links only the first and never sees SwiftUI.

It exists to hold one copy of the two orderings that fail **silently**:

1. **Stamp the cooldown on commit, not on appearance.** `commitToPromptIfEligible` stamps before it
   returns `true`. Stamping on `onAppear` means a crash or a backgrounding in between leaves the gate
   armed with nothing recorded, and the user is asked again next launch.
2. **Act on the rating only after your own UI is fully dismissed.** Only `promptDidDismiss()` ever
   hands it back. Requesting the system prompt mid-dismiss makes the system drop it — the user taps
   five stars, nothing happens, and analytics still records a success. The same slot serves the
   unhappy branch, for the same reason: a feedback composer opened from the star handler presents UI
   while the sheet is still dismissing.

Both are load-bearing. When changing `ReviewPromptFlow`, mutation-test them against the measured
counts below, so a weakened suite shows up as a smaller number and not just as "still red":

| Mutation | Reds |
| --- | --- |
| delete `counters.markPrompted()` from `commit(to:)` | 5 |
| fire `.systemPromptRequested` from `recordOutcome` | 5 |
| widen `abandon()`'s guard to `case .presenting` | 4 |
| drop the setback check from `meetsSharedFloors` | 4 (3 in release — see below) |
| clamp negative thresholds instead of trapping | 4 |
| collapse `resolvePrompt`'s switch to an unconditional request | 9 |
| let a `nil` `launchFallback` prompt instead of failing closed | 2 |

Run `scripts/mutation-check.sh` to re-measure all seven. It applies each mutation from
`scripts/mutations/mutations.json` to a scratch copy outside the repo, runs `swift test`, and fails if
any count reads **lower** than the `expectedReds` beside it there. A number that **drops** means a
test that used to catch the mutation no longer does. When a row legitimately rises, update
`mutations.json` and this table in the same commit — `.github/workflows/mutation.yml` parses this
table and fails if the two disagree.

Two things about the numbers. **"Reds" counts failing *tests*, not recorded *issues*** — the setback
row is 4 tests but 389 issues, because the diagnosis-agreement test walks an exhaustive matrix. And
**every count is a debug number**: the setback row drops to 3 under `swift test -c release`, where
`ReviewGateDiagnosisTests` does not compile.

The mutations are find/replace entries in one JSON file, not patches, and `apply.py` requires every
find-string to match exactly once. Do not re-encode them as diffs — a diff carries hunk line numbers
and incidental context that rot whenever anything near the mutation moves.

## Where things live

- `Sources/ReviewKit/` — `ReviewGate` (the pure decision) · `ReviewPromptFlow` (the doors, the one
  `State` enum, and both `ReviewOutcome` and `ReviewEvent`) · `ReviewCounters` and `ReviewKeys`
  (storage) · `ReviewPolicy.swift` (both policy types *and* `ReviewConfiguration`) · `ReviewState` ·
  `ReviewTrigger`.
- `Sources/ReviewKitUI/` — `ReviewPrompt.swift` (both `reviewPrompt` overloads and `resolvePrompt`) ·
  `ReviewPromptSheet` · `ReviewPromptCopy` · `ReviewDiagnosticsView`.
- **`ReviewGate.diagnose` is in `ReviewGateDiagnosis.swift`, not `ReviewGate.swift`** — an extension
  beside the verdict type it returns, and that whole file is one `#if DEBUG`.
- `Tests/*/TrapTests.swift` are the exit tests. `scripts/mutations/` is the mutation harness.

## Build and test

```sh
swift build
swift test              # 106 tests, 11 suites
swift test -c release   # 85 tests, 9 suites — required, not a nicety
xcodebuild -scheme ReviewKit-Package -destination 'generic/platform=iOS' build
```

**Swift 6 language mode** (`swift-tools-version: 6.0`), and the iOS 18 floor is policy rather than
necessity — nothing here needs it, and it is set where the package is actually built and tested
rather than claiming a long tail nobody tests against. Do not lower it.

**The `.macOS(.v15)` floor is a test-host requirement, not a support claim, and it is not
removable.** iOS is the only supported platform. The README's **Platforms** section is the claim.
Delete the floor and SwiftPM falls back to its own ancient default, where most of SwiftUI does not
exist yet — 670 availability errors, none about anything wrong. Tooling that reads `platforms:` will
show macOS as a result. `platforms:` declares floors, not an allowlist, and the README's platform
badge is **static** for the same reason.

**Not an iOS simulator instead:** Swift Testing's exit tests are unavailable on iOS, so
`TrapTests.swift` does not compile there, and those exit tests are the only coverage the load-bearing
`precondition`s have.

**The tested build is not the shipped build.** Tests compile against macOS, so every `#if os(iOS)`
block — today just `ReviewDiagnosticsView`'s `navigationBarTitleDisplayMode` — is excluded from every
test run. Only the CI iOS build catches a mistake in one.

**The two counts reconcile exactly, and that is the check.** Two whole suites are `#if DEBUG` and
release drops both: `ReviewGateDiagnosis` (12) and `ReviewDiagnosticsView` (7). Two more tests are
individually gated inside `ReviewCountersGateTests`, because they call the debug-only
`diagnose(trigger:configuration:)`. So 19 + 2 = 21, and 106 − 21 = 85. If release ever reports 106, or
the arithmetic stops closing, debug-only surface is leaking into release builds. Skip counts are not
symmetric — debug skips one test, release skips two — so check which configuration a skip count came
from before trusting it.

**Another platform gets added on demand, not in advance.** A platform nothing builds and nothing
tests is a claim, not support. Do not reinstate one without an adopter and a runner that genuinely
builds it, and read the `reviewPrompt` rule below before declaring watchOS or tvOS.

**Exit tests cover the traps** (`Tests/*/TrapTests.swift`). Their bodies run in a fresh child process
and capture nothing: build what they need inside the closure, and use a suite name that is never
written to, so the dying child leaves no plist behind.

## The example app

`Examples/ReviewKitExample.xcodeproj` — a one-screen iOS app linking both products. `open` it. There
is nothing to generate, and the repo must not require a project generator.

- **Its event log is the deliverable, not the screen.** A five-star tap prints `rated(positive)`,
  `dismissed`, `systemPromptRequested` in that order, and the commit door prints "cooldown stamped"
  before anything is presented. That makes both orderings observable, which no test here can do.
- **CI builds it**, so it is the standing check that the README's snippet still compiles. Do not
  delete that CI step and leave the app — an example nothing builds rots into a claim.
- The project points at the package by **relative path**, so it builds the working tree. Its scheme is
  in `xcshareddata` on purpose, or a fresh clone and CI both fail with "scheme not found". Signing
  stays enabled. CI passes `CODE_SIGNING_ALLOWED=NO` instead.
- Its cadence is a **demo** cadence — low floors, but a real 120-day cooldown. The refusal after the
  first prompt is the cooldown working, and `Reset` is the way to go again.
- No `#if os(...)` in the example's own sources.

## Rules that fail silently when broken

Each of these looks like a bug or an oversight and is neither.

**The gate**

- **No UI, no StoreKit call, and no copy in `ReviewKit`.** Apps differ on the sheet and agree on the
  gate. Sharing the sheet and hiding the ordering is exactly backwards.
- **The package never owns UserDefaults key names — the host injects them** (`ReviewKeys`). A
  host is typically a shipped app whose users already carry review state, and both directions of
  getting this wrong are unrecoverable: lose the counters and someone mid-cooldown is re-asked. Lose the stamp and you
  spend one of the platform's ~3 yearly prompts on someone who already declined.
- **`launchFallback` is optional, and `nil` is the trigger switched off.** There is deliberately **no
  default argument**. The alternative is simulating "off" with floors believed unreachable, which
  holds only until something starts counting launches.
- **`LaunchFallbackPolicy` has no value-moment floor, and cannot.** `markPrompted()` zeroes that
  counter and this path serves users who never rebuild it, so a floor there is not a stricter gate
  but a permanent one. Do not merge the two policy types back together.
- **The two counters have opposite semantics.** `launchCount` is lifetime. `valueMomentCount` is since
  the last prompt.
- **A setback is a silence, not a counter.** `recordSetback()` stamps a timestamp and leaves
  `valueMomentCount` alone. It applies to **both** triggers. Set on only one policy it is legal and
  silently half-applied — not guarded, because it is a real cadence.
- **`ReviewKeys.lastSetbackAt` is `String?`, and `nil` is the whole of opting out.** A policy with a
  `setbackCooldownHours` and no key never blocks and reports nowhere, so `ReviewPromptFlow.init`
  `assert`s on the pairing — `assert`, not `precondition`, because it disables a feature rather than
  corrupting state.
- **Negative thresholds trap rather than clamp**, and `ReviewConfiguration` is **not** `Codable`.
  Clamping `-1` to `0` would still mean no cooldown.
- **`cooldownDays` cannot express a sub-day cooldown.** `0` means *no cooldown*, not "short". Anyone
  migrating something sub-day rounds **up**.
- **Timestamps read a `Date` object as well as epoch seconds.** An injected key can hold one, and
  reading it as a `Double` yields `0` — "never prompted" — which re-asks everyone mid-cooldown.
- **`recordLaunch()`, `recordValueMoment()` and `recordSetback()` are `nonisolated`**, while the
  presentation doors are `@MainActor`. Counting is not committing.
- **`ReviewCounters` is plain `Sendable`, not `@unchecked`** — the exemption is `nonisolated(unsafe)`
  on the one `defaults` property, so the compiler still checks the rest.
- **`ReviewPromptFlow` holds no presentation state and is not `@Observable`.** The host owns
  `isPresenting`, which is what keeps the package UI-framework-free.
- **The flow's lifecycle is one `State` enum**, not a set of flags. Do not reintroduce booleans
  alongside it.
- **`promptDidDismiss()` returns `ReviewOutcome?`, not `Bool`, and carries no star score.** `nil`
  deliberately conflates "dismissed unrated" with "nothing in flight".
- **`abandon()` discards a *prompt*, never an *outcome*.** The guard is
  `case .presenting(outcome: .none)`, not `case .presenting` — clearing unconditionally lets a
  teardown throw away a five-star rating.
- **`abandon()` does not refund the cooldown and emits no `ReviewEvent`.** Refunding would permit a
  double-ask. Do not reuse `.dismissed` for it, and do not add an `.abandoned` case: `ReviewEvent` is
  a public non-frozen enum and the README's idiom is an exhaustive `switch`.
- **There is no per-session cap.** The cooldown is the bound.

**`ReviewKitUI`**

- **`reviewPrompt` carries no platform guard, because every supported platform has
  `RequestReviewAction`.** Declaring watchOS or tvOS again means restoring the guard **in the same
  commit**: a modifier that existed there and quietly skipped the request would still emit
  `.systemPromptRequested`. Restore it as an allowlist, never `#if !os(watchOS)`, and it must admit
  macOS as well as iOS or the test host stops compiling.
- **The hand-off lives in a free function, `resolvePrompt(flow:requestReview:onNegative:)`.** A
  SwiftUI `onDismiss` closure cannot be unit-tested, and this is the one thing worth proving. It stays
  **internal**. What no test covers is *placement* — moving the request into the sheet's rating
  handler still passes.
- **`.reviewPrompt` takes your sheet and an `onNegative:`.** `onNegative` is not an instruction, and
  it must never become a second route to the store rating.
- **`abandonsOnDisappear` defaults to `true`**, attached to the **presenting** view. Never wire
  `abandon()` on the sheet's *content* — there it fires mid-dismissal, which reintroduces the second
  silent failure.
- **The sheet reports a raw star count and never buckets it.** `ReviewOutcome.forStarRating` owns the
  threshold, so a gate and its sheet cannot disagree about what "happy" means.
- **`ReviewPromptSheet` emits no analytics and counts no dismissal.** The flow already emits both.
- **The sheet's content is a `ViewThatFits`, not a bare `ScrollView`.** A scroll view alone fills the
  detent and top-aligns its content, which breaks every normal-sized sheet. Do not collapse it to one
  branch.
- **The stars and "not now" are padded to 44 pt** with `.contentShape(.rect)`, and the row spacing was
  cut to 0 to pay for it. **No test covers this** — it is held by review.
- **`ReviewPromptCopy` is `Sendable` and its closure is `@Sendable`**, or a host's `static let` copy
  does not compile under Swift 6.
- **`ReviewDiagnosticsView` is here and not in core**, carries `#if DEBUG` and nothing else, and
  tracks `reviewPrompt`'s gate. Hosts must `#if DEBUG` their own call site — that is the point, since
  a `NavigationLink` to a type absent in release fails at build time in the host.
- **`forceShow` is a `Binding`, never a package-owned key**, and the screen only reports it. The
  `extras` slot is what keeps this from becoming one app's screen. It re-reads its snapshot on
  `UserDefaults.didChangeNotification`, hopped to the **main queue** — not `RunLoop.main`, which does
  not deliver in tracking modes.

## Testing gotchas

- **A flow test with `cooldown: 0` cannot observe the cooldown at all.** `ReviewPromptFlowTests` keeps
  `permissive` (floors only) and `strict` (a real 120-day cooldown) for exactly this.
- **Isolation comes from unique keys, not from a suite per test.** A `UserDefaults(suiteName:)`
  registers a **persistent** domain, so the first write leaves a plist behind, and they accumulate
  into the thousands unnoticed. Teardown does not rescue it:
  `removePersistentDomain(forName:)` empties the file without unlinking it, and unlinking loses too,
  because `cfprefsd` flushes pending domains roughly five seconds *after* the test process exits. So
  `ThrowawaySuites` holds **one** domain per target and hands each test a unique `ReviewKeys`. When
  changing this, count `~/Library/Preferences/ReviewKit*` **fifteen seconds** after a run — checking
  immediately reports a clean zero, which is how a first attempt gets mistakenly declared working.
- Swift Testing (`@Test`, `#expect`, `@Suite`), not XCTest. Exit tests for anything that traps.
