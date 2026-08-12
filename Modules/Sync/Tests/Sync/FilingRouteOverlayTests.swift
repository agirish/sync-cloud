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

    // MARK: - The peer-name rerank reaches the router

    /// **A call-site test, and the reason it exists is that the helper's own tests all passed while
    /// nothing called it.** `rerankedByPeerNames`, the `PeerNameCache` and a `peerNames` closure
    /// threaded through three signatures all shipped; `route` accepted the parameter and never read
    /// it. Every unit test of the rule was green throughout, because they call the rule directly.
    ///
    /// So this asserts the rule *through the seam the app uses*, in BOTH directions — without the
    /// lookup the parent wins, with it the child does. One direction alone would pass against a
    /// `route` that ignores the parameter again.
    @Test func theRouterAppliesThePeerNameRerankItIsGiven() {
        // Both folders describe the same documents, which is what makes them inseparable by
        // content: the parent outranks its child on the score alone.
        let shared = ["divit", "oci", "photo"]
        let index = FilingRouterTests.index(
            memoryDocs: ["Immigration/OCI/Divit": shared,
                         "Immigration/OCI/Divit/Application": shared],
            // The memory only ranks folders the taxonomy knows about.
            extraFolders: ["Immigration/OCI/Divit", "Immigration/OCI/Divit/Application"])
        let s = [Self.suggestion("Divit OCI Photo.jpg", best: nil)]
        let snippets = ["\(Self.root)/TODO/Divit OCI Photo.jpg": "divit oci photo"]

        let (bare, _, _) = FileSyncManager.applyRoutes(
            s, index: index, snippets: snippets, providerRoot: Self.root)
        #expect(bare[0].best?.path == "\(Self.root)/Immigration/OCI/Divit",
                "fixture no longer holds: the child must NOT already win, or the check below is vacuous")

        // The lookup is keyed by ABSOLUTE folder, which is the adapter `route` has to get right:
        // the router ranks relative paths and the real lookup lists real directories.
        let names = [
            "\(Self.root)/Immigration/OCI/Divit": ["Divit - eOCI.pdf"],
            "\(Self.root)/Immigration/OCI/Divit/Application": ["Divit OCI Photo - 4up print sheet.jpg"],
        ]
        let (routed, _, _) = FileSyncManager.applyRoutes(
            s, index: index, snippets: snippets, providerRoot: Self.root,
            peerNames: { names[$0] ?? [] })
        #expect(routed[0].best?.path == "\(Self.root)/Immigration/OCI/Divit/Application",
                "the peer-name lookup reached the ranking")
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

    /// **An existing folder full of the same documents beats inventing one from a filename word.**
    /// The keyword engine returns `.high` for rules as generic as "receipt or invoice — filed by
    /// year": a T-Mobile bill was headed for a NEW `Purchases/2025` while five siblings sat in an
    /// existing folder the router ranks first. Confidence cannot arbitrate between those two claims,
    /// so `newSegments` does.
    @Test func aRouterHomeReplacesAHighConfidenceProposalToCreateAFolder() {
        let creating = FilingDestination(path: "/prov/Purchases/2025", confidence: .high,
                                         reasons: ["Receipt or invoice — filed by year"],
                                         newSegments: ["2025"], fromContent: false,
                                         remembered: false, fromAI: false)
        let s = FilingRouteOverlayTests.suggestion("bill.pdf", best: creating)
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [s], index: FilingRouteOverlayTests.index, snippets: ["/prov/TODO/bill.pdf": "perioperative anesthesia stoll"],
            providerRoot: "/prov")
        #expect(routed == 1)
        #expect(out.first?.best?.newSegments.isEmpty == true, "swapped one new folder for another")
        #expect(out.first?.best?.path != "/prov/Purchases/2025")
    }

    /// The other half: a confident home that names a folder that already EXISTS is left alone, which
    /// is the rule this carve-out must not swallow.
    @Test func aRouterHomeStillLeavesAnExistingConfidentHomeAlone() {
        let existing = FilingDestination(path: "/prov/Purchases/2025", confidence: .high,
                                         reasons: ["Receipt or invoice — filed by year"],
                                         newSegments: [], fromContent: false,
                                         remembered: false, fromAI: false)
        let s = FilingRouteOverlayTests.suggestion("bill.pdf", best: existing)
        let (out, routed, shortlist) = FileSyncManager.applyRoutes(
            [s], index: FilingRouteOverlayTests.index, snippets: ["/prov/TODO/bill.pdf": "perioperative anesthesia stoll"],
            providerRoot: "/prov")
        #expect(routed == 0)
        #expect(out.first?.best?.path == "/prov/Purchases/2025")
        #expect(shortlist["/prov/TODO/bill.pdf"]?.isEmpty == false, "it must still be ranked for the menu")
    }

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

    /// **And the refine pass applies it too**, which is the third consumer and the one that had no
    /// test at all.
    ///
    /// `refineFilingSuggestions` builds the classifier's folder menu by ranking these same files
    /// again — its comment calls it "the same folder menu the scan builds" — and it was ranking
    /// raw. So the scan shortlisted the child (peer names separate the pair) and a refine of the
    /// same unchanged file shortlisted the parent, handing the paid backend a differently ordered
    /// menu for one question. Asserted at the source because the behavioural setup needs a live
    /// classifier, a spend budget and peer files on disk; the rule itself is proven above, and what
    /// is unproven without this is that the second caller reaches it.
    @Test func theRefinePassAlsoRanksThroughThePeerNameRerank() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+FilingRefine.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read FileSyncManager+FilingRefine.swift — this scan is vacuous")
        try #require(source.count > 500, "FileSyncManager+FilingRefine.swift is implausibly short")

        #expect(source.contains("FilingRouter.rerankedByPeerNames("),
                "the refine pass ranks raw again, so its menu can disagree with the scan's")
        #expect(source.contains("peerNameLookup()"),
                "the rerank is called without the lookup that makes it do anything")
        // Both consumers reach the rerank; neither is allowed to be the only one.
        let route = try #require(try? String(contentsOf: url.deletingLastPathComponent()
                                                .appendingPathComponent("FileSyncManager+FilingRoute.swift"),
                                             encoding: .utf8))
        #expect(route.contains("FilingRouter.rerankedByPeerNames("),
                "the scan no longer reranks — this pair is what has to agree")
    }
}
