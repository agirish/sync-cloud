import Testing
import AppKit
import AppIntents
import Events
import Settings
import Sync
@testable import SyncCloud

// Keep an explicit AppIntents symbol reference so metadata extraction sees the framework dependency.
private let _syncCloudTestsAppIntentsDependency: Any.Type = (any AppIntent).self

@Suite struct SyncCloudTests {

    /// The pure quit decision (the NSAlert branch itself isn't unit-testable). No active
    /// operations means an unconditional, silent terminate — no breadcrumb is needed.
    @Test func testQuitDecisionAllowsWhenNoActiveOperations() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true)
            == .allowNoActiveOperations)
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: false)
            == .allowNoActiveOperations)
    }

    /// Active operations with the warning disabled skips the alert but still quits — the app
    /// delegate logs the quit-with-operations breadcrumb (worded for the setting, not the dialog
    /// nobody saw) and flushes on this branch so it survives.
    @Test func testQuitDecisionAllowsWithoutWarningWhenSettingDisabled() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 3, warnBeforeQuit: false)
            == .allowWithoutWarning(activeOperations: 3))
    }

    /// Active operations with the warning enabled must route to the alert, carrying the count
    /// through so the logged decision names how many operations were in flight.
    @Test func testQuitDecisionWarnsWhenActiveOperationsAndWarningEnabled() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 5, warnBeforeQuit: true)
            == .warn(activeOperations: 5))
    }

    /// SwiftUI may re-run `App.init`, creating a throwaway `FileSyncManager` that `@StateObject`
    /// discards. Adopting that orphan would leave the quit guard watching an operation count
    /// that is always zero, so only the first adopted manager may stick.
    @MainActor
    @Test func testQuitGuardKeepsFirstManagerAcrossAppReinit() async throws {
        SyncCloudAppDelegate.sharedSyncManager = nil
        let delegate = SyncCloudAppDelegate()
        let liveManager = FileSyncManager()
        let orphan = FileSyncManager()

        delegate.adoptSyncManager(liveManager)
        delegate.adoptSyncManager(orphan) // a re-run App.init offers its throwaway manager

        #expect(delegate.syncManager === liveManager)
        #expect(SyncCloudAppDelegate.sharedSyncManager === liveManager)
    }

    @MainActor
    @Test func testProviderSwitchStateReset() async throws {
        let manager = FileSyncManager()
        
        // 1. Simulate active state
        manager.selectedLeftPaths = ["/src/a.txt"]
        manager.selectedRightPaths = ["/dst/b.txt"]
        manager.leftRelativePath = "subfolder"
        manager.rightRelativePath = "otherfolder"

        // 2. This simulates what the ContentView .onChange(of: leftProviderId) does
        manager.selectedLeftPaths = []
        manager.leftRelativePath = ""
        manager.resetNavigation()
        
        // 3. Verify specifically the navigation reset effects
        #expect(manager.selectedLeftPaths.isEmpty)
        #expect(manager.leftRelativePath.isEmpty)
        #expect(manager.leftHistory == PaneNavigationHistory())
        #expect(manager.rightHistory == PaneNavigationHistory())
    }

    @Test func testResolvedProviderSelectionPrefersDistinctDestinationDuringBootstrap() async throws {
        let providers = [
            CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", rootPath: "/iCloud", type: .iCloud),
            CloudProvider(id: "oneDrive", displayName: "OneDrive", imageName: "onedrive", rootPath: "/oneDrive", type: .oneDrive)
        ]

        let resolved = ContentView.resolvedProviderSelection(
            providers: providers,
            currentLeftId: "iCloud",
            currentRightId: "iCloud",
            preferDistinctPair: true
        )

        #expect(resolved?.leftId == "iCloud")
        #expect(resolved?.rightId == "oneDrive")
    }

    @Test func testResolvedProviderSelectionPreservesExplicitSameProviderOutsideBootstrap() async throws {
        let providers = [
            CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", rootPath: "/iCloud", type: .iCloud),
            CloudProvider(id: "oneDrive", displayName: "OneDrive", imageName: "onedrive", rootPath: "/oneDrive", type: .oneDrive)
        ]

        let resolved = ContentView.resolvedProviderSelection(
            providers: providers,
            currentLeftId: "iCloud",
            currentRightId: "iCloud",
            preferDistinctPair: false
        )

        #expect(resolved?.leftId == "iCloud")
        #expect(resolved?.rightId == "iCloud")
    }

    // MARK: Settings-driven rescan gating

    private func provider(_ id: String, path: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "icloud", rootPath: path, type: .iCloud)
    }

    @Test func testUnrelatedProviderChangeDoesNotRequirePaneRefresh() {
        // Toggling or re-pathing a provider neither pane shows must not rescan —
        // that spurious rescan put spinners over both panes on unrelated edits.
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b"), provider("OneDrive", path: "/c")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]

        #expect(!ContentView.paneProvidersChanged(old: old, new: new, leftId: "iCloud", rightId: "Dropbox"))
    }

    @Test func testPaneProviderPathEditRequiresPaneRefresh() {
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/elsewhere")]

        #expect(ContentView.paneProvidersChanged(old: old, new: new, leftId: "iCloud", rightId: "Dropbox"))
    }

    @Test func testPaneProviderRenameIsANoOpForPaneRefresh() {
        // Renaming a provider in Settings (setCustomName) changes only displayName.
        // That must NOT read as a pane-provider change: it used to trip the
        // .comparisonRootEdited teardown — dropping an in-flight duplicate review with
        // no restore — and force a full rescan for a purely cosmetic edit.
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]
        let new = [
            CloudProvider(id: "iCloud", displayName: "My Renamed iCloud", imageName: "icloud", rootPath: "/a", type: .iCloud),
            provider("Dropbox", path: "/b")
        ]

        #expect(!ContentView.paneProvidersChanged(old: old, new: new, leftId: "iCloud", rightId: "Dropbox"))
    }

    @Test func testPaneProviderAppearingOrVanishingRequiresPaneRefresh() {
        let old = [provider("iCloud", path: "/a")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]

        // A pane pointing at a provider that just became enabled must load it.
        #expect(ContentView.paneProvidersChanged(old: old, new: new, leftId: "iCloud", rightId: "Dropbox"))
    }

    // MARK: Collision prompt wording (file vs. folder, and where-from/where-to)

    private static func collision(isMove: Bool = false, isDirectory: Bool = false) -> FileCollision {
        FileCollision(
            sourcePath: "/LeftRoot/Documents/item.txt",
            destinationPath: "/RightRoot/Documents/item.txt",
            isMove: isMove,
            isDirectory: isDirectory
        )
    }

    @Test func testFolderCollisionPromptWarnsAboutWholesaleReplacement() {
        // A folder collision must warn that Replace trashes the whole existing folder — the
        // file wording ("replace it with the one you're …") does not convey that data loss.
        let fileText = SyncOperationAlerts.collisionInformativeText(Self.collision(isDirectory: false))
        let folderText = SyncOperationAlerts.collisionInformativeText(Self.collision(isDirectory: true))

        #expect(fileText != folderText)
        #expect(!fileText.contains("entire contents"))
        #expect(folderText.contains("Replacing a folder replaces its entire contents"))
        #expect(folderText.contains("moved to the Trash"))
        // The folder warning ADDS to the base replace question; it must not displace it
        // (this pins the copy+folder combination, which no verb test covers).
        #expect(folderText.contains("Do you want to replace it with the one you're copying?"))
    }

    @Test func testCollisionPromptReflectsMoveVsCopyVerb() {
        // The verb still tracks the operation, independent of the folder warning.
        #expect(SyncOperationAlerts.collisionInformativeText(Self.collision(isMove: true)).contains("moving"))
        #expect(SyncOperationAlerts.collisionInformativeText(Self.collision(isMove: false)).contains("copying"))
        #expect(SyncOperationAlerts.collisionInformativeText(Self.collision(isMove: true, isDirectory: true)).contains("moving"))
    }

    @Test func testCollisionPromptNamesBothLocations() {
        // The message line's "this location" is ambiguous in a two-pane app; the body must say
        // which item is coming in and which existing item would be replaced, for both verbs.
        let copyText = SyncOperationAlerts.collisionInformativeText(Self.collision(isMove: false))
        #expect(copyText.contains("Copying: /LeftRoot/Documents/item.txt"))
        #expect(copyText.contains("Replacing: /RightRoot/Documents/item.txt"))

        let moveText = SyncOperationAlerts.collisionInformativeText(Self.collision(isMove: true))
        #expect(moveText.contains("Moving: /LeftRoot/Documents/item.txt"))
        #expect(moveText.contains("Replacing: /RightRoot/Documents/item.txt"))
    }

    // MARK: Transfer confirmation wording

    @Test func testTransferConfirmationMessageSingleVsBulkAndVerb() {
        let single = TransferSummary(isMove: false, itemCount: 1, firstItemName: "Resume.docx", sourceDirectory: "/Left/Documents", destinationDirectory: "/Right/Documents")
        #expect(SyncOperationAlerts.transferConfirmationMessage(single) == "Copy \"Resume.docx\" to \"Documents\"?")

        let bulk = TransferSummary(isMove: true, itemCount: 3, firstItemName: "Resume.docx", sourceDirectory: "/Left/Documents", destinationDirectory: "/Right/Documents")
        #expect(SyncOperationAlerts.transferConfirmationMessage(bulk) == "Move 3 items to \"Documents\"?")
    }

    @Test func testTransferConfirmationBodyNamesBothFolders() {
        let summary = TransferSummary(isMove: false, itemCount: 2, firstItemName: "a.txt", sourceDirectory: "/Left/Documents", destinationDirectory: "/Right/Documents")
        let body = SyncOperationAlerts.transferConfirmationInformativeText(summary)
        #expect(body == "From: /Left/Documents\nTo: /Right/Documents")
    }

    @Test func testMoveConfirmationStatesTheRemoval() {
        // Copy and move dialogs otherwise differ by one verb; a move must state its
        // destructive half (the sentence the retired NativeAlerts.confirmMove carried).
        let single = TransferSummary(isMove: true, itemCount: 1, firstItemName: "a.txt", sourceDirectory: "/L", destinationDirectory: "/R")
        #expect(SyncOperationAlerts.transferConfirmationInformativeText(single)
            .hasSuffix("The item will be removed from the original location."))

        let bulk = TransferSummary(isMove: true, itemCount: 3, firstItemName: "a.txt", sourceDirectory: "/L", destinationDirectory: "/R")
        #expect(SyncOperationAlerts.transferConfirmationInformativeText(bulk)
            .hasSuffix("The items will be removed from the original location."))

        // Copies must NOT carry the removal sentence.
        let copy = TransferSummary(isMove: false, itemCount: 1, firstItemName: "a.txt", sourceDirectory: "/L", destinationDirectory: "/R")
        #expect(!SyncOperationAlerts.transferConfirmationInformativeText(copy).contains("removed"))
    }

    @Test func testDisplayPathAbbreviatesHome() {
        let home = NSHomeDirectory()
        #expect(SyncOperationAlerts.displayPath("\(home)/Documents") == "~/Documents")
        #expect(SyncOperationAlerts.displayPath("/Volumes/External/x") == "/Volumes/External/x")
    }

    // MARK: Collision-resolver wiring (Settings policy → the two manager seams)
    //
    // `ConflictPolicyTests` (Sync) covers the policy function; these pin the app-side wiring it
    // hangs off — that BOTH seams consult it, that folder collisions still reach the prompt, and
    // that it is re-read per collision. A dropped wiring or an inverted directory gate replaces
    // the user's files with no prompt at all, and nothing on the Sync side can catch it. The
    // prompts are recorded rather than shown; a policy answer must never reach them.

    /// A prompt recorder standing in for the NSAlert. Its sentinel answers are deliberately
    /// distinguishable from every policy answer's "apply to all" flag, so a test can tell which
    /// side produced a resolution even when the resolution itself matches.
    @MainActor
    private final class PromptSpy {
        var singleCalls: [FileCollision] = []
        var bulkCalls: [FileCollision] = []
        var single: @MainActor (FileCollision) -> CollisionResolution {
            { collision in self.singleCalls.append(collision); return .keepBoth }
        }
        var bulk: @MainActor (FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) {
            { collision in self.bulkCalls.append(collision); return (.keepBoth, true) }
        }
    }

    @MainActor
    private func wiredManager(policy: ConflictPolicy?, defaults: UserDefaults, spy: PromptSpy) -> FileSyncManager {
        if let policy {
            defaults.set(policy.rawValue, forKey: ConflictPolicy.defaultsKey)
        } else {
            defaults.removeObject(forKey: ConflictPolicy.defaultsKey)
        }
        let manager = FileSyncManager()
        SyncCloudApp.wireCollisionResolvers(into: manager, defaults: defaults,
                                            prompt: spy.single, bulkPrompt: spy.bulk)
        return manager
    }

    @MainActor
    @Test func testBothCollisionSeamsAreWiredToTheStandingPolicy() throws {
        let test = TestDefaults()
        defer { test.wipe() }

        for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
            let spy = PromptSpy()
            let manager = wiredManager(policy: policy, defaults: test.defaults, spy: spy)
            let expected = try #require(policy.autoResolution(isDirectory: false))

            // Unwired, each seam keeps Sync's fail-safe default (skip / (skip, false)), so a
            // dropped wiring shows up as the wrong answer for every policy but `.skip`.
            #expect(manager.collisionResolver(Self.collision()) == expected)
            let bulk = manager.bulkCollisionResolver(Self.collision())
            #expect(bulk.resolution == expected)
            // A standing policy already applies to every collision, so "apply to all" is moot —
            // and `true` here is the spy's sentinel, i.e. proof the prompt was reached.
            #expect(bulk.applyToAll == false)

            #expect(spy.singleCalls.isEmpty)
            #expect(spy.bulkCalls.isEmpty)
        }
    }

    @MainActor
    @Test func testFolderCollisionsStillPromptUnderEveryAutoPolicy() {
        let test = TestDefaults()
        defer { test.wipe() }

        // Replacing a folder trashes everything in it, including items that exist ONLY there, so
        // no standing policy may automate it away. An inverted `isDirectory` gate would answer
        // these from the policy — the single most destructive silent failure in the app.
        for policy in [ConflictPolicy.replace, .skip, .keepBoth] {
            let spy = PromptSpy()
            let manager = wiredManager(policy: policy, defaults: test.defaults, spy: spy)

            #expect(manager.collisionResolver(Self.collision(isDirectory: true)) == .keepBoth)
            #expect(spy.singleCalls.count == 1)

            let bulk = manager.bulkCollisionResolver(Self.collision(isDirectory: true))
            #expect(bulk.resolution == .keepBoth)
            #expect(bulk.applyToAll)   // the spy's sentinel: this came from the prompt, not the policy
            #expect(spy.bulkCalls.count == 1)
        }
    }

    @MainActor
    @Test func testAskPolicyAlwaysReachesThePrompt() {
        let test = TestDefaults()
        defer { test.wipe() }
        let spy = PromptSpy()
        let manager = wiredManager(policy: .ask, defaults: test.defaults, spy: spy)

        #expect(manager.collisionResolver(Self.collision()) == .keepBoth)
        #expect(manager.bulkCollisionResolver(Self.collision()).applyToAll)
        #expect(spy.singleCalls.count == 1)
        #expect(spy.bulkCalls.count == 1)

        // Unset (never configured) is `.ask` too — the historical always-prompt behavior.
        let unsetSpy = PromptSpy()
        let unset = wiredManager(policy: nil, defaults: test.defaults, spy: unsetSpy)
        #expect(unset.collisionResolver(Self.collision()) == .keepBoth)
        #expect(unsetSpy.singleCalls.count == 1)
    }

    @MainActor
    @Test func testPolicyIsRereadForEveryCollisionSoASettingsChangeAppliesImmediately() {
        let test = TestDefaults()
        defer { test.wipe() }
        let spy = PromptSpy()
        // Wired ONCE, up front — exactly as `App.init` does it. Reading the policy at wiring time
        // instead of per collision would pin the app to whatever was set at launch.
        let manager = wiredManager(policy: .replace, defaults: test.defaults, spy: spy)
        #expect(manager.collisionResolver(Self.collision()) == .replace)

        test.defaults.set(ConflictPolicy.skip.rawValue, forKey: ConflictPolicy.defaultsKey)
        #expect(manager.collisionResolver(Self.collision()) == .skip)
        #expect(manager.bulkCollisionResolver(Self.collision()).resolution == .skip)

        // …including a switch back to "Ask every time", which must restore the prompt.
        test.defaults.set(ConflictPolicy.ask.rawValue, forKey: ConflictPolicy.defaultsKey)
        #expect(manager.collisionResolver(Self.collision()) == .keepBoth)
        #expect(spy.singleCalls.count == 1)
    }

    // MARK: Reset All Settings

    @MainActor
    @Test func testResetAllSettingsWipesDefaultsResetsTheLogGateAndClearsIgnores() throws {
        let test = TestDefaults()
        defer { test.wipe() }
        // A key nothing re-writes on reset, so its disappearance proves the domain was wiped.
        test.defaults.set(true, forKey: "openSettingsOnLaunch")

        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults,
                                       overridesDomainName: test.suiteName,
                                       cloudStorageLister: { .read([]) })
        settings.ignorePatterns = ["*.tmp"]
        settings.conflictPolicy = .replace

        let manager = FileSyncManager()
        manager.ignoredPaths = ["Documents/private.pdf"]

        // Recorded rather than applied: the live `Logger.shared` gate is process-wide, and
        // raising it here would swallow other suites' entries. Each record also captures whether
        // the defaults wipe had already happened, which is what pins the ORDER — running the log
        // reset first would let `resetAllSettings`'s own re-seed overwrite it.
        var logLevels: [(level: LogLevel, patternsAlreadyCleared: Bool)] = []

        ContentView.applyFullSettingsReset(settings: settings, syncManager: manager) { level in
            logLevels.append((level, settings.ignorePatterns.isEmpty))
        }

        // 1. The defaults domain is gone (and the manager republished at its defaults).
        #expect(test.defaults.object(forKey: "openSettingsOnLaunch") == nil)
        #expect(settings.ignorePatterns.isEmpty)
        #expect(settings.conflictPolicy == .ask)
        // 2. The log gate is back to logging everything — it does NOT flow through any
        //    `.onChange` mirror, so only this call restores it before a relaunch.
        #expect(logLevels.count == 1)
        let logged = try #require(logLevels.first)
        #expect(logged.level == .debug)
        #expect(logged.patternsAlreadyCleared)
        // 3. The in-memory ignore sets are cleared — also not mirrored, so items ignored under
        //    the old settings would otherwise stay hidden from every comparison this session.
        #expect(manager.ignoredPaths.isEmpty)
    }

    // MARK: The pane-bar migration's launch line

    /// Swift source with its comments removed, for the two call-site scans below.
    ///
    /// **Whole-line `//` was not enough, and the gap was in the direction that matters.** Both
    /// scans used to drop lines whose first non-space characters were `//`, which leaves a trailing
    /// comment and a `/* */` block in the text. A scan's POSITIVE control — "the call is still
    /// here, so the absence checks below mean something" — is a `contains`, so
    /// `// PaneBarMigration.migrationMessage(` written at the end of any line, or commented out
    /// inside a block, satisfied it with the real call deleted. The check that exists to stop the
    /// rest of the test passing vacuously could itself be satisfied by a comment.
    ///
    /// A character scanner rather than a regex, because the one thing it must not do is strip a
    /// `//` inside a string literal — `"https://…"` would otherwise swallow the rest of the line.
    /// Escapes are honoured, and block comments nest, as they do in Swift.
    ///
    /// **Not handled: multiline (`"""`) and raw (`#"`) string literals.** Rather than pretend
    /// otherwise, `theCommentStripperHandlesTheFormsTheScannedFileUses` asserts the scanned file
    /// contains neither, so the day one appears the stripper is corrected instead of quietly
    /// mis-parsing from there to the end of the file.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inString = false
        var inLine = false
        var blockDepth = 0
        var escaped = false
        var i = source.startIndex
        func peek(_ offset: Int) -> Character? {
            source.index(i, offsetBy: offset, limitedBy: source.index(before: source.endIndex))
                .map { source[$0] }
        }
        while i < source.endIndex {
            let c = source[i]
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if blockDepth > 0 {
                if c == "/", peek(1) == "*" { blockDepth += 1; i = source.index(i, offsetBy: 2); continue }
                if c == "*", peek(1) == "/" { blockDepth -= 1; i = source.index(i, offsetBy: 2); continue }
                // Newlines survive so line-oriented positions downstream stay sane.
                if c == "\n" { out.append(c) }
            } else if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; escaped = false; out.append(c)
            } else if c == "/", peek(1) == "/" {
                inLine = true; i = source.index(i, offsetBy: 2); continue
            } else if c == "/", peek(1) == "*" {
                blockDepth = 1; i = source.index(i, offsetBy: 2); continue
            } else {
                out.append(c)
            }
            i = source.index(after: i)
        }
        return out
    }

    /// The stripper's own proof, and the guard on its stated limits.
    ///
    /// Every case here is one the two scans below would get wrong without it — a trailing comment
    /// and a block comment are exactly how a deleted call keeps answering a `contains`, and the
    /// URL case is how an over-eager stripper would delete real code and fail the same scans from
    /// the other side. Both directions, because only one of them is obvious.
    @Test func theCommentStripperHandlesTheFormsTheScannedFileUses() throws {
        let stripped = Self.strippingComments("""
        let a = 1 // PaneBarMigration.migrationMessage(
        // whole line
        /* block PaneBarMigration.migrationMessage( */ let b = 2
        /* outer /* nested */ still comment */ let c = 3
        let url = "https://example.com/x" // tail
        let quoted = "a \\" // not a comment" + "b"
        real()
        """)
        #expect(!stripped.contains("PaneBarMigration.migrationMessage("),
                "a commented-out call survived the stripper, so a scan's positive control can be satisfied by a comment")
        #expect(!stripped.contains("whole line"))
        #expect(!stripped.contains("still comment"), "nested block comments are not closed correctly")
        #expect(!stripped.contains("tail"))
        // …and it did not eat real code. A stripper that deleted everything would satisfy every
        // expectation above and break both scans below, so these are not optional.
        #expect(stripped.contains("let a = 1"))
        #expect(stripped.contains("let b = 2"))
        #expect(stripped.contains("let c = 3"))
        #expect(stripped.contains("\"https://example.com/x\""),
                "the stripper treated a URL's // as a comment and ate the rest of the line")
        #expect(stripped.contains("\"a \\\" // not a comment\""),
                "the stripper does not honour escapes inside string literals")
        #expect(stripped.contains("real()"))

        // The stated limit, asserted rather than assumed: the scanned file uses neither form, so
        // the stripper is correct FOR IT. If one ever appears this fails here instead of silently
        // mis-parsing the remainder of the file.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read MacApp/SyncCloudApp.swift")
        #expect(!raw.contains("\"\"\""),
                "SyncCloudApp.swift now has a multiline string literal, which strippingComments does not parse")
        #expect(!raw.contains("#\""),
                "SyncCloudApp.swift now has a raw string literal, which strippingComments does not parse")
    }

    /// **The line this launch writes must be the migration's own answer, not a literal.**
    ///
    /// `App.init` used to hold `Logger.shared.info("[panebar] added Search to a stored pane-bar
    /// arrangement")` behind a `Bool`. True only while Search was the sole step there could be: the
    /// next control to take a migration step would have left every migrating launch crediting
    /// Search for something it did not add, in `~/sync-cloud.log`, with nothing to catch it.
    ///
    /// **A source scan, and it has to be**, which is stated rather than worked around: the call is
    /// inside `if !isRunningTests` precisely so the test host does not run it, so no fixture can
    /// reach it. `PaneBarMigrationTests.theLaunchLineNamesEveryControlTheMigrationActuallyAdded`
    /// owns the wording; this owns the fact that the app asks for it. Without this half, the
    /// helper is one revert away from being a well-tested function nothing calls.
    ///
    /// The absence is read off comment-stripped source — the prose above the call names the old
    /// literal, and would answer the scan for it.
    @Test func testTheLaunchNamesWhatThePaneBarMigrationActuallyAdded() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read MacApp/SyncCloudApp.swift")
        let source = Self.strippingComments(raw)
        // The positive control: this is the right file and the migration still runs at launch. A
        // scan of the wrong text would otherwise report the absence below for free.
        #expect(source.contains("PaneBarMigration.apply(defaults: .standard)"),
                "the pane-bar migration no longer runs at launch — every check here is vacuous")
        #expect(source.contains("PaneBarMigration.migrationMessage("),
                "the launch line is no longer built from what the migration reported")
        // And the literal is gone. Any control's name hard-coded into this file's log call is the
        // defect: the first one is true today and false on the day a second step ships.
        // Shortened from "added Search to" now that the line reads "…arrangement: added Search":
        // the needle has to be the part a hand-written literal would still carry.
        for name in ["added Search", "added Delete", "added Preview", "rewrote a stored"] {
            #expect(!source.contains(name),
                    "SyncCloudApp names a pane-bar control in a log line (“\(name)”) instead of naming what the migration reported")
        }
    }

    /// **The report of what the stored bar cannot show belongs to the delegate, not to `App.init`.**
    ///
    /// It used to be a `defer` inside `PaneBarMigration.apply`, whose one production caller is
    /// `App.init` — and this file says three lines from that call why nothing that WRITES may sit
    /// there: SwiftUI can re-run `init`, which is exactly why the launch breadcrumb lives in
    /// `applicationDidFinishLaunching`. Its four neighbours are annotated "the repeat App.init calls
    /// noted above are harmless" because a repeat writes nothing. This one wrote its whole report
    /// again, so a user who took a control off two releases ago collected the same paragraph on
    /// every rebuild of the scene, forever.
    ///
    /// A source scan for the same reason its sibling above is one: `applicationDidFinishLaunching`
    /// is AppKit's to call, and the test host's own launch is not the app's. What is checkable is
    /// where the call sits, and that is the whole of the fix. `PaneBarMigrationTests.testTheMigration
    /// ItselfWritesNoReachReport` owns the other end — that `apply` no longer reports — so between
    /// them a report that ran twice per launch and one that ran not at all both fail.
    @Test func testTheStoredPaneBarIsReportedOnceFromTheLaunchDelegate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read MacApp/SyncCloudApp.swift")
        let source = Self.strippingComments(raw)

        let call = "PaneBarMigration.reportStoredArrangementReach(defaults: .standard)"
        let sites = source.components(separatedBy: call).count - 1
        let wrongCount = "the stored pane bar is reported \(sites) times in SyncCloudApp.swift; it "
            + "is a per-launch fact and belongs in exactly one place"
        #expect(sites == 1, "\(wrongCount)")
        // …and that place is the delegate method that fires exactly once, not `init`. The anchor is
        // required first: without it the containment check below would read an empty range and pass
        // by finding nothing. The method's statements are indented eight spaces and every nested
        // block closes at that depth, so the first `\n    }` is its own closing brace.
        let delegate = try #require(source.range(of: "func applicationDidFinishLaunching("),
                                    "applicationDidFinishLaunching is gone or renamed — this scan is vacuous")
        let tail = source[delegate.upperBound...]
        let body = tail[..<(tail.range(of: "\n    }")?.upperBound ?? tail.endIndex)]
        // The positive control: the breadcrumb whose placement rule this follows is in that method,
        // so a scan that had drifted onto the wrong region fails here rather than passing quietly.
        let wrongRegion = "the launch breadcrumb is not in this range — the scan is reading a "
            + "different method from the one the rule is about, and the check below means nothing"
        #expect(body.contains("launched\")"), "\(wrongRegion)")
        let notInDelegate = "the reach report is not inside applicationDidFinishLaunching. Back in "
            + "App.init it repeats for one launch every time SwiftUI rebuilds the scene, which is "
            + "the whole reason the breadcrumb above it is not in init either"
        #expect(body.contains(call), "\(notInDelegate)")
    }
}
