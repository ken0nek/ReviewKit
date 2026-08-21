// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewKit",
    // Foundation only — no UI, no StoreKit — so nothing here needs a floor at
    // all. The iOS one is a policy choice: match the oldest OS this is actually
    // built and tested against, rather than court a long tail that is under 2%
    // worldwide and would never be tested against.
    //
    // **iOS is the supported platform. The macOS floor is NOT a support claim,
    // and it is not removable.** `swift build` and `swift test` run on a Mac
    // host, and that is the entire suite. Delete the line and SwiftPM falls back
    // to its own ancient default deployment target, where `Binding`, `Button` and
    // most of SwiftUI do not exist yet — 670 availability errors, none of them
    // about anything that is actually wrong. macOS is where the tests run, not
    // something this package speaks for. The README's Platforms section is the
    // claim.
    //
    // Testing on an iOS simulator instead would need no macOS floor at all, and
    // is deliberately not done: Swift Testing's exit tests do not exist on iOS,
    // so `TrapTests.swift` does not compile there, and those exit tests are the
    // only coverage every load-bearing `precondition` here has.
    //
    // watchOS, tvOS and visionOS are absent, and each fails a different bar.
    // Neither tvOS nor visionOS can be proven here: no test exercises either,
    // and CI cannot build either — GitHub's macOS runners do not reliably ship
    // those platform *components*, so a job must treat a missing one as a skip,
    // and a green run then asserts nothing about them. A declared platform that
    // nothing builds and nothing tests is a claim, not support. visionOS is
    // further out still: `ReviewPromptSheet`'s `.sensoryFeedback` does not exist
    // before visionOS 26, so a visionOS 2 floor is not merely unproven but
    // false. watchOS builds, and is absent for the simpler reason that nothing
    // ships there.
    //
    // Adding one back: `platforms:` declares floors, not an allowlist, so leaving
    // a platform out does not stop anyone building for it and putting one in does
    // not make it work. Support means built on every push and tested. Note that
    // declaring a platform without `RequestReviewAction` — watchOS or tvOS —
    // means restoring `ReviewKitUI`'s platform guard in the same commit. See
    // CLAUDE.md.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ReviewKit", targets: ["ReviewKit"]),
        // Additive, and a separate product rather than UI folded into the core
        // module: an app that brings its own sheet — which is most of them —
        // links the gate without linking SwiftUI.
        .library(name: "ReviewKitUI", targets: ["ReviewKitUI"]),
    ],
    targets: [
        // The privacy manifest declares `UserDefaults` as a required-reason API.
        // It ships here rather than being left to the host because Apple is
        // explicit that "your third-party SDK can't rely on the privacy manifest
        // files for apps that link the third-party SDK" to report its use.
        //
        // `.copy` rather than `.process` so the filename survives verbatim —
        // Apple's tooling looks for exactly `PrivacyInfo.xcprivacy`.
        .target(
            name: "ReviewKit",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Ships its own manifest rather than relying on the core's: a manifest
        // covers the target it ships in, and this one declares nothing at all.
        .target(
            name: "ReviewKitUI",
            dependencies: ["ReviewKit"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "ReviewKitTests", dependencies: ["ReviewKit"]),
        .testTarget(name: "ReviewKitUITests", dependencies: ["ReviewKitUI"]),
    ]
)
