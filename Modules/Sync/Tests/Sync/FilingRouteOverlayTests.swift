import Foundation
import Testing
@testable import Sync

/// Phase 2.5 — how router homes are laid over the keyword engine's suggestions.
///
/// The dangerous direction here is not a missed suggestion but a *demotion*: promoting a
/// low-margin content guess over a strong filename match would also flip the card to
/// `fromContent`, which drops the file out of the blind "File recommended" batch. Every test below
/// pins one half of that rule.
@Suite struct FilingRouteOverlayTests {

    static let root = "/prov"

    static func suggestion(_ name: String, best: FilingDestination?) -> FilingSuggestion {
        FilingSuggestion(filePath: "\(root)/TODO/\(name)", fileName: name, size: 10,
                         modificationDate: nil, candidates: best.map { [$0] } ?? [],
                         providerRoot: root)
    }

    static func destination(_ rel: String, _ c: FilingConfidence, remembered: Bool = false) -> FilingDestination {
        FilingDestination(path: "\(root)/\(rel)", confidence: c, reasons: ["existing"],
                          newSegments: [], remembered: remembered)
    }

    static var index: FilingRouter.Index {
        FilingRouterTests.index(memoryDocs: [
            "Health/Medical/Kaiser/Surgery": ["perioperative", "anesthesia", "stoll"],
        ])
    }

    @Test func aFileWithNoHomeGetsTheRouterHome() {
        let s = [Self.suggestion("scan001.pdf", best: nil)]
        let (out, routed) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia note"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
        // Content-derived, so it stays out of the blind batch and carries its evidence.
        #expect(out[0].best?.fromContent == true)
        #expect(out[0].best?.fromAI == false)
        #expect(out[0].isBatchEligible == false)
        #expect(out[0].best?.evidenceToken != nil)
        #expect((out[0].best?.neighborMatches ?? 0) > 0)
    }

    /// A remembered rule is an explicit correction the user taught. Nothing derived outranks it.
    @Test func arememberedHomeIsNeverReplaced() {
        let taught = Self.destination("Somewhere/Else", .medium, remembered: true)
        let s = [Self.suggestion("scan001.pdf", best: taught)]
        let (out, routed) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == taught)
    }

    /// A weaker router answer must not displace a strong filename match.
    ///
    /// The fixture has to produce a *real but low-margin* candidate. An earlier version used a
    /// snippet matching nothing at all, so `rank` returned no candidate and the overlay bailed out
    /// one line above the guard being tested — deleting the guard left the test green.
    @Test func aLowMarginRouteDoesNotDemoteAConfidentName() {
        // Both folders carry the same single anchor, so neither can win: the margin collapses and
        // the router reports `.low`.
        let tied = FilingRouterTests.index(memoryDocs: [
            "Home/Utilities/PG&E/2023": ["statement"],
            "Home/Utilities/AT&T/2023": ["statement"],
        ])
        let snippets = ["\(Self.root)/TODO/ambiguous.pdf": "statement"]
        let ranking = FilingRouter.rank(fileName: "ambiguous.pdf",
                                        contentSnippet: "statement", index: tied)
        #expect(ranking.best != nil)              // there IS an answer to demote with
        #expect(ranking.confidence == .low)

        let strong = Self.destination("Finance/US/Income Tax/2023", .high)
        let (out, routed) = FileSyncManager.applyRoutes(
            [Self.suggestion("ambiguous.pdf", best: strong)], index: tied,
            snippets: snippets, providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == strong)
    }

    /// The other half of the same rule: an equally confident router home *does* lead, or the
    /// guard above would be indistinguishable from never routing at all.
    @Test func anEquallyConfidentRouteDoesLead() {
        let weakExisting = Self.destination("Finance/US/Income Tax/2023", .low)
        let (out, routed) = FileSyncManager.applyRoutes(
            [Self.suggestion("op.pdf", best: weakExisting)], index: Self.index,
            snippets: ["\(Self.root)/TODO/op.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
    }

    @Test func aRejectedDestinationIsNotReoffered() {
        let s = [Self.suggestion("scan001.pdf", best: nil)]
        let rejected = ["\(Self.root)/TODO/scan001.pdf": Set(["Health/Medical/Kaiser/Surgery"])]
        let (out, routed) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia"],
            providerRoot: Self.root, rejectedByFile: rejected)
        #expect(routed == 0)
        #expect(out[0].best == nil)
    }

    /// With nothing extracted the router still has the filename, and must not invent a home from
    /// nothing — this is the no-content path a machine with reading turned off takes.
    @Test func noSnippetAndNoNameMatchPlacesNothing() {
        let s = [Self.suggestion("IMG_0007.HEIC", best: nil)]
        let (out, routed) = FileSyncManager.applyRoutes(s, index: Self.index, snippets: [:],
                                                        providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == nil)
    }

    /// The whole phase is gated on artifacts existing. An empty index must leave every suggestion
    /// byte-identical — this is what makes the change additive for anyone unsurveyed.
    @Test func anEmptyIndexChangesNothing() {
        let empty = FilingRouter.makeIndex(destinations: [], profile: nil, memory: nil)
        let strong = Self.destination("Finance/US/Income Tax/2023", .high)
        let s = [Self.suggestion("a.pdf", best: nil), Self.suggestion("b.pdf", best: strong)]
        let (out, routed) = FileSyncManager.applyRoutes(
            s, index: empty, snippets: ["\(Self.root)/TODO/a.pdf": "perioperative"],
            providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out == s)
    }
}
