import Foundation

/// The `UserDefaults` key names ``ReviewCounters`` reads and writes.
///
/// **These are supplied by you, never owned by ReviewKit.** That is deliberate.
/// An app adopting this package almost always has users in the wild already
/// carrying review state under its own key names, and a package that imposed its
/// own would force a migration on every one of them. Get that migration wrong in
/// either direction and it is not recoverable by a later release: lose the
/// counters and a user mid-cooldown is asked again. Lose the cooldown stamp and
/// you burn one of the platform's few yearly prompts on someone who already
/// declined.
///
/// So: pass the keys you already ship. Adoption then moves no persisted state at
/// all, and backing the change out is just as cheap.
///
/// ## Check the stored type, not just the name
///
/// Matching key *names* is only half of it — the stored *value* has to be one
/// ``ReviewCounters`` understands. It writes timestamps as epoch seconds
/// (`Double`) and reads either epoch seconds or a `Date` object, because a
/// hand-rolled gate may well have persisted its last-prompt stamp as a `Date`.
/// Injecting such a key is therefore safe. The counters read it and write
/// epoch seconds from then on.
///
/// Any *other* shape under a timestamp key — a formatted string, a dictionary —
/// reads as long-ago-or-never. Under ``firstUseAt`` that only delays the ask.
/// Under ``lastPromptedAt`` it is the unrecoverable direction described above:
/// the cooldown reads as expired and the next eligible moment re-asks someone who
/// already declined. Inspect the suite before you adopt, and prefer
/// ``ReviewCounters/state`` in a debug build to confirm what the package sees.
///
/// A greenfield app can use ``ReviewKeys/standard`` and never think about it.
public struct ReviewKeys: Sendable, Equatable, Hashable {
    public var launchCount: String
    public var valueMomentCount: String
    public var firstUseAt: String
    public var lastPromptedAt: String
    /// Where ``ReviewCounters/recordSetback()`` stamps, or `nil` to not track
    /// setbacks at all.
    ///
    /// Optional rather than defaulted because the alternative is the package
    /// picking a key name, which is the one thing ``ReviewKeys`` exists to avoid.
    /// `nil` makes ``ReviewCounters/recordSetback()`` a no-op and leaves
    /// ``ReviewState/lastSetbackAt`` permanently `nil`, so a policy with a
    /// setback cooldown and no key here silently never blocks — supply both or
    /// neither.
    public var lastSetbackAt: String?

    public init(
        launchCount: String,
        valueMomentCount: String,
        firstUseAt: String,
        lastPromptedAt: String,
        lastSetbackAt: String? = nil
    ) {
        self.launchCount = launchCount
        self.valueMomentCount = valueMomentCount
        self.firstUseAt = firstUseAt
        self.lastPromptedAt = lastPromptedAt
        self.lastSetbackAt = lastSetbackAt
    }

    /// Sensible names for an app with no existing review state to preserve.
    public static let standard = ReviewKeys(
        launchCount: "review.launchCount",
        valueMomentCount: "review.valueMomentCount",
        firstUseAt: "review.firstUseAt",
        lastPromptedAt: "review.lastPromptedAt",
        lastSetbackAt: "review.lastSetbackAt"
    )
}
