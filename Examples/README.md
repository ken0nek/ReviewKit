# ReviewKitExample

A one-screen iOS app that exercises the whole package, so the two orderings
ReviewKit exists to enforce are things you can *watch* rather than read about.

```sh
open Examples/ReviewKitExample.xcodeproj
```

No tooling to install and nothing to generate — the project is committed and
points at the package beside it by relative path (`..`), so it always builds the
working tree rather than a tagged release.

## What to look at

**The event log at the bottom of the screen is the point.** Tap five stars and
watch the order it prints:

```
systemPromptRequested  ← the hand-off actually happened
dismissed
rated(positive)
```

Newest first, so read upward: the rating is *recorded* while the sheet is still
up, and the platform's request is only made once the sheet is fully gone. That
ordering is the whole reason this package exists. Requesting the review
mid-dismissal makes the system drop it — the user taps five stars, nothing
happens, and your analytics still records a success.

The other ordering is visible in the log too. `commitToPromptIfEligible` prints
*"cooldown stamped"* **before** anything is presented, because it stamps before it
returns `true`. Stamping when the sheet appears instead would mean a crash or a
backgrounding in between leaves the gate armed with nothing recorded, and the user
is asked again on the next launch.

Things worth trying:

- **Something valuable happened** — the real path. Takes two taps to open the gate
  under this example's cadence, then refuses for 120 days. That refusal is the
  cooldown working. Use **Reset counters** to go again.
- **Ask with my own sheet** — the same ordering around a sheet the app brings
  itself, which is the overload most apps want. The built-in sheet is the other
  button.
- **Rate this app (Settings row)** — bypasses the floors but is still stamped, so
  an explicit ask does not buy a free automatic one straight after.
- **Rate two stars** — the unhappy branch. The host's follow-up runs from the same
  safe moment as the request would have, and no store rating is asked for.
- **Something went wrong** — a setback. Both triggers go quiet for 48 hours, and
  the value-moment counter is *not* spent: a bad day defers the ask rather than
  making the user earn it again.
- **Review gate diagnosis** — the package's `#if DEBUG` screen, explaining
  requirement by requirement why the gate would or would not open right now.

## The system review prompt itself

`systemPromptRequested` in the log means ReviewKit made the request. Whether iOS
*shows* anything is the platform's call, and it will usually show nothing here:
the sheet is rate-limited to roughly three times a year per user and behaves
differently outside App Store and TestFlight builds. **Nothing appearing is not a
bug**, and it is exactly why the log records the request separately from the
result.

## Reading the code

Three files, in the order they matter:

| File | What it is |
| --- | --- |
| `ExampleReviewGate.swift` | the entire integration — four key names, one cadence, one flow |
| `ContentView.swift` | the commit doors and `.reviewPrompt`, both overloads |
| `ReviewKitExampleApp.swift` | `recordLaunch()`, once per launch |

The cadence in `ExampleReviewGate` is a **demo cadence, not a shipping one** — the
floors are low so the gate opens in a few taps. The 120-day cooldown is real on
purpose, because a cooldown of `0` prompts on every value moment and would hide
the behavior this screen is meant to show.

## Maintaining the project file

The `.xcodeproj` was scaffolded once with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and is maintained in Xcode from here on. There is no `project.yml`, and the repo
depends on no generator. Adding another platform later means a second app target
over the same `ReviewKitExample/` sources — the sources have no `#if os(...)` in
them today, so that target is additive rather than a rewrite. Note that
`reviewPrompt` needs a platform with an in-app review request: watchOS and tvOS
have none, and the package would need its platform guard restored first.
