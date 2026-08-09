import Testing
import Foundation
@testable import Sync

/// Organize's scope as a **persisted** value.
///
/// **Every fixture here starts from a stored string, never from the in-memory default.** That is
/// the whole point of the suite: a persisted user-arrangeable value has a failure mode invisible to
/// any test that begins at the default — the default is always self-consistent, and what breaks is
/// what a *real launch reads off disk* from an older version, another provider, or a folder that
/// has since moved. This codebase has already lost a persisted collection that way.
///
/// Each test uses its own `UserDefaults` suite so nothing here can touch the shared
/// `~/Library/Preferences` domain, which is shared with other projects on this machine.
@Suite(.serialized) struct OrganizeScopeStorageTests {

    /// A throwaway defaults suite, removed afterwards.
    static func withSuite(_ name: String, _ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "OrganizeScopeStorageTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    static let root = "/Users/x/Documents"

    // MARK: The migration

    @Test func migratingFromStampZeroClearsAForeignStoredValue() {
        Self.withSuite("stampZero") { d in
            // The state every existing install is in: no stamp, and — crucially — a value sitting
            // under a key that no released build has ever written. Anything there came from
            // somewhere this code does not know about.
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
            // The normalization rule, exercised from DISK rather than through the setter. Even if
            // some future writer stores the root, reading it back must still produce the one
            // representation of the global view rather than a second one.
            d.set(Self.root, forKey: OrganizeScopeDefaults.pathKey)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: Self.root) == nil)
        }
    }

    @Test func aScopeStoredFORANOTHERPROVIDERDegradesToGlobal() {
        Self.withSuite("otherProvider") { d in
            // The real cross-launch hazard: the scope was set while iCloud was showing, the app
            // reopened on a Dropbox pane. Filtering every lens to nothing would look like a broken
            // Organize; falling back to the whole tree is the honest answer.
            d.set("/Users/x/Documents/Legal", forKey: OrganizeScopeDefaults.pathKey)
            #expect(OrganizeScopeDefaults.scope(
                fromStored: d.string(forKey: OrganizeScopeDefaults.pathKey),
                providerRoot: "/Users/x/Dropbox") == nil)
        }
    }

    @Test func aStoredTILDEPathStillResolves() {
        Self.withSuite("storedTilde") { d in
            // Stored strings outlive the code that wrote them, and tilde-abbreviated paths are all
            // over this app's settings. An unexpanded "~/…" matches no absolute row, so the scope
            // would silently filter every lens to empty.
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
            // Write what the setter writes (`scope.path`), read it back, and land on an equal
            // scope. A round trip that quietly normalized differently on the way out than on the
            // way in would make the chip and the filter disagree after a relaunch.
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
