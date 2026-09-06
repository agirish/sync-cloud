import Testing
import Foundation
@testable import Settings
import Sync

/// **The v5.3 move of iCloud's root from `~/Documents` up to the iCloud Drive container**, and what
/// happens to everything stored relative to the old root.
///
/// The same silent failure the first migration's tests describe applies: a rebased path that comes
/// out wrong does not throw, it opens a pane at the top of the account and reads as lost work. The
/// new hazards are this move's own — a Mac whose iCloud Drive does not link `Documents` in at all,
/// where the old root is not in the cloud and must be KEPT rather than moved; and the stored
/// landing override, which is measured from the old root and has to gain the prefix too.
@MainActor
struct ICloudRootMoveTests {

    static let oldRoot = "/Users/u/Documents"
    static let newRoot = "/Users/u/Library/Mobile Documents/com~apple~CloudDocs"
    /// The container as Desktop & Documents syncing leaves it.
    static let linked: PathBoundary.LinkedFolders = [newRoot: ["Documents": oldRoot, "Desktop": "/Users/u/Desktop"]]

    static func plan(rootOverride: String? = nil, legacyPathOverride: String? = nil,
                     openAtOverride: String? = nil,
                     links: PathBoundary.LinkedFolders = linked) -> RootsMigration.ICloudRootMovePlan {
        RootsMigration.iCloudRootMovePlan(oldRoot: oldRoot, newRoot: newRoot,
                                          rootOverride: rootOverride, legacyPathOverride: legacyPathOverride,
                                          openAtOverride: openAtOverride, links: links)
    }

    @discardableResult
    static func move(_ defaults: UserDefaults, links: PathBoundary.LinkedFolders = linked) -> RootsMigration.ICloudRootMoveOutcome {
        RootsMigration.moveICloudRoot(defaults: defaults, domainName: nil,
                                      oldRoot: oldRoot, newRoot: newRoot, links: links)
    }

    // MARK: - The plan

    @Test("With Documents linked in, every stored position gains the link's name")
    func aLinkedDocumentsMovesEverythingDownIntoIt() {
        let planned = Self.plan()
        #expect(planned.decision == .move(prefix: "Documents"))
        #expect(planned.plan.prefixes["iCloud"] == "Documents")
        #expect(planned.plan.rootRemap[Self.oldRoot] == Self.newRoot)
        // The prefix IS the discovered landing default, so nothing is persisted for it.
        #expect(planned.plan.openAtOverrides.isEmpty)
        #expect(planned.plan.rootOverrides.isEmpty)
    }

    @Test("A stored landing override was measured from the old root and gains the prefix too")
    func aLandingOverrideIsRebased() {
        #expect(Self.plan(openAtOverride: "Family").plan.openAtOverrides["iCloud"] == "Documents/Family")
        // `""` is a real stored value — the root — and under the new root it would land at the
        // container. It becomes the folder it named.
        #expect(Self.plan(openAtOverride: "").plan.openAtOverrides["iCloud"] == "Documents")
    }

    @Test("Without the link, ~/Documents is not in iCloud: the old root is kept as an override")
    func noLinkKeepsTheOldRootAsAnOverride() {
        let planned = Self.plan(links: [:])
        #expect(planned.decision == .keepOldRootAsOverride)
        #expect(planned.plan.rootOverrides["iCloud"] == Self.oldRoot)
        // The discovered landing is Documents now; under the kept root that is a folder that is
        // not there. The old default — the root — is written so the new one cannot apply.
        #expect(planned.plan.openAtOverrides["iCloud"] == "")
        #expect(planned.plan.prefixes.isEmpty)
        #expect(planned.plan.rootRemap.isEmpty)
        // A landing the user chose under the kept root is kept with it.
        #expect(Self.plan(openAtOverride: "Family", links: [:]).plan.openAtOverrides["iCloud"] == "Family")
    }

    @Test("A root that is already a stored override is not moving, so nothing is rebased")
    func aRootOverrideIsLeftAlone() {
        let planned = Self.plan(rootOverride: "/Volumes/Backup/Docs")
        #expect(planned.decision == .leaveAlone(reason: "its root is a stored override"))
        #expect(planned.plan.prefixes.isEmpty)
        #expect(planned.plan.rootOverrides.isEmpty)
        #expect(planned.plan.openAtOverrides.isEmpty)
    }

    /// The first migration may not have settled a hand-typed Location yet (an unreadable
    /// CloudStorage defers it, not this). One that names `~/Documents` is no override at all and
    /// the move proceeds; any other is the root it will be pinned to, and nothing here moves.
    @Test("A legacy Location is an override only when it names somewhere else")
    func aLegacyLocationElsewhereIsLeftForTheFirstMigration() {
        #expect(Self.plan(legacyPathOverride: "/Volumes/Backup/Docs").decision
                == .leaveAlone(reason: "its Location was set by hand and stays as the root"))
        #expect(Self.plan(legacyPathOverride: "/Users/u/Documents/").decision == .move(prefix: "Documents"))
        #expect(Self.plan(legacyPathOverride: "").decision == .move(prefix: "Documents"))
    }

    // MARK: - The stores

    @Test("Both tab strips, pins, the Favorites order and filing destinations move together")
    func theStoresAreRebased() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let d = test.defaults
        d.set(RootsMigrationTests.oneTab(providerId: "iCloud", relativePath: "Family"),
              forKey: RootsMigration.leftTabsKey)
        d.set(RootsMigrationTests.oneTab(providerId: "Dropbox", relativePath: "Documents/Work"),
              forKey: RootsMigration.rightTabsKey)
        let pins: [String: [[String: Any]]] = [
            Self.oldRoot: [["relativePath": "Legal", "name": "Legal", "visitedAt": 5.5]],
            "/Users/u/Library/CloudStorage/Dropbox": [["relativePath": "Documents/Work", "name": "Work"]],
        ]
        d.set(try JSONSerialization.data(withJSONObject: pins), forKey: RootsMigration.pinnedByRootKey)
        d.set(["\(Self.oldRoot)\u{0}Legal", "/Users/u/Library/CloudStorage/Dropbox\u{0}Documents/Work"],
              forKey: RootsMigration.favoriteOrderKey)
        d.set([Self.oldRoot: ["/Users/u/Documents/Inbox"]], forKey: RootsMigration.destinationRecentsKey)

        let outcome = Self.move(d)
        #expect(outcome == .moved(prefix: "Documents", moved: 4, unreadable: []))

        #expect(try RootsMigrationTests.firstTabPath(d) == "Documents/Family")
        // The other strip names another source, and it is untouched.
        #expect(try RootsMigrationTests.firstTabPath(d, RootsMigration.rightTabsKey) == "Documents/Work")

        let encoded = try #require(d.data(forKey: RootsMigration.pinnedByRootKey))
        let out = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: [[String: Any]]])
        #expect(out[Self.newRoot]?.first?["relativePath"] as? String == "Documents/Legal")
        #expect(out[Self.newRoot]?.first?["visitedAt"] as? Double == 5.5)
        #expect(out[Self.oldRoot] == nil)
        #expect(out["/Users/u/Library/CloudStorage/Dropbox"]?.first?["relativePath"] as? String == "Documents/Work")

        #expect(d.stringArray(forKey: RootsMigration.favoriteOrderKey)
                == ["\(Self.newRoot)\u{0}Documents/Legal", "/Users/u/Library/CloudStorage/Dropbox\u{0}Documents/Work"])
        // Absolute values stay; only the key they are filed under moves.
        #expect(d.dictionary(forKey: RootsMigration.destinationRecentsKey) as? [String: [String]]
                == [Self.newRoot: ["/Users/u/Documents/Inbox"]])
        #expect(d.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "iCloud") == nil)
        #expect(d.string(forKey: SettingsManager.rootOverrideKeyPrefix + "iCloud") == nil)
    }

    @Test("A stored landing override is rewritten on disk")
    func theLandingOverrideIsWritten() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("Family", forKey: SettingsManager.openAtOverrideKeyPrefix + "iCloud")
        Self.move(test.defaults)
        #expect(test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "iCloud") == "Documents/Family")
    }

    @Test("Without the link, the root override is written and no position moves")
    func noLinkWritesTheRootOverride() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let d = test.defaults
        d.set(RootsMigrationTests.oneTab(providerId: "iCloud", relativePath: "Family"),
              forKey: RootsMigration.leftTabsKey)
        #expect(Self.move(d, links: [:]) == .keptAtDocuments)
        #expect(d.string(forKey: SettingsManager.rootOverrideKeyPrefix + "iCloud") == Self.oldRoot)
        #expect(d.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "iCloud") == "")
        #expect(try RootsMigrationTests.firstTabPath(d) == "Family")
    }

    @Test("Running twice changes nothing the second time — App.init can run more than once")
    func theStampMakesItIdempotent() throws {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set(RootsMigrationTests.oneTab(providerId: "iCloud", relativePath: "Family"),
                          forKey: RootsMigration.leftTabsKey)
        #expect(Self.move(test.defaults) != .alreadyDone)
        #expect(try RootsMigrationTests.firstTabPath(test.defaults) == "Documents/Family")
        #expect(Self.move(test.defaults) == .alreadyDone)
        #expect(try RootsMigrationTests.firstTabPath(test.defaults) == "Documents/Family",
                "a second pass prepended a second prefix")
        #expect(test.defaults.integer(forKey: RootsMigration.iCloudRootMoveStampKey) == 1)
    }

    /// The two migrations, in the order the app runs them, against an install from before either:
    /// the first leaves iCloud where it found it, the second moves it — once.
    @Test("After the first migration's frozen mapping, the second moves iCloud exactly once")
    func theTwoMigrationsCompose() throws {
        let test = TestDefaults(); defer { test.wipe() }
        let d = test.defaults
        d.set(RootsMigrationTests.oneTab(providerId: "iCloud", relativePath: "Family"),
              forKey: RootsMigration.leftTabsKey)
        d.set(RootsMigrationTests.oneTab(providerId: "OneDrive-Personal", relativePath: "Work"),
              forKey: RootsMigration.rightTabsKey)

        RootsMigrationTests.migrate(d)
        #expect(try RootsMigrationTests.firstTabPath(d) == "Family", "the first migration moved iCloud")
        #expect(try RootsMigrationTests.firstTabPath(d, RootsMigration.rightTabsKey) == "Documents/Work")

        Self.move(d)
        #expect(try RootsMigrationTests.firstTabPath(d) == "Documents/Family")
        #expect(try RootsMigrationTests.firstTabPath(d, RootsMigration.rightTabsKey) == "Documents/Work")
    }

    @Test("The log line says what moved, and stays quiet once settled")
    func theLogLine() {
        #expect(RootsMigration.ICloudRootMoveOutcome.alreadyDone.logLine == nil)
        let moved = RootsMigration.ICloudRootMoveOutcome.moved(prefix: "Documents", moved: 3, unreadable: []).logLine
        #expect(moved?.contains("3 stored folder positions moved down into Documents") == true)
        #expect(RootsMigration.ICloudRootMoveOutcome.keptAtDocuments.logLine?.contains("Reset") == true)
    }
}
