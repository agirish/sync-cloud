import Testing
import Foundation
@testable import Sync

/// Organize's scope as a persisted value. Every fixture starts from a stored string, never the
/// in-memory default: the default is always self-consistent, and what breaks is what a real launch
/// reads off disk from an older version, another provider, or a folder that has since moved.
///
/// Each test uses its own `UserDefaults` suite, so nothing here touches the shared
/// `~/Library/Preferences` domain.
@Suite(.serialized) struct OrganizeScopeStorageTests {

    /// A throwaway defaults suite: fresh, so it starts empty, and removed — plist too — afterwards.
    static func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        try body(ScratchDefaults("OrganizeScopeStorageTests.\(name)"))
    }

    static let root = "/Users/x/Documents"

    // MARK: Reading a stored string back

    @Test func aStoredSubtreePathResolvesToThatScope() {
        Self.withSuite("storedSubtree") { d in
            d.set("/Users/x/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)

            let scope = OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root)
            #expect(scope?.name == "Legal")
            #expect(scope?.relativePath == "Legal")
        }
    }

    /// Each reads back as the one global view: a stored EMPTY string; an ABSENT key; a stored
    /// PROVIDER ROOT (the normalization rule, read from disk rather than through the setter, must
    /// not make a second global view); and a scope stored FOR ANOTHER PROVIDER (set while iCloud
    /// was showing, reopened on a Dropbox pane: filtering every lens to nothing would look broken,
    /// and the whole tree is the honest answer).
    @Test(arguments: [
        ("storedEmpty", "", "/Users/x/Documents"),
        ("absent", nil, "/Users/x/Documents"),
        ("storedRoot", "/Users/x/Documents", "/Users/x/Documents"),
        ("otherProvider", "/Users/x/Documents/Legal", "/Users/x/Dropbox"),
    ] as [(String, String?, String)])
    func aStoredValueReadsAsTheGlobalView(suite: String, stored: String?, providerRoot: String) {
        Self.withSuite(suite) { d in
            if let stored { d.set(stored, forKey: OrganizeScopeDefaults.pathKey) }
            #expect(d.string(forKey: OrganizeScopeDefaults.pathKey) == stored)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: providerRoot) == nil)
        }
    }

    @Test func aStoredTILDEPathStillResolves() {
        Self.withSuite("storedTilde") { d in
            // Tilde paths are common in this app's settings. An unexpanded "~/…" matches no
            // absolute row, so the scope would silently filter every lens to empty.
            let home = NSHomeDirectory()
            let root = (home as NSString).appendingPathComponent("Documents")
            d.set("~/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)

            let scope = OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey), providerRoot: root)
            #expect(scope?.name == "Legal")
            #expect(scope?.contains((root as NSString)
                .appendingPathComponent("Legal/case.pdf")) == true)
        }
    }

    @Test func theStoredValueRoundTripsThroughAResolvedScope() {
        Self.withSuite("roundTrip") { d in
            // Write what the setter writes (`scope.path`) and read back an equal scope, or the chip
            // and the filter disagree after a relaunch.
            let original = OrganizeScope(path: "/Users/x/Documents/Finance/US",
                                         providerRoot: Self.root)!
            d.set(original.path, forKey: OrganizeScopeDefaults.pathKey)
            let reread = OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root)
            #expect(reread == original)
        }
    }
}
