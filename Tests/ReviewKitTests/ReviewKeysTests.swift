import Testing
import ReviewKit

@Suite("ReviewKeys")
struct ReviewKeysTests {
    @Test("the standard key names are pinned")
    func standardKeyNamesArePinned() {
        #expect(ReviewKeys.standard == ReviewKeys(
            launchCount: "review.launchCount",
            valueMomentCount: "review.valueMomentCount",
            firstUseAt: "review.firstUseAt",
            lastPromptedAt: "review.lastPromptedAt",
            lastSetbackAt: "review.lastSetbackAt"
        ))
    }
}
