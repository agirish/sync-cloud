import Testing
import Foundation
@testable import Sync

/// Where Organize is aimed, and when the pane has left it.
///
/// **The precedence is the deliverable, so every case here distinguishes it from its neighbours.**
/// A fixture where the scope, the scanned root and the provider root name the same folder cannot
/// tell a three-rung chain from a one-rung one — it passes against any of them — so each rung is
/// asserted with the rungs below it set to something *different*, and the answer names which one
/// won.
@Suite struct OrganizeAimTests {

    static let root = "/Users/x/Documents"
    static let legal = "/Users/x/Documents/Legal"
    static let aditi = "/Users/x/Documents/Family/Aditi"

    static func scope(_ path: String) -> OrganizeScope {
        OrganizeScope(path: path, providerRoot: root)!
    }

    // MARK: The precedence

    @Test func theScopeOutranksTheScannedRootAndTheProviderRoot() {
        // All three set, all three different: only an answer of `legal` can come from rung 1.
        #expect(OrganizeAim.subject(scope: Self.scope(Self.legal),
                                    scannedRoot: Self.aditi,
                                    providerRoot: Self.root) == Self.legal)
    }

    @Test func theScannedRootOutranksTheProviderRoot() {
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: Self.aditi,
                                    providerRoot: Self.root) == Self.aditi)
    }

    @Test func theProviderRootIsTheSubjectWhenNothingIsScopedOrScanned() {
        // **The rung that was missing.** This used to answer nil, and a nil subject is what made
        // `paneMovedAway` false everywhere before the first scan.
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: nil, providerRoot: Self.root)
                == Self.root)
    }

    @Test func emptyStringsAreSkippedLikeAbsentOnes() {
        // Every one of these arrives from a defaults read or a settings value, where "" is the
        // ordinary absent state — a subject of "" would compare unequal to any real folder and
        // report the pane as permanently moved.
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: "", providerRoot: Self.root)
                == Self.root)
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: "", providerRoot: "") == nil)
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: nil, providerRoot: nil) == nil)
    }

    // MARK: Has the pane moved off it?

    @Test func browsingAwayFromTheProviderRootReadsAsMovedBeforeAnyScan() {
        // The reported defect, at the level the rule owns it: nothing scanned, nothing scoped, the
        // pane in a subfolder. The offer has to be available or there is no way to aim Organize
        // from its own header.
        #expect(OrganizeAim.paneMovedAway(paneFolder: Self.aditi, scope: nil, scannedRoot: nil,
                                          providerRoot: Self.root))
    }

    @Test func sittingAtTheProviderRootIsNotMoved() {
        // The other direction of the same guard, and the one that keeps the fix from drawing a
        // button in the state it should not: unscoped Organize already answers about everything.
        #expect(!OrganizeAim.paneMovedAway(paneFolder: Self.root, scope: nil, scannedRoot: nil,
                                           providerRoot: Self.root))
    }

    @Test func aPaneInsideTheScopeHasNotMoved() {
        #expect(!OrganizeAim.paneMovedAway(paneFolder: Self.legal, scope: Self.scope(Self.legal),
                                           scannedRoot: Self.aditi, providerRoot: Self.root))
    }

    @Test func aPaneAtTheRootHasMovedWhenAScopeIsSet() {
        // Not symmetric with the case above, deliberately: with a scope set, the top of the tree is
        // somewhere else, and this is how the "Organize everything" branch becomes reachable.
        #expect(OrganizeAim.paneMovedAway(paneFolder: Self.root, scope: Self.scope(Self.legal),
                                          scannedRoot: nil, providerRoot: Self.root))
    }

    @Test func aPaneMatchingTheScannedRootHasNotMoved() {
        #expect(!OrganizeAim.paneMovedAway(paneFolder: Self.aditi, scope: nil,
                                           scannedRoot: Self.aditi, providerRoot: Self.root))
    }

    @Test func noPaneFolderIsNeverMoved() {
        #expect(!OrganizeAim.paneMovedAway(paneFolder: nil, scope: nil, scannedRoot: nil,
                                           providerRoot: Self.root))
        #expect(!OrganizeAim.paneMovedAway(paneFolder: "", scope: nil, scannedRoot: nil,
                                           providerRoot: Self.root))
    }

    @Test func noSubjectAtAllIsNeverMoved() {
        // No provider configured: there is nothing to have moved away from, and an offer to point
        // Organize at a folder inside no tree is an offer to do nothing.
        #expect(!OrganizeAim.paneMovedAway(paneFolder: Self.aditi, scope: nil, scannedRoot: nil,
                                           providerRoot: nil))
    }

    // MARK: One folder, three spellings

    @Test func theComparisonSeesThroughTildesAndTrailingSlashes() {
        // The three inputs come from three different places — a persisted scope, a lens's scanned
        // root, a settings value — and only `OrganizeScope` guarantees an expanded path. A pane
        // sitting exactly on its subject must not read as moved because one side spelled it `~`.
        let home = NSHomeDirectory()
        #expect(!OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents", scope: nil,
                                           scannedRoot: "~/Documents", providerRoot: nil))
        #expect(!OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents/", scope: nil,
                                           scannedRoot: "\(home)/Documents", providerRoot: nil))
        // And it is not simply blind: a genuinely different folder still reads as moved.
        #expect(OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents/Legal", scope: nil,
                                          scannedRoot: "~/Documents", providerRoot: nil))
    }

    @Test func aSiblingWithASharedPrefixIsNotTheSameFolder() {
        // Path comparison, not string prefixing: `/a/bc` is not `/a/b`.
        #expect(OrganizeAim.paneMovedAway(paneFolder: Self.root + "/Legalese", scope: nil,
                                          scannedRoot: Self.legal, providerRoot: Self.root))
    }
}
