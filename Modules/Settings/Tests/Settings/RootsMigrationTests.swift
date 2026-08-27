import Testing
import Foundation
@testable import Settings
import Sync

/// The one-time move of stored folder positions from documents-rooted sources to account-rooted
/// ones.
///
/// Every test here fixes a specific way the move can be silently wrong. "Silently" is the operative
/// word: a rebased path that comes out malformed does not throw — `PathBoundary.join` hands back
/// the bare root for anything with a leading slash, so the whole failure mode is *panes quietly
/// opening at the top of an account*, which reads as lost work rather than as a bug.
@MainActor
struct RootsMigrationTests {

    // MARK: - Fixtures

    static let cloudStorage = "/Users/u/Library/CloudStorage"

    /// The providers as discovery produces them, with no `openAt` override applied — the input the
    /// migration is specified against.
    static func discovered(_ accountFolders: [String] = ["OneDrive-Personal", "Dropbox"]) -> [CloudProvider] {
        SettingsManager.mapProviders(
            cloudStorageFolders: accountFolders.map { URL(fileURLWithPath: "\(cloudStorage)/\($0)") },
            iCloudDefaultPath: "/Users/u/Documents")
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
        // Nothing to persist: the prefix IS the discovered default, so writing an override would
        // make an untouched install look customized and leave Reset with nothing to reset.
        #expect(plan.openAtOverrides.isEmpty)
        #expect(plan.rootOverrides.isEmpty)
    }

    /// **An empty stored Location is no Location, and the consequence of reading it as one is a
    /// source with no root at all.**
    ///
    /// `overridesByProviderId` deliberately does not filter empty values — it cannot, because the
    /// landing-folder key uses `""` as a real answer — so an empty `path_override_` arrives here as
    /// a legacy root of `""`. That relativizes under nothing, takes the "somewhere else entirely"
    /// branch, and is written back out as a `root_override_` of `""`: a provider whose `rootPath`
    /// is empty, which Settings shows as invalid and which no pane can open. Old builds cleared the
    /// key rather than storing an empty string, so this guards a shape that should not exist — and
    /// a one-shot migration is the worst place to discover that it does.
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
        // Absent from `prefixes`, not present-and-empty: `prefixes` carries only the sources that
        // actually move, so `prefixes.isEmpty` can mean "nothing to do". `handled` is what says the
        // source was looked at — and it has to say so, or a later pass would plan it again.
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
        // Differs from the discovered default, so it IS persisted — otherwise the next discovery
        // would move this user's panes a level deeper than where they left them.
        #expect(plan.openAtOverrides["GoogleDrive-a@b.com"] == "My Drive")
    }

    @Test("A Location override outside the account becomes the root itself, and nothing is rebased")
    func anOverrideOutsideTheAccountBecomesItsOwnRoot() {
        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": "/Volumes/Backup/Work"])
        #expect(plan.rootOverrides["OneDrive-Personal"] == "/Volumes/Backup/Work")
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "")
        // No prefix: there is no discovered root containing that path, so no stored position of
        // this source is measured from anywhere that moved.
        #expect(plan.prefixes["OneDrive-Personal"] == nil)
        #expect(plan.handled.contains("OneDrive-Personal"))
        // Named specifically rather than asserting the whole map is empty — the fixture also has a
        // Dropbox, whose root moves normally, and an `isEmpty` here would pass only by accident of
        // which providers the fixture happens to carry.
        #expect(plan.rootRemap["\(Self.cloudStorage)/OneDrive-Personal/Documents"] == nil)
        #expect(plan.rootRemap["/Volumes/Backup/Work"] == nil)
    }

    // MARK: - The stamp

    /// Measured through the tab strip, which is the store this used to check through the
    /// per-pane focus path — a key the app stopped reading, so the migration stopped moving it.
    /// Any rebased store answers this; the strip is the one whose entries carry a relative path.
    @Test("Running twice changes nothing the second time — App.init can run more than once")
    func theStampMakesItIdempotent() throws {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set(Self.oneTab(providerId: "OneDrive-Personal", relativePath: "Family"),
                          forKey: RootsMigration.leftTabsKey)

        #expect(Self.migrate(test.defaults) != .alreadyDone)
        #expect(try Self.firstTabPath(test.defaults) == "Documents/Family")

        #expect(Self.migrate(test.defaults) == .alreadyDone)
        // The tell for a missing stamp is a DOUBLE prefix, which is exactly the shape that survives
        // a naive re-run and points every pane at a folder that does not exist.
        #expect(try Self.firstTabPath(test.defaults) == "Documents/Family")
    }

    @Test("An unreadable CloudStorage root defers rather than stamping a plan about nothing")
    func anUnreadableRootDefers() throws {
        let test = TestDefaults(); defer { test.wipe() }
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

    /// One tab strip entry, as the app stores it — the vehicle for the stamp and defer cases above.
    static func oneTab(providerId: String, relativePath: String) -> String {
        """
        [{"providerId":"\(providerId)","relativePath":"\(relativePath)","stackDepth":0,"pinned":false}]
        """
    }

    /// The first stored tab's relative path, parsed rather than string-matched: `JSONSerialization`
    /// decides its own slash escaping, and a `contains` over the raw string would be asserting that
    /// choice instead of the path.
    static func firstTabPath(_ defaults: UserDefaults) throws -> String {
        let raw = try #require(defaults.string(forKey: RootsMigration.leftTabsKey))
        let entries = try #require(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        return try #require(entries.first?["relativePath"] as? String)
    }


    // MARK: - What the CLI asks

    /// **The read the CLI refuses on, and it must not be "is the stamp missing".**
    ///
    /// The CLI shares the app's defaults domain, so an un-migrated legacy Location reads under the
    /// new meaning and points a scan — or a `sync`'s mass copy — at a different tree than the user
    /// chose. It refuses rather than migrating, because migrating from a terminal would rewrite tab
    /// strips and pins possibly while the app is running against the same domain.
    ///
    /// The narrowness is the part with teeth: a fresh install is unstamped and has nothing to move,
    /// and answering "pending" there would refuse every CLI run on a machine that has no problem.
    @Test("Only an unstamped domain that actually holds legacy state is reported as pending")
    func legacyStateIsReportedOnlyWhenThereIsSome() {
        let test = TestDefaults(); defer { test.wipe() }
        let key = "\(SettingsManager.legacyPathOverrideKeyPrefix)OneDrive-Personal"

        // Unstamped and empty — a fresh install. Nothing to migrate, so nothing to refuse over.
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName).isEmpty)

        // Unstamped WITH a legacy Location: this is the case that reads wrong, and it names the
        // source so the message can too.
        test.defaults.set("/Volumes/Backup/Work", forKey: key)
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName) == ["OneDrive-Personal": "/Volumes/Backup/Work"])

        // Once the app has migrated, the same key is still there — the migration is additive and
        // deliberately never rewrites it — and the CLI must stop refusing anyway. Asserting the key
        // survives is what makes that a real claim rather than a tautology.
        Self.migrate(test.defaults, legacyOverrides: ["OneDrive-Personal": "/Volumes/Backup/Work"])
        #expect(test.defaults.string(forKey: key) == "/Volumes/Backup/Work")
        #expect(RootsMigration.legacyStateAwaitingMigration(
            defaults: test.defaults, domainName: test.suiteName).isEmpty)
    }

    // MARK: - Tabs

    @Test("Every tab moves by its own source's prefix, and unknown fields survive")
    func tabsAreRebasedPerEntryAndKeepUnknownFields() throws {
        let test = TestDefaults(); defer { test.wipe() }
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
        // The column stack is counted from the END of the path, so prefixing must not disturb it.
        #expect(entries[0]["stackDepth"] as? Int == 1)
        #expect(entries[0]["pinned"] as? Bool == true)
        // The maintenance lines write this same strip. A Codable round-trip would have dropped
        // whatever they know that this build does not.
        #expect(entries[2]["aFieldFromAnotherBuild"] as? Int == 7)
    }

    // MARK: - Payloads the migration must survive rather than corrupt

    /// **A tab on a source the plan says nothing about is left exactly as it is.**
    ///
    /// An id can be unknown for two reasons that look identical here: the source was removed from
    /// Settings, or it is signed out and this launch could not see it. The second is why leaving the
    /// entry alone is the only safe answer — a later launch settles that source and moves this tab
    /// then, and `handledProviderIds` is what stops it moving twice. Prefixing an unknown id now
    /// would be unrecoverable, since nothing records that it was guessed.
    @Test("A tab naming a source the plan does not cover is left untouched")
    func anUnknownProviderIdOnATabIsLeftAlone() throws {
        let test = TestDefaults(); defer { test.wipe() }
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

    /// A tab strip present under the wrong TYPE is named, not skipped in silence.
    ///
    /// `PaneTabsStore` only ever writes a string, so this arrives from a build that does not exist
    /// yet or a hand-edited plist — but the answer matters more than the odds, because the
    /// migration is one-shot: a strip it passes over is a strip nothing will ever come back for.
    /// A garbage STRING was already reported through `unreadable`; a non-string value fell through
    /// `string(forKey:)` and read as absent, which is the one outcome that says nothing at all.
    @Test("A strip stored under the wrong type is reported, not silently passed over")
    func aTabStripOfTheWrongTypeIsReportedAsUnreadable() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set(Data("[]".utf8), forKey: RootsMigration.leftTabsKey)
        let line = Self.migrate(test.defaults).logLine
        #expect(line?.contains(RootsMigration.leftTabsKey) == true,
                "the log line does not name the strip it could not read: \(line ?? "nil")")
    }

    /// A Favorites entry that is not exactly `root\0relative` is carried across verbatim.
    ///
    /// The separator is a NUL, so an entry with none — or with two — is not a shape this code can
    /// reason about, and rewriting it on a guess would destroy the only copy. Every malformed
    /// entry keeps its place in the order, which is the half a `compactMap` would quietly lose.
    @Test("A malformed Favorites entry keeps its exact bytes and its position")
    func aFavoritesEntryWithTheWrongNumberOfHalvesIsCarriedAcross() {
        let test = TestDefaults(); defer { test.wipe() }
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

    /// Two accounts of the SAME provider type each take their own prefix.
    ///
    /// They share a type, a default `openAt` and a discovery rule, and differ only by account
    /// folder — which is exactly the shape a per-type rather than per-source plan would collapse.
    /// This developer runs two Google Drive accounts, so it is the ordinary case here, not an edge.
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
        let test = TestDefaults(); defer { test.wipe() }
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
        // The clock survives: a dropped `visitedAt` would silently sort every migrated recent to
        // the end of the sidebar's one global list.
        #expect(moved.first?["visitedAt"] as? Double == 12345.5)
        #expect(out[oldRoot] == nil)
        // iCloud's root did not move, so its pins are carried across untouched.
        #expect(out["/Users/u/Documents"]?.first?["relativePath"] as? String == "Legal")
    }

    @Test("The Favorites order rewrites both halves of its composite key")
    func favoriteOrderMovesRootAndPath() {
        let test = TestDefaults(); defer { test.wipe() }
        let oldRoot = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        test.defaults.set(["\(oldRoot)\u{0}Family", "/Users/u/Documents\u{0}Legal"],
                          forKey: RootsMigration.favoriteOrderKey)
        Self.migrate(test.defaults)
        #expect(test.defaults.stringArray(forKey: RootsMigration.favoriteOrderKey) == [
            "\(Self.cloudStorage)/OneDrive-Personal\u{0}Documents/Family",
            // Untouched, and KEPT: this list is the sequence, so dropping an entry reorders the
            // section rather than merely losing one row.
            "/Users/u/Documents\u{0}Legal",
        ])
    }

    // MARK: - Filing destinations

    @Test("Filing destinations are re-keyed but their absolute paths are not touched")
    func destinationRecentsMoveKeyOnly() {
        let test = TestDefaults(); defer { test.wipe() }
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
        // The failure this guards is invisible at the call site: `PathBoundary.join` returns the
        // bare root for a relative path starting with `/`, so a malformed rebase opens every
        // affected pane at the top of the account with nothing logged and nothing thrown.
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
        let test = TestDefaults(); defer { test.wipe() }
        let legacy = "\(Self.cloudStorage)/GoogleDrive-a@b.com/My Drive"
        let key = SettingsManager.legacyPathOverrideKeyPrefix + "GoogleDrive-a@b.com"
        test.defaults.set(legacy, forKey: key)

        RootsMigration.apply(defaults: test.defaults,
                             accounts: Self.accounts(["GoogleDrive-a@b.com"]),
                             discovered: Self.discovered(["GoogleDrive-a@b.com"]),
                             legacyOverrides: ["GoogleDrive-a@b.com": legacy])

        // v3.x and v2.x share this defaults domain and read this key as their Location. Someone who
        // tries this build and reinstalls the last release must find their settings as they left
        // them — so the migration reads it and writes beside it, never over it.
        #expect(test.defaults.string(forKey: key) == legacy)
        #expect(test.defaults.string(
            forKey: SettingsManager.openAtOverrideKeyPrefix + "GoogleDrive-a@b.com") == "My Drive")
    }

    @Test("A migrated install lands exactly where it was, in absolute terms")
    func theMigratedLandingNamesTheSameFolderAsTheOldRoot() {
        let test = TestDefaults(); defer { test.wipe() }
        let legacy = "\(Self.cloudStorage)/GoogleDrive-a@b.com/My Drive"
        Self.migrate(test.defaults, accountFolders: ["GoogleDrive-a@b.com"],
                     legacyOverrides: ["GoogleDrive-a@b.com": legacy])

        // The whole migration rests on this identity: root + openAt names the folder the old single
        // path named. Everything stored as an ABSOLUTE path — automations, Organize's scope, every
        // cache — is left alone precisely because of it, so if this ever stops holding, those are
        // all silently wrong and nothing here would say so. (The ignore sets are NOT in that list:
        // they are stored root-RELATIVE, which is why they are migrated. See
        // `ignoredItemsAreRebasedByTheLeftSourcesPrefix`.)
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
    /// Decoded rather than string-matched: `JSONSerialization` writes `/` as `\/`, so a
    /// `contains("Documents/Taxes")` on the raw string is false for a strip that is perfectly
    /// correct. (Harmless in production — every reader here is a JSON decoder, which unescapes it.)
    static func firstTabPath(_ defaults: UserDefaults, _ key: String) throws -> String {
        let raw = try #require(defaults.string(forKey: key))
        // One `#require` per statement — nested, the macro expands recursively and does not compile.
        let data = try #require(raw.data(using: .utf8))
        let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try #require(entries.first?["relativePath"] as? String)
    }

    @Test("A source that is signed out at migration time is picked up by a later launch, not lost")
    func anUnmountedSourceIsMigratedWhenItComesBack() throws {
        let test = TestDefaults(); defer { test.wipe() }
        // A tab on an account that is not mounted right now — an ordinary state, not an exotic one.
        test.defaults.set(#"[{"providerId":"OneDrive-Work","relativePath":"Clients/Acme"}]"#,
                          forKey: RootsMigration.leftTabsKey)
        test.defaults.set(#"[{"providerId":"Dropbox","relativePath":"Taxes"}]"#,
                          forKey: RootsMigration.rightTabsKey)

        // Launch one: only Dropbox is there.
        let first = Self.migrate(test.defaults, accountFolders: ["Dropbox"])
        #expect(first != .alreadyDone)
        #expect(try Self.firstTabPath(test.defaults, RootsMigration.rightTabsKey) == "Documents/Taxes")
        // The tell for the bug this replaced: the stamp must NOT be set while a source the stored
        // state names has never been planned. Setting it made the loss permanent — the account came
        // back a week later and every one of its tabs was a level too high, silently.
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

    /// **A folder source in a pane or a tab must not hold the fast exit open forever.**
    ///
    /// `outstanding` is "every id the stored state mentions, minus every id this plan settled", and
    /// the wait it implies is right for an account that is signed out — it will be there on some
    /// later launch. A folder source will not: `applyAtLaunch` maps only the CloudStorage accounts
    /// and iCloud, deliberately, because a folder source is its own root and always was and there
    /// is nothing about it to migrate. So its id can never enter `handled`, while
    /// `referencedProviderIds` picks it straight out of `selectedLeftProviderId` and the tab
    /// strips — and the stamp is then never written on any install that has one selected or tabbed,
    /// which is an entirely ordinary configuration.
    ///
    /// Two things go wrong and neither says anything. The launch pays for a `~/Library/CloudStorage`
    /// listing every single time, forever, which is the one cost the stamp exists to buy off. And
    /// `legacyStateAwaitingMigration` gates on the stamp, so a machine that also carries a legacy
    /// Location has its CLI refuse **permanently**, telling the user to launch the app to migrate —
    /// which they have, and which can never clear it.
    @Test("A folder source is settled, not waited for")
    func aFolderSourceDoesNotHoldTheStampOpen() {
        let test = TestDefaults(); defer { test.wipe() }
        let folderId = FolderSource.idPrefix + "F4008545-0F87-4E94-A355-9795214B2246"
        // Exactly the shape this developer's own install is in: the left pane on a folder source,
        // the right on an account, and a tab strip naming the folder source too.
        test.defaults.set(folderId, forKey: RootsMigration.leftProviderKey)
        test.defaults.set("Dropbox", forKey: RootsMigration.rightProviderKey)
        test.defaults.set(Self.oneTab(providerId: folderId, relativePath: "Notes"),
                          forKey: RootsMigration.leftTabsKey)

        let outcome = Self.migrate(test.defaults, accountFolders: ["Dropbox"])

        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == RootsMigration.currentStamp,
                "the fast exit was left open by a source that will never appear in the discovered list")
        // And the folder source's own stored position is untouched: it is its own root, and the
        // migration has nothing to say about it. A "settled" that quietly rebased it would be a
        // worse bug than the one above.
        #expect((try? Self.firstTabPath(test.defaults)) == "Notes",
                "the folder source's tab was rebased — it is its own root and did not move")
        if case .migrated(_, _, let outstanding, _) = outcome {
            #expect(!outstanding.contains(folderId),
                    "the log line tells the user it is still waiting for a folder source that is right there")
        }
    }

    @Test("An outstanding source is named in the log line, so the wait is visible rather than silent")
    func theLogLineNamesASourceItIsStillWaitingFor() {
        let test = TestDefaults(); defer { test.wipe() }
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
        // Without this the discovered default `Documents` applies and every pane, tab and new tab
        // lands a level BELOW where the user deliberately put themselves — reading as "the app
        // forgot my setting". `""` is a real landing folder, so it is written rather than skipped.
        #expect(plan.openAtOverrides["OneDrive-Personal"] == "")
        #expect(plan.prefixes["OneDrive-Personal"] == nil)
        #expect(plan.handled.contains("OneDrive-Personal"))
    }

    @Test("The same intent with a trailing slash reaches the same answer")
    func aTrailingSlashOnTheLegacyLocationDoesNotLeakIntoTheLandingFolder() {
        let plan = RootsMigration.plan(
            discovered: Self.discovered(),
            legacyOverrides: ["OneDrive-Personal": "\(Self.cloudStorage)/OneDrive-Personal/Reports/"])
        // `Reports/` and `Reports` are two different tabs for one folder once the value rides out
        // through `openAtIfReachable` into a pane's focus — and the slash survives every join.
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
        let test = TestDefaults(); defer { test.wipe() }
        // Re-pointing an account's Location was deliberately unrestricted, so this is reachable:
        // OneDrive-Personal aimed at Dropbox's documents folder. It is also the only shape in which
        // two sources could ever name one legacy root — and it does NOT collide, because a path
        // inside one account folder is outside every other, so it takes the no-containing-root
        // branch. That is what makes `rootRemap` an assignment rather than a merge.
        let shared = "\(Self.cloudStorage)/Dropbox/Documents"
        let pins = [shared: [["relativePath": "Invoices", "pinned": true]]]
        test.defaults.set(try JSONSerialization.data(withJSONObject: pins),
                          forKey: RootsMigration.pinnedByRootKey)

        let plan = RootsMigration.plan(discovered: Self.discovered(),
                                       legacyOverrides: ["OneDrive-Personal": shared])
        #expect(plan.rootOverrides["OneDrive-Personal"] == shared)
        #expect(plan.rootRemap[shared] == "\(Self.cloudStorage)/Dropbox")

        Self.migrate(test.defaults, legacyOverrides: ["OneDrive-Personal": shared])

        // Two statements: a `#require` nested inside another expands recursively and the compiler
        // rejects it outright.
        let encoded = try #require(test.defaults.data(forKey: RootsMigration.pinnedByRootKey))
        let out = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: [[String: Any]]])
        // The pin follows Dropbox, whose key it genuinely was. OneDrive-Personal shared that key
        // before this change too — the store has never been able to tell the two apart — so this
        // takes nothing away that the split created.
        #expect(out["\(Self.cloudStorage)/Dropbox"]?.count == 1)
        #expect(out[shared] == nil)
    }

    // MARK: - The ignore sets

    @Test("Durable ignore entries move down with the root they are measured from")
    func ignoredItemsAreRebasedByTheAnchorSourcesPrefix() {
        let test = TestDefaults(); defer { test.wipe() }
        let key = "ignoredItems_v1_Dropbox|OneDrive-Personal"
        test.defaults.set(["Archive/big.zip", "Scratch"], forKey: key)

        Self.migrate(test.defaults)

        // These are stored PANE-ROOT-relative, so a widened root silently re-points every one of
        // them at a different file one level up. The bad direction is un-ignoring by accident:
        // Sync All then acts on a file the user deliberately excluded.
        #expect(test.defaults.stringArray(forKey: key)?.sorted()
            == ["Documents/Archive/big.zip", "Documents/Scratch"])
    }

    /// **The prefix comes from the id the key names FIRST, not from whichever id happens to have
    /// one** — because that first id is the source `IgnoredItemsStore` quotes these entries
    /// against (`FileSyncManager.ignoreAnchorIsLeft`), and a migration that moves them into any
    /// other frame writes strings the app will read against a root they were never rebased onto.
    ///
    /// The two rules agree for every pair of cloud accounts, which is why the distinction needs a
    /// pair where they do not: a folder source sorting ahead of an account. The folder source is
    /// its own root and did not move, so its coordinate system is unchanged and the entries are
    /// already right — while "the first id that HAS a prefix" would find the account's `Documents`
    /// and push every entry a level down into a folder the anchor knows nothing about.
    @Test("An ignore set anchored on a source that did not move is left exactly as it is")
    func ignoredItemsFollowTheKeysLeadingIdEvenWhenItDidNotMove() {
        let test = TestDefaults(); defer { test.wipe() }
        // "Aaa-folder" sorts ahead of "OneDrive-Personal", so it is what `pairKey` names first.
        let key = "ignoredItems_v1_Aaa-folder|OneDrive-Personal"
        test.defaults.set(["Archive/big.zip"], forKey: key)

        Self.migrate(test.defaults)

        #expect(test.defaults.stringArray(forKey: key) == ["Archive/big.zip"],
                "the entries were rebased onto the OTHER source's prefix, which is not the frame they are read in")
    }

    @Test("A pair whose roots did not move keeps its ignore entries exactly as they are")
    func ignoredItemsForAnUnmovedPairAreLeftAlone() {
        let test = TestDefaults(); defer { test.wipe() }
        // iCloud's root did not move and a folder source is its own root, so nothing in this pair's
        // coordinate system changed — rebasing would be the corruption here.
        let key = "ignoredItems_v1_iCloud|folder-abc"
        test.defaults.set(["Archive/big.zip"], forKey: key)

        Self.migrate(test.defaults)

        #expect(test.defaults.stringArray(forKey: key) == ["Archive/big.zip"])
    }

    // MARK: - What the log line claims

    @Test("A fresh install is not told its folder positions moved, because it had none")
    func nothingStoredMeansNothingMoved() {
        let test = TestDefaults(); defer { test.wipe() }
        let line = Self.migrate(test.defaults).logLine
        // The first draft described the PLAN, so an install with no stored state at all announced
        // that its positions "were moved down into (Dropbox → Documents, …)" — naming folders it
        // had never held a position in. A count the reader can check is the point of the line.
        #expect(line?.contains("no stored folder positions to move") == true)
        #expect(line?.contains("moved down into") == false)
    }

    @Test("A store that is present and unreadable is named, not silently skipped")
    func anUnreadableTabStripIsReported() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("{not json", forKey: RootsMigration.leftTabsKey)
        let line = Self.migrate(test.defaults).logLine
        // Present-and-unreadable is not the same as absent, and it is the case that loses data in
        // silence: the strip stays measured from the old root and every tab on it opens elsewhere.
        #expect(line?.contains(RootsMigration.leftTabsKey) == true)
        #expect(line?.contains("could not be read") == true)
    }

    // MARK: - Where the keys are read from

    @Test("A Location the app's own domain does not own is not adopted as this install's")
    func applyAtLaunchReadsOnlyItsOwnPersistentDomain() {
        let test = TestDefaults(); defer { test.wipe() }
        let legacyKey = SettingsManager.legacyPathOverrideKeyPrefix + "OneDrive-Personal"
        // The registration domain is the honest stand-in for a stray NSGlobalDomain key: it is in
        // `dictionaryRepresentation()` and answers `string(forKey:)`, and it is NOT in
        // `persistentDomain(forName:)`. So this passes only if the read is scoped — and a fresh
        // install, whose persistent domain is nil, is exactly when a `?? dictionaryRepresentation()`
        // fallback would honour it.
        test.defaults.register(defaults: [legacyKey: "/Volumes/Elsewhere"])
        #expect(test.defaults.string(forKey: legacyKey) == "/Volumes/Elsewhere")

        RootsMigration.applyAtLaunch(defaults: test.defaults, domainName: test.suiteName,
                                     lister: { Self.accounts() })

        // Adopted, it would have become a root override pinning the source at /Volumes/Elsewhere —
        // permanently, since the migration is the only writer of that key.
        #expect(test.defaults.string(
            forKey: SettingsManager.rootOverrideKeyPrefix + "OneDrive-Personal") == nil)
        // And the ordinary discovered move still happened, so this is not passing by doing nothing.
        #expect(test.defaults.stringArray(forKey: RootsMigration.handledProviderIdsKey)?
            .contains("OneDrive-Personal") == true)
    }

    @Test("Filing destinations merged onto one key keep the store's own cap")
    func mergedDestinationRecentsStayWithinTheStoresLimit() {
        let test = TestDefaults(); defer { test.wipe() }
        let old = "\(Self.cloudStorage)/OneDrive-Personal/Documents"
        let new = "\(Self.cloudStorage)/OneDrive-Personal"
        test.defaults.set([old: ["/a", "/b", "/c", "/d"], new: ["/e", "/f", "/g"]],
                          forKey: RootsMigration.destinationRecentsKey)

        Self.migrate(test.defaults)

        let merged = test.defaults.dictionary(forKey: RootsMigration.destinationRecentsKey) as? [String: [String]]
        // `DestinationRecents.load` does not trim on read, so a merge that overran the cap would
        // leave more entries than the store's own writer could ever produce.
        #expect(merged?[new]?.count == DestinationRecents.limit)
        #expect(merged?[old] == nil)
    }
}
