import Foundation

/// Which moment is asking to raise the rating prompt.
///
/// Two paths, because the populations differ. Someone who has completed the
/// app's core action has demonstrably got value from it. Someone who merely
/// keeps opening the app has not *proven* it — but excluding them forever caps
/// the ratings ceiling at the power-user segment. So the value-moment path opens
/// early and the launch-only fallback opens late.
///
/// An app with a single path never asks with ``launchFallback``.
///
/// - Note: the raw values are a wire contract the moment you log
///   `trigger.rawValue` as an analytics event name, as the README's example does.
///   Renaming a case renames the event and breaks continuity with everything
///   already recorded.
public enum ReviewTrigger: String, Sendable, Hashable, CaseIterable, Codable {
    /// A deliberate success just landed — the app's core action completed. The
    /// good ask.
    case valueMoment
    /// Sustained launches, whatever the value-moment count. The safety net.
    ///
    /// - Important: this is *not* "the user has no value moments". A user with
    ///   fifty passes here just as readily as one with none, because
    ///   ``LaunchFallbackPolicy`` has no value-moment floor to apply — see that
    ///   type for why it cannot. What makes this the fallback is a much higher
    ///   launch floor.
    case launchFallback
}
