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

    @Test("Running twice changes nothing the second time — App.init can run more than once")
    func theStampMakesItIdempotent() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("Family", forKey: RootsMigration.leftFocusKey)
        test.defaults.set("OneDrive-Personal", forKey: RootsMigration.leftProviderKey)

        #expect(Self.migrate(test.defaults) != .alreadyDone)
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "Documents/Family")

        #expect(Self.migrate(test.defaults) == .alreadyDone)
        // The tell for a missing stamp is a DOUBLE prefix, which is exactly the shape that survives
        // a naive re-run and points every pane at a folder that does not exist.
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "Documents/Family")
    }

    @Test("An unreadable CloudStorage root defers rather than stamping a plan about nothing")
    func anUnreadableRootDefers() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("Family", forKey: RootsMigration.leftFocusKey)
        test.defaults.set("OneDrive-Personal", forKey: RootsMigration.leftProviderKey)

        let outcome = RootsMigration.apply(defaults: test.defaults,
                                           accounts: .unreadableRoot,
                                           discovered: Self.discovered([]),
                                           legacyOverrides: [:])
        #expect(outcome == .deferred)
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "Family")
        #expect(test.defaults.integer(forKey: RootsMigration.stampKey) == 0)
        // And the next launch, with a readable root, still does the work.
        #expect(Self.migrate(test.defaults) != .deferred)
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "Documents/Family")
    }

    // MARK: - Focus

    @Test("A pane sitting at its root stays at its root")
    func anEmptyFocusIsLeftAlone() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("", forKey: RootsMigration.leftFocusKey)
        test.defaults.set("OneDrive-Personal", forKey: RootsMigration.leftProviderKey)
        Self.migrate(test.defaults)
        // "" meant the documents folder before and means the account root now — but the pane is
        // re-homed on its landing folder at launch, which is the same folder. Prefixing it here
        // would fight that and pin the pane where a preference should decide.
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "")
    }

    @Test("Each pane's focus takes the prefix of the source that pane was on")
    func eachPaneUsesItsOwnSourcesPrefix() {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set("Family", forKey: RootsMigration.leftFocusKey)
        test.defaults.set("iCloud", forKey: RootsMigration.leftProviderKey)
        test.defaults.set("Invoices", forKey: RootsMigration.rightFocusKey)
        test.defaults.set("Dropbox", forKey: RootsMigration.rightProviderKey)
        Self.migrate(test.defaults)
        #expect(test.defaults.string(forKey: RootsMigration.leftFocusKey) == "Family")
        #expect(test.defaults.string(forKey: RootsMigration.rightFocusKey) == "Documents/Invoices")
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
    func ignoredItemsAreRebasedByTheLeftSourcesPrefix() {
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
