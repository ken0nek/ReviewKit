import Foundation

/// The persisted counters the gate decides over.
///
/// A plain value type with no storage opinion, so ``ReviewGate`` is a pure
/// function of it. ``ReviewCounters`` is the `UserDefaults`-backed store that
/// produces one, but you can build it from anywhere — SwiftData, a keychain, a
/// server — if that suits your app better.
public struct ReviewState: Sendable, Equatable, Codable {
    /// Lifetime launches recorded. Never reset.
    public var launchCount: Int
    /// Value moments recorded **since the last prompt**, not over the app's
    /// lifetime: ``ReviewCounters/markPrompted()`` zeroes this on every commit so
    /// the next ask needs fresh evidence rather than riding the same successes
    /// forever.
    ///
    /// The asymmetry with ``launchCount`` is the whole reason
    /// ``LaunchFallbackPolicy`` has no value-moment floor at all — one against a
    /// counter that resets would permanently retire a path meant for exactly the
    /// users who never rebuild it.
    public var valueMomentCount: Int
    /// When the first use was recorded. `nil` means never.
    public var firstUseAt: Date?
    /// When a prompt was last shown. `nil` means never.
    public var lastPromptedAt: Date?
    /// When a setback was last recorded — see ``ReviewCounters/recordSetback()``.
    /// `nil` means never, which is also what an app that records none reports.
    ///
    /// Unlike ``lastPromptedAt`` this is never written by the flow: it is stamped
    /// only when *you* say something went wrong for this user, because ReviewKit
    /// has no view of what "wrong" means in your app.
    public var lastSetbackAt: Date?

    public init(
        launchCount: Int = 0,
        valueMomentCount: Int = 0,
        firstUseAt: Date? = nil,
        lastPromptedAt: Date? = nil,
        lastSetbackAt: Date? = nil
    ) {
        self.launchCount = launchCount
        self.valueMomentCount = valueMomentCount
        self.firstUseAt = firstUseAt
        self.lastPromptedAt = lastPromptedAt
        self.lastSetbackAt = lastSetbackAt
    }
}
