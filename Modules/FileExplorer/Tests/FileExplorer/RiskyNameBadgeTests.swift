import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// The row badge's predicate: which names earn a mark, which do not, and what the memo is allowed
/// to change about the answer (nothing).
///
/// Every assertion names the exact string it is about. A test that only counted badges would pass
/// against a predicate that flagged the wrong file, and "some row in this folder is marked" is not
/// what the badge promises.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgePredicateTests {

    /// The memo is process-wide, so one case's answers must not decide another's — and the
    /// provider-keying test below is meaningless if a previous case already populated the table.
    private func fresh() { RiskyNameBadgeCache.resetForTesting() }

    /// A name OneDrive will reject earns a badge; its cleaned-up twin does not.
    ///
    /// The pair is deliberate. Asserting only the positive passes against a predicate that returns
    /// non-nil for everything, which is the mutation a single-name test cannot see.
    @Test func aTrailingSpaceIsBadgedAndTheSameNameWithoutOneIsNot() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Statement 2026 ", isDirectory: false, provider: .oneDrive) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "Statement 2026", isDirectory: false, provider: .oneDrive) == nil)
    }

    @Test func aForbiddenCharacterIsBadgedAndAnOrdinaryNameIsNot() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .oneDrive) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "Q3 final.pdf", isDirectory: false, provider: .oneDrive) == nil)
    }

    /// A zero-width character is invisible by construction, so this is the one hazard the user
    /// cannot see for themselves — the badge is the only thing that can report it. Flagged for
    /// EVERY provider, including the permissive ones, because it is a cross-cloud hazard rather
    /// than a rule any single provider spells out.
    @Test func anInvisibleHazardIsBadgedOnAPermissiveProviderToo() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "report\u{200B}.pdf", isDirectory: false, provider: .iCloud) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "report.pdf", isDirectory: false, provider: .iCloud) == nil)
    }

    /// Folder names are flagged too — `NameNormalizer` scans directories, and a hostile folder name
    /// breaks a sync exactly as thoroughly as a hostile file name.
    @Test func aRiskyFolderNameIsBadged() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Tax Returns ", isDirectory: true, provider: .oneDrive) != nil)
    }

    /// **The provider must be part of the cache key.** `Q3: final.pdf` is fine on iCloud and
    /// rejected by OneDrive, so asking about the same name twice under different rulesets must give
    /// two different answers. Drop the provider from `RiskyNameBadgeCache.Key` and whichever
    /// question is asked first answers both — silently, and for as long as the entry lives.
    ///
    /// Asked iCloud-first deliberately: that order caches the *permissive* answer, so the failure
    /// is a badge that never appears rather than one that appears too often. A missing badge is the
    /// failure nobody notices.
    @Test func theSameNameAnswersDifferentlyPerProvider() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .iCloud) == nil)
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .oneDrive) != nil)
    }

    /// The memo may not change any verdict, only its cost. Asks every name twice and requires the
    /// second answer to equal the first AND to equal what the unmemoized detector says.
    @Test func theMemoAnswersExactlyWhatTheDetectorDoes() {
        fresh()
        let names = ["clean.pdf", "trailing ", " leading", "colon:name", "dot.", "CON.txt",
                     "zero\u{200B}width", "nb\u{00A0}space", "café.pdf", "ordinary name.txt"]
        for provider in [CloudProvider.ProviderType.oneDrive, .iCloud, .dropBox, .googleDrive] {
            for name in names {
                let truth = NameNormalizer.risky(name: name, relativePath: name, absolutePath: name,
                                                 isDirectory: false, provider: provider)?.reason
                let first = RiskyNameBadgeCache.reason(name: name, isDirectory: false, provider: provider)
                let second = RiskyNameBadgeCache.reason(name: name, isDirectory: false, provider: provider)
                #expect(first == truth, "\(provider.rawValue) “\(name)”: memo disagreed with the detector")
                #expect(second == truth, "\(provider.rawValue) “\(name)”: second look changed the answer")
            }
        }
    }

    /// The tooltip carries the REASON, not a generic label — it is the only place the *why* is
    /// available without opening a menu.
    @Test func theReasonIsTheProvidersOwnPhrasingWhenItHasOne() {
        fresh()
        let reason = RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .oneDrive)
        #expect(reason?.contains("OneDrive") == true)
        #expect(reason?.contains(":") == true)
    }
}

/// The badge's route from the delegate to the row, and the two things that must silence it.
@MainActor
@Suite(.serialized) struct RiskyNameBadgeRoutingTests {

    /// Answers from a fixed table, so these cases test the WIRING rather than re-testing the rules.
    private struct StubDelegate: FileActionDelegate {
        var reasons: [String: String] = [:]
        var kept: Set<String> = []
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
        func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
            kept.contains(name) ? nil : reasons[name]
        }
        func isKeptName(_ name: String) -> Bool { kept.contains(name) }
        func riskyName(for node: FileNode) -> RiskyName? {
            guard let reason = reasons[node.name] else { return nil }
            return RiskyName(id: node.id, relativePath: node.name, currentName: node.name,
                             sanitizedName: "fixed", reason: reason, isDirectory: node.isDirectory)
        }
    }

    /// **Every one of these must be reachable through the EXISTENTIAL**, which is the only way any
    /// caller holds a delegate (`FileContextMenu.delegate`, `FileTreeView.delegate`).
    ///
    /// Declared in a protocol *extension* instead of the protocol *body*, these bind statically to
    /// their defaults and a conformer's implementation is never called. That is not a hypothetical:
    /// it is how `riskyName(for:)` shipped, which made "Fix name…" unreachable in the row menu from
    /// the day it was added. The type annotation below is the entire point of the test — drop it,
    /// let Swift infer `StubDelegate`, and this passes against the broken arrangement.
    @Test func theDelegatesNameAnswersSurviveTheExistential() {
        let delegate: FileActionDelegate = StubDelegate(reasons: ["Q3: final.pdf": "colon"],
                                                        kept: ["meant it "])
        let node = FileNode(id: "/root/Q3: final.pdf", name: "Q3: final.pdf",
                            isDirectory: false, children: nil)
        #expect(delegate.riskyName(for: node)?.reason == "colon",
                "riskyName(for:) bound to the extension default — “Fix name…” would never appear")
        #expect(delegate.riskyNameReason(forName: "Q3: final.pdf", isDirectory: false) == "colon",
                "riskyNameReason bound to the extension default — no row would ever badge")
        #expect(delegate.isKeptName("meant it "),
                "isKeptName bound to the extension default — a keep could never be withdrawn")
    }

    /// A delegate that has not opted in — every test double, and any pane with no provider context —
    /// reports nothing, so no surface starts badging by accident when the protocol grew.
    private struct BareDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    @Test func theDefaultDelegateBadgesNothing() {
        let delegate: FileActionDelegate = BareDelegate()
        #expect(delegate.riskyNameReason(forName: "Q3: final.pdf", isDirectory: false) == nil)
        #expect(delegate.isKeptName("Q3: final.pdf") == false)
    }

    /// Keeping a name silences the badge — the whole point of the durable state — while leaving
    /// `isKeptName` able to say WHY it went quiet, which is what lets the row menu offer the way
    /// back. A single "no reason" answer cannot distinguish the two, which is why both exist.
    @Test func aKeptNameIsSilencedButStillKnownToBeKept() {
        let delegate: FileActionDelegate = StubDelegate(
            reasons: ["kept ": "trailing space", "flagged ": "trailing space"],
            kept: ["kept "])
        #expect(delegate.riskyNameReason(forName: "kept ", isDirectory: false) == nil)
        #expect(delegate.isKeptName("kept "))
        // The neighbour with the identical hazard is untouched — a keep is about one name, not
        // about the hazard class.
        #expect(delegate.riskyNameReason(forName: "flagged ", isDirectory: false) == "trailing space")
        #expect(delegate.isKeptName("flagged ") == false)
    }

    /// The badge draws nothing at all — not an empty reserved slot — for a clean name. Unlike the
    /// cloud badge there is no late-arriving answer to hold space for, so reserving would cost
    /// every clean row in the pane a permanent gap.
    @Test func theBadgeIsEmptyForACleanName() {
        let painted = NSHostingView(rootView: RiskyNameBadge(reason: "ends with a space"))
        let blank = NSHostingView(rootView: RiskyNameBadge(reason: nil))
        painted.layoutSubtreeIfNeeded()
        blank.layoutSubtreeIfNeeded()
        #expect(blank.fittingSize.width == 0,
                "a clean name must take no width; got \(blank.fittingSize.width)")
        #expect(painted.fittingSize.width > 0,
                "a risky name must actually draw something; got \(painted.fittingSize.width)")
    }
}

/// The Differences table asks BOTH panes' rulesets, because a differences row is a copy waiting to
/// happen and the direction is the user's to flip.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct DifferencesRiskyNameRulesTests {

    @Test func distinctCollapsesAMatchedPairAndKeepsAMixedOne() {
        #expect(PaneProviderRules(left: .iCloud, right: .iCloud).distinct == [.iCloud])
        #expect(PaneProviderRules(left: .iCloud, right: .oneDrive).distinct == [.iCloud, .oneDrive])
    }

    /// The case the whole type exists for: a name iCloud stores happily and OneDrive rejects, on a
    /// row that spans both. Checking only the left would leave it unflagged on its way to the side
    /// that cannot store it.
    @Test func aNameOnlyOneSideRejectsIsStillFlagged() {
        RiskyNameBadgeCache.resetForTesting()
        let rules = PaneProviderRules(left: .iCloud, right: .oneDrive)
        let flagged = rules.distinct.contains {
            RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: $0) != nil
        }
        #expect(flagged)
        // And a name neither side objects to stays clean, so the union is not simply "always yes".
        let clean = rules.distinct.contains {
            RiskyNameBadgeCache.reason(name: "Q3 final.pdf", isDirectory: false, provider: $0) != nil
        }
        #expect(clean == false)
    }

    /// The fallback for an unresolved provider is the STRICTEST ruleset, so a pane whose provider
    /// has not loaded over-reports rather than letting a breaking name through unflagged.
    @Test func theFallbackRulesAreTheStrictest() {
        #expect(PaneProviderRules.strictest.distinct == [.oneDrive])
    }
}
