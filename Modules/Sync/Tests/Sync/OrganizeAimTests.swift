import Testing
import Foundation
@testable import Sync

/// Where Organize is aimed, and when the pane has left it.
///
/// The precedence is what this pins, so every case tells it from its neighbours: a fixture where
/// the scope, the scanned root and the provider root name the same folder passes against a
/// one-rung chain too. Each rung is asserted with the rungs below it set to something different,
/// and the answer names which one won.
@Suite struct OrganizeAimTests {

    static let root = "/Users/x/Documents"
    static let legal = "/Users/x/Documents/Legal"
    static let daughter = "/Users/x/Documents/Family/Daughter"

    static func scope(_ path: String) -> OrganizeScope {
        OrganizeScope(path: path, providerRoot: root)!
    }

    // MARK: The precedence

    @Test func theScopeOutranksTheScannedRootAndTheProviderRoot() {
        // All three set, all three different: only an answer of `legal` can come from rung 1.
        #expect(OrganizeAim.subject(scope: Self.scope(Self.legal),
                                    scannedRoot: Self.daughter,
                                    providerRoot: Self.root) == Self.legal)
    }

    @Test func theScannedRootOutranksTheProviderRoot() {
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: Self.daughter,
                                    providerRoot: Self.root) == Self.daughter)
    }

    @Test func theProviderRootIsTheSubjectWhenNothingIsScopedOrScanned() {
        // Without this rung the subject would be nil, and a nil subject makes `paneMovedAway`
        // false everywhere before the first scan.
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: nil, providerRoot: Self.root)
                == Self.root)
    }

    @Test func emptyStringsAreSkippedLikeAbsentOnes() {
        // Each of these comes from a defaults read or a settings value, where "" is the ordinary
        // absent state; a subject of "" would compare unequal to any real folder and report the
        // pane as permanently moved.
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: "", providerRoot: Self.root)
                == Self.root)
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: "", providerRoot: "") == nil)
        #expect(OrganizeAim.subject(scope: nil, scannedRoot: nil, providerRoot: nil) == nil)
    }

    // MARK: Has the pane moved off it?

    /// (label, pane folder, scope, scanned root, provider root, moved). A subfolder reads as moved
    /// before any scan, so Organize can be aimed from its header; with a scope set the root has
    /// moved, which is how "Organize everything" becomes reachable; with no subject nothing has.
    static let movedAwayCases: [(String, String?, String?, String?, String?, Bool)] = [
        ("a subfolder before any scan",    daughter,          nil,   nil,      root, true),
        ("the provider root",              root,              nil,   nil,      root, false),
        ("inside the scope",               legal,             legal, daughter, root, false),
        ("the root, with a scope set",     root,              legal, nil,      root, true),
        ("the scanned root",               daughter,          nil,   daughter, root, false),
        ("no pane folder",                 nil,               nil,   nil,      root, false),
        ("an empty pane folder",           "",                nil,   nil,      root, false),
        ("no subject at all",              daughter,          nil,   nil,      nil,  false),
        // Path comparison, not string prefixing: `/a/bc` isn't `/a/b`.
        ("a sibling sharing a prefix",     root + "/Legalese", nil,  legal,    root, true),
    ]

    @Test(arguments: movedAwayCases)
    func paneMovedAway(label: String, paneFolder: String?, scope: String?, scannedRoot: String?,
                       providerRoot: String?, moved: Bool) {
        #expect(OrganizeAim.paneMovedAway(paneFolder: paneFolder, scope: scope.map { Self.scope($0) },
                                          scannedRoot: scannedRoot, providerRoot: providerRoot) == moved,
                "\(label)")
    }

    // MARK: One folder, three spellings

    @Test func theComparisonSeesThroughTildesAndTrailingSlashes() {
        // The three inputs come from three places (a persisted scope, a lens's scanned root, a
        // settings value), and only `OrganizeScope` guarantees an expanded path. A pane sitting on
        // its subject must not read as moved because one side spelled it `~`.
        let home = NSHomeDirectory()
        #expect(!OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents", scope: nil,
                                           scannedRoot: "~/Documents", providerRoot: nil))
        #expect(!OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents/", scope: nil,
                                           scannedRoot: "\(home)/Documents", providerRoot: nil))
        // And it isn't simply blind: a different folder still reads as moved.
        #expect(OrganizeAim.paneMovedAway(paneFolder: "\(home)/Documents/Legal", scope: nil,
                                          scannedRoot: "~/Documents", providerRoot: nil))
    }
}
