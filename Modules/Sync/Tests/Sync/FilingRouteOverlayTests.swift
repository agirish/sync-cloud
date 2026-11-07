import Foundation
import Testing
@testable import Sync

/// How router homes are laid over the keyword engine's suggestions. The danger is a wrong
/// promotion more than a missed suggestion: a router home displaces a confident model answer or a
/// taught rule, and flipping a card to `fromContent` drops the file from the blind "File
/// recommended" batch. Each test pins one half of a rule.
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
        // Never a file count: the card renders `neighborMatches` as "N similar files already
        // here", and the memory records which words a folder's documents use, not how many use each.
        #expect(out[0].best?.neighborMatches == 0)
        #expect(out[0].best?.reasons.first?.contains("similar file") == false)
        #expect(out[0].best?.reasons.first?.contains("read from the file") == true)
    }

    // MARK: - The peer-name rerank reaches the router

    /// A call-site test: `rerankedByPeerNames`' unit tests call the rule directly and stay green if
    /// `route` ignores its `peerNames` parameter. So the rule is asserted through the seam the app
    /// uses, in both directions: without the lookup the parent wins, with it the child does.
    @Test func theRouterAppliesThePeerNameRerankItIsGiven() {
        // Both folders describe the same documents, so content can't separate them and the parent
        // outranks its child on score alone.
        let shared = ["son", "oci", "photo"]
        let index = FilingRouterTests.index(
            memoryDocs: ["Immigration/OCI/Son": shared,
                         "Immigration/OCI/Son/Application": shared],
            // The memory only ranks folders the taxonomy knows about.
            extraFolders: ["Immigration/OCI/Son", "Immigration/OCI/Son/Application"])
        let s = [Self.suggestion("Son OCI Photo.jpg", best: nil)]
        let snippets = ["\(Self.root)/TODO/Son OCI Photo.jpg": "son oci photo"]

        let (bare, _, _) = FileSyncManager.applyRoutes(
            s, index: index, snippets: snippets, providerRoot: Self.root)
        #expect(bare[0].best?.path == "\(Self.root)/Immigration/OCI/Son",
                "fixture no longer holds: the child must NOT already win, or the check below is vacuous")

        // The lookup is keyed by absolute folder: the router ranks relative paths, and `route` must
        // adapt them for a lookup that lists real directories.
        let names = [
            "\(Self.root)/Immigration/OCI/Son": ["Son - eOCI.pdf"],
            "\(Self.root)/Immigration/OCI/Son/Application": ["Son OCI Photo - 4up print sheet.jpg"],
        ]
        let (routed, _, _) = FileSyncManager.applyRoutes(
            s, index: index, snippets: snippets, providerRoot: Self.root,
            peerNames: { names[$0] ?? [] })
        #expect(routed[0].best?.path == "\(Self.root)/Immigration/OCI/Son/Application",
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

    /// A weaker router answer must not displace a strong model answer. (It does displace a word
    /// match, carrying its own Low onto the card:
    /// `FilingSuggestionLearningTests.anUnsureSurveyHomeStillLeadsOverAWordMatch`.) The fixture must
    /// produce a real low-margin candidate: with none, the overlay returns before the guard and the
    /// test can't fail.
    @Test func aLowMarginRouteDoesNotDemoteAConfidentModelAnswer() {
        // Both folders carry the same single anchor, so the margin collapses and the router reports
        // `.low`.
        let tied = FilingRouterTests.index(memoryDocs: [
            "Home/Utilities/PG&E/2023": ["statement"],
            "Home/Utilities/AT&T/2023": ["statement"],
        ])
        let snippets = ["\(Self.root)/TODO/ambiguous.pdf": "statement"]
        let ranking = FilingRouter.rank(fileName: "ambiguous.pdf",
                                        contentSnippet: "statement", index: tied)
        #expect(ranking.best != nil)              // there is an answer to demote with
        #expect(ranking.confidence == .low)

        let strong = FilingDestination(path: "\(Self.root)/Finance/US/Income Tax/2023", confidence: .high,
                                       reasons: ["Chosen by Claude"], newSegments: [], fromAI: true)
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [Self.suggestion("ambiguous.pdf", best: strong)], index: tied,
            snippets: snippets, providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == strong)
    }

    /// The other half: an equally confident router home does lead, or the guard above would look
    /// the same as never routing.
    @Test func anEquallyConfidentRouteDoesLead() {
        let weakExisting = Self.destination("Finance/US/Income Tax/2023", .low)
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [Self.suggestion("op.pdf", best: weakExisting)], index: Self.index,
            snippets: ["\(Self.root)/TODO/op.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
    }

    /// And for a model's answer: one the router matches in confidence gives way to it, as only a
    /// weaker one is kept (`aLowMarginRouteDoesNotDemoteAConfidentModelAnswer`). The word match in
    /// the test above takes the branch every guess takes, whatever the confidence, so it cannot
    /// tell `>=` from `>` here.
    @Test func anEquallyConfidentRouteReplacesAModelAnswer() {
        let tied = FilingRouterTests.index(memoryDocs: [
            "Home/Utilities/PG&E/2023": ["statement"],
            "Home/Utilities/AT&T/2023": ["statement"],
        ])
        let snippets = ["\(Self.root)/TODO/ambiguous.pdf": "statement"]
        let ranking = FilingRouter.rank(fileName: "ambiguous.pdf", contentSnippet: "statement", index: tied)
        #expect(ranking.confidence == .low, "the fixture no longer ties — the confidences below are not equal")

        let model = FilingDestination(path: "\(Self.root)/Finance/US/Income Tax/2023", confidence: .low,
                                      reasons: ["Chosen by Claude"], newSegments: [], fromAI: true)
        let (out, routed, _) = FileSyncManager.applyRoutes(
            [Self.suggestion("ambiguous.pdf", best: model)], index: tied,
            snippets: snippets, providerRoot: Self.root)
        #expect(routed == 1, "an equally confident route did not replace the model's answer")
        #expect(out[0].best?.path.hasPrefix("\(Self.root)/Home/Utilities/") == true)
        #expect(out[0].best?.confidence == .low)
    }

    /// Rejections are recorded as absolute paths, the form the scan builds (they become relative
    /// only for a backend). A relative path here would pass without the conversion inside
    /// `applyRoutes`. The other half: an unrelated rejection must not suppress a good home.
    @Test func aRejectedDestinationIsNotReoffered() {
        let s = [Self.suggestion("scan001.pdf", best: nil)]
        let snippets = ["\(Self.root)/TODO/scan001.pdf": "perioperative anesthesia"]
        let rejected = ["\(Self.root)/TODO/scan001.pdf":
                            Set(["\(Self.root)/Health/Medical/Kaiser/Surgery"])]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: snippets, providerRoot: Self.root, rejectedByFile: rejected)
        #expect(routed == 0)
        #expect(out[0].best == nil)

        let unrelated = ["\(Self.root)/TODO/scan001.pdf": Set(["\(Self.root)/Finance/US/Income Tax/2023"])]
        let (kept, keptCount, _) = FileSyncManager.applyRoutes(
            s, index: Self.index, snippets: snippets, providerRoot: Self.root, rejectedByFile: unrelated)
        #expect(keptCount == 1)
        #expect(kept[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
    }

    /// With nothing extracted the router still has the filename, and must not invent a home from
    /// nothing. This is the path a machine with reading turned off takes.
    @Test func noSnippetAndNoNameMatchPlacesNothing() {
        let s = [Self.suggestion("IMG_0007.HEIC", best: nil)]
        let (out, routed, _) = FileSyncManager.applyRoutes(s, index: Self.index, snippets: [:],
                                                        providerRoot: Self.root)
        #expect(routed == 0)
        #expect(out[0].best == nil)
    }

    /// A confident word match gives way to the survey: on real filed documents a keyword High was
    /// right 4% of the time against the router's 42% (`FilingCardReplayTests`). The file leaves the
    /// batch, which is right for a home read out of the document, and is still ranked for the menu.
    @Test func aConfidentWordMatchGivesWayToTheSurvey() {
        let strong = Self.destination("Finance/US/Income Tax/2023", .high)
        let s = [Self.suggestion("op.pdf", best: strong)]
        let (out, routed, shortlist) = FileSyncManager.applyRoutes(
            s, index: Self.index,
            snippets: ["\(Self.root)/TODO/op.pdf": "perioperative anesthesia stoll"],
            providerRoot: Self.root)
        #expect(routed == 1)
        #expect(out[0].best?.path == "\(Self.root)/Health/Medical/Kaiser/Surgery")
        #expect(out[0].candidates.contains(strong))
        #expect(!out[0].isBatchEligible, "a home read out of the document is never moved unseen")
        #expect(shortlist["\(Self.root)/TODO/op.pdf"]?.isEmpty == false, "it must still be ranked for the menu")
    }

    /// Routing is gated on artifacts existing. An empty index leaves every suggestion identical, so
    /// an unsurveyed tree is unaffected.
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

/// The chunked driver the scan uses, so a few hundred homeless files don't freeze the window. It
/// must agree with the one-pass helper exactly.
@Suite @MainActor struct FilingRouteYieldingTests {

    /// An existing folder full of the same documents beats inventing one from a filename word. The
    /// keyword engine returns `.high` for rules as generic as "receipt or invoice, filed by year", so
    /// confidence can't arbitrate between a new folder and the router's existing one; `newSegments`
    /// does.
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

    /// The refine pass ranks through the peer-name rerank too. `refineFilingSuggestions` builds the
    /// classifier's folder menu by ranking the same files again; ranked raw, it would hand the paid
    /// backend a differently ordered menu than the scan's. Asserted at the source, since the
    /// behavioural setup needs a live classifier, a spend budget and peer files on disk.
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
        // The scan's half is behavioural: `theRouterAppliesThePeerNameRerankItIsGiven`.
    }
}
