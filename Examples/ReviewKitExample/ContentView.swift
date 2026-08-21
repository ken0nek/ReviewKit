import ReviewKit
import ReviewKitUI
import SwiftUI

/// The integration, and nothing else. Two ways to ask, both of which get the two
/// orderings right for the same reason: the cooldown is stamped by the commit
/// door *before* anything is presented, and `.reviewPrompt` owns what happens
/// after the sheet is fully gone.
struct ContentView: View {
    @ObservedObject var gate: ExampleReviewGate

    /// The host owns the presentation flag. ReviewKit holds no presentation state
    /// and is not `@Observable`, which is what keeps it UI-framework-free.
    @State private var isShowingSuppliedSheet = false
    @State private var isShowingOwnSheet = false

    /// The unhappy branch. `onNegative` is a hand-back, not an instruction —
    /// doing nothing with it is a complete implementation, and it must never
    /// become a second route to the public store rating.
    @State private var isShowingFeedback = false

    /// The host's own flag, read at the host's own commit site. Deliberately not
    /// a package-owned key: the moment ReviewKit names a default, it owns a key
    /// in a shipped app's suite.
    @AppStorage("example.review.forceShow") private var forceShow = false

    private static let copy = ReviewPromptCopy(
        title: Text(verbatim: "Enjoying the example?"),
        subtitle: Text(verbatim: "Tap a star. Nothing is sent anywhere."),
        dismiss: Text(verbatim: "Not now"),
        starAccessibilityLabel: { Text(verbatim: "\($0) of 5") }
    )

    var body: some View {
        List {
            Section {
                Button("Something valuable happened") { valueMomentHappened() }
                Button("Ask with my own sheet") { valueMomentHappened(useOwnSheet: true) }
            } header: {
                Text(verbatim: "The real path")
            } footer: {
                Text(verbatim: "Records a value moment, then asks the gate. Nothing is presented unless the gate says yes — and by the time it does, the cooldown is already stamped.")
            }

            Section {
                Button("Rate this app (Settings row)") { hostInitiatedAsk() }
                Button("Something went wrong") { setbackHappened() }
                Toggle("Force show (host's own flag)", isOn: $forceShow)
            } header: {
                Text(verbatim: "The other doors")
            } footer: {
                Text(verbatim: "A Settings row goes through commitToPrompt, which bypasses the floors but is still stamped. A setback defers both triggers for 48 hours without spending the user's progress.")
            }

            Section {
                LabeledContent("Launches", value: "\(gate.counters.state.launchCount)")
                LabeledContent("Value moments", value: "\(gate.counters.state.valueMomentCount)")
                LabeledContent("Last prompted", value: describe(gate.counters.state.lastPromptedAt))
                LabeledContent("Last setback", value: describe(gate.counters.state.lastSetbackAt))
            } header: {
                Text(verbatim: "Counters")
            } footer: {
                Text(verbatim: "launchCount is lifetime. valueMomentCount is since the last prompt — committing zeroes it, so the next ask needs fresh evidence.")
            }

            Section {
                // The screen is `#if DEBUG` in the package, so the host's call site
                // must be too. That is the point rather than a wart: a
                // NavigationLink to a type that does not exist in release fails at
                // build time here, instead of a debug surface quietly shipping.
                #if DEBUG
                NavigationLink("Review gate diagnosis") {
                    ReviewDiagnosticsView(
                        counters: gate.counters,
                        configuration: ExampleReviewGate.configuration,
                        forceShow: $forceShow
                    ) {
                        LabeledContent("Suite", value: "standard")
                        Button("Record a value moment") {
                            gate.flow.recordValueMoment()
                            gate.note("recordValueMoment() from diagnostics")
                        }
                    }
                }
                #endif
                Button("Reset counters", role: .destructive) { gate.reset() }
            } header: {
                Text(verbatim: "Debugging")
            }

            Section {
                if gate.log.isEmpty {
                    Text(verbatim: "No events yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(gate.log.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(.footnote.monospaced())
                    }
                }
            } header: {
                Text(verbatim: "Events, newest first")
            } footer: {
                Text(verbatim: "Watch the order on a five-star tap: rated, then dismissed, then systemPromptRequested. The request comes last because the system drops one made mid-dismissal — silently, while your analytics still records a success.")
            }
        }
        .navigationTitle(Text(verbatim: "ReviewKit"))
        // The sheet the package ships, via the `copy:` convenience.
        .reviewPrompt(
            flow: gate.flow,
            isPresented: $isShowingSuppliedSheet,
            copy: Self.copy,
            onNegative: { isShowingFeedback = true }
        )
        // Your own sheet, via the primary overload. Same ordering, your layout.
        .reviewPrompt(
            flow: gate.flow,
            isPresented: $isShowingOwnSheet,
            content: {
                OwnRatingSheet { stars in
                    // Record, never act. The hand-off waits for the dismissal.
                    gate.flow.recordOutcome(.forStarRating(stars))
                }
            },
            onNegative: { isShowingFeedback = true }
        )
        .alert("Tell us what went wrong?", isPresented: $isShowingFeedback) {
            Button("Not now", role: .cancel) {}
            Button("Send feedback") { gate.note("host opened its own feedback flow") }
        } message: {
            Text(verbatim: "Your app would open a mail composer or form here. It is safe to present now — the rating sheet is fully gone.")
        }
    }

    // MARK: - The commit doors

    private func valueMomentHappened(useOwnSheet: Bool = false) {
        gate.flow.recordValueMoment()
        gate.note("recordValueMoment()")

        if forceShow {
            // The host bypasses its own gate. The package only reports the flag.
            _ = gate.flow.commitToPrompt(trigger: .valueMoment)
            gate.note("forceShow on → commitToPrompt(valueMoment)")
            present(useOwnSheet: useOwnSheet)
            return
        }

        // `commitToPromptIfEligible` stamps the cooldown *before* it returns true.
        // Stamping on the sheet's onAppear instead would mean a crash or a
        // backgrounding in between leaves the gate armed with nothing recorded —
        // and the user is asked again next launch.
        if gate.flow.commitToPromptIfEligible(trigger: .valueMoment) {
            gate.note("commitToPromptIfEligible(valueMoment) → true, cooldown stamped")
            present(useOwnSheet: useOwnSheet)
        } else {
            gate.note("commitToPromptIfEligible(valueMoment) → false, nothing presented")
        }
    }

    private func hostInitiatedAsk() {
        // An explicit ask from a Settings row skips the floors, but is still
        // accounted for — otherwise it spends a system prompt with nothing
        // recorded, and the next automatic ask arrives too soon.
        if gate.flow.commitToPrompt(trigger: .valueMoment) {
            gate.note("commitToPrompt(valueMoment) → true")
            present(useOwnSheet: false)
        } else {
            gate.note("commitToPrompt → false, a prompt is already in flight")
        }
    }

    private func setbackHappened() {
        gate.flow.recordSetback()
        gate.note("recordSetback() — both triggers deferred 48h, progress kept")
    }

    private func present(useOwnSheet: Bool) {
        if useOwnSheet { isShowingOwnSheet = true } else { isShowingSuppliedSheet = true }
    }

    private func describe(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A deliberately plain stand-in for the sheet an app would bring itself. Its
/// only obligations: call `recordOutcome` as the rating is chosen, and dismiss.
/// It must not call `requestReview()`, present anything on the strength of the
/// rating, or emit its own analytics.
private struct OwnRatingSheet: View {
    let onRate: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text(verbatim: "Your own sheet")
                .font(.title2.weight(.semibold))
            Text(verbatim: "Bespoke layout, your copy, your dwell. ReviewKitUI only owns the ordering around it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        onRate(star)
                        dismiss()
                    } label: {
                        Image(systemName: "star")
                            .imageScale(.large)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(star) of 5"))
                }
            }
            Button("Not now") { dismiss() }
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding()
        .presentationDetents([.height(280)])
    }
}
