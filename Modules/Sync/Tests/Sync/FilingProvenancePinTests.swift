import Foundation
import Testing
@testable import Sync

/// Characterization pins for the confidence-cap / provenance / rule-eligibility refactor.
///
/// Written against the PRE-refactor engine and kept green through it: each test names one of the
/// construction sites that used to spell the content-derived cap (or the eligibility filter) for
/// itself, and pins the OUTPUT the shared spelling must keep producing. `isBatchEligible` is the
/// consumer that makes these pins matter — it gates files moving without the user looking.
@Suite struct FilingProvenancePinTests {

    // Mid-2024 so the year is 2024 in every timezone.
    private let y2024 = Date(timeIntervalSince1970: 1_720_000_000)

    private func file(_ path: String, size: Int = 8192, modified: Date? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: modified, fileSize: size)
    }
    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    // MARK: - The cap, per construction site

    /// Taxonomy site. A CONTENT token matching a folder's NAME earns base `.high` (a real
    /// folder-name hit) — the cap is the only thing that brings it to `.medium`, so this fixture
    /// discriminates "capped" from "not capped" rather than agreeing with both.
    @Test func aContentTokenMatchingAFolderNameIsCappedToMedium() throws {
        let taxonomy = [dir("/root/Receipts", [])]
        // "scan" is a stopword and "0071" a bare number, so the filename contributes no tokens:
        // the deciding signal can only be the content token.
        let loose = [file("/root/inbox/scan0071.pdf", modified: y2024)]
        let s = try #require(FilingEngine.suggest(
            looseFiles: loose, taxonomy: taxonomy, providerRoot: "/root",
            contentTokens: ["/root/inbox/scan0071.pdf": ["receipts"]]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Receipts")
        #expect(best.confidence == .medium)
        #expect(best.fromContent)
        #expect(!s.isBatchEligible)
    }

    /// Same site, name-derived control: the identical hit from the FILENAME keeps `.high` and the
    /// blind-batch door open — proving the fixture above was capped, not merely born `.medium`.
    @Test func theSameFolderNameHitFromTheFilenameStaysHigh() throws {
        let taxonomy = [dir("/root/Receipts", [])]
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/receipts march.pdf", modified: y2024)],
            taxonomy: taxonomy, providerRoot: "/root").first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Receipts")
        #expect(best.confidence == .high)
        #expect(!best.fromContent)
        #expect(s.isBatchEligible)
    }

    /// Remembered-rule site (the site that used to OVERWRITE `.medium`/`.high` rather than cap —
    /// same output while base is `.high`, which this pins).
    @Test func aRememberedRuleMatchedOnlyInContentIsMediumRememberedAndOffTheBatch() throws {
        let rule = FilingRule(tokens: ["kaiser"], destinationPath: "/root/Medical")
        let taxonomy = [dir("/root/Medical", [])]
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/scan0071.pdf", modified: y2024)],
            taxonomy: taxonomy, providerRoot: "/root",
            contentTokens: ["/root/inbox/scan0071.pdf": ["kaiser"]],
            rules: [rule]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Medical")
        #expect(best.confidence == .medium)
        #expect(best.fromContent)
        #expect(best.remembered)
        #expect(!s.isBatchEligible)
    }

    @Test func aRememberedRuleMatchedInTheFilenameIsHighAndBatchEligible() throws {
        let rule = FilingRule(tokens: ["kaiser"], destinationPath: "/root/Medical")
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/kaiser eob.pdf", modified: y2024)],
            taxonomy: [dir("/root/Medical", [])], providerRoot: "/root",
            rules: [rule]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Medical")
        #expect(best.confidence == .high)
        #expect(!best.fromContent)
        #expect(s.isBatchEligible)
    }

    /// Automation site (the other overwrite spelling).
    @Test func anAutomationMatchedOnlyThroughContentIsMediumAndOffTheBatch() throws {
        let rule = AutomationRule(name: "Kaiser papers", matchMode: .all,
                                  conditions: [.mentionsAll(["kaiser"])],
                                  destinationTemplate: "Medical")
        let path = "/root/inbox/scan0071.pdf"
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file(path, modified: y2024)],
            taxonomy: [dir("/root/Medical", [])], providerRoot: "/root",
            automations: [rule],
            automationSnippets: [path: "kaiser permanente explanation of benefits"]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Medical")
        #expect(best.confidence == .medium)
        #expect(best.fromContent)
        #expect(best.remembered)
        #expect(best.reasons.first?.contains("read from the file") == true)
        #expect(!s.isBatchEligible)
    }

    @Test func anAutomationMatchedByTheFilenameIsHighAndBatchEligible() throws {
        let rule = AutomationRule(name: "Kaiser papers", matchMode: .all,
                                  conditions: [.mentionsAll(["kaiser"])],
                                  destinationTemplate: "Medical")
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/kaiser eob.pdf", modified: y2024)],
            taxonomy: [dir("/root/Medical", [])], providerRoot: "/root",
            automations: [rule]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Medical")
        #expect(best.confidence == .high)
        #expect(!best.fromContent)
        #expect(s.isBatchEligible)
    }

    /// Universal-rule site (`min(base, .medium)` inside the `rule` closure): the receipt rule's
    /// base is `.high`, and a content-only signal caps it and annotates the reason.
    @Test func aReceiptWordReadFromContentCapsTheHighReceiptRule() throws {
        let taxonomy = [dir("/root/Receipts", [])]
        let path = "/root/inbox/scan0071.pdf"
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file(path, modified: y2024)], taxonomy: taxonomy, providerRoot: "/root",
            contentTokens: [path: ["invoice"]]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Receipts/2024")
        #expect(best.confidence == .medium)
        #expect(best.fromContent)
        #expect(best.reasons.first?.hasSuffix("(read from the file)") == true)
        #expect(!s.isBatchEligible)
    }

    @Test func aReceiptWordInTheFilenameKeepsTheHighReceiptRule() throws {
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/invoice march.pdf", modified: y2024)],
            taxonomy: [dir("/root/Receipts", [])], providerRoot: "/root").first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Receipts/2024")
        #expect(best.confidence == .high)
        #expect(!best.fromContent)
        #expect(s.isBatchEligible)
    }

    /// The AI construction site deliberately BYPASSES the cap: a verdict's confidence is the
    /// backend's own, and the `fromAI` flag (not a demotion) is what keeps it out of the batch.
    @Test func anAIVerdictKeepsItsHighConfidenceAndStaysOffTheBatchViaFromAI() throws {
        let dest = try #require(FilingEngine.destination(
            from: FilingVerdict(relativePath: "Medical", confidence: .high, reason: "model"),
            providerRoot: "/root", existingRelative: ["Medical"], fileName: "scan0071.pdf"))
        #expect(dest.confidence == .high)
        #expect(dest.fromAI)
        #expect(!dest.fromContent)
        let s = FilingSuggestion(filePath: "/root/inbox/scan0071.pdf", fileName: "scan0071.pdf",
                                 size: 1, modificationDate: nil, candidates: [dest])
        #expect(s.hasConfidentHome)
        #expect(!s.isBatchEligible)
    }

    /// The route construction site: the router's confidence is a MEASURED margin, and is not
    /// capped even when the evidence is content-derived — `fromContent` alone handles the batch.
    /// (A lone scoring candidate has margin 1.0 ⇒ `.high`; the guard message keeps the fixture
    /// honest about that.)
    @Test func aRouterHomeKeepsItsMeasuredConfidenceEvenWhenContentDerived() throws {
        let root = "/prov"
        let index = FilingRouterTests.index(memoryDocs: [
            "Health/Medical/Kaiser/Surgery": ["perioperative", "anesthesia", "stoll"],
        ])
        let s = [FilingSuggestion(filePath: "\(root)/TODO/scan001.pdf", fileName: "scan001.pdf",
                                  size: 10, modificationDate: nil, candidates: [],
                                  providerRoot: root)]
        let (out, routed, _) = FileSyncManager.applyRoutes(
            s, index: index, snippets: ["\(root)/TODO/scan001.pdf": "perioperative anesthesia note"],
            providerRoot: root)
        #expect(routed == 1)
        let best = try #require(out[0].best)
        #expect(best.fromContent, "fixture must exercise the content-derived path")
        #expect(best.evidenceToken != nil)
        #expect(best.confidence == .high,
                "the router's measured margin is not subject to the heuristic content cap")
        #expect(!out[0].isBatchEligible)
    }

    /// The route site's OTHER branch, and the only one that can mint a blind-batch-eligible home:
    /// with no snippet there is no evidence token, so the destination is built `.name`, and a
    /// measured `.high` margin then leaves `isBatchEligible` true — a file moved without the user
    /// looking, on a ranking made from its filename. That is the intended trade (a filename is the
    /// checkable signal), but it is the consequential one, so it is pinned rather than assumed.
    ///
    /// The sibling test above covers the content branch; between them the `evidence:` ternary at
    /// the construction site has both of its arms pinned.
    @Test func aRouterHomeRankedFromTheFilenameAloneStaysInTheBlindBatch() throws {
        let root = "/prov"
        let index = FilingRouterTests.index()
        let path = "\(root)/TODO/kaiser surgery notes.pdf"
        let s = [FilingSuggestion(filePath: path, fileName: "kaiser surgery notes.pdf",
                                  size: 10, modificationDate: nil, candidates: [],
                                  providerRoot: root)]
        // No snippets at all: the ranking can only have come from the name.
        let (out, routed, _) = FileSyncManager.applyRoutes(s, index: index, snippets: [:],
                                                          providerRoot: root)
        #expect(routed == 1)
        let best = try #require(out[0].best)
        #expect(best.path == "\(root)/Health/Medical/Kaiser/Surgery")
        #expect(!best.fromContent, "fixture must exercise the NAME branch of the evidence ternary")
        #expect(best.evidenceToken == nil)
        #expect(best.reasons == ["Fits how this folder is used"])
        #expect(best.confidence == .high)
        #expect(best.newSegments.isEmpty, "the router only ever names folders that already exist")
        #expect(out[0].isBatchEligible,
                "a name-ranked router home is the one router home the blind batch may move")
    }

    // MARK: - Merge discipline when two candidates name the same folder

    /// The SAME folder named by a remembered rule (filename evidence, `.high`) and by a taxonomy
    /// content match (`.medium`, `fromContent`). The winner's provenance stands: the merged
    /// candidate is NOT `fromContent`, so it keeps `.high` coherently and STAYS in the blind
    /// batch. This is exactly the case where an OR-merge of `fromContent` would flip
    /// `isBatchEligible` — the pin that makes that a decision, not an accident.
    @Test func sameFolderNamedByARuleAndByContentKeepsTheWinnersProvenance() throws {
        let rule = FilingRule(tokens: ["invoice"], destinationPath: "/root/Receipts")
        let taxonomy = [dir("/root/Receipts", [])]
        let path = "/root/inbox/invoice march.pdf"
        // "invoice" is in the NAME (rule match, not content); "receipts" only in the CONTENT
        // (taxonomy folder-name match, content-derived). Both name /root/Receipts.
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file(path, modified: y2024)], taxonomy: taxonomy, providerRoot: "/root",
            contentTokens: [path: ["receipts"]], rules: [rule]).first)
        let best = try #require(s.best)
        #expect(best.path == "/root/Receipts")
        #expect(best.confidence == .high)
        #expect(best.remembered)             // carried by OR from the rule candidate
        #expect(!best.fromContent)           // the WINNER's flag, not the loser's
        #expect(best.evidenceToken == nil)   // the winner's (absent) evidence, not the loser's
        #expect(best.reasons.count == 2)     // both stories about the folder survive the merge
        #expect(s.isBatchEligible)
    }

    // MARK: - isBatchEligible per provenance combination

    private func dest(_ c: FilingConfidence, fromContent: Bool = false,
                      fromAI: Bool = false) -> FilingDestination {
        FilingDestination(path: "/root/X", confidence: c, reasons: ["r"], newSegments: [],
                          fromContent: fromContent, fromAI: fromAI)
    }
    private func sugg(_ d: FilingDestination, alreadyFiledAt: [String] = []) -> FilingSuggestion {
        FilingSuggestion(filePath: "/root/inbox/f.pdf", fileName: "f.pdf", size: 1,
                         modificationDate: nil, candidates: [d], alreadyFiledAt: alreadyFiledAt)
    }

    @Test func batchEligibilityTruthTable() {
        #expect(sugg(dest(.high)).isBatchEligible)
        #expect(sugg(dest(.medium)).isBatchEligible)
        #expect(!sugg(dest(.low)).isBatchEligible)
        #expect(!sugg(dest(.high, fromContent: true)).isBatchEligible)
        #expect(!sugg(dest(.high, fromAI: true)).isBatchEligible)
        #expect(!sugg(dest(.high), alreadyFiledAt: ["Somewhere"]).isBatchEligible)
    }

    // MARK: - Automation eligibility at the engine site

    /// The engine acts only on enabled AND runnable automations — a disabled rule and a
    /// half-built one (no name ⇒ not runnable) steer nothing even when their conditions match.
    @Test func disabledOrUnrunnableAutomationsNeverSteerASuggestion() throws {
        let disabled = AutomationRule(name: "Off", enabled: false, matchMode: .all,
                                      conditions: [.mentionsAll(["kaiser"])],
                                      destinationTemplate: "Medical")
        let unrunnable = AutomationRule(name: "   ", matchMode: .all,
                                        conditions: [.mentionsAll(["kaiser"])],
                                        destinationTemplate: "Elsewhere")
        let s = try #require(FilingEngine.suggest(
            looseFiles: [file("/root/inbox/kaiser eob.pdf", modified: y2024)],
            taxonomy: [dir("/root/Medical", []), dir("/root/Elsewhere", [])],
            providerRoot: "/root", automations: [disabled, unrunnable]).first)
        #expect(!s.candidates.contains { $0.remembered },
                "no automation candidate may appear for ineligible rules")
    }
}

/// Unit tests of the seams the refactor introduced — the capped construction path, the merge
/// discipline, and `AutomationRuleSet`. These probe the cases the engine's public surface cannot
/// reach (which is exactly why they exist: a rule extracted for testability needs its own proof).
@Suite struct FilingProvenanceSeamTests {

    private func d(_ c: FilingConfidence, fromContent: Bool = false, remembered: Bool = false,
                   fromAI: Bool = false, token: String? = nil,
                   reasons: [String] = ["r"]) -> FilingDestination {
        FilingDestination(path: "/root/X", confidence: c, reasons: reasons, newSegments: [],
                          fromContent: fromContent, remembered: remembered, fromAI: fromAI,
                          evidenceToken: token)
    }

    // MARK: The capped construction path

    /// The case where "cap" and the old per-site "overwrite to .medium" answer DIFFERENTLY:
    /// a `.low` base with content evidence must stay `.low` — capping never promotes.
    @Test func theCapNeverPromotesALowBase() {
        let dest = FilingDestination(path: "/p", base: .low, evidence: .content,
                                     reasons: [], newSegments: [])
        #expect(dest.confidence == .low)
        #expect(dest.fromContent)
    }

    @Test func theCapOnlyBindsContentEvidence() {
        #expect(FilingDestination(path: "/p", base: .high, evidence: .content,
                                  reasons: [], newSegments: []).confidence == .medium)
        #expect(FilingDestination(path: "/p", base: .high, evidence: .name,
                                  reasons: [], newSegments: []).confidence == .high)
        // Measured (router-margin) content evidence is trusted as-is — but still marked.
        let measured = FilingDestination(path: "/p", base: .high, evidence: .measuredContent,
                                         reasons: [], newSegments: [])
        #expect(measured.confidence == .high)
        #expect(measured.fromContent)
    }

    /// The capped path can never build the state the cap forbids, whatever it is handed.
    @Test func theCappedPathNeverBuildsHighPlusHeuristicContent() {
        for base in [FilingConfidence.low, .medium, .high] {
            let dest = FilingDestination(path: "/p", base: base, evidence: .content,
                                         reasons: [], newSegments: [])
            #expect(dest.confidence <= .medium)
        }
    }

    // MARK: The merge discipline

    @Test func mergeUnionsRememberedAndAIButKeepsTheWinnersContentFlag() {
        // Winner (higher confidence) is content-derived; loser is a name match that was taught.
        let winner = d(.medium, fromContent: true, token: "Invoice")
        let loser = d(.low, remembered: true, fromAI: true)
        let merged = winner.merging(loser)
        #expect(merged.confidence == .medium)
        #expect(merged.fromContent, "the winner's deciding signal stands")
        #expect(merged.remembered, "remembered ORs in from the loser")
        #expect(merged.fromAI, "fromAI ORs in from the loser")
        #expect(merged.evidenceToken == "Invoice")
    }

    @Test func mergeTieKeepsTheEarlierCandidatesClaim() {
        // Equal confidence: `self` (the earlier-constructed candidate) is the winner — the order
        // the engine's candidate builders run in is part of the pinned behavior.
        let first = d(.medium, fromContent: false, reasons: ["first"])
        let second = d(.medium, fromContent: true, token: "Late", reasons: ["second"])
        let merged = first.merging(second)
        #expect(!merged.fromContent)
        #expect(merged.evidenceToken == nil)
        #expect(merged.reasons == ["first", "second"])   // sorted union
    }

    @Test func mergeIsKeyedOnConfidenceNotArgumentOrder() {
        let strong = d(.high, reasons: ["strong"])
        let weak = d(.low, fromContent: true, reasons: ["weak"])
        #expect(strong.merging(weak).confidence == .high)
        #expect(weak.merging(strong).confidence == .high)
        #expect(!weak.merging(strong).fromContent, "the stronger claim wins from either side")
    }

    // MARK: AutomationRuleSet

    private static func rule(_ name: String, enabled: Bool = true,
                             tokens: [String] = ["kaiser"],
                             dest: String = "Medical") -> AutomationRule {
        AutomationRule(name: name, enabled: enabled, matchMode: .all,
                       conditions: [.mentionsAll(tokens)], destinationTemplate: dest)
    }

    @Test func eligibleRequiresEnabledAndRunnable() {
        let on = Self.rule("On")
        let off = Self.rule("Off", enabled: false)
        let unrunnable = AutomationRule(name: "  ", matchMode: .all,
                                        conditions: [.mentionsAll(["x"])],
                                        destinationTemplate: "Y")
        let set = AutomationRuleSet.eligible([off, on, unrunnable])
        #expect(set.rules.map(\.id) == [on.id])
    }

    @Test func testingAdmitsADisabledRuleButNeverAnUnrunnableOne() {
        let off = Self.rule("Off", enabled: false)
        let broken = AutomationRule(name: "", enabled: false, matchMode: .all,
                                    conditions: [.mentionsAll(["x"])], destinationTemplate: "Y")
        #expect(AutomationRuleSet.testing(off.id, in: [off, broken]).rules.map(\.id) == [off.id])
        #expect(AutomationRuleSet.testing(broken.id, in: [off, broken]).isEmpty)
    }

    @Test func narrowedOnlyRemoves() {
        let a = Self.rule("A"), b = Self.rule("B")
        let set = AutomationRuleSet.eligible([a, b]).narrowed { $0.id != a.id }
        #expect(set.rules.map(\.id) == [b.id])
    }

    @Test func contentGateFiresOnlyWhileContentCouldStillFlipARule() {
        let set = AutomationRuleSet.eligible([Self.rule("Kaiser")])
        #expect(set.readsContent)
        let file = FileNode(id: "/root/inbox/scan0071.pdf", name: "scan0071.pdf",
                            isDirectory: false, fileSize: 10)
        // No content yet, and the name alone does not match ⇒ worth reading.
        #expect(set.contentCouldStillDecide(FilingEngine.automationFacts(for: file), now: .now))
        // The name already matches ⇒ nothing left for content to decide.
        let named = FileNode(id: "/root/inbox/kaiser eob.pdf", name: "kaiser eob.pdf",
                             isDirectory: false, fileSize: 10)
        #expect(!set.contentCouldStillDecide(FilingEngine.automationFacts(for: named), now: .now))
    }

    @Test func firstMatchHonorsUserOrder() {
        let a = Self.rule("A", tokens: ["kaiser"], dest: "MedicalA")
        let b = Self.rule("B", tokens: ["kaiser"], dest: "MedicalB")
        let file = FileNode(id: "/root/kaiser.pdf", name: "kaiser.pdf",
                            isDirectory: false, fileSize: 10)
        let match = AutomationRuleSet.eligible([a, b])
            .firstMatch(for: FilingEngine.automationFacts(for: file), now: .now)
        #expect(match?.id == a.id)
    }
}
