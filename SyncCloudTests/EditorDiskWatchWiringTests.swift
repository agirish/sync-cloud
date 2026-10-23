import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **TE59's window half, and the three refresh gaps that came with it.**
///
/// `ContentView` cannot be built in a test, so the rules are extracted and run, and the call sites
/// that connect them to the window are read — a rule one revert away from being unused is not
/// covered by its own test (testing law 5).
@MainActor
@Suite struct EditorDiskWatchWiringTests {

    // MARK: A banner stops autosave; its going resumes it

    @Test func aBannerStopsAutosaveAndOnlyAnAgreeingDiskResumesIt() {
        typealias C = ContentView
        #expect(C.autosaveStop(after: .changed, current: nil, diskAgrees: false) == .diverged(.changed))
        #expect(C.autosaveStop(after: .deleted, current: nil, diskAgrees: false) == .diverged(.missing))
        #expect(C.autosaveStop(after: nil, current: .diverged(.changed), diskAgrees: true) == nil)
        #expect(C.autosaveStop(after: nil, current: .diverged(.changed), diskAgrees: false) == .diverged(.changed),
                "the banner went while the disk still disagrees — autosave would write over the other version")
        #expect(C.autosaveStop(after: nil, current: .failed("disk full"), diskAgrees: true) == .failed("disk full"),
                "a failed write's stop is not the banner's to clear")
    }

    @Test func theWindowAttachesTheWatchAndAnswersItsCallbacks() throws {
        let view = CodeText(try Self.source("ContentView.swift"))
        #expect(view.contains("attachEditorDiskWatch()"), "nothing attaches the disk watch — nothing is watched")
        let attach = try Self.body("func attachEditorDiskWatch()")
        #expect(attach.contains("editorDiskWatch.attach(document: editorDocument, undoStore: editorUndoStore)"))
        #expect(attach.contains("editorDiskWatch.onMoved = { old, new, byThisApp in editorDocumentDidMove(from: old, to: new, byThisApp: byThisApp) }"))
        #expect(attach.contains("editorDiskWatch.onBannerChange = { banner in editorDiskBannerDidChange(banner) }"))
        let app = CodeText(try Self.source("SyncCloudApp.swift"))
        #expect(app.contains("editorDiskWatch: editorDiskWatch,"))
    }

    @Test func theWorkspaceIsHandedTheBannerAndItsAnswers() throws {
        let call = try CallArguments(of: "EditorWorkspaceView(", in: normalizedCode(Self.editor()))
        #expect(call.passes("diskBanner", "editorDiskWatch.banner"))
        #expect(call.passes("diskNotice", "editorDiskWatch.notice?.text"))
        #expect(call.passes("onDiskBanner", "{ answerEditorDiskBanner($0) }"))
    }

    /// **A move takes the window's path-keyed state with it** — the autosave switch most of all: a
    /// file switched off must not quietly come back on under its new name.
    @Test func aMoveTakesTheWindowsPathKeyedStateWithIt() throws {
        let moved = try Self.body("func editorDocumentDidMove(from old: String, to new: String, byThisApp: Bool)")
        #expect(moved.contains("editorAutosavePolicy.move(from: old, to: new)"))
        #expect(moved.contains("EditorOutlineScroll.moveAnchor(in: &editorOutlineAnchors, from: old, to: new)"))
        #expect(moved.contains("refreshEditorRail()"))
        #expect(moved.contains("rereadPanesAfterEditorWrite(new, writer: \"The open document was moved elsewhere to\")"),
                "the log calls a move a write Edit made")
        // **After the app's own operation the lists are its refresh's to re-read**, not this one's.
        let skip = try #require(moved.range(of: "guard !byThisApp else { return }"),
                                "a move the app made re-reads the panes its own refresh just re-read")
        let rail = try #require(moved.range(of: "refreshEditorRail()"))
        let reread = try #require(moved.range(of: "rereadPanesAfterEditorWrite("))
        #expect(skip.lowerBound < rail.lowerBound && skip.lowerBound < reread.lowerBound)
        let after = try Self.body("func refreshEditorAfterFileOperation()")
        #expect(after.contains("editorDiskWatch.reconcile(afterOwnFileOperation: true)"),
                "the look after the app's own operation does not say whose move it follows")
    }

    /// **Keep Mine… asks first, through every door** (TE97) — the banner, the ⌘S alert and the
    /// comparison sheet's foot all reach `applyDivergenceAnswer`'s `.saveAnyway` arm, and the consent
    /// is asked there, before the write. The sheet's used to write without asking.
    ///
    /// Mutation: drop the consent from `.saveAnyway`, or route the banner's Keep Mine… straight to
    /// `writeEditorDocument`, and this fails.
    @Test func keepMineAsksBeforeItWrites() throws {
        let apply = try Self.body("func applyDivergenceAnswer(")
        let keep = try #require(apply.range(of: "case .saveAnyway:"))
        let asks = try #require(apply.range(of: "EditorAlerts.keepMineAsks(for: divergence)"))
        let ask = try #require(apply.range(of: "!EditorAlerts.confirmKeepMine(name: editorDocument.name)"))
        let declined = try #require(apply.range(of: "editorAutosaveStop = .diverged(divergence) return false"))
        // …with the disk stamp the user agreed to replace, or the version they chose to discard
        // would be kept aside as an "(other version)" (FR48).
        let write = try #require(apply.range(
            of: "return writeEditorDocument(explicit: explicit, consentedTo: EditorFileStore.stamp(ofPath: path))"))
        #expect(keep.lowerBound < asks.lowerBound && asks.lowerBound < ask.lowerBound
                && ask.lowerBound < declined.lowerBound && declined.lowerBound < write.lowerBound,
                "Keep Mine… writes before it asks")
        // The banner's Keep Mine… is the same answer, not a write of its own.
        let banner = try Self.body("func answerEditorDiskBanner(_ action: EditorDiskBannerAction)")
        let bannerKeep = try #require(banner.range(of: "case .keepMine:"))
        let routed = try #require(banner.range(of: "applyDivergenceAnswer(.saveAnyway, divergence: .changed, path: path, explicit: true)"))
        let next = try #require(banner.range(of: "case .useDisks:"))
        #expect(bannerKeep.lowerBound < routed.lowerBound && routed.lowerBound < next.lowerBound)
        #expect(!banner.normalized[bannerKeep.lowerBound..<next.lowerBound].contains("writeEditorDocument"),
                "the banner's Keep Mine… writes on its own path again")
        // The sheet's foot comes back through `answerEditorDivergenceDiff` into the same function.
        let foot = try Self.body("func answerEditorDivergenceDiff(_ verdict: EditorDivergenceVerdict)")
        #expect(foot.contains("applyDivergenceAnswer(EditorAlerts.divergenceAnswer(for: verdict),"))
        #expect(EditorAlerts.keepMineButtonTitles == ["Keep Mine", "Cancel"])
        #expect(EditorAlerts.keepMineInformativeText.contains("the other changes are lost"))
        #expect(EditorAlerts.isConfirmed(.alertFirstButtonReturn))
        #expect(!EditorAlerts.isConfirmed(.alertSecondButtonReturn), "Cancel was read as consent")
    }

    /// **The sheet says ⌘Z brings the typing back only where it does** — with the banner up, where
    /// Use Disk Version is the undoable take (TE97).
    @Test func theSheetIsToldWhetherTakingTheDiskIsUndoable() throws {
        let view = try Self.source("ContentView.swift")
        let call = try CallArguments(of: "EditorDivergenceDiffOverlay(", in: normalizedCode(view))
        #expect(call.passes("takingDiskIsUndoable", "editorDiskWatch.banner == .changed"))
    }

    /// **Save Again looks before it writes** — a file back at the path is not written over — and the
    /// ⌘S alert's Save Again, for a file that is gone, is the banner's, through the same path (TE151).
    @Test func saveAgainLooksBeforeItWrites() throws {
        let again = try Self.body("func saveEditorDocumentAgain(explicit: Bool) -> Bool")
        let look = try #require(again.range(of: "editorDiskWatch.prepareSaveAgain()"))
        let write = try #require(again.range(of: "return writeEditorDocument(explicit: explicit)"))
        #expect(look.lowerBound < write.lowerBound)
        #expect(again.contains("case .write: return writeEditorDocument(explicit: explicit) case .notMissing: return false"),
                "Save Again writes whatever the look found")
        #expect(again.contains("case .failed(let why): syncManager.banner = .error("),
                "a folder that could not be made again fails silently")
        let banner = try Self.body("func answerEditorDiskBanner(_ action: EditorDiskBannerAction)")
        #expect(banner.contains("case .saveAgain: saveEditorDocumentAgain(explicit: true)"))
        #expect(!banner.contains("writeEditorDocument"), "the banner writes on a path of its own")
        let apply = try Self.body("func applyDivergenceAnswer(")
        let saveAnyway = try #require(apply.range(of: "case .saveAnyway:"))
        let gone = try #require(apply.range(of: "if divergence == .missing { return saveEditorDocumentAgain(explicit: explicit) }"))
        let keepMine = try #require(apply.range(of: "EditorAlerts.keepMineAsks(for: divergence)"))
        #expect(saveAnyway.lowerBound < gone.lowerBound && gone.lowerBound < keepMine.lowerBound,
                "the alert's Save Again writes without looking first")
    }

    /// The diff's Use Disk Version, with the banner up, is the banner's — the undoable one.
    @Test func reloadFromDiskUnderTheBannerIsTheUndoableOne() throws {
        let apply = try Self.body("func applyDivergenceAnswer(")
        let reload = try #require(apply.range(of: "case .reloadFromDisk:"))
        let use = try #require(apply.range(of: "editorDiskWatch.useDisksVersion()"))
        let old = try #require(apply.range(of: "return reloadOverTheBuffer(path: path)"))
        #expect(reload.lowerBound < use.lowerBound && use.lowerBound < old.lowerBound)
    }

    /// Autosave's own check finding a divergence goes to the watch first — a banner, not a modal.
    @Test func autosavesBlockedWriteAsksTheWatchFirst() throws {
        let outcome = try Self.body("private func applyAutosaveOutcome(_ outcome: EditorAutosave.Outcome)")
        let blocked = try #require(outcome.range(of: "case .blocked(let divergence):"))
        let watch = try #require(outcome.range(of: "editorDiskWatch.reconcile()"))
        let alert = try #require(outcome.range(of: "EditorAlerts.askAboutDivergence("))
        #expect(blocked.lowerBound < watch.lowerBound && watch.lowerBound < alert.lowerBound)
    }

    /// **The banner and the stop cannot disagree for long**: a blocked autosave that the watch
    /// answers with its banner re-latches the stop from it, and Compare latches it before it reads
    /// it — a stop cleared under a standing banner left Compare doing nothing and autosave free.
    @Test func theStopIsLatchedFromTheBannerWhereItIsRead() throws {
        let outcome = try Self.body("private func applyAutosaveOutcome(_ outcome: EditorAutosave.Outcome)")
        let asked = try #require(outcome.range(of: "case .asked:"))
        let latch = try #require(outcome.range(of: "editorDiskBannerDidChange(editorDiskWatch.banner)"))
        let returned = try #require(outcome.ranges(of: "return").first { $0.lowerBound > latch.lowerBound })
        #expect(asked.lowerBound < latch.lowerBound && latch.lowerBound < returned.lowerBound,
                "a blocked autosave answered by the banner leaves the stop as it was")
        let answer = try Self.body("func answerEditorDiskBanner(_ action: EditorDiskBannerAction)")
        let compare = try #require(answer.range(of: "case .compare:"))
        let compareLatch = try #require(answer.range(of: "editorDiskBannerDidChange(editorDiskWatch.banner)"))
        let diff = try #require(answer.range(of: "showEditorDivergenceDiff()"))
        #expect(compare.lowerBound < compareLatch.lowerBound && compareLatch.lowerBound < diff.lowerBound,
                "Compare reads a stop nothing latched")
        // And the latch itself: a standing banner always means a stop.
        #expect(ContentView.autosaveStop(after: .changed, current: nil, diskAgrees: true) == .diverged(.changed))
    }

    /// ⌘S and leaving a document both let the watch look before they ask — so a move is followed
    /// and a re-stamp taken instead of a question about nothing.
    @Test func explicitSavesAndLeavingLookBeforeTheyAsk() throws {
        let save = try Self.body("func saveEditorDocument() -> Bool")
        let look = try #require(save.range(of: "editorDiskWatch.reconcile()"))
        let ask = try #require(save.range(of: "EditorAlerts.askAboutDivergence("))
        #expect(look.lowerBound < ask.lowerBound)
        let settle = try Self.body("func settleEditorDocument(asksAboutPDFWork: Bool = true, asksAboutTheOnlyCopy: Bool = true, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool")
        let blocked = try #require(settle.range(of: "case .blocked(let divergence):"))
        // The one after `.blocked` — TE146's look for a gone file comes earlier.
        let settleLook = try #require(settle.ranges(of: "editorDiskWatch.reconcile()").first { $0.lowerBound > blocked.lowerBound })
        let question = try #require(settle.range(of: "editorAutosaveStop = .diverged(divergence)"))
        #expect(blocked.lowerBound < settleLook.lowerBound && settleLook.lowerBound < question.lowerBound)
    }

    /// **TE145: ⌘S on a clean document writes nothing** — unless a stop stands, which ⌘S settles.
    /// The skip sits after the divergence check, so a file that went or changed is still asked
    /// about, and stays out of `writeEditorDocument`, which Keep Mine and Save Again write through.
    @Test func saveWithNothingChangedWritesNothing() throws {
        #expect(ContentView.saveHasNothingToWrite(isDirty: false, stop: nil))
        #expect(!ContentView.saveHasNothingToWrite(isDirty: true, stop: nil))
        for stop: EditorAutosaveStop in [.failed("disk full"), .unchecked("couldn’t be read back"),
                                         .diverged(.changed), .diverged(.missing)] {
            #expect(!ContentView.saveHasNothingToWrite(isDirty: false, stop: stop),
                    "a clean document with autosave stopped (\(stop)) is not written by ⌘S")
        }
        let save = try Self.body("func saveEditorDocument() -> Bool")
        let divergence = try #require(save.range(of: "EditorAlerts.askAboutDivergence("))
        let skip = try #require(save.range(of: "if Self.saveHasNothingToWrite(isDirty: editorDocument.isDirty, stop: editorAutosaveStop) {"))
        let write = try #require(save.range(of: "return writeEditorDocument(explicit: true)"))
        #expect(divergence.lowerBound < skip.lowerBound && skip.lowerBound < write.lowerBound,
                "the skip must follow the divergence question and precede the write")
        let writer = try Self.body("private func writeEditorDocument(explicit: Bool, consentedTo: EditorFileStore.Stamp? = nil) -> Bool")
        #expect(!writer.contains("saveHasNothingToWrite"),
                "Keep Mine and Save Again write through here and must write whatever the buffer is")
    }

    // MARK: Gap 1 — a write that puts a deleted file back is listed

    @Test func aWriteThatRecreatesTheFileShowsItInThePane() throws {
        let write = try Self.body("private func writeEditorDocument(explicit: Bool, consentedTo: EditorFileStore.Stamp? = nil) -> Bool")
        #expect(write.contains("let recreates = editorDocument.path.map { !FileManager.default.fileExists(atPath: $0) } ?? false"))
        #expect(write.contains("if recreates { showCreatedFileInPane(path) }"),
                "Save Again after a delete leaves the panes without the file")
        let measured = try #require(write.range(of: "let recreates"))
        let written = try #require(write.range(of: "EditorFileStore.write(editorDocument, consentedTo: consentedTo)"))
        #expect(measured.lowerBound < written.lowerBound, "asked after the write, when the file always exists")
    }

    // MARK: Gap 2 — Edit's rail follows the app's own file operations

    @Test func theRailIsReReadAfterTheAppsOwnFileOperations() throws {
        let view = try Self.source("ContentView.swift")
        let receive = try declarationBody(of: ".onReceive(syncManager.refreshSubject)", in: view)
        #expect(CodeText(receive).contains("refreshEditorAfterFileOperation()"))
        let after = try Self.body("func refreshEditorAfterFileOperation()")
        #expect(after.contains("Task { await refreshEditorRail() }"))
        #expect(after.contains("editorDiskWatch.reconcile(afterOwnFileOperation: true)"),
                "gap 3: the open note is not looked at after the app's own rename, move or delete")
        #expect(ContentView.railRefreshesAfterFileOperation(workspace: .editor))
        #expect(!ContentView.railRefreshesAfterFileOperation(workspace: .browse),
                "the rail is not drawn there, and arriving in Edit re-reads it")
    }

    @Test func anImageImportReReadsTheRail() throws {
        let images = try Self.body("func noteEditorImages(_ report: EditorImageImport.Report)")
        #expect(images.contains("if !files.isEmpty || madeFolder != nil { Task { await refreshEditorRail() } }"))
    }

    // MARK: Gap 4 — the destination picker's New Folder is listed even when the transfer is not made

    @Test func aFolderThePickerMadeIsListedWhateverTheTransferDoes() throws {
        let call = try CallArguments(of: "DestinationPicker(", in: normalizedCode(Self.source("ContentView.swift")))
        #expect(call.passes("onFolderCreated",
                            "{ rereadPanesAfterEditorWrite($0, writer: \"The destination picker made\", comparesInCompare: false) }"),
                "in Compare the picker's folder starts a rescan the transfer's own refresh supersedes")
    }

    // MARK: Helpers

    static func editor() throws -> String { try source("ContentView+Editor.swift") }

    static func body(_ declaration: String) throws -> CodeText {
        CodeText(try declarationBody(of: declaration, in: editor()))
    }

    static func source(_ name: String) throws -> String {
        try EditorHeaderDoorsWiringTests.source(name)
    }
}
