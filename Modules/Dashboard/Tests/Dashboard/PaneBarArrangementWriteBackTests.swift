import Testing
import Foundation
@testable import Dashboard

/// The write half of the tolerant decode whose read half `PaneBarArrangementTests` covers. A bar
/// from a newer build survives a downgrade only if its unknown tokens survive the writes too:
/// `PaneBarCustomizeSheet.commit` writes `next.encoded` back to the same key, so without
/// `unknownTokens` a downgrade, an edit and a re-upgrade would lose the newer build's control.
@Suite struct PaneBarArrangementWriteBackTests {

    @Test func aNewerBuildsTokenSurvivesTheDecodeEncodeRoundTrip() {
        let stored = "scan,search,futureControl"
        let arrangement = PaneBarArrangement(encoded: stored)

        // The read half: the unknown token doesn't reject the bar and never reaches its items.
        #expect(arrangement.items == [.scan, .search])

        // The write half: what the customize sheet persists after any edit.
        #expect(arrangement.encoded.contains("futureControl"),
                "an unknown token must be carried back to disk, or the sheet's write destroys the newer build's control — got \"\(arrangement.encoded)\"")
    }

    /// The sheet's actual shape: decode the stored string, mutate, persist `encoded`. The token
    /// must ride through the mutation, not just through an untouched round trip.
    @Test func theTokenSurvivesTheEditThatUsedToDestroyIt() {
        var arrangement = PaneBarArrangement(encoded: "flexibleSpace,scan,search,futureControl")
        arrangement.insert(.sort, at: 1)
        arrangement.remove(at: arrangement.items.firstIndex(of: .search)!)

        #expect(arrangement.items.contains(.sort))
        #expect(!arrangement.items.contains(.search))
        #expect(arrangement.encoded.contains("futureControl"),
                "the first edit after a downgrade is exactly when the stored token used to be lost")
    }

    /// The other production writer: `PaneBarMigration.apply` re-encodes a stored bar to add a
    /// shipped control, and must not strip a foreign token while it does.
    @Test func theMigrationRewriteCarriesTheTokenToo() {
        let suite = "panebar-writeback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        defaults.set("flexibleSpace,scan,futureControl", forKey: PaneBar.arrangementKey)

        PaneBarMigration.apply(defaults: defaults)

        let rewritten = defaults.string(forKey: PaneBar.arrangementKey) ?? ""
        #expect(rewritten.contains("search"), "the migration itself must still have happened")
        #expect(rewritten.contains("futureControl"),
                "the migration's rewrite is a write like any other — it must not strip what it cannot name")
    }

    /// Carried tokens are capped like `items`, so a corrupt or hand-edited value can't make every
    /// later write re-persist an unbounded payload.
    @Test func aFloodOfJunkTokensIsBounded() {
        let junk = (0..<100).map { "junk\($0)" }.joined(separator: ",")
        let arrangement = PaneBarArrangement(encoded: "scan," + junk)
        let carried = arrangement.encoded.split(separator: ",").filter { $0.hasPrefix("junk") }
        #expect(carried.count == PaneBarArrangement.maxItems,
                "carried unknown tokens must be capped, not unbounded — got \(carried.count)")
    }

    /// An arrangement built in code (the default, or a test fixture) carries nothing and encodes
    /// exactly its items: only decoding carries tokens.
    @Test func anArrangementBuiltInCodeEncodesExactlyItsItems() {
        #expect(PaneBarArrangement.default.encoded
                == PaneBarArrangement.default.items.map(\.rawValue).joined(separator: ","))
    }
}
