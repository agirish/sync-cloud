import Testing
import AppKit
import Foundation
import FileExplorer
@testable import SyncCloud

/// The editor's two modal questions — specifically, the mapping from a button press to an answer.
///
/// **This is the half a review found untested, and it is the half that matters.** The wording can
/// be wrong and someone will notice; a mapping that reads Cancel as consent discards work silently.
/// The titles and the mapping are asserted together on purpose: reordering `unsavedButtonTitles` is
/// the natural way to reword this dialog, and doing that alone would turn Cancel into Discard with
/// nothing on screen to say so.
@Suite struct EditorAlertsTests {

    // MARK: Leaving a document with unsaved changes

    @Test func theThreeButtonsAreInThePlatformsOrder() {
        #expect(EditorAlerts.unsavedButtonTitles == ["Save", "Cancel", "Don't Save"])
    }

    /// The mapping, stated as a table over every response an `NSAlert` can hand back — including
    /// the ones it never hands back from a three-button alert, because "everything else is Cancel"
    /// is the rule that keeps a dismissed sheet from discarding work.
    @Test(arguments: [
        (NSApplication.ModalResponse.alertFirstButtonReturn, EditorAlerts.UnsavedAnswer.save),
        (.alertSecondButtonReturn, .cancel),
        (.alertThirdButtonReturn, .discard),
        (.abort, .cancel),
        (.stop, .cancel),
        (.cancel, .cancel),
        (.OK, .cancel),
    ])
    func eachResponseMeansExactlyOneThing(response: NSApplication.ModalResponse,
                                          answer: EditorAlerts.UnsavedAnswer) {
        #expect(EditorAlerts.answer(for: response) == answer)
    }

    /// **The button in position N does what the title in position N says.** The two tests above are
    /// each true of a dialog whose buttons are in the wrong order; this is the one that is not.
    @Test func theTitleAndTheAnswerAgreePositionByPosition() {
        let responses: [NSApplication.ModalResponse] =
            [.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn]
        let expected: [String: EditorAlerts.UnsavedAnswer] =
            ["Save": .save, "Cancel": .cancel, "Don't Save": .discard]
        for (index, title) in EditorAlerts.unsavedButtonTitles.enumerated() {
            let answered = EditorAlerts.answer(for: responses[index])
            #expect(answered == expected[title],
                    "the button titled “\(title)” sits at position \(index), where the mapping answers \(answered)")
        }
    }

    @Test func theMessageNamesTheFileAtRisk() {
        let message = EditorAlerts.unsavedMessage(name: "september-backlog.md")
        #expect(message.contains("september-backlog.md"))
        #expect(!EditorAlerts.unsavedInformativeText.isEmpty)
    }

    // MARK: The file changed under the buffer

    @Test func onlyTheFirstButtonConfirmsWritingOverAChangedFile() {
        #expect(EditorAlerts.divergenceButtonTitles == ["Save Anyway", "Cancel"])
        #expect(EditorAlerts.isConfirmed(.alertFirstButtonReturn))
        for response: NSApplication.ModalResponse in [.alertSecondButtonReturn, .alertThirdButtonReturn,
                                                      .abort, .stop, .cancel, .OK] {
            #expect(!EditorAlerts.isConfirmed(response),
                    "\(response) was read as permission to overwrite a file that changed")
        }
    }

    /// **The two divergences get different sentences, and that is the point of the enum.** A file
    /// that is simply gone was very probably filed or renamed by an Organize run in this same
    /// window, and saving would put a second copy back at the old path — so the prompt says so
    /// rather than describing a generic conflict.
    @Test func aMissingFileIsExplainedDifferentlyFromAChangedOne() {
        let changed = EditorAlerts.divergenceMessage(name: "a.md", divergence: .changed)
        let missing = EditorAlerts.divergenceMessage(name: "a.md", divergence: .missing)
        #expect(changed != missing)
        #expect(changed.contains("a.md") && missing.contains("a.md"))

        let changedWhy = EditorAlerts.divergenceInformativeText(.changed)
        let missingWhy = EditorAlerts.divergenceInformativeText(.missing)
        #expect(changedWhy != missingWhy)
        // The missing case has to name what saving would actually do, because "Save Anyway" reads
        // as "write it where it was" and that is exactly the surprising part.
        #expect(missingWhy.lowercased().contains("moved") || missingWhy.lowercased().contains("renamed"))
    }
}

/// The quit guard's new branch: an unsaved editor buffer is the one thing ⌘Q could take with it.
@Suite struct EditorQuitGuardTests {

    @Test func aCleanQuitIsStillAClearQuit() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true,
                                                  hasUnsavedDocument: false)
                == .allowNoActiveOperations)
    }

    @Test func anUnsavedDocumentStopsTheQuit() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true,
                                                  hasUnsavedDocument: true)
                == .warnUnsavedDocument(activeOperations: 0))
    }

    /// **`warnBeforeQuit` does not govern this branch**, and that is a decision rather than an
    /// oversight. That setting is about interrupting file operations, which the engine can finish
    /// or roll back. Unsaved typing exists nowhere but in memory, and switching the operations
    /// warning off is not a statement that documents may be discarded.
    @Test func switchingOffTheOperationsWarningDoesNotSilenceThisOne() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: false,
                                                  hasUnsavedDocument: true)
                == .warnUnsavedDocument(activeOperations: 0))
    }

    /// **A file operation LEADS the question; it no longer replaces it.**
    ///
    /// A half-finished copy is the worse thing to interrupt, so its alert is the one shown — and
    /// the ranking was implemented by dropping `hasUnsavedDocument` on the floor, which is a
    /// different thing. The alert then named only the copy, and its "Quit Anyway" button terminated
    /// with no second question and no mention that there was typing to lose. The rationale offered
    /// for the ranking — *its "Wait" answer keeps the app up, which is also the answer that saves
    /// the buffer* — is true of one of the two buttons; the other one was the bug. The fact now
    /// travels with the decision so one alert can name both.
    @Test func aFileOperationInFlightLeadsButTheBufferIsStillNamed() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: true,
                                                  hasUnsavedDocument: true)
                == .warn(activeOperations: 2, hasUnsavedDocument: true))
        // And with nothing unsaved it is the plain operations warning, unchanged.
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: true,
                                                  hasUnsavedDocument: false)
                == .warn(activeOperations: 2, hasUnsavedDocument: false))
    }

    /// **Every cell of the truth table, so no combination can go unasked again.**
    ///
    /// The gap that shipped was one cell of six — operations in flight, their warning on, a dirty
    /// buffer — and it had a test beside it asserting the wrong answer. Enumerating the whole table
    /// is what makes "which combinations are covered?" a question the file answers rather than one
    /// a reader has to reconstruct from four separately-named tests.
    @Test func everyCombinationOfTheThreeInputsHasAnAnswerThatMentionsWhatIsAtRisk() {
        for ops in [0, 3] {
            for warn in [true, false] {
                for dirty in [true, false] {
                    let decision = SyncCloudAppDelegate.quitDecision(
                        activeOperations: ops, warnBeforeQuit: warn, hasUnsavedDocument: dirty)
                    switch decision {
                    case .allowNoActiveOperations, .allowWithoutWarning:
                        #expect(!dirty, "a dirty buffer was allowed to quit silently (ops \(ops), warn \(warn))")
                        #expect(ops == 0 || !warn)
                    case .warnUnsavedDocument(let count):
                        #expect(dirty, "the document alert was raised with nothing unsaved")
                        #expect(count == ops, "the breadcrumb lost the operation count")
                    case .warn(let count, let unsaved):
                        #expect(ops > 0 && warn)
                        #expect(count == ops)
                        #expect(unsaved == dirty,
                                "the operations alert does not know whether a buffer is at risk (ops \(ops), dirty \(dirty))")
                    }
                    // The property the whole guard exists for, stated once over the whole table.
                    if dirty {
                        let silent = decision == .allowNoActiveOperations
                            || decision == .allowWithoutWarning(activeOperations: ops)
                        #expect(!silent, "⌘Q would discard unsaved work with no prompt (ops \(ops), warn \(warn))")
                    }
                }
            }
        }
    }

    /// **The one combination that used to quit outright**, and the assertion that used to bless it.
    ///
    /// With operations in flight AND their warning switched off, this returned
    /// `.allowWithoutWarning` — so ⌘Q terminated with no prompt and took the unsaved buffer with
    /// it. The test asserted exactly that, which is how a data-losing arm shipped green beside a
    /// doc comment saying it must not exist. Nothing about switching off the *operations* warning
    /// is a statement about documents.
    @Test func operationsInFlightWithTheirWarningOffStillAsksAboutTheDocument() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: false,
                                                  hasUnsavedDocument: true)
                == .warnUnsavedDocument(activeOperations: 2))
        // …and with nothing unsaved, that arm is unchanged.
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: false,
                                                  hasUnsavedDocument: false)
                == .allowWithoutWarning(activeOperations: 2))
    }

    /// The default keeps every existing caller of this function meaning what it meant.
    @Test func theUnsavedQuestionDefaultsToNo() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true)
                == .allowNoActiveOperations)
    }

    /// **The guard follows the live document, and takes the newest rather than the first.**
    ///
    /// It mirrored `adoptSyncManager`, which keeps the FIRST manager because a re-run `App.init`
    /// offers a throwaway `@StateObject` never kept alive. The mirror image is the hazard here: the
    /// reference is `weak`, there is only ever one document, and a `guard … == nil` meant that if
    /// the previous one happened to still be alive when a new one was adopted — a teardown in
    /// progress, an autorelease pool not yet drained — the stale object was kept and nothing ever
    /// re-adopted. The quit guard then answered "nothing unsaved" about a document nobody could
    /// see, for the rest of the session.
    @MainActor
    @Test func theQuitGuardFollowsTheDocumentThatIsActuallyOpen() {
        SyncCloudAppDelegate.sharedEditorDocument = nil
        let delegate = SyncCloudAppDelegate()

        let first = EditorDocument()
        delegate.adoptEditorDocument(first)
        #expect(SyncCloudAppDelegate.sharedEditorDocument === first)

        // A rebuilt view offers its own document while the previous one is still alive.
        let second = EditorDocument()
        delegate.adoptEditorDocument(second)
        #expect(SyncCloudAppDelegate.sharedEditorDocument === second,
                "the guard kept the previous document — it now answers about one nobody can see")

        // And what it answers is the live document's state, which is the whole point of following.
        // A real file, because `isDirty` is false with nothing open — the buffer is only at risk
        // once it stands for something on disk.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quit-guard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.md")
        try? Data("on disk\n".utf8).write(to: file)
        EditorFileStore.load(path: file.path, into: second)

        #expect(SyncCloudAppDelegate.sharedEditorDocument?.isDirty == false, "a freshly opened file is not dirty")
        second.text = "typed over it\n"
        #expect(SyncCloudAppDelegate.sharedEditorDocument?.isDirty == true,
                "the guard does not see the live document's unsaved changes")
        SyncCloudAppDelegate.sharedEditorDocument = nil
    }
}
