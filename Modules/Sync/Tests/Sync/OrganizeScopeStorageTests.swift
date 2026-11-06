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

    // MARK: The migration

    @Test func migratingFromStampZeroClearsAForeignStoredValue() {
        Self.withSuite("stampZero") { d in
            // No stamp, and a value under a key no released build has written: it came from
            // somewhere this code doesn't know about.
            d.set("/Users/x/Documents/SomethingElse", forKey: OrganizeScopeDefaults.pathKey)

            #expect(OrganizeScopeDefaults.migrate(defaults: d))
            #expect(d.string(forKey: OrganizeScopeDefaults.pathKey) == nil)
            #expect(d.integer(forKey: OrganizeScopeDefaults.stampKey)
                    == OrganizeScopeDefaults.currentStamp)
        }
    }

    @Test func migrationIsIdempotentAndLeavesACurrentValueAlone() {
        Self.withSuite("idempotent") { d in
            // First run stamps it.
            #expect(OrganizeScopeDefaults.migrate(defaults: d))
            // A scope the user then sets, at the current stamp.
            d.set("/Users/x/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)

            // Second and third runs must not touch it — this is called on every launch.
            #expect(!OrganizeScopeDefaults.migrate(defaults: d))
            #expect(!OrganizeScopeDefaults.migrate(defaults: d))
            #expect(d.string(forKey: OrganizeScopeDefaults.pathKey) == "/Users/x/Documents/Legal")
        }
    }

    // MARK: Reading a stored string back

    @Test func aStoredSubtreePathResolvesToThatScope() {
        Self.withSuite("storedSubtree") { d in
            OrganizeScopeDefaults.migrate(defaults: d)
            d.set("/Users/x/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)

            let scope = OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root)
            #expect(scope?.name == "Legal")
            #expect(scope?.relativePath == "Legal")
        }
    }

    @Test func aStoredEMPTYStringIsTheGlobalView() {
        Self.withSuite("storedEmpty") { d in
            d.set("", forKey: OrganizeScopeDefaults.pathKey)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root) == nil)
        }
    }

    @Test func anABSENTKeyIsTheGlobalView() {
        Self.withSuite("absent") { d in
            #expect(d.string(forKey: OrganizeScopeDefaults.pathKey) == nil)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root) == nil)
        }
    }

    @Test func aStoredPROVIDERROOTIsTheGlobalView() {
        Self.withSuite("storedRoot") { d in
            // The normalization rule, read from disk rather than through the setter: a stored root
            // must still read back as the one global view, not a second one.
            d.set(Self.root, forKey: OrganizeScopeDefaults.pathKey)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root) == nil)
        }
    }

    @Test func aScopeStoredFORANOTHERPROVIDERDegradesToGlobal() {
        Self.withSuite("otherProvider") { d in
            // Set while iCloud was showing, reopened on a Dropbox pane. Filtering every lens to
            // nothing would look broken; falling back to the whole tree is the honest answer.
            d.set("/Users/x/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: "/Users/x/Dropbox") == nil)
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
