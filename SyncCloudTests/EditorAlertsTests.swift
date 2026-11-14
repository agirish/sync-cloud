import Testing
import AppKit
import Foundation
import FileExplorer
@testable import SyncCloud

/// The editor's two modal questions, and above all the mapping from a button press to an answer.
/// A mapping that reads Cancel as consent discards work silently, and reordering
/// `unsavedButtonTitles` alone would turn Cancel into Discard with nothing on screen to say so,
/// so titles and mapping are asserted together.
@Suite struct EditorAlertsTests {
    // MARK: Leaving a document with unsaved changes

    /// The mapping over every response an `NSAlert` can hand back, including ones a three-button
    /// alert never does: "everything else is Cancel" keeps a dismissed sheet from discarding work.
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

    /// The button in position N does what the title in position N says. The two tests above each
    /// hold for a dialog whose buttons are in the wrong order; this one doesn't.
    @Test func theTitleAndTheAnswerAgreePositionByPosition() {
        let responses: [NSApplication.ModalResponse] =
            [.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn]
        let expected: [String: EditorAlerts.UnsavedAnswer] =
            ["Save": .save, "Cancel": .cancel, "Don’t Save": .discard]
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

    /// The titles are per divergence: a changed file gains a reload; a gone file is offered the
    /// banner's Save Again. They follow the banner's order, so Compare…, which writes nothing, is
    /// first and takes Return.
    @Test func onlyTheFirstButtonConfirmsWritingOverAChangedFile() {
        #expect(EditorAlerts.divergenceButtonTitles(for: .missing) == ["Save Again", "Cancel"])
        #expect(EditorAlerts.divergenceButtonTitles(for: .changed)
                == ["Compare…", "Use Disk Version", "Keep Mine…", "Cancel"])
        #expect(EditorAlerts.isConfirmed(.alertFirstButtonReturn))
        for response: NSApplication.ModalResponse in [.alertSecondButtonReturn, .alertThirdButtonReturn,
                                                      .abort, .stop, .cancel, .OK] {
            #expect(!EditorAlerts.isConfirmed(response),
                    "\(response) was read as permission to overwrite a file that changed")
        }
    }

    /// The ⌘S alert, the banner and the comparison sheet's foot read the same three verbs, pinned as
    /// literals so a change to the shared constants can't pass by agreeing with itself.
    @Test func theAlertTheBannerAndTheSheetUseOneSetOfWords() {
        #expect(EditorDiskVerbs.compare == "Compare…")
        #expect(EditorDiskVerbs.keepMine == "Keep Mine…")
        #expect(EditorDiskVerbs.useDiskVersion == "Use Disk Version")
    }

    /// Keep Mine… asks for a file that changed, and Save Again for a gone one doesn't: there is no
    /// other version at that path to replace.
    @Test func keepMineAsksOnlyWhereThereIsAnotherVersionToLose() {
        #expect(EditorAlerts.keepMineAsks(for: .changed))
        #expect(!EditorAlerts.keepMineAsks(for: .missing))
    }

    /// A gone file was very likely filed or renamed by an Organize run in this window, and saving
    /// would put a second copy back at the old path, so its prompt says so.
    @Test func aMissingFileIsExplainedDifferentlyFromAChangedOne() {
        let changed = EditorAlerts.divergenceMessage(name: "a.md", divergence: .changed)
        let missing = EditorAlerts.divergenceMessage(name: "a.md", divergence: .missing)
        #expect(changed != missing)
        #expect(changed.contains("a.md") && missing.contains("a.md"))

        let changedWhy = EditorAlerts.divergenceInformativeText(.changed)
        let missingWhy = EditorAlerts.divergenceInformativeText(.missing)
        #expect(changedWhy != missingWhy)
        // The missing case names what Save Again does: the banner's write, folder and all.
        #expect(missingWhy == "Save Again writes it back where it was, making its folder again if that went too.")
        // The banner's words for a changed file, and "your version" in the sentence.
        #expect(changed == "“a.md” changed on disk while you were typing.")
        // A gone file in the banner's words, not a sentence that reads as a move.
        #expect(missing == "“a.md” is no longer on disk.")
        #expect(changedWhy == "Keeping your version replaces the one on disk, and the other changes are lost.")
    }
}

/// The quit guard's new branch: an unsaved editor buffer is the one thing ⌘Q could take with it.
@Suite struct EditorQuitGuardTests {
    @Test func aCleanQuitIsStillAClearQuit() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true,
                                                  hasUnsavedDocument: false)
                == .allowNoActiveOperations)
    }

    /// A file operation leads the question but doesn't replace it: a half-finished copy is the worse
    /// thing to interrupt, but its "Quit Anyway" would otherwise terminate with no mention of typing
    /// to lose, so one alert names both.
    @Test func aFileOperationInFlightLeadsButTheBufferIsStillNamed() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: true,
                                                  hasUnsavedDocument: true)
                == .warn(activeOperations: 2, hasUnsavedDocument: true))
        // And with nothing unsaved it is the plain operations warning, unchanged.
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: true,
                                                  hasUnsavedDocument: false)
                == .warn(activeOperations: 2, hasUnsavedDocument: false))
    }

    /// Every cell of the truth table, so no combination goes unasked.
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

    /// Operations in flight with their warning off still ask about an unsaved document: switching
    /// that warning off says nothing about documents. Fails with `.allowWithoutWarning` here.
    @Test func operationsInFlightWithTheirWarningOffStillAsksAboutTheDocument() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: false,
                                                  hasUnsavedDocument: true)
                == .warnUnsavedDocument(activeOperations: 2))
        // …and with nothing unsaved, that arm is unchanged.
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 2, warnBeforeQuit: false,
                                                  hasUnsavedDocument: false)
                == .allowWithoutWarning(activeOperations: 2))
    }

    // MARK: Which version wins

    /// "Use Disk Version" is the second button for a changed file and doesn't exist for a gone one,
    /// where the second button is Cancel. Reading the position without the divergence turns the safe
    /// answer into the destructive one.
    @Test func theSameButtonPositionMeansDifferentThingsForTheTwoDivergences() {
        #expect(EditorAlerts.divergenceAnswer(for: .alertFirstButtonReturn, divergence: .changed)
                == .showWhatChanged)
        #expect(EditorAlerts.divergenceAnswer(for: .alertFirstButtonReturn, divergence: .missing)
                == .saveAnyway)
        #expect(EditorAlerts.divergenceAnswer(for: .alertSecondButtonReturn, divergence: .changed)
                == .reloadFromDisk)
        #expect(EditorAlerts.divergenceAnswer(for: .alertSecondButtonReturn, divergence: .missing)
                == .cancel,
                "the second button on a MISSING file is Cancel — reading it as reload would discard the buffer for a file there is nothing to reload from")
    }

    /// The titles and the mapping agree position by position, or the alert says one thing and the
    /// code does another. Positions come from `divergenceResponse(atButtonIndex:)`: `NSApplication`
    /// names only three, and the alert has four buttons.
    @Test func everyDivergenceButtonMapsToTheAnswerItsWordsPromise() {
        for divergence in [EditorFileStore.Divergence.changed, .missing] {
            let titles = EditorAlerts.divergenceButtonTitles(for: divergence)
            for (index, title) in titles.enumerated() {
                let answer = EditorAlerts.divergenceAnswer(
                    for: EditorAlerts.divergenceResponse(atButtonIndex: index),
                    divergence: divergence)
                switch title {
                case "Save Again", "Keep Mine…": #expect(answer == .saveAnyway)
                case "Use Disk Version": #expect(answer == .reloadFromDisk)
                case "Compare…": #expect(answer == .showWhatChanged)
                case "Cancel": #expect(answer == .cancel)
                default: Issue.record("unrecognised button “\(title)” — it maps to \(answer)")
                }
            }
        }
    }

    /// The positions read here are AppKit's own: `NSApplication` names only three, and a four-button
    /// alert's last is `alertThirdButtonReturn + 1`. Pins the helper against the three that exist.
    @Test func theButtonPositionsAreAppKitsOwnNumbering() {
        #expect(EditorAlerts.divergenceResponse(atButtonIndex: 0) == .alertFirstButtonReturn)
        #expect(EditorAlerts.divergenceResponse(atButtonIndex: 1) == .alertSecondButtonReturn)
        #expect(EditorAlerts.divergenceResponse(atButtonIndex: 2) == .alertThirdButtonReturn)
        #expect(EditorAlerts.divergenceResponse(atButtonIndex: 3).rawValue
                == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1)
    }

    /// Neither destructive answer keeps Return, and the detour is not destructive: the alert strips
    /// Return and paints destructive styling from this, and "Compare…" discards nothing.
    @Test func onlyTheAnswersThatDiscardSomethingAreDestructive() {
        #expect(EditorAlerts.DivergenceAnswer.saveAnyway.isDestructive(for: .changed))
        #expect(EditorAlerts.DivergenceAnswer.reloadFromDisk.isDestructive(for: .changed))
        #expect(!EditorAlerts.DivergenceAnswer.showWhatChanged.isDestructive(for: .changed))
        #expect(!EditorAlerts.DivergenceAnswer.cancel.isDestructive(for: .changed))
        // Save Again discards nothing, so it is not destructive here or on the banner.
        #expect(!EditorAlerts.DivergenceAnswer.saveAnyway.isDestructive(for: .missing))

        // Position by position, as the alert applies it: for a changed file exactly Use Disk Version
        // and Keep Mine… are stripped, and for a missing one nothing.
        for divergence in [EditorFileStore.Divergence.changed, .missing] {
            let titles = EditorAlerts.divergenceButtonTitles(for: divergence)
            let destructive = titles.indices.filter {
                EditorAlerts.divergenceAnswer(for: EditorAlerts.divergenceResponse(atButtonIndex: $0),
                                              divergence: divergence).isDestructive(for: divergence)
            }
            #expect(destructive.map { titles[$0] } == (divergence == .changed ? ["Use Disk Version", "Keep Mine…"] : []),
                    "\(divergence): destructive styling lands on \(destructive.map { titles[$0] })")
            #expect(!destructive.contains { titles[$0] == "Cancel" },
                    "\(divergence): Cancel would be styled destructive and lose its Escape")
        }
    }

    /// A gone file is offered neither the reload nor the diff: there is nothing at that path to read.
    @Test func aMissingFileIsNotOfferedTheDiffEither() {
        // No position on a missing file answers `.showWhatChanged`, whatever AppKit returns.
        for index in 0..<6 {
            #expect(EditorAlerts.divergenceAnswer(
                for: EditorAlerts.divergenceResponse(atButtonIndex: index),
                divergence: .missing) != .showWhatChanged)
        }
    }

    /// The overlay's foot hands back the alert's own answers, and can't hand back the detour, which
    /// would reopen the overlay from inside itself and leave the question unanswerable.
    @Test func theOverlayAnswersWithTheSameThreeVerbsTheAlertOffers() {
        #expect(EditorAlerts.divergenceAnswer(for: EditorDivergenceVerdict.saveAnyway) == .saveAnyway)
        #expect(EditorAlerts.divergenceAnswer(for: .reloadFromDisk) == .reloadFromDisk)
        #expect(EditorAlerts.divergenceAnswer(for: .cancel) == .cancel)
    }

    /// Anything AppKit returns that is not a button this alert drew changes nothing, the same rule
    /// the unsaved question keeps.
    @Test func anUnrecognisedResponseChangesNothing() {
        for divergence in [EditorFileStore.Divergence.changed, .missing] {
            // One past the last button the alert drew.
            let pastTheEnd = EditorAlerts.divergenceResponse(
                atButtonIndex: EditorAlerts.divergenceButtonTitles(for: divergence).count)
            #expect(EditorAlerts.divergenceAnswer(for: pastTheEnd, divergence: divergence) == .cancel)
            #expect(EditorAlerts.divergenceAnswer(for: .stop, divergence: divergence) == .cancel)
            #expect(EditorAlerts.divergenceAnswer(for: .abort, divergence: divergence) == .cancel)
        }
    }

    /// The default keeps every existing caller of this function meaning what it meant.
    @Test func theUnsavedQuestionDefaultsToNo() {
        #expect(SyncCloudAppDelegate.quitDecision(activeOperations: 0, warnBeforeQuit: true)
                == .allowNoActiveOperations)
    }

    /// The guard follows the live document, taking the newest rather than the first. Unlike
    /// `adoptSyncManager` (where a re-run `App.init` offers a throwaway `@StateObject`), the reference
    /// is `weak` and there is one document: keeping the first would hold a stale one mid-teardown,
    /// and the quit guard would answer "nothing unsaved" about a document nobody can see.
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

        // It answers with the live document's state. A real file, because `isDirty` is false with
        // nothing open: the buffer is at risk only once it stands for something on disk.
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
