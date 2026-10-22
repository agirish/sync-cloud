import Testing
import AppKit
import Foundation
import FileExplorer
@testable import SyncCloud

/// **Leaving a document, asked the same way from every door** — TE146 (a file that is gone with
/// nothing typed), TE148 (one title and one cause line) and TE176 (Don't Save is destructive).
///
/// `ContentView` cannot be built in a test, so the words and the alerts are built and read, and the
/// call sites that connect them to the window and to ⌘Q are read (testing law 5).
@MainActor
@Suite struct EditorLeaveQuestionsTests {

    // MARK: TE148 — one title, one cause line

    @Test func theTitleSaysSaveWhereverTheQuestionComesFrom() {
        #expect(EditorAlerts.unsavedMessage(name: "Plan.md") == "Save your changes to “Plan.md”?")
    }

    /// The first cause that applies, in the page's order: gone, changed, failed, unchecked, off.
    @Test func theCauseIsTheFirstThatApplies() {
        typealias A = EditorAlerts
        #expect(A.leaveCause(isGone: true, stop: .failed("x"), autosaveOff: true) == .gone)
        #expect(A.leaveCause(isGone: false, stop: .diverged(.missing), autosaveOff: true) == .gone)
        #expect(A.leaveCause(isGone: false, stop: .diverged(.changed), autosaveOff: true) == .changed)
        #expect(A.leaveCause(isGone: false, stop: .failed("No space left on device"), autosaveOff: true)
                == .failed("No space left on device"))
        #expect(A.leaveCause(isGone: false, stop: .unchecked("couldn’t read it back to check it."), autosaveOff: true)
                == .unchecked("Saved, but couldn’t read it back to check it."))
        #expect(A.leaveCause(isGone: false, stop: nil, autosaveOff: true) == .autosaveOff)
        #expect(A.leaveCause(isGone: false, stop: nil, autosaveOff: false) == nil)
    }

    @Test func eachCauseIsOneLine() {
        typealias A = EditorAlerts
        #expect(A.causeLine(.gone) == "It’s no longer on disk — this text may be the only copy.")
        #expect(A.causeLine(.changed) == "It changed on disk while you were typing.")
        #expect(A.causeLine(.failed("No space left on device")) == "Its last save failed — No space left on device")
        #expect(A.causeLine(.unchecked("Saved, but couldn’t read it back to check it."))
                == "Saved, but couldn’t read it back to check it.")
        #expect(A.causeLine(.autosaveOff) == "Autosave is off for this file.")
    }

    /// **TE176: Don't Save is destructive, keeps ⌘D, and Return stays on Save.**
    @Test func dontSaveIsDestructiveAndKeepsItsKey() {
        let alert = EditorAlerts.saveButtonsAlert(message: "m", informative: "i")
        #expect(alert.buttons.map(\.title) == ["Save", "Cancel", "Don’t Save"])
        #expect(alert.buttons[2].hasDestructiveAction)
        #expect(!alert.buttons[0].hasDestructiveAction && !alert.buttons[1].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent == "\r", "Return left Save")
        #expect(alert.buttons[2].keyEquivalent == "d", "Don’t Save lost its ⌘D: “\(alert.buttons[2].keyEquivalent)”")
    }

    // MARK: TE146 — a file that is gone with nothing typed

    @Test func aGoneFileIsAskedWhetherToSaveItAgain() {
        #expect(EditorAlerts.onlyCopyMessage(name: "Plan.md") == "Save “Plan.md” again?")
        #expect(EditorAlerts.onlyCopyLine == "It’s no longer on disk — this text may be the only copy.")
    }

    /// **Read-only, it can only be left** — Cancel · Don't Save, and by decision BS Esc cancels and
    /// Return does nothing.
    @Test func aGoneReadOnlyFileIsAskedOnlyWhetherToLeaveIt() {
        let alert = EditorAlerts.readOnlyGoneAlert(name: "Plan.md")
        #expect(alert.messageText == "“Plan.md” is no longer on disk")
        #expect(alert.informativeText == "Leaving now loses this text — it may be the only copy.")
        #expect(alert.buttons.map(\.title) == ["Don’t Save", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[0].keyEquivalent.isEmpty, "Return discards")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}", "Esc doesn’t cancel")
        #expect(EditorAlerts.readOnlyGoneAnswer(for: .alertFirstButtonReturn) == .discard)
        for response: NSApplication.ModalResponse in [.alertSecondButtonReturn, .abort, .stop, .cancel] {
            #expect(EditorAlerts.readOnlyGoneAnswer(for: response) == .cancel)
        }
    }

    @Test func quittingSaysTheTextMayBeTheOnlyCopy() {
        #expect(SyncCloudAppDelegate.quitGoneInformativeText == "Quitting now loses this text — it may be the only copy.")
        #expect(SyncCloudAppDelegate.quitGoneButtonTitles == ["Quit Anyway", "Cancel"])
        typealias D = SyncCloudAppDelegate
        #expect(D.fileOperationsDocumentSentence(name: "a.md", isDirty: false, isOnlyCopy: true, cause: nil)
                == " “a.md” is no longer on disk, and its text may be the only copy.")
        #expect(D.fileOperationsDocumentSentence(name: "a.md", isDirty: true, isOnlyCopy: false, cause: .autosaveOff)
                == " Unsaved changes to “a.md” are discarded too. Autosave is off for this file.")
        #expect(D.fileOperationsDocumentSentence(name: "a.md", isDirty: false, isOnlyCopy: false, cause: nil) == "")
    }

    // MARK: Wiring

    /// Every door out of a document asks — the settle — before the flush; a window close doesn't.
    @Test func leavingAsksAboutTheOnlyCopyBeforeTheFlush() throws {
        let settle = try EditorDiskWatchWiringTests.body("func settleEditorDocument(asksAboutPDFWork: Bool = true, asksAboutTheOnlyCopy: Bool = true, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool")
        let gone = try #require(settle.range(of: "if asksAboutTheOnlyCopy, !editorDocument.isDirty, editorDiskWatch.isGone {"))
        let look = try #require(settle.range(of: "editorDiskWatch.reconcile()"))
        let ask = try #require(settle.range(of: "if editorDiskWatch.mayBeTheOnlyCopy { return confirmLeavingTheOnlyCopy() }"))
        let flush = try #require(settle.range(of: "EditorAutosave.attempt(editorDocument)"))
        #expect(gone.lowerBound < look.lowerBound && look.lowerBound < ask.lowerBound && ask.lowerBound < flush.lowerBound)
        // Save is Save Again, for the gone file with or without typing.
        let only = try EditorDiskWatchWiringTests.body("private func confirmLeavingTheOnlyCopy() -> Bool")
        #expect(only.contains("case .save: return saveEditorDocumentAgain(explicit: true)"))
        #expect(only.contains("? EditorAlerts.askAboutLeavingAGoneReadOnlyFile(name: name) : EditorAlerts.askAboutTheOnlyCopy(name: name)"))
        let unwritten = try EditorDiskWatchWiringTests.body("private func confirmLeavingAnUnwrittenDocument() -> Bool")
        #expect(unwritten.contains("if isGone { return saveEditorDocumentAgain(explicit: true) }"))
        #expect(unwritten.contains("EditorAlerts.askAboutUnsavedChanges(name: editorDocument.name, cause: cause)"))
    }

    /// ⌘Q asks too, with its own words — and the watch and the stop reach the delegate.
    @Test func quittingAsksAboutTheOnlyCopy() throws {
        let app = try EditorHeaderDoorsWiringTests.source("SyncCloudApp.swift")
        let terminate = CodeText(try declarationBody(of: "func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply", in: app))
        #expect(terminate.contains("let isOnlyCopy = !isDirty && watch?.mayBeTheOnlyCopy == true"))
        #expect(terminate.contains("let hasUnsavedDocument = isDirty || isOnlyCopy"))
        let special = try #require(terminate.range(of: "case .warnUnsavedDocument(let count) where isOnlyCopy:"))
        let general = try #require(terminate.ranges(of: "case .warnUnsavedDocument(let count):").first)
        #expect(special.lowerBound < general.lowerBound, "the general unsaved alert would answer first")
        let view = try EditorHeaderDoorsWiringTests.source("ContentView.swift")
        #expect(CodeText(view).contains("SyncCloudAppDelegate.shared?.adoptDiskWatch(editorDiskWatch)"))
        #expect(CodeText(view).contains(".onChange(of: editorAutosaveStop, initial: true) { _, stop in SyncCloudAppDelegate.editorAutosaveStop = stop }"))
    }
}
