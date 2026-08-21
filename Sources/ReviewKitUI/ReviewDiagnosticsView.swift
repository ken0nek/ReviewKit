#if DEBUG
import Foundation
import ReviewKit
import SwiftUI

// Cross-module symbol links (a `ReviewKit` symbol referenced from a
// `ReviewKitUI` doc comment) do not resolve for this target's dependency
// shape. Fully qualified, unqualified, and the combined-documentation flag all
// fail the same way. The single backticks below are the honest spelling of
// that, not an oversight to "upgrade" back.
/// A developer menu's page for the review gate: what each trigger would decide
/// right now, requirement by requirement, and the counters behind it.
///
/// ## Why this ships here
///
/// `ReviewGateDiagnosis` renders nothing on purpose — the verdicts are
/// the part every app needs identically, the style is the part each menu has its
/// own opinion about. But a menu still has to turn a verdict into a row, and the
/// obvious way is to re-derive met and unmet in the view, where that copy can
/// drift from the gate and the screen reports a state the app does not act on.
/// That is worse than showing nothing, because this is the screen you consult
/// when the ask misbehaves. The verdicts are shared already. This is the screen
/// that reads them, once rather than once per menu.
///
/// It is `DEBUG` only, like the diagnosis it draws, so it is not in a TestFlight or
/// App Store build at all. Guard your own call site the same way — a
/// `NavigationLink` to a type that does not exist in release does not compile.
///
/// ## What it deliberately does not own
///
/// Nothing durable and no policy. The counters are the ones you already inject,
/// the configuration is your cadence, and `forceShow` is a `Binding` to a flag
/// your app owns and reads at its own commit site — the package picks no key for
/// it, for the same reason `ReviewKeys` exists. This screen only
/// *reports* the flag. It cannot bypass the gate itself.
///
/// The `extras` slot is for the rows only your app can write: which suite the
/// counters read, whether the App Group resolved, a button that fires a value
/// moment. Keeping those yours is what stops this view from slowly growing a
/// host-shaped configuration surface and becoming one app's debug screen again.
///
/// ```swift
/// #if DEBUG
/// NavigationLink {
///     ReviewDiagnosticsView(
///         counters: counters,
///         configuration: .default,
///         forceShow: $forceShowReviewPrompt   // your own @AppStorage
///     )
/// } label: {
///     Text(verbatim: "Review gate")
/// }
/// #endif
/// ```
///
/// - Note: `#if DEBUG` only, like the `ReviewGateDiagnosis` it draws — a screen
///   that outlived the verdict type would be a public debug surface in a shipped
///   app. It carries no platform gate, because every supported platform has an
///   in-app review request for it to explain.
public struct ReviewDiagnosticsView<Extras: View>: View {
    private let counters: ReviewCounters?
    private let configuration: ReviewConfiguration
    @Binding private var forceShow: Bool
    private let extras: () -> Extras

    /// The one snapshot every section reads, so a diagnosis and the counters
    /// beneath it can never come from two different moments.
    ///
    /// Seeded in the initializer rather than left `nil`: with `nil` as the initial
    /// value the first body pass renders the empty state over perfectly good
    /// counters, which is the one thing this screen must not do — it is consulted
    /// precisely when someone already suspects the counters are wrong.
    @State private var state: ReviewState?
    @State private var isConfirmingReset = false

    /// - Parameters:
    ///   - counters: the counters your app records into, or `nil` if they could
    ///     not be built — an App Group that did not resolve, say. `nil` renders as
    ///     an empty state rather than as zeroes, because zeroes are exactly what a
    ///     fresh install looks like.
    ///   - configuration: the same cadence you pass to the gate.
    ///   - forceShow: your own bypass flag, reported here and honoured by you.
    ///   - extras: rows only your app can write, appended below the rest.
    public init(
        counters: ReviewCounters?,
        configuration: ReviewConfiguration,
        forceShow: Binding<Bool>,
        @ViewBuilder extras: @escaping () -> Extras
    ) {
        self.counters = counters
        self.configuration = configuration
        _forceShow = forceShow
        self.extras = extras
        _state = State(initialValue: counters?.state)
    }

    public var body: some View {
        Form {
            // The branch is on `counters`, not on the snapshot. `nil` counters is
            // the host saying there is nothing to inspect. A `nil` snapshot would
            // only ever be a transient of ours, and reporting the two the same way
            // would blame the host for our own first render.
            if let counters {
                // Almost always the seeded snapshot: the initializer fills it, so
                // the coalesce is reached only when SwiftUI carries `@State` across
                // a re-creation at the same identity that began with `nil`
                // counters. Written as one unwrap at the top rather than four
                // optional chains through the body, `ReviewGate.diagnose` taking a
                // non-optional.
                let snapshot = state ?? counters.state

                // `clock: counters.clock`, not the default `now: Date()` inside
                // `diagnosisSection` — `snapshot` was read from these same
                // counters, and judging it against wall time instead of the clock
                // that stamped it is exactly the drift this screen exists to
                // catch. Do not "simplify" this back to the default.
                diagnosisSection(
                    for: .valueMoment, snapshot: snapshot, clock: counters.clock
                )
                diagnosisSection(
                    for: .launchFallback, snapshot: snapshot, clock: counters.clock
                )
                countersSection(snapshot)
                stampsSection(snapshot)
                controlsSection(counters)
            } else {
                Section {
                    // Why the host passed `nil` is the host's to say — an
                    // unresolved App Group reads nothing like a suite it chose not
                    // to build — so the package states the fact and leaves the
                    // explanation to `extras`.
                    Text(verbatim: "No counters — nothing to inspect.")
                        .foregroundStyle(.red)
                }
            }

            extras()
        }
        // Re-read on every appearance, because the counters move while this screen
        // is off-screen and a stale row here sends someone hunting the wrong
        // requirement. Deliberately not `.id(token)` bumped from a subtree's own
        // `onAppear`: that re-creates the subtree, which fires `onAppear` again,
        // forever.
        .onAppear { state = counters?.state }
        // And re-read on every write, because `onAppear` cannot see a mutation
        // made *from* this screen. `extras` is documented as the place a host
        // puts "a button that fires a value moment", and it is a plain
        // `@ViewBuilder` with no reach into this `@State` — so without this the
        // row increments the counter and the screen keeps reporting the old one,
        // which is precisely the drift this screen exists to catch. The reset
        // control's explicit read-back below is the same fix for the one mutation
        // the package owns. This covers the ones it does not.
        //
        // Hopped to the main queue because the recorders are `nonisolated`: a
        // background App Intent bumping a counter posts this notification on its
        // own thread, and `@State` must not be written there. `DispatchQueue`
        // rather than `RunLoop`, which does not deliver in tracking modes — a
        // refresh that waits for a scroll to end is the symptom again, smaller.
        //
        // Both halves measured rather than assumed: the notification does fire for
        // a `UserDefaults(suiteName:)` instance and not only for `.standard` — so
        // a host on an App Group is covered — and a write dispatched to a global
        // queue posts it on that queue's thread, which is the hop's whole reason.
        //
        // Not covered by a test: this suite reads the wording, not the lifecycle
        // (see `title(for:)` and `footerText`). Held by review and by running the
        // example app, like the sheet's tap targets.
        .onReceive(
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in state = counters?.state }
        .navigationTitle(Text(verbatim: "Review gate"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func diagnosisSection(
        for trigger: ReviewTrigger, snapshot: ReviewState, clock: @Sendable () -> Date
    ) -> some View {
        let diagnosis = ReviewGate.diagnose(
            trigger: trigger, state: snapshot, configuration: configuration, now: clock()
        )

        return Section {
            LabeledContent {
                // `wouldPrompt`, never `checks.allSatisfy(\.isMet)`. The whole
                // point of that property is that it *is* the gate's own answer, so
                // re-deriving it here would reintroduce the drift the diagnosis
                // exists to remove.
                Text(verbatim: diagnosis.wouldPrompt ? "yes" : "no")
                    .foregroundStyle(diagnosis.wouldPrompt ? Color.green : .red)
            } label: {
                Text(verbatim: "Would show")
            }

            // A requirement appears at most once per diagnosis, so it is its own
            // identity here.
            ForEach(diagnosis.checks, id: \.requirement) { check in
                LabeledContent {
                    Text(verbatim: check.detail)
                        .monospacedDigit()
                        .foregroundStyle(check.isMet ? Color.green : .red)
                } label: {
                    Text(verbatim: check.requirement.label)
                }
            }
        } header: {
            Text(verbatim: Self.title(for: trigger))
        } footer: {
            Text(verbatim: Self.footerText(diagnosis: diagnosis, isForceShowOn: forceShow))
        }
    }

    private func countersSection(_ snapshot: ReviewState) -> some View {
        Section {
            LabeledContent {
                Text(verbatim: "\(snapshot.launchCount)").monospacedDigit()
            } label: {
                Text(verbatim: "Launches")
            }

            LabeledContent {
                Text(verbatim: "\(snapshot.valueMomentCount)").monospacedDigit()
            } label: {
                Text(verbatim: "Value moments")
            }
        } header: {
            Text(verbatim: "Counters")
        } footer: {
            // The two read as the same kind of number and are not, which is the
            // misreading this screen would otherwise cause: a value-moment count
            // that fell to zero is a prompt that was committed to, not data lost.
            Text(verbatim: "Launches are lifetime. Value moments are since the last prompt — committing to one zeroes them.")
        }
    }

    private func stampsSection(_ snapshot: ReviewState) -> some View {
        Section {
            stampRow("First use", snapshot.firstUseAt)
            stampRow("Last prompt", snapshot.lastPromptedAt)
            stampRow("Last setback", snapshot.lastSetbackAt)
        } header: {
            Text(verbatim: "Stamps")
        }
    }

    private func stampRow(_ label: String, _ date: Date?) -> some View {
        LabeledContent {
            Text(verbatim: Self.formatted(date))
                .foregroundStyle(.secondary)
        } label: {
            Text(verbatim: label)
        }
    }

    private func controlsSection(_ counters: ReviewCounters) -> some View {
        Section {
            Toggle(isOn: $forceShow) {
                Text(verbatim: "Force show")
            }

            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text(verbatim: "Reset counters")
            }
        } header: {
            Text(verbatim: "Controls")
        }
        // Confirmed rather than immediate: a reset is not undoable, and on a
        // device carrying real state it is the difference between reading the gate
        // and destroying the thing you came to read.
        .confirmationDialog(
            Text(verbatim: "Reset counters?"),
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                counters.reset()
                // Read back rather than zero a local copy: `reset()` clears only
                // the keys `ReviewKeys` names, so reading is the only way this
                // screen reports what the gate will actually see next.
                state = counters.state
            } label: {
                Text(verbatim: "Reset")
            }

            Button(role: .cancel) {} label: {
                Text(verbatim: "Cancel")
            }
        } message: {
            Text(verbatim: "Clears the keys this host injected, and nothing else. The gate then reads as a fresh install.")
        }
    }

    // MARK: - The wording, extracted so it can be tested

    // Same reason `resolvePrompt` is a free function: a SwiftUI body is not
    // something a test can read, and these strings are the part worth pinning —
    // a footer naming the wrong blocker sends someone to fix the wrong floor.

    static func title(for trigger: ReviewTrigger) -> String {
        switch trigger {
        case .valueMoment: "Value moment"
        case .launchFallback: "Launch fallback"
        }
    }

    /// In priority order: force-show first, because a host bypassing the gate
    /// makes every row above it advisory. Then a trigger switched off entirely.
    /// Then the first blocker, which is the one to go and fix. Then the
    /// all-clear.
    ///
    /// The force-show wording says *the host* bypasses the gate because that is
    /// literally what happens — the bypass is the host calling
    /// `commitToPrompt(trigger:)` on that path, and this screen only reports the
    /// flag.
    ///
    /// A disabled trigger gets its own sentence rather than going through the
    /// blocker branch, which would render "Blocked by trigger." — grammatical, and
    /// useless. It says *not configured* rather than *not met*, because the two
    /// send you to different places: one is a cadence you chose, the other is a
    /// floor to wait out.
    static func footerText(diagnosis: ReviewGateDiagnosis, isForceShowOn: Bool) -> String {
        if isForceShowOn {
            "Force show is on, so the host bypasses the gate whatever this says."
        } else if diagnosis.blockers.contains(where: { $0.requirement == .enabled }) {
            "This trigger is off — no policy is configured for it, so it never fires."
        } else if let blocker = diagnosis.blockers.first {
            "Blocked by \(blocker.requirement.label.lowercased())."
        } else {
            "Every requirement is met."
        }
    }

    /// `nil` is "never" rather than a dash. All three stamps can legitimately be
    /// unset, and a dash reads as missing data on the one screen you open when you
    /// already suspect data is missing.
    static func formatted(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

public extension ReviewDiagnosticsView where Extras == EmptyView {
    /// The same screen with no rows of your own.
    ///
    /// A second initializer rather than a default argument because a default
    /// cannot bind the enclosing type's generic parameter — `extras: () -> Extras
    /// = { EmptyView() }` does not compile.
    init(
        counters: ReviewCounters?,
        configuration: ReviewConfiguration,
        forceShow: Binding<Bool>
    ) {
        self.init(
            counters: counters,
            configuration: configuration,
            forceShow: forceShow,
            extras: { EmptyView() }
        )
    }
}

#Preview {
    NavigationStack {
        ReviewDiagnosticsView(
            // Named unlike either test scratch domain, so a plist left by a
            // rendered preview cannot be mistaken for a test that built its own
            // `UserDefaults` suite. `.map` rather than `!`: the initializer takes
            // an optional anyway, and a suite that will not open is the empty
            // state this preview exists to show.
            counters: UserDefaults(suiteName: "ReviewKitUI.previewScratch").map {
                ReviewCounters(defaults: $0, keys: .standard)
            },
            configuration: .default,
            forceShow: .constant(false)
        )
    }
}
#endif
