import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// The row badge's predicate: which names earn a mark, which don't, and what the memo may change
/// about the answer (nothing). Every assertion names its exact string: a test that only counted
/// badges would pass against a predicate that flagged the wrong file.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgePredicateTests {

    /// The memo is process-wide, so one case's answers must not decide another's, and the
    /// provider-keying test below means nothing if an earlier case filled the table.
    private func fresh() { RiskyNameBadgeCache.resetForTesting() }

    /// A name OneDrive will reject earns a badge; its cleaned-up twin doesn't. The pair matters: the
    /// positive alone passes against a predicate that returns non-nil for everything.
    @Test func aTrailingSpaceIsBadgedAndTheSameNameWithoutOneIsNot() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Statement 2026 ", isDirectory: false, provider: .oneDrive) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "Statement 2026", isDirectory: false, provider: .oneDrive) == nil)
    }

    @Test func aForbiddenCharacterIsBadgedAndAnOrdinaryNameIsNot() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .oneDrive) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "Q3 final.pdf", isDirectory: false, provider: .oneDrive) == nil)
        #expect(RiskyNameBadgeCache.reason(name: "Q3 final.pdf", isDirectory: false, provider: .iCloud) == nil)
    }

    /// A zero-width character is invisible, so the badge is the only thing that can report it.
    /// Flagged for every provider, permissive ones included, because it is a cross-cloud hazard
    /// rather than any one provider's rule.
    @Test func anInvisibleHazardIsBadgedOnAPermissiveProviderToo() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "report\u{200B}.pdf", isDirectory: false, provider: .iCloud) != nil)
        #expect(RiskyNameBadgeCache.reason(name: "report.pdf", isDirectory: false, provider: .iCloud) == nil)
    }

    /// Folder names are flagged too: `NameNormalizer` scans directories, and a hostile folder name
    /// breaks a sync as thoroughly as a hostile file name.
    @Test func aRiskyFolderNameIsBadged() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Tax Returns ", isDirectory: true, provider: .oneDrive) != nil)
    }

    /// The provider must be part of the cache key. `Q3: final.pdf` is fine on iCloud and rejected
    /// by OneDrive; without the provider in `RiskyNameBadgeCache.Key`, whichever question is asked
    /// first silently answers both for as long as the entry lives.
    ///
    /// Asked iCloud-first on purpose: that caches the permissive answer, so the failure is a badge
    /// that never appears, the failure nobody notices.
    @Test func theSameNameAnswersDifferentlyPerProvider() {
        fresh()
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .iCloud) == nil)
        #expect(RiskyNameBadgeCache.reason(name: "Q3: final.pdf", isDirectory: false, provider: .oneDrive) != nil)
    }

    /// The memo may change no verdict, only its cost: every name is asked twice, and both answers
    /// must equal what the unmemoized detector says.
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

    /// The tooltip carries the reason, not a generic label: it is the only place the why is
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

    /// Answers from a fixed table, so these cases test the wiring rather than the rules.
    private struct StubDelegate: NoOpFileActions {
        var reasons: [String: String] = [:]
        var kept: Set<String> = []
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

    /// Each of these must be reachable through the existential, the only way any caller holds a
    /// delegate (`FileContextMenu.delegate`, `FileTreeView.delegate`).
    ///
    /// Declared only in a protocol extension instead of the protocol body, they bind statically to
    /// their defaults and a conformer's implementation is never called (for `riskyName(for:)`, that
    /// makes "Fix name" unreachable in the row menu). The type annotation below is the point of the
    /// test: let Swift infer `StubDelegate` and this passes against the broken arrangement.
    @Test func theDelegatesNameAnswersSurviveTheExistential() {
        let delegate: FileActionDelegate = StubDelegate(reasons: ["Q3: final.pdf": "colon"],
                                                        kept: ["meant it "])
        let node = FileNode(id: "/root/Q3: final.pdf", name: "Q3: final.pdf",
                            isDirectory: false, children: nil)
        #expect(delegate.riskyName(for: node)?.reason == "colon",
                "riskyName(for:) bound to the extension default — “Fix name” would never appear")
        #expect(delegate.riskyNameReason(forName: "Q3: final.pdf", isDirectory: false) == "colon",
                "riskyNameReason bound to the extension default — no row would ever badge")
        #expect(delegate.isKeptName("meant it "),
                "isKeptName bound to the extension default — a keep could never be withdrawn")
    }

    /// A delegate that hasn't opted in (every test double, and any pane with no provider context)
    /// reports nothing, so no surface badges by accident.
    @Test func theDefaultDelegateBadgesNothing() {
        let delegate: FileActionDelegate = NoOpFileActionDelegate()
        #expect(delegate.riskyNameReason(forName: "Q3: final.pdf", isDirectory: false) == nil)
        #expect(delegate.isKeptName("Q3: final.pdf") == false)
    }

    /// Keeping a name silences the badge, while `isKeptName` can still say why it went quiet, which
    /// lets the row menu offer the way back. A single "no reason" answer can't tell the two apart.
    @Test func aKeptNameIsSilencedButStillKnownToBeKept() {
        let delegate: FileActionDelegate = StubDelegate(
            reasons: ["kept ": "trailing space", "flagged ": "trailing space"],
            kept: ["kept "])
        #expect(delegate.riskyNameReason(forName: "kept ", isDirectory: false) == nil)
        #expect(delegate.isKeptName("kept "))
        // The neighbour with the identical hazard is untouched: a keep is about one name, not the
        // hazard class.
        #expect(delegate.riskyNameReason(forName: "flagged ", isDirectory: false) == "trailing space")
        #expect(delegate.isKeptName("flagged ") == false)
    }

    /// The badge draws nothing at all for a clean name, not an empty reserved slot. Unlike the
    /// cloud badge there is no late answer to hold space for, so reserving would give every clean
    /// row a permanent gap.
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

/// The Differences table asks both panes' rulesets, because a differences row is a copy waiting to
/// happen and the direction is the user's to flip.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct DifferencesRiskyNameRulesTests {

    /// A mixed pair keeps both rulesets: the case the type exists for is a name iCloud stores and
    /// OneDrive rejects (`Q3: final.pdf`, pinned per provider above), which checking only the left
    /// would leave unflagged on its way to the side that can't store it.
    @Test func distinctCollapsesAMatchedPairAndKeepsAMixedOne() {
        #expect(PaneProviderRules(left: .iCloud, right: .iCloud).distinct == [.iCloud])
        #expect(PaneProviderRules(left: .iCloud, right: .oneDrive).distinct == [.iCloud, .oneDrive])
    }

    /// The fallback for an unresolved provider is the strictest ruleset, so a pane whose provider
    /// hasn't loaded over-reports rather than letting a breaking name through.
    @Test func theFallbackRulesAreTheStrictest() {
        #expect(PaneProviderRules.strictest.distinct == [.oneDrive])
    }
}
