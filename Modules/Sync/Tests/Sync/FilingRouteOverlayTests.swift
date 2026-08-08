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
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia note"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
        // Content-derived, so it stays out of the blind batch and carries its evidence.
        #expect(out[0].best?.fromContent == true)
        #expect(out[0].best?.fromAI == false)
        #expect(out[0].isBatchEligible == false)
        #expect(out[0].best?.evidenceToken != nil)
        // **Never a file count.** The card renders `neighborMatches` as "N similar files already
        // here", and the memory cannot prove that number — it records which words a folder's
        // documents use, not how many use each one.
        #expect(out[0].best?.neighborMatches == 0)
        #expect(out[0].best?.reasons.first?.contains("similar file") == false)
        #expect(out[0].best?.reasons.first?.contains("read from the file") == true)
    }

    /// A remembered rule is an explicit correction the user taught. Nothing derived outranks it.
    @Test func arememberedHomeIsNeverReplaced() {
        let taught = Self.destination("Somewhere/Else", .medium, remembered: true)
        let s = [Self.suggestion("scan001.pdf", best: taught)]
        let (out, routed, _) = FileSyncManager.applyRoutes(
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
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [Self.suggestion("ambiguous.pdf", best: strong)], index: tied,
            snippets: snippets, providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == strong)
    }

    /// The other half of the same rule: an equally confident router home *does* lead, or the
    /// guard above would be indistinguishable from never routing at all.
    @Test func anEquallyConfidentRouteDoesLead() {
        let weakExisting = Self.destination("Finance/US/Income Tax/2023", .low)
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [Self.suggestion("op.pdf", best: weakExisting)], index: Self.index,
            snippets: ["\(Self.root)/TODO/op.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
    }

    /// Rejections are recorded as **absolute** paths, which is the form the scan actually builds
    /// (phase 3 converts them to relative before handing them to a backend). An earlier version of
    /// this test used a relative path — a domain no caller produces — so it passed while the
    /// conversion inside `applyRoutes` was missing entirely.
    @Test func aRejectedDestinationIsNotReoffered() {
        let s = [Self.suggestion("scan001.pdf", best: nil)]
        let rejected = ["\(Self.root)/TODO/scan001.pdf":
                            Set(["\(Self.root)/Health/Medical/Kaiser/Surgery"])]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia"],
            providerRoot: Self.root, rejectedByFile: rejected)
        #expect(routed == 0)
        #expect(out[0].best == nil)
    }

    /// The other half: an unrelated rejection must not suppress a good home.
    @Test func anUnrelatedRejectionDoesNotBlockRouting() {
        let s = [Self.suggestion("scan001.pdf", best: nil)]
        let rejected = ["\(Self.root)/TODO/scan001.pdf": Set(["\(Self.root)/Finance/US/Income Tax/2023"])]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia"],
            providerRoot: Self.root, rejectedByFile: rejected)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
    }

    /// With nothing extracted the router still has the filename, and must not invent a home from
    /// nothing — this is the no-content path a machine with reading turned off takes.
    @Test func noSnippetAndNoNameMatchPlacesNothing() {
        let s = [Self.suggestion("IMG_0007.HEIC", best: nil)]
        let (out, routed, _) = FileSyncManager.applyRoutes(s, index: Self.index, snippets: [:],
                                                        providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == nil)
    }

    /// **A file that already has a confident home is left alone.** Ranking it could only replace a
    /// filename match with an equally confident content one — which flips `fromContent` and drops
    /// the file out of the blind "File all N" batch for no accuracy gain.
    @Test func aConfidentlyPlacedFileIsNotReRouted() {
        let strong = Self.destination("Finance/US/Income Tax/2023", .high)
        let s = [Self.suggestion("op.pdf", best: strong)]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: Self.index,
            snippets: ["\(Self.root)/TODO/op.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == strong)
        #expect(out[0].isBatchEligible)          // still auto-filable, which is the point
    }

    /// The whole phase is gated on artifacts existing. An empty index must leave every suggestion
    /// byte-identical — this is what makes the change additive for anyone unsurveyed.
    @Test func anEmptyIndexChangesNothing() {
        let empty = FilingRouter.makeIndex(destinations: [], profile: nil, memory: nil)
        let strong = Self.destination("Finance/US/Income Tax/2023", .high)
        let s = [Self.suggestion("a.pdf", best: nil), Self.suggestion("b.pdf", best: strong)]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: empty, snippets: ["\(Self.root)/TODO/a.pdf": "perioperative"],
            providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out == s)
    }
}

/// The chunked driver used by the scan. It exists so a few hundred homeless files do not freeze the
/// window, and it must agree with the one-pass helper exactly.
@Suite @MainActor struct FilingRouteYieldingTests {

    @Test func yieldingAgreesWithTheOnePassHelper() async {
        let index = FilingRouteOverlayTests.index
        let snippets = (0..<60).reduce(into: [String: String]()) {
            $0["/prov/TODO/f\($1).pdf"] = "perioperative anesthesia stoll"
        }
        let files = (0..<60).map { FilingRouteOverlayTests.suggestion("f\($0).pdf", best: nil) }
        let manager = FileSyncManager()
        let chunked = await manager.applyRoutesYielding(files, index: index, snippets: snippets,
                                                        providerRoot: "/prov", chunk: 7)
        let onePass = FileSyncManager.applyRoutes(files, index: index, snippets: snippets,
                                                  providerRoot: "/prov")
        #expect(chunked.routed == onePass.routed)
        #expect(chunked.routed == 60)
        #expect(chunked.suggestions == onePass.suggestions)
        #expect(chunked.shortlists == onePass.shortlists)
        #expect(chunked.shortlists.count == 60)
    }

    /// A cancelled scan must get its input back untouched, not a half-routed list.
    @Test func cancellationReturnsTheInputUnchanged() async {
        let index = FilingRouteOverlayTests.index
        let files = (0..<60).map { FilingRouteOverlayTests.suggestion("f\($0).pdf", best: nil) }
        let snippets = (0..<60).reduce(into: [String: String]()) {
            $0["/prov/TODO/f\($1).pdf"] = "perioperative anesthesia stoll"
        }
        let manager = FileSyncManager()
        let task = Task { @MainActor in
            await manager.applyRoutesYielding(files, index: index, snippets: snippets,
                                              providerRoot: "/prov", chunk: 1)
        }
        task.cancel()
        let out = await task.value
        #expect(out.routed == 0)
        #expect(out.suggestions == files)
    }
}
