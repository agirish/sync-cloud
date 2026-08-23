import Testing
import Foundation
@testable import Dashboard

/// The write half of the tolerant decode that `PaneBarArrangementTests` covers the read half of.
///
/// `init(encoded:)`'s doc claims dropping unknown tokens "is what makes a bar arranged on a newer
/// build survive a downgrade instead of resetting to the default" — but until `unknownTokens`
/// existed it survived only the READING. `PaneBarCustomizeSheet.commit` writes `next.encoded` back
/// to the same key, so the first time the user touched the customize sheet on the older build,
/// whatever the decode dropped was gone permanently: downgrade → edit → re-upgrade lost the newer
/// build's control. These pin the carry-through that makes the doc's claim true.
@Suite struct PaneBarArrangementWriteBackTests {

    @Test func aNewerBuildsTokenSurvivesTheDecodeEncodeRoundTrip() {
        let stored = "scan,search,futureControl"
        let arrangement = PaneBarArrangement(encoded: stored)

        // The read half (already pinned elsewhere): the unknown token doesn't reject the bar and
        // never reaches the items the bar draws.
        #expect(arrangement.items == [.scan, .search])

        // The write half — what the customize sheet persists after ANY edit.
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

    /// The OTHER production writer: `PaneBarMigration.apply` re-encodes a stored arrangement to
    /// add a shipped control. A stored bar carrying a foreign token must not have the migration's
    /// rewrite strip it.
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

    /// Tolerance is not an invitation: a corrupt or hand-edited value does not get to smuggle an
    /// unbounded payload that every later write faithfully re-persists. Bounded like `items`.
    @Test func aFloodOfJunkTokensIsBounded() {
        let junk = (0..<100).map { "junk\($0)" }.joined(separator: ",")
        let arrangement = PaneBarArrangement(encoded: "scan," + junk)
        let carried = arrangement.encoded.split(separator: ",").filter { $0.hasPrefix("junk") }
        #expect(carried.count == PaneBarArrangement.maxItems,
                "carried unknown tokens must be capped, not unbounded — got \(carried.count)")
    }

    /// An arrangement built in code — the default, or any test fixture — carries nothing and
    /// encodes exactly as it always did. The carry is a property of decoding, never of building.
    @Test func anArrangementBuiltInCodeEncodesExactlyItsItems() {
        #expect(PaneBarArrangement.default.encoded
                == PaneBarArrangement.default.items.map(\.rawValue).joined(separator: ","))
    }
}
