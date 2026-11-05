import Testing
import Foundation
@testable import Settings
import Sync

/// The one-time move of stored folder positions from documents-rooted sources to account-rooted
/// ones. Each test pins a way the move can be silently wrong: a malformed rebased path doesn't
/// throw, since `PathBoundary.join` hands back the bare root for anything with a leading slash, so
/// panes just open at the top of an account, which reads as lost work rather than a bug.
@MainActor
struct RootsMigrationTests {

    // MARK: - Fixtures

    static let cloudStorage = "/Users/u/Library/CloudStorage"

    /// The providers as discovery produced them at this migration's version, with no `openAt`
    /// override applied: the input the migration is specified against. iCloud is rooted at
    /// `~/Documents` and lands on itself, as `applyAtLaunch` freezes it.
    static func discovered(_ accountFolders: [String] = ["OneDrive-Personal", "Dropbox"]) -> [CloudProvider] {
        SettingsManager.mapProviders(
            cloudStorageFolders: accountFolders.map { URL(fileURLWithPath: "\(cloudStorage)/\($0)") },
            iCloudDefaultPath: "/Users/u/Documents",
            iCloudDefaultOpenAt: "")
    }

    static func accounts(_ accountFolders: [String] = ["OneDrive-Personal", "Dropbox"]) -> CloudStorageAccounts {
        .read(accountFolders.map { URL(fileURLWithPath: "\(cloudStorage)/\($0)") })
    }

    @discardableResult
    static func migrate(_ defaults: UserDefaults,
                        accountFolders: [String] = ["OneDrive-Personal", "Dropbox"],
                        legacyOverrides: [String: String] = [:]) -> RootsMigration.Outcome {
        RootsMigration.apply(defaults: defaults,
                             accounts: accounts(accountFolders),
                             discovered: discovered(accountFolders),
                             legacyOverrides: legacyOverrides)
    }

    // MARK: - The plan

    @Test("An account with no Location override moves its stored positions down into Documents")
    func aPlainAccountGainsTheDocumentsPrefix() {
        let plan = RootsMigration.plan(discovered: Self.discovered(), legacyOverrides: [:])
        #expect(plan.prefixes["OneDrive-Personal"] == "Documents")
        #expect(plan.prefixes["Dropbox"] == "Documents")
        // Nothing to persist: the prefix is the discovered default, and an override would make an
        // untouched install look customized.
        #expect(plan.openAtOverrides.isEmpty)
        #expect(plan.rootOverrides.isEmpty)
    }

    /// An empty stored Location is no Location. `overridesByProviderId` can't filter empty values,
    /// because the landing-folder key uses `""` as a real answer, so an empty `path_override_`
    /// arrives here as a legacy root of `""`. Adopted, it would become a `root_override_` of `""`: a
    /// provider with an empty `rootPath` that no pane can open. Unlikely, but a one-shot migration
    /// gets no second try.
    @Test("An empty stored Location is treated as absent rather than as a root")
    func anEmptyLegacyOverrideIsNotAdopted() {
        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": ""])
        #expect(plan.rootOverrides.isEmpty, "an empty Location became a root override")
        #expect(plan.prefixes["OneDrive-Personal"] == "Documents",
                "the source was not planned as though it had no override at all")
        #expect(plan.openAtOverrides.isEmpty)
    }

    @Test("Google Drive's two-level default becomes a two-level prefix")
    func googleDriveGainsBothLevels() {
        let plan = RootsMigration.plan(discovered: Self.discovered(["GoogleDrive-a@b.com"]),
                                       legacyOverrides: [:])
        #expect(plan.prefixes["GoogleDrive-a@b.com"] == "My Drive/Documents")
    }

    @Test("iCloud's root does not move, so nothing of iCloud's is rebased")
    func iCloudIsUntouched() {
        let plan = RootsMigration.plan(discovered: Self.discovered(), legacyOverrides: [:])
        // Absent from `prefixes`, not present and empty: `prefixes` holds only sources that move,
        // so `prefixes.isEmpty` can mean "nothing to do". `handled` records that the source was
        // looked at, or a later pass would plan it again.
        #expect(plan.prefixes["iCloud"] == nil)
        #expect(plan.handled.contains("iCloud"))
        #expect(plan.rootRemap["/Users/u/Documents"] == nil)
    }

    @Test("A Location override inside the account becomes that source's landing folder")
    func anOverrideInsideTheAccountBecomesTheLandingFolder() {
        let plan = RootsMigration.plan(
            discovered: Self.discovered(["GoogleDrive-a@b.com"]),
            legacyOverrides: ["GoogleDrive-a@b.com": "\(Self.cloudStorage)/GoogleDrive-a@b.com/My Drive"])
        #expect(plan.prefixes["GoogleDrive-a@b.com"] == "My Drive")
        // Differs from the discovered default, so it is persisted, or the next discovery would
        // move the panes a level deeper than where they were left.
        #expect(plan.openAtOverrides["GoogleDrive-a@b.com"] == "My Drive")
    }

    @Test("A Location override outside the account becomes the root itself, and nothing is rebased")
    func anOverrideOutsideTheAccountBecomesItsOwnRoot() {
        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": "/Volumes/Backup/Work"])
        #expect(plan.rootOverrides["OneDrive-Personal"] == "/Volumes/Backup/Work")
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "")
        // No prefix: no discovered root contains that path, so none of this source's stored
        // positions are measured from anywhere that moved.
        #expect(plan.prefixes["OneDrive-Personal"] == nil)
        #expect(plan.handled.contains("OneDrive-Personal"))
        // Named keys, not `isEmpty`: the fixture's Dropbox moves normally, so the map isn't empty.
        #expect(plan.rootRemap["\(Self.cloudStorage)/OneDrive-Personal/Documents"] == nil)
        #expect(plan.rootRemap["/Volumes/Backup/Work"] == nil)
    }

    // MARK: - The stamp

    /// Measured through the tab strip, a rebased store whose entries carry a relative path.
    @Test("Running twice changes nothing the second time — App.init can run more than once")
    func theStampMakesItIdempotent() throws {
        let test = TestDefaults()
        test.defaults.set(Self.oneTab(providerId: "OneDrive-Personal", relativePath: "Family"),
                          forKey: RootsMigration.leftTabsKey)

        #expect(Self.migrate(test.defaults) != .alreadyDone)
        #expect(try Self.firstTabPath(test.defaults) == "Documents/Family")

        #expect(Self.migrate(test.defaults) == .alreadyDone)
        // A missing stamp shows as a double prefix, which points every pane at a folder that
        // doesn't exist.
        #expect(try Self.firstTabPath(test.defaults) == "Documents/Family")
    }

    @Test("An unreadable CloudStorage root defers rather than stamping a plan about nothing")
    func anUnreadableRootDefers() throws {
        let test = TestDefaults()
        test.defaults.set(Self.oneTab(providerId: "OneDrive-Personal", relativePath: "Family"),
                          forKey: RootsMigration.leftTabsKey)

        let outcome = RootsMigration.apply(defaults: test.defaults,
                                           accounts: .unreadableRoot,
                                           discovered: Self.discovered([]),
                                           legacyOverrides: [:])
        #expect(outcome == .deferred)
        #expect(try Self.firstTabPath(test.defaults) == "Family")
        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == 0)
        // And the next launch, with a readable root, still does the work.
        #expect(Self.migrate(test.defaults) != .deferred)
        #expect(try Self.firstTabPath(test.defaults) == "Documents/Family")
    }

    /// One tab strip entry, as the app stores it, for the stamp and defer cases above.
    static func oneTab(providerId: String, relativePath: String) -> String {
        """
        [{"providerId":"\(providerId)","relativePath":"\(relativePath)","stackDepth":0,"pinned":false}]
        """
    }

    /// The first stored tab's relative path, parsed rather than string-matched, because
    /// `JSONSerialization` chooses its own slash escaping.
    static func firstTabPath(_ defaults: UserDefaults) throws -> String {
        let raw = try #require(defaults.string(forKey: RootsMigration.leftTabsKey))
        let entries = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        return try #require(entries.first?["relativePath"] as? String)
    }


    // MARK: - What the CLI asks

    /// The read the CLI refuses on, which must not be just "is the stamp missing". The CLI shares
    /// the app's defaults domain, so an unmigrated legacy Location would point a scan, or a `sync`'s
    /// mass copy, at a tree the user didn't choose. It refuses rather than migrating, since the app
    /// may be running against the same domain. A fresh install is unstamped with nothing to move,
    /// and must not be refused.
    @Test("Only an unstamped domain that actually holds legacy state is reported as pending")
    func legacyStateIsReportedOnlyWhenThereIsSome() {
        let test = TestDefaults()
        let key = "\(SettingsManager.legacyPathOverrideKeyPrefix)OneDrive-Personal"

        // Unstamped and empty, a fresh install: nothing to migrate, nothing to refuse over.
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName).isEmpty)

        // Unstamped with a legacy Location: the case that reads wrong, named by source so the
        // message can name it too.
        test.defaults.set("/Volumes/Backup/Work", forKey: key)
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName) == ["OneDrive-Personal": "/Volumes/Backup/Work"])

        // After the app migrates, the key is still there (the migration never rewrites it) and the
        // CLI must stop refusing anyway. Asserting the key survives keeps that from being vacuous.
        Self.migrate(test.defaults, legacyOverrides: ["OneDrive-Personal": "/Volumes/Backup/Work"])
        #expect(test.defaults.string(forKey: key) == "/Volumes/Backup/Work")
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName).isEmpty)
    }

    // MARK: - Tabs

    @Test("Every tab moves by its own source's prefix, and unknown fields survive")
    func tabsAreRebasedPerEntryAndKeepUnknownFields() throws {
        let test = TestDefaults()
        let stored = """
        [{"providerId":"OneDrive-Personal","relativePath":"Family/Photos","stackDepth":1,"pinned":true},\
        {"providerId":"iCloud","relativePath":"Legal","stackDepth":0,"pinned":false},\
        {"providerId":"Dropbox","relativePath":"","stackDepth":0,"pinned":false,"aFieldFromAnotherBuild":7}]
        """
        test.defaults.set(stored, forKey: RootsMigration.leftTabsKey)
        Self.migrate(test.defaults)

        let raw = try #require(test.defaults.string(forKey: RootsMigration.leftTabsKey))
        let entries = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        try #require(entries.count == 3)
        #expect(entries[0]["relativePath"] as? String == "Documents/Family/Photos")
        #expect(entries[1]["relativePath"] as? String == "Legal")
        #expect(entries[2]["relativePath"] as? String == "Documents")
        // The column stack is counted from the end of the path, so prefixing must not disturb it.
        #expect(entries[0]["stackDepth"] as? Int == 1)
        #expect(entries[0]["pinned"] as? Bool == true)
        // The maintenance lines write this same strip; a Codable round-trip would drop fields this
        // build doesn't know.
        #expect(entries[2]["aFieldFromAnotherBuild"] as? Int == 7)
    }

    // MARK: - Payloads the migration must survive rather than corrupt

    /// A tab on a source the plan doesn't cover is left exactly as it is. The source may be removed,
    /// or just signed out this launch; a later launch settles it and moves the tab then, and
    /// `handledProviderIds` stops it moving twice. Prefixing on a guess would be unrecoverable.
    @Test("A tab naming a source the plan does not cover is left untouched")
    func anUnknownProviderIdOnATabIsLeftAlone() throws {
        let test = TestDefaults()
        let stored = """
        [{"providerId":"OneDrive-Personal","relativePath":"Family","stackDepth":0,"pinned":false},\
        {"providerId":"SomeSourceThatIsGone","relativePath":"Family","stackDepth":0,"pinned":false}]
        """
        test.defaults.set(stored, forKey: RootsMigration.leftTabsKey)
        Self.migrate(test.defaults)

        let raw = try #require(test.defaults.string(forKey: RootsMigration.leftTabsKey))
        let entries = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        try #require(entries.count == 2)
        #expect(entries[0]["relativePath"] as? String == "Documents/Family")
        #expect(entries[1]["relativePath"] as? String == "Family",
                "an unknown source's tab was rebased on a prefix that is not its own")
    }

    /// A tab strip stored under the wrong type is named, not skipped in silence. `PaneTabsStore`
    /// only writes strings, so this takes a hand-edited plist or a future build, but the migration
    /// is one-shot and nothing comes back for a strip it passes over. `string(forKey:)` reads a
    /// non-string as absent, so it must be reported like a garbage string.
    @Test("A strip stored under the wrong type is reported, not silently passed over")
    func aTabStripOfTheWrongTypeIsReportedAsUnreadable() {
        let test = TestDefaults()
        test.defaults.set(Data("[]".utf8), forKey: RootsMigration.leftTabsKey)
        let line = Self.migrate(test.defaults).logLine
        #expect(line?.contains(RootsMigration.leftTabsKey) == true,
                "the log line does not name the strip it could not read: \(line ?? "nil")")
    }

    /// A Favorites entry that isn't exactly `root\0relative` is carried across verbatim: with no
    /// NUL, or two, rewriting it on a guess would destroy the only copy. It also keeps its place in
    /// the order, which a `compactMap` would lose.
    @Test("A malformed Favorites entry keeps its exact bytes and its position")
    func aFavoritesEntryWithTheWrongNumberOfHalvesIsCarriedAcross() {
        let test = TestDefaults()
        let oldRoot = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        let good = "\(oldRoot)\u{0}Family"
        let noSeparator = "somethingWithNoNul"
        let twoSeparators = "a\u{0}b\u{0}c"
        test.defaults.set([noSeparator, good, twoSeparators], forKey: RootsMigration.favoriteOrderKey)
        Self.migrate(test.defaults)

        let out = test.defaults.stringArray(forKey: RootsMigration.favoriteOrderKey)
        #expect(out?.count == 3, "an entry was dropped rather than carried across")
        #expect(out?[0] == noSeparator)
        #expect(out?[2] == twoSeparators)
        // The well-formed one still moved, so this is not passing by migrating nothing.
        #expect(out?[1].hasSuffix("\u{0}Documents/Family") == true,
                "the well-formed entry did not move: \(out?[1] ?? "nil")")
    }

    /// Two accounts of the same provider type each take their own prefix. They share a type, a
    /// default `openAt` and a discovery rule and differ only by account folder, which a per-type
    /// plan would collapse. Two Google Drive accounts is an ordinary setup.
    @Test("Two accounts of one provider type are planned separately")
    func twoAccountsOfTheSameTypeEachGetTheirOwnPrefix() {
        let plan = RootsMigration.plan(
            discovered: Self.discovered(["GoogleDrive-personal", "GoogleDrive-work"]),
            legacyOverrides: ["GoogleDrive-work": "\(Self.cloudStorage)/GoogleDrive-work/My Drive"])
        // The untouched one takes the discovered default...
        #expect(plan.prefixes["GoogleDrive-personal"] == "My Drive/Documents")
        // ...while its sibling keeps the Location its owner chose, one level up.
        #expect(plan.prefixes["GoogleDrive-work"] == "My Drive")
        #expect(plan.handled.isSuperset(of: ["GoogleDrive-personal", "GoogleDrive-work"]))
    }

    // MARK: - Pins, recents and their order

    @Test("Pins and recents are re-keyed onto the new root and their paths move with them")
    func jumpFoldersMoveKeyAndValueTogether() throws {
        let test = TestDefaults()
        let oldRoot = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        let payload: [String: [[String: Any]]] = [
            oldRoot: [["relativePath": "Family", "name": "Family", "visitedAt": 12345.5]],
            "/Users/u/Documents": [["relativePath": "Legal", "name": "Legal"]],
        ]
        test.defaults.set(try JSONSerialization.data(withJSONObject: payload),
                          forKey: RootsMigration.pinnedByRootKey)
        Self.migrate(test.defaults)

        let encoded = try #require(test.defaults.data(forKey: RootsMigration.pinnedByRootKey))
        let out = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: [[String: Any]]])
        let moved = try #require(out["\(Self.cloudStorage)/OneDrive-Personal"])
        #expect(moved.first?["relativePath"] as? String == "Documents/Family")
        // The clock survives: a dropped `visitedAt` would sort every migrated recent to the end of
        // the sidebar's one global list.
        #expect(moved.first?["visitedAt"] as? Double == 12345.5)
        #expect(out[oldRoot] == nil)
        // iCloud's root did not move, so its pins are carried across untouched.
        #expect(out["/Users/u/Documents"]?.first?["relativePath"] as? String == "Legal")
    }

    @Test("The Favorites order rewrites both halves of its composite key")
    func favoriteOrderMovesRootAndPath() {
        let test = TestDefaults()
        let oldRoot = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        test.defaults.set(["\(oldRoot)\u{0}Family", "/Users/u/Documents\u{0}Legal"],
                          forKey: RootsMigration.favoriteOrderKey)
        Self.migrate(test.defaults)
        #expect(test.defaults.stringArray(forKey: RootsMigration.favoriteOrderKey) == [
            "\(Self.cloudStorage)/OneDrive-Personal\u{0}Documents/Family",
            // Untouched and kept: this list is the sequence, so dropping an entry reorders the
            // section rather than just losing a row.
            "/Users/u/Documents\u{0}Legal",
        ])
    }

    // MARK: - Filing destinations

    @Test("Filing destinations are re-keyed but their absolute paths are not touched")
    func destinationRecentsMoveKeyOnly() {
        let test = TestDefaults()
        let oldRoot = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        test.defaults.set([oldRoot: ["\(oldRoot)/Invoices/2026"]],
                          forKey: RootsMigration.destinationRecentsKey)
        Self.migrate(test.defaults)

        let out = test.defaults.dictionary(forKey: RootsMigration.destinationRecentsKey) as? [String: [String]]
        #expect(out?["\(Self.cloudStorage)/OneDrive-Personal"] == ["\(oldRoot)/Invoices/2026"])
        #expect(out?[oldRoot] == nil)
    }

    // MARK: - The shape of what comes out

    @Test("No rebased path can begin with a separator, whatever it started as")
    func rebasingCannotProduceALeadingSlash() {
        // `PathBoundary.join` returns the bare root for a relative path starting with `/`, so a
        // malformed rebase opens panes at the top of the account with nothing logged or thrown.
        for input in ["", "/", "Family", "/Family", "Family/", "//Family//Photos//"] {
            let out = RootsMigration.rebased(input, under: "Documents")
            #expect(!out.hasPrefix("/"), "\(input) rebased to \(out)")
            #expect(!out.contains("//"), "\(input) rebased to \(out)")
            #expect(out.hasPrefix("Documents"), "\(input) rebased to \(out)")
        }
        #expect(RootsMigration.rebased("Family", under: "") == "Family")
        #expect(RootsMigration.rebased("", under: "Documents") == "Documents")
    }

    @Test("The legacy Location key is never rewritten, so an older build still reads its setting")
    func theLegacyOverrideSurvivesUntouched() {
        let test = TestDefaults()
        let legacy = "\(Self.cloudStorage)/GoogleDrive-a@b.com/My Drive"
        let key = SettingsManager.legacyPathOverrideKeyPrefix + "GoogleDrive-a@b.com"
        test.defaults.set(legacy, forKey: key)

        RootsMigration.apply(defaults: test.defaults,
                             accounts: Self.accounts(["GoogleDrive-a@b.com"]),
                             discovered: Self.discovered(["GoogleDrive-a@b.com"]),
                             legacyOverrides: ["GoogleDrive-a@b.com": legacy])

        // Older release lines share this defaults domain and read this key as their Location, so
        // reinstalling one must find the settings as they were: the migration writes beside it.
        #expect(test.defaults.string(forKey: key) == legacy)
        #expect(test.defaults.string(
            forKey: SettingsManager.openAtOverrideKeyPrefix + "GoogleDrive-a@b.com") == "My Drive")
    }

    @Test("A migrated install lands exactly where it was, in absolute terms")
    func theMigratedLandingNamesTheSameFolderAsTheOldRoot() {
        let test = TestDefaults()
        let legacy = "\(Self.cloudStorage)/GoogleDrive-a@b.com/My Drive"
        Self.migrate(test.defaults, accountFolders: ["GoogleDrive-a@b.com"],
                     legacyOverrides: ["GoogleDrive-a@b.com": legacy])

        // The migration rests on this identity: root + openAt names the folder the old single path
        // named. Everything stored as an absolute path (automations, Organize's scope, caches) is
        // left alone because of it, and would be silently wrong if it broke. The ignore sets are
        // root-relative, so they are migrated (`ignoredItemsAreRebasedByTheAnchorSourcesPrefix`).
        let manager = SettingsManager(autoDiscover: false, userDefaults: test.defaults,
                                      overridesDomainName: test.suiteName,
                                      cloudStorageLister: { .read([]) },
                                      pathValidator: { _ in true })
        manager.availableProviders = SettingsManager.mapProviders(
            cloudStorageFolders: Self.accounts(["GoogleDrive-a@b.com"]).folders,
            iCloudDefaultPath: "/Users/u/Documents",
            openAtOverride: { test.defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + $0) })
        #expect(manager.landingPath(for: "GoogleDrive-a@b.com") == legacy)
    }

    // MARK: - Sources that are not mounted when this runs

    /// The `relativePath` of the first entry of a stored strip.
    ///
    /// Decoded rather than string-matched: `JSONSerialization` writes `/` as `\/`, so a raw
    /// `contains("Documents/Taxes")` fails on a correct strip. Every production reader decodes it.
    static func firstTabPath(_ defaults: UserDefaults, _ key: String) throws -> String {
        let raw = try #require(defaults.string(forKey: key))
        // One `#require` per statement: nested, the macro expands recursively and won't compile.
        let data = try #require(raw.data(using: .utf8))
        let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try #require(entries.first?["relativePath"] as? String)
    }

    @Test("A source that is signed out at migration time is picked up by a later launch, not lost")
    func anUnmountedSourceIsMigratedWhenItComesBack() throws {
        let test = TestDefaults()
        // A tab on an account that isn't mounted right now, an ordinary state.
        test.defaults.set(#"[{"providerId":"OneDrive-Work","relativePath":"Clients/Acme"}]"#,
                          forKey: RootsMigration.leftTabsKey)
        test.defaults.set(#"[{"providerId":"Dropbox","relativePath":"Taxes"}]"#,
                          forKey: RootsMigration.rightTabsKey)

        // Launch one: only Dropbox is there.
        let first = Self.migrate(test.defaults, accountFolders: ["Dropbox"])
        #expect(first != .alreadyDone)
        #expect(try Self.firstTabPath(test.defaults, RootsMigration.rightTabsKey) == "Documents/Taxes")
        // The stamp must not be set while a source the stored state names is unplanned, or the
        // account would come back later with every tab silently a level too high.
        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == 0)
        #expect(try Self.firstTabPath(test.defaults, RootsMigration.leftTabsKey) == "Clients/Acme")

        // Launch two, with the account back. Dropbox must not move a second time.
        let second = Self.migrate(test.defaults, accountFolders: ["Dropbox", "OneDrive-Work"])
        #expect(second != .alreadyDone)
        #expect(try Self.firstTabPath(test.defaults, RootsMigration.leftTabsKey)
            == "Documents/Clients/Acme")
        #expect(try Self.firstTabPath(test.defaults, RootsMigration.rightTabsKey) == "Documents/Taxes")
        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == RootsMigration.currentStamp)
    }

    /// A folder source in a pane or a tab must not hold the fast exit open forever. `outstanding`
    /// is every id the stored state mentions minus every id the plan settled, and waiting is right
    /// for a signed-out account. But `applyAtLaunch` maps only CloudStorage accounts and iCloud,
    /// since a folder source is its own root with nothing to migrate, so a selected or tabbed
    /// folder source would never be handled and the stamp never written.
    ///
    /// Silently, every launch would then pay for a `~/Library/CloudStorage` listing, and with a
    /// legacy Location the CLI would refuse permanently, since `legacyStateAwaitingMigration` gates
    /// on the stamp.
    @Test("A folder source is settled, not waited for")
    func aFolderSourceDoesNotHoldTheStampOpen() {
        let test = TestDefaults()
        let folderId = FolderSource.idPrefix + "F4008545-0F87-4E94-A355-9795214B2246"
        // A common setup: the left pane on a folder source, the right on an account, and a tab
        // strip naming the folder source too.
        test.defaults.set(folderId, forKey: RootsMigration.leftProviderKey)
        test.defaults.set("Dropbox", forKey: RootsMigration.rightProviderKey)
        test.defaults.set(Self.oneTab(providerId: folderId, relativePath: "Notes"),
                          forKey: RootsMigration.leftTabsKey)

        let outcome = Self.migrate(test.defaults, accountFolders: ["Dropbox"])

        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == RootsMigration.currentStamp,
                "the fast exit was left open by a source that will never appear in the discovered list")
        // And the folder source's stored position is untouched: it is its own root, so settling it
        // must not rebase it.
        #expect((try? Self.firstTabPath(test.defaults)) == "Notes",
                "the folder source's tab was rebased — it is its own root and did not move")
        if case .migrated(_, _, let outstanding, _) = outcome {
            #expect(!outstanding.contains(folderId),
                    "the log line tells the user it is still waiting for a folder source that is right there")
        }
    }

    @Test("An outstanding source is named in the log line, so the wait is visible rather than silent")
    func theLogLineNamesASourceItIsStillWaitingFor() {
        let test = TestDefaults()
        test.defaults.set(#"[{"providerId":"OneDrive-Work","relativePath":"Clients"}]"#,
                          forKey: RootsMigration.leftTabsKey)
        let line = Self.migrate(test.defaults, accountFolders: ["Dropbox"]).logLine
        #expect(line?.contains("OneDrive-Work") == true)
        #expect(line?.contains("Still waiting") == true)
    }

    // MARK: - The Location that was already the account folder

    @Test("A Location the user pointed AT the account folder stays at the account folder")
    func aLegacyLocationEqualToTheRootIsKeptAsTheRootLanding() {
        let account = "\(Self.cloudStorage)/OneDrive-Personal"
        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": account])
        // Otherwise the discovered default `Documents` applies and every pane and tab lands a level
        // below where the user put it. `""` is a real landing folder, so it is written.
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "")
        #expect(plan.prefixes["OneDrive-Personal"] == nil)
        #expect(plan.handled.contains("OneDrive-Personal"))
    }

    @Test("The same intent with a trailing slash reaches the same answer")
    func aTrailingSlashOnTheLegacyLocationDoesNotLeakIntoTheLandingFolder() {
        let plan = RootsMigration.plan(
            discovered: Self.discovered(),
            legacyOverrides: ["OneDrive-Personal": "\(Self.cloudStorage)/OneDrive-Personal/Reports/"])
        // `Reports/` and `Reports` would be two tabs for one folder once the value reaches a pane
        // through `openAtIfReachable`, and the slash survives every join.
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "Reports")
        #expect(plan.prefixes["OneDrive-Personal"] == "Reports")
    }

    @Test("An account folder spelled with a trailing slash is still recognised as the account folder")
    func aTrailingSlashOnARootEqualLocationIsStillTheRoot() {
        let plan = RootsMigration.plan(
            discovered: Self.discovered(),
            legacyOverrides: ["OneDrive-Personal": "\(Self.cloudStorage)/OneDrive-Personal/"])
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "")
        #expect(plan.prefixes["OneDrive-Personal"] == nil)
    }

    // MARK: - A Location aimed into another account

    @Test("A Location inside a DIFFERENT account cannot claim that account's remap key")
    func aLocationAimedAtAnotherAccountBecomesItsOwnRootInstead() throws {
        let test = TestDefaults()
        // A Location could point anywhere, so this is reachable: OneDrive-Personal aimed at
        // Dropbox's documents folder, the only way two sources name one legacy root. It doesn't
        // collide: a path inside one account folder is outside every other, so it takes the
        // no-containing-root branch, which lets `rootRemap` be an assignment rather than a merge.
        let shared = "\(Self.cloudStorage)/Dropbox/Documents"
        let pins = [shared: [["relativePath": "Invoices", "pinned": true]]]
        test.defaults.set(try JSONSerialization.data(withJSONObject: pins),
                          forKey: RootsMigration.pinnedByRootKey)

        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": shared])
        #expect(plan.rootOverrides["OneDrive-Personal"] == shared)
        #expect(plan.rootRemap[shared] == "\(Self.cloudStorage)/Dropbox")

        Self.migrate(test.defaults, legacyOverrides: ["OneDrive-Personal": shared])

        // Two statements: a nested `#require` expands recursively and won't compile.
        let encoded = try #require(test.defaults.data(forKey: RootsMigration.pinnedByRootKey))
        let out = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: [[String: Any]]])
        // The pin follows Dropbox, whose key it was. The store could never tell the two sources'
        // pins apart under that key, so OneDrive-Personal loses nothing it had.
        #expect(out["\(Self.cloudStorage)/Dropbox"]?.count == 1)
        #expect(out[shared] == nil)
    }

    // MARK: - The ignore sets

    @Test("Durable ignore entries move down with the root they are measured from")
    func ignoredItemsAreRebasedByTheAnchorSourcesPrefix() {
        let test = TestDefaults()
        let key = "ignoredItems_v1_Dropbox|OneDrive-Personal"
        test.defaults.set(["Archive/big.zip", "Scratch"], forKey: key)

        Self.migrate(test.defaults)

        // Stored pane-root-relative, so a widened root would re-point each at a different file a
        // level up, un-ignoring by accident: Sync All would act on a file the user excluded.
        #expect(test.defaults.stringArray(forKey: key)?.sorted()
            == ["Documents/Archive/big.zip", "Documents/Scratch"])
    }

    /// The prefix comes from the id the key names first, not whichever id has one:
    /// `IgnoredItemsStore` reads the entries against that first source
    /// (`FileSyncManager.ignoreAnchorIsLeft`). The two rules agree for any pair of cloud accounts,
    /// so this uses a folder source sorting ahead of an account. The folder source didn't move, so
    /// its entries are already right; "the first id with a prefix" would push them a level down
    /// into the account's `Documents`.
    @Test("An ignore set anchored on a source that did not move is left exactly as it is")
    func ignoredItemsFollowTheKeysLeadingIdEvenWhenItDidNotMove() {
        let test = TestDefaults()
        // "Aaa-folder" sorts ahead of "OneDrive-Personal", so `pairKey` names it first.
        let key = "ignoredItems_v1_Aaa-folder|OneDrive-Personal"
        test.defaults.set(["Archive/big.zip"], forKey: key)

        Self.migrate(test.defaults)

        #expect(test.defaults.stringArray(forKey: key) == ["Archive/big.zip"],
                "the entries were rebased onto the OTHER source's prefix, which is not the frame they are read in")
    }

    @Test("A pair whose roots did not move keeps its ignore entries exactly as they are")
    func ignoredItemsForAnUnmovedPairAreLeftAlone() {
        let test = TestDefaults()
        // Neither root moved (iCloud's stays, a folder source is its own), so rebasing would
        // corrupt these.
        let key = "ignoredItems_v1_iCloud|folder-abc"
        test.defaults.set(["Archive/big.zip"], forKey: key)

        Self.migrate(test.defaults)

        #expect(test.defaults.stringArray(forKey: key) == ["Archive/big.zip"])
    }

    // MARK: - What the log line claims

    @Test("A fresh install is not told its folder positions moved, because it had none")
    func nothingStoredMeansNothingMoved() {
        let test = TestDefaults()
        let line = Self.migrate(test.defaults).logLine
        // The line reports what moved, not the plan: an install with no stored state must not be
        // told its positions "moved down into" folders it never held a position in.
        #expect(line?.contains("no stored folder positions to move") == true)
        #expect(line?.contains("moved down into") == false)
    }

    @Test("A store that is present and unreadable is named, not silently skipped")
    func anUnreadableTabStripIsReported() {
        let test = TestDefaults()
        test.defaults.set("{not json", forKey: RootsMigration.leftTabsKey)
        let line = Self.migrate(test.defaults).logLine
        // Present and unreadable isn't absent: the strip stays measured from the old root and every
        // tab on it opens elsewhere, so it must be reported.
        #expect(line?.contains(RootsMigration.leftTabsKey) == true)
        #expect(line?.contains("could not be read") == true)
    }

    // MARK: - Where the keys are read from

    @Test("A Location the app's own domain does not own is not adopted as this install's")
    func applyAtLaunchReadsOnlyItsOwnPersistentDomain() {
        let test = TestDefaults()
        let legacyKey = SettingsManager.legacyPathOverrideKeyPrefix + "OneDrive-Personal"
        // The registration domain stands in for a stray NSGlobalDomain key: it answers
        // `string(forKey:)` but isn't in `persistentDomain(forName:)`, so this passes only if the
        // read is scoped. A fresh install has a nil persistent domain, exactly when a
        // `?? dictionaryRepresentation()` fallback would honour it.
        test.defaults.register(defaults: [legacyKey: "/Volumes/Elsewhere"])
        #expect(test.defaults.string(forKey: legacyKey) == "/Volumes/Elsewhere")

        RootsMigration.applyAtLaunch(defaults: test.defaults, domainName: test.suiteName,
                                     lister: { Self.accounts() })

        // Adopted, it would become a root override pinning the source at /Volumes/Elsewhere for
        // good, since the migration is that key's only writer.
        #expect(test.defaults.string(
            forKey: SettingsManager.rootOverrideKeyPrefix + "OneDrive-Personal") == nil)
        // And the ordinary move still happened, so this isn't passing by doing nothing.
        #expect(test.defaults.stringArray(forKey: RootsMigration.handledProviderIdsKey)?
            .contains("OneDrive-Personal") == true)
    }

    @Test("Filing destinations merged onto one key keep the store's own cap")
    func mergedDestinationRecentsStayWithinTheStoresLimit() {
        let test = TestDefaults()
        let old = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        let new = "\(Self.cloudStorage)/OneDrive-Personal"
        test.defaults.set([old: ["/a", "/b", "/c", "/d"], new: ["/e", "/f", "/g"]],
                          forKey: RootsMigration.destinationRecentsKey)

        Self.migrate(test.defaults)

        let merged = test.defaults.dictionary(forKey: RootsMigration.destinationRecentsKey) as? [String: [String]]
        // `DestinationRecents.load` doesn't trim on read, so an overrun merge would leave more
        // entries than the store's own writer could produce.
        #expect(merged?[new]?.count == DestinationRecents.limit)
        #expect(merged?[old] == nil)
    }
}
