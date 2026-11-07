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

    /// The pure quit decision (the NSAlert branch itself isn't unit-testable), `(operations in
    /// flight, warn before quit, decision)`. No active operations means an unconditional, silent
    /// terminate, no breadcrumb needed. Active operations with the warning disabled skip the alert
    /// but still quit: the delegate logs the quit-with-operations breadcrumb (worded for the
    /// setting, not the dialog nobody saw) and flushes on this branch so it survives. With the
    /// warning enabled they route to the alert, carrying the count so the logged decision names
    /// how many operations were in flight.
    @Test(arguments: [
        (0, true, SyncCloudAppDelegate.QuitDecision.allowNoActiveOperations),
        (0, false, .allowNoActiveOperations),
        (3, false, .allowWithoutWarning(activeOperations: 3)),
        (5, true, .warn(activeOperations: 5, hasUnsavedDocument: false)),
    ])
    func testQuitDecision(activeOperations: Int, warnBeforeQuit: Bool,
                          expected: SyncCloudAppDelegate.QuitDecision) {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: activeOperations,
                                                  warnBeforeQuit: warnBeforeQuit) == expected)
    }

    /// The quit guard counts a Restructure landing as in flight. Its re-derive queues no file
    /// operation, so a guard reading only `activeFileOperationsCount` would let ⌘Q through
    /// silently mid-landing. `FileSyncManager.operationsAQuitWouldInterrupt` owns the counting
    /// (tested in Sync); this pins that the guard asks it. Read off comment-stripped source.
    @Test func testTheQuitGuardCountsALandingInProgress() throws {
        let source = sourceCodeOnly(try macAppFile("SyncCloudApp.swift"))
        #expect(source.contains("func applicationShouldTerminate("),
                "the quit guard moved — this scan reads nothing")
        #expect(source.contains("let activeOperations = manager?.operationsAQuitWouldInterrupt ?? 0"))
        #expect(!source.contains("manager?.activeFileOperationsCount"),
                "the quit guard counts only queued file operations, and a landing queues none")
    }

    /// SwiftUI may re-run `App.init`, creating a throwaway `FileSyncManager` that `@State`
    /// discards. Adopting that orphan would leave the quit guard watching a count that is always
    /// zero, so only the first adopted manager may stick.
    @MainActor
    @Test func testQuitGuardKeepsFirstManagerAcrossAppReinit() async throws {
        // Put back afterwards: the static is the host app's own, and a test that reads it
        // (`AppSceneObservationTests`) must not find this test's manager, or nothing, there.
        let hostManager = SyncCloudAppDelegate.sharedSyncManager
        defer { SyncCloudAppDelegate.sharedSyncManager = hostManager }
        SyncCloudAppDelegate.sharedSyncManager = nil
        let delegate = SyncCloudAppDelegate()
        let liveManager = FileSyncManager.scratch()
        let orphan = FileSyncManager.scratch()

        delegate.adoptSyncManager(liveManager)
        delegate.adoptSyncManager(orphan) // a re-run App.init offers its throwaway manager

        #expect(delegate.syncManager === liveManager)
        #expect(SyncCloudAppDelegate.sharedSyncManager === liveManager)
    }

    @MainActor
    @Test func testProviderSwitchResetsOnlyTheSwitchedPane() async throws {
        let manager = FileSyncManager.scratch()

        // 1. Both panes navigated, both holding a selection. The app never selects in two panes at
        //    once, but this fixture tells "cleared the switched pane" from "cleared whichever".
        manager.selectedLeftPaths = ["/src/a.txt"]
        manager.selectedRightPaths = ["/dst/b.txt"]
        manager.focusOn(relativePath: "subfolder", isLeft: true)
        manager.focusOn(relativePath: "otherfolder", isLeft: false)

        // 2. This is what ContentView's .onChange(of: leftProviderId) does.
        manager.retargetPane(isLeft: true, landing: "")

        // 3. The switched pane is re-homed and cleared...
        #expect(manager.selectedLeftPaths.isEmpty)
        #expect(manager.leftRelativePath.isEmpty)
        #expect(manager.leftHistory == PaneNavigationHistory())

        // ...and the other pane keeps its folder, selection and Back stack.
        #expect(manager.selectedRightPaths == ["/dst/b.txt"])
        #expect(manager.rightRelativePath == "otherfolder")
        #expect(manager.rightHistory.entries == ["", "otherfolder"])
    }

    /// Both panes on iCloud: during bootstrap the right pane is moved to a distinct destination;
    /// outside it an explicit same-provider pair is kept.
    @Test(arguments: [(true, "oneDrive"), (false, "iCloud")])
    func testResolvedProviderSelection(preferDistinctPair: Bool, right: String) async throws {
        let providers = [
            CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", rootPath: "/iCloud", type: .iCloud),
            CloudProvider(id: "oneDrive", displayName: "OneDrive", imageName: "onedrive", rootPath: "/oneDrive", type: .oneDrive)
        ]

        let resolved = ContentView.resolvedProviderSelection(
            providers: providers,
            currentLeftId: "iCloud",
            currentRightId: "iCloud",
            preferDistinctPair: preferDistinctPair
        )

        #expect(resolved?.leftId == "iCloud")
        #expect(resolved?.rightId == right)
    }

    // MARK: Settings-driven rescan gating

    private func provider(_ id: String, path: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "icloud", rootPath: path, type: .iCloud)
    }

    @Test func testUnrelatedProviderChangeDoesNotRequirePaneRefresh() {
        // Toggling or re-pathing a provider neither pane shows must not rescan, or both panes
        // would show spinners on an unrelated edit.
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b"), provider("OneDrive", path: "/c")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]

        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "iCloud", rightId: "Dropbox") == nil)
    }

    /// Editing one pane's Location scopes the teardown to that pane. The answer is a side, not a
    /// Bool, because the caller spends it on `invalidateComparisonState(reloading:)` and on the
    /// rescan; a plain `true` would tear down the other pane too, for a root that hadn't moved.
    @Test func testPaneProviderPathEditRequiresPaneRefresh() {
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/elsewhere")]

        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "iCloud", rightId: "Dropbox") == .rightOnly)
        // The mirror, so the polarity is measured rather than assumed.
        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "Dropbox", rightId: "iCloud") == .leftOnly)
    }

    /// Both panes on one source is an ordinary configuration, and then one Location edit really
    /// does move both roots.
    @Test func testAPathEditUnderBothPanesRequiresBoth() {
        let old = [provider("iCloud", path: "/a")]
        let new = [provider("iCloud", path: "/elsewhere")]

        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "iCloud", rightId: "iCloud") == .both)
    }

    @Test func testPaneProviderRenameIsANoOpForPaneRefresh() {
        // Renaming a provider in Settings (setCustomName) changes only displayName, which must
        // not read as a pane-provider change: the .comparisonRootEdited teardown would drop an
        // in-flight duplicate review and force a full rescan for a cosmetic edit.
        let old = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]
        let new = [
            CloudProvider(id: "iCloud", displayName: "My Renamed iCloud", imageName: "icloud", rootPath: "/a", type: .iCloud),
            provider("Dropbox", path: "/b")
        ]

        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "iCloud", rightId: "Dropbox") == nil)
    }

    @Test func testPaneProviderAppearingOrVanishingRequiresPaneRefresh() {
        let old = [provider("iCloud", path: "/a")]
        let new = [provider("iCloud", path: "/a"), provider("Dropbox", path: "/b")]

        // A pane pointing at a provider that just became enabled must load it.
        #expect(ContentView.paneRootEdits(old: old, new: new, leftId: "iCloud", rightId: "Dropbox") == .rightOnly)
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
        // A folder collision must warn that Replace trashes the whole existing folder; the file
        // wording ("replace it with the one you're …") doesn't convey that data loss.
        let fileText = SyncOperationAlerts.collisionInformativeText(Self.collision(isDirectory: false))
        let folderText = SyncOperationAlerts.collisionInformativeText(Self.collision(isDirectory: true))

        #expect(fileText != folderText)
        #expect(!fileText.contains("entire contents"))
        #expect(folderText.contains("Replacing a folder replaces its entire contents"))
        #expect(folderText.contains("moved to the Trash"))
        // The folder warning ADDS to the base replace question; it must not displace it
        // (this pins the copy+folder combination, which no verb test covers).
        #expect(folderText.contains("Do you want to replace it with the one you’re copying?"))
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
        #expect(SyncOperationAlerts.transferConfirmationMessage(single) == "Copy “Resume.docx” to “Documents”?")

        let bulk = TransferSummary(isMove: true, itemCount: 3, firstItemName: "Resume.docx", sourceDirectory: "/Left/Documents", destinationDirectory: "/Right/Documents")
        #expect(SyncOperationAlerts.transferConfirmationMessage(bulk) == "Move 3 items to “Documents”?")
    }

    @Test func testTransferConfirmationBodyNamesBothFolders() {
        let summary = TransferSummary(isMove: false, itemCount: 2, firstItemName: "a.txt", sourceDirectory: "/Left/Documents", destinationDirectory: "/Right/Documents")
        let body = SyncOperationAlerts.transferConfirmationInformativeText(summary)
        #expect(body == "From: /Left/Documents\nTo: /Right/Documents")
    }

    /// A copy against the suggestion says it overwrites the newer file, in both its prompts: the
    /// confirmation after its From/To lines, the collision alert after its question. Without a
    /// note, neither changes.
    @Test func testACopyOverANewerFileSaysSoInBothPrompts() {
        let note = "The file on iCloud is newer than the one you’re about to copy over it."
        let summary = TransferSummary(isMove: false, itemCount: 1, firstItemName: "a.txt", sourceDirectory: "/Right/Docs",
                                      destinationDirectory: "/Left/Docs", newerDestinationNote: note)
        #expect(SyncOperationAlerts.transferConfirmationInformativeText(summary)
                == "From: /Right/Docs\nTo: /Left/Docs\n\n" + note)
        let collision = FileCollision(sourcePath: "/Right/Docs/a.txt", destinationPath: "/Left/Docs/a.txt",
                                      isMove: false, isDirectory: false, newerDestinationNote: note)
        #expect(SyncOperationAlerts.collisionInformativeText(collision)
                == "Do you want to replace it with the one you’re copying? " + note
                + "\n\nCopying: /Right/Docs/a.txt\nReplacing: /Left/Docs/a.txt")
        let plain = FileCollision(sourcePath: "/Right/Docs/a.txt", destinationPath: "/Left/Docs/a.txt",
                                  isMove: false, isDirectory: false)
        #expect(!SyncOperationAlerts.collisionInformativeText(plain).contains("newer"))
    }

    @Test func testMoveConfirmationStatesTheRemoval() {
        // Copy and move dialogs otherwise differ by one verb; a move must state its destructive
        // half.
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
        let manager = FileSyncManager.scratch()
        SyncCloudApp.wireCollisionResolvers(into: manager, defaults: defaults,
                                            prompt: spy.single, bulkPrompt: spy.bulk)
        return manager
    }

    @MainActor
    @Test func testBothCollisionSeamsAreWiredToTheStandingPolicy() throws {
        let test = TestDefaults()

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
        let spy = PromptSpy()
        let manager = wiredManager(policy: .ask, defaults: test.defaults, spy: spy)

        #expect(manager.collisionResolver(Self.collision()) == .keepBoth)
        #expect(manager.bulkCollisionResolver(Self.collision()).applyToAll)
        #expect(spy.singleCalls.count == 1)
        #expect(spy.bulkCalls.count == 1)

        // Unset (never configured) is `.ask` too: always prompt.
        let unsetSpy = PromptSpy()
        let unset = wiredManager(policy: nil, defaults: test.defaults, spy: unsetSpy)
        #expect(unset.collisionResolver(Self.collision()) == .keepBoth)
        #expect(unsetSpy.singleCalls.count == 1)
    }

    @MainActor
    @Test func testPolicyIsRereadForEveryCollisionSoASettingsChangeAppliesImmediately() {
        let test = TestDefaults()
        let spy = PromptSpy()
        // Wired once, up front, as `App.init` does. Reading the policy at wiring time instead of
        // per collision would pin the app to whatever was set at launch.
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
        // A key nothing re-writes on reset, so its disappearance proves the domain was cleared.
        test.defaults.set(true, forKey: "openSettingsOnLaunch")

        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults,
                                       overridesDomainName: test.suiteName,
                                       cloudStorageLister: { .read([]) })
        settings.ignorePatterns = ["*.tmp"]
        settings.conflictPolicy = .replace

        let manager = FileSyncManager.scratch()
        manager.ignoredPaths = ["Documents/private.pdf"]

        // Recorded rather than applied: the live `Logger.shared` gate is process-wide, and raising
        // it would swallow other suites' entries. Each record notes whether the defaults wipe had
        // happened, pinning the order: a log reset first would be overwritten by the re-seed.
        var logLevels: [(level: LogLevel, patternsAlreadyCleared: Bool)] = []

        ContentView.applyFullSettingsReset(settings: settings, syncManager: manager) { level in
            logLevels.append((level, settings.ignorePatterns.isEmpty))
        }

        // 1. The defaults domain is cleared (and the manager republished at its defaults).
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

    /// Swift source with its comments removed, for the call-site scans below. Trailing and block
    /// comments go too: a scan's positive control is a `contains`, which a commented-out call
    /// would otherwise satisfy with the real call deleted.
    ///
    /// A character scanner, not a regex, so a `//` inside a string literal (`"https://…"`) is
    /// kept. Escapes are honoured, and block comments nest, as in Swift.
    ///
    /// Not handled: multiline (`"""`) and raw (`#"`) string literals.
    /// `theCommentStripperHandlesTheFormsTheScannedFileUses` asserts the scanned file has neither.
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

    /// The stripper's own proof, and the guard on its stated limits. Both directions: trailing and
    /// block comments must go, or a deleted call keeps answering a `contains`; and real code must
    /// stay, as in the URL case, or the same scans fail from the other side.
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
        // …and it did not eat real code, which a stripper that deleted everything would pass above.
        #expect(stripped.contains("let a = 1"))
        #expect(stripped.contains("let b = 2"))
        #expect(stripped.contains("let c = 3"))
        #expect(stripped.contains("\"https://example.com/x\""),
                "the stripper treated a URL's // as a comment and ate the rest of the line")
        #expect(stripped.contains("\"a \\\" // not a comment\""),
                "the stripper does not honour escapes inside string literals")
        #expect(stripped.contains("real()"))

        // The stated limit, asserted: the scanned file uses neither form. If one appears, this
        // fails instead of the stripper silently mis-parsing the rest of the file.
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

    /// The line this launch writes must be the migration's own answer, not a literal naming a
    /// control, which would go false as soon as a second migration step shipped.
    ///
    /// A source scan because the call sits inside `if !isRunningTests`, so no fixture can reach it.
    /// `PaneBarMigrationTests.theLaunchLineNamesEveryControlTheMigrationActuallyAdded` owns the
    /// wording; this pins that the app asks for it. Read off comment-stripped source.
    @Test func testTheLaunchNamesWhatThePaneBarMigrationActuallyAdded() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read MacApp/SyncCloudApp.swift")
        let source = Self.strippingComments(raw)
        // The positive control: the right file, and the migration still runs at launch, so the
        // absence below means something.
        #expect(source.contains("PaneBarMigration.apply(defaults: .standard)"),
                "the pane-bar migration no longer runs at launch — every check here is vacuous")
        #expect(source.contains("PaneBarMigration.migrationMessage("),
                "the launch line is no longer built from what the migration reported")
        // And no literal: a control's name hard-coded into the log call is the defect. Each needle
        // is the part a hand-written literal would carry.
        for name in ["added Search", "added Delete", "added Preview", "rewrote a stored"] {
            #expect(!source.contains(name),
                    "SyncCloudApp names a pane-bar control in a log line (“\(name)”) instead of naming what the migration reported")
        }
    }

    /// The report of what the stored bar cannot show belongs to the delegate, not `App.init`.
    /// SwiftUI can re-run `init`, so anything there that writes would repeat on every rebuild of the
    /// scene; the launch breadcrumb lives in `applicationDidFinishLaunching` for the same reason.
    ///
    /// A source scan because `applicationDidFinishLaunching` is AppKit's to call, and the test
    /// host's launch is not the app's. `PaneBarMigrationTests.testTheMigrationItselfWritesNoReachReport`
    /// owns the other end, so a report that runs twice per launch and one that never runs both fail.
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
        // …and that place is the delegate method that fires once, not `init`. The anchor is
        // required first, or the check below would read an empty range. The method's nested blocks
        // close deeper than four spaces, so the first `\n    }` is its own closing brace.
        let delegate = try #require(source.range(of: "func applicationDidFinishLaunching("),
                                    "applicationDidFinishLaunching is gone or renamed — this scan is vacuous")
        let tail = source[delegate.upperBound...]
        let body = tail[..<(tail.range(of: "\n    }")?.upperBound ?? tail.endIndex)]
        // The positive control: the launch breadcrumb is in that method, so a scan reading the
        // wrong region fails here.
        let wrongRegion = "the launch breadcrumb is not in this range — the scan is reading a "
            + "different method from the one the rule is about, and the check below means nothing"
        #expect(body.contains("launched\")"), "\(wrongRegion)")
        let notInDelegate = "the reach report is not inside applicationDidFinishLaunching. Back in "
            + "App.init it repeats for one launch every time SwiftUI rebuilds the scene, which is "
            + "the whole reason the breadcrumb above it is not in init either"
        #expect(body.contains(call), "\(notInDelegate)")
    }
}
