import Foundation
import Testing
@testable import ReviewKit

/// Isolated storage per test: **one** persistent domain for the whole run, with a
/// unique set of ``ReviewKeys`` handed to each caller.
///
/// A third copy of the type also declared in `ReviewPromptFlowTests.swift` and
/// `ReviewCountersGateTests.swift`, `private` to this file the way Swift
/// requires — see either of those for the full account of why a suite per test
/// leaks a plist into `~/Library/Preferences` permanently, and why isolating by
/// unique keys on one shared domain is the fix instead. Same domain name as both,
/// deliberately: the isolation comes from the keys, not from the suite, so every
/// copy has to agree on which suite they share.
private final class ThrowawaySuites {
    /// `nonisolated(unsafe)` for the same reason ``ReviewCounters``'s own
    /// `defaults` property is: `UserDefaults` is documented thread-safe but is
    /// not marked `Sendable`.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "ReviewKitTests.scratch")!

    private var made: [ReviewKeys] = []

    func makeCounters(
        now: @escaping @Sendable () -> Date
    ) -> (ReviewCounters, UserDefaults, ReviewKeys) {
        let id = UUID().uuidString
        let keys = ReviewKeys(
            launchCount: "\(id).launchCount",
            valueMomentCount: "\(id).valueMomentCount",
            firstUseAt: "\(id).firstUseAt",
            lastPromptedAt: "\(id).lastPromptedAt",
            lastSetbackAt: "\(id).lastSetbackAt"
        )
        made.append(keys)
        let defaults = Self.defaults
        return (ReviewCounters(defaults: defaults, keys: keys, now: now), defaults, keys)
    }

    deinit {
        for keys in made {
            let names = [
                keys.launchCount, keys.valueMomentCount,
                keys.firstUseAt, keys.lastPromptedAt,
            ] + [keys.lastSetbackAt].compactMap { $0 }
            for name in names { Self.defaults.removeObject(forKey: name) }
        }
    }
}

/// Passing `value` through here and back is the assertion: a non-`Sendable` `T`
/// would fail to compile at the call site, not at runtime, which is exactly what
/// a dropped `Sendable` conformance needs to be caught by. See
/// ``ConformanceTests/reviewCountersIsSendable()``.
private func acceptSendable<T: Sendable>(_ value: T) {}

/// The conformances the public API promises, pinned.
///
/// A dropped conformance is a source break for every consumer and produces no
/// failure here unless something asks for it, so each of these asks: `Hashable`
/// on ``ReviewEvent``, `Sendable` on ``ReviewCounters`` — compiler-checked
/// per-property now that the type is plain `Sendable` rather than
/// `@unchecked` — and the `Codable` round trip on ``ReviewState`` that
/// `README.md` documents as the supported way to read counters out of a release
/// build, and that nothing else here exercises.
@Suite("public conformances")
struct ConformanceTests {
    private let suites = ThrowawaySuites()

    @Test("every case is Hashable; identical payloads collapse and different ones do not")
    func reviewEventIsHashable() {
        let events: Set<ReviewEvent> = [
            .promptShown(.valueMoment),
            .promptShown(.valueMoment),
            .promptShown(.launchFallback),
            .rated(.positive),
            .rated(.negative),
            .systemPromptRequested,
            .dismissed,
        ]

        // Seven literals above, one an exact duplicate (same trigger) of another
        // — it must collapse. The third `.promptShown` carries a different
        // trigger and must not collapse with either.
        #expect(events.count == 6)
        #expect(events.contains(.promptShown(.valueMoment)))
        #expect(events.contains(.promptShown(.launchFallback)))
        #expect(events.contains(.rated(.positive)))
        #expect(events.contains(.rated(.negative)))
        #expect(events.contains(.systemPromptRequested))
        #expect(events.contains(.dismissed))
    }

    @Test("ReviewCounters is Sendable")
    func reviewCountersIsSendable() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let (counters, _, _) = suites.makeCounters(now: { t0 })

        // A runtime `is Sendable` check would not be meaningful — `Sendable` is
        // a compile-time-only marker protocol. Passing `counters` through a
        // function generic over `Sendable` makes the compiler check it instead;
        // if this file still builds, the conformance held.
        acceptSendable(counters)
        #expect(Bool(true))
    }

    @Test("ReviewState round-trips through Codable with every field populated")
    func reviewStateRoundTripsThroughCodable() throws {
        let original = ReviewState(
            launchCount: 7,
            valueMomentCount: 3,
            firstUseAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPromptedAt: Date(timeIntervalSince1970: 1_750_000_000),
            lastSetbackAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReviewState.self, from: data)

        #expect(decoded == original)
    }
}
