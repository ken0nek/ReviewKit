# ``ReviewKit``

Decide **when** to ask a user to rate your app, and get the ordering right so
the ask is not silently thrown away.

## Overview

`ReviewKit` is the gate, not the sheet: no UI, no StoreKit dependency, no
opinion about your design system, and no dependencies of its own. It answers
one question — *may I ask right now?* — by weighing a cadence you configure
against counters you own, and it enforces the two orderings that are easy to
get wrong and expensive to get wrong, because both fail silently. Bring your
own rating UI, or link the optional `ReviewKitUI` product for one that wires
the ordering for you.

## Topics

### Essentials

- <doc:TheTwoOrderings>

### The decision

- ``ReviewGate``
- ``ReviewState``
- ``ReviewTrigger``

### The cadence

- ``ReviewConfiguration``
- ``ValueMomentPolicy``
- ``LaunchFallbackPolicy``

### Storage

- ``ReviewCounters``
- ``ReviewKeys``

### The flow

- ``ReviewPromptFlow``
- ``ReviewOutcome``
- ``ReviewEvent``

### Debugging

- ``ReviewGateDiagnosis``
