import Testing
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// Which autosave stops have a second version to show. Once the alert is dismissed the header's
/// amber line is the door back to "which version wins", but for one stop only: a moved file has
/// nothing at its path to show, and a failed write is not a disagreement between two versions.
@Suite struct EditorAutosaveStopDoorTests {
    @Test func onlyAChangedFileOffersTheDiff() {
        #expect(EditorAutosaveStop.diverged(.changed).offersDiff)
        #expect(!EditorAutosaveStop.diverged(.missing).offersDiff,
                "a moved or renamed file has nothing at its path to show on the right")
        #expect(!EditorAutosaveStop.failed("No space left on device").offersDiff,
                "a failed write is one version and an error, not two versions to compare")
    }

    /// Every stop says something, door or not: a stop must be legible state, not an empty line.
    @Test func everyStopStillCarriesItsOwnWords() {
        let stops: [EditorAutosaveStop] = [.diverged(.changed), .diverged(.missing),
                                           .failed("No space left on device"),
                                           .unchecked("couldn’t read it back to check it.")]
        for stop in stops {
            #expect(!stop.caption.isEmpty)
            #expect(stop.caption.hasPrefix("not saving"), "got “\(stop.caption)”")
        }
        // Distinct, so the door's case is identifiable on screen and not just in the type.
        #expect(Set(stops.map(\.caption)).count == stops.count)
    }

    /// A save that landed is not reported as a failure: the banner warns "Saved “x”, but …", the
    /// header says it couldn't check the save, and both stops carry their reason for the tooltip.
    @Test func aSaveThatLandedIsNotReportedAsAFailure() {
        let unchecked = EditorAutosaveStop(saveError: EditorFileStore.Failure(
            message: "Saved, but couldn’t read it back to check it.",
            savedBut: "couldn’t read it back to check it."))
        #expect(unchecked == .unchecked("couldn’t read it back to check it."))
        let banner = unchecked.banner(name: "Plan.md")
        #expect(banner?.message == "Saved “Plan.md”, but couldn’t read it back to check it.")
        #expect(banner?.severity == .warning)
        #expect(unchecked.caption == "not saving — couldn’t check the save")
        #expect(unchecked.detail == "Saved, but couldn’t read it back to check it.")
        #expect(!unchecked.offersDiff)

        let failed = EditorAutosaveStop(saveError: EditorFileStore.Failure(message: "Permission denied"))
        #expect(failed == .failed("Permission denied"))
        #expect(failed.banner(name: "Plan.md")?.message == "Couldn’t save “Plan.md” — Permission denied")
        #expect(failed.banner(name: "Plan.md")?.severity == .error)
        #expect(failed.detail == "Permission denied", "the red word's tooltip lost the reason")
        #expect(EditorAutosaveStop.diverged(.changed).detail == nil, "the door has its own tooltip")
        #expect(EditorAutosaveStop.diverged(.changed).banner(name: "x") == nil)
    }

    /// Every save failure in the editor (⌘S, the flush on leaving, autosave) is said through the
    /// stop, so none composes "Couldn't save — Saved, but…". The header gets the reason as tooltip.
    @Test func everySaveFailureIsSaidThroughTheStop() throws {
        let editor = CodeText(try macAppFile("ContentView+Editor.swift"))
        #expect(editor.contains("let stop = EditorAutosaveStop(saveError: error)"))
        #expect(editor.count(of: "case .savedUnchecked(let clause): editorAutosaveStop = .unchecked(clause)") == 2)
        let call = try CallArguments(of: "EditorWorkspaceView(", in: normalizedCode(macAppFile("ContentView+Editor.swift")))
        #expect(call.passes("stoppedDetail", "editorAutosaveStop?.detail"))
    }

    /// The one door is on the stop whose words say the file changed, so what the reader clicks and
    /// what they are shown are about the same event.
    @Test func theDoorIsOnTheWordsThatNameTheChange() {
        #expect(EditorAutosaveStop.diverged(.changed).caption == "not saving — changed on disk")
    }
}

/// The editor's divergence wiring inside `ContentView`, checked at source level because its
/// memberwise initializer is private (see `BrowseWorkspaceCallSiteTests`), with that file's
/// guards: name what you read, fail loudly when it can't be read, keep a positive control.
@Suite struct EditorDivergenceWiringTests {
    /// Which stops save from the header and which are Save Again, by the stop's own rule.
    @Test func whichStopsSaveFromTheHeader() throws {
        #expect(EditorAutosaveStop.failed("No space left on device").savesFromTheHeader)
        #expect(!EditorAutosaveStop.unchecked("x").savesFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.changed).savesFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.missing).savesFromTheHeader)
        #expect(EditorAutosaveStop.diverged(.missing).savesAgainFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.changed).savesAgainFromTheHeader)
        #expect(!EditorAutosaveStop.unchecked("x").savesAgainFromTheHeader)
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        #expect(editor.contains("onSaveNow: (editorAutosaveStop?.savesFromTheHeader ?? true) ? { _ = saveEditorDocument() } : nil,"))
        #expect(editor.contains("onSaveAgain: (editorAutosaveStop?.savesAgainFromTheHeader ?? false)"))
        #expect(editor.contains("? { saveEditorDocumentAgain(explicit: true) } : nil,"))
    }

    /// The header's door is guarded by `EditorAutosaveStop.offersDiff`, not a second copy such as
    /// `if case .diverged(.changed)` at the call site, free to drift.
    @Test func theHeaderIsHandedTheDoorOnlyWhenTheStopOffersOne() throws {
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        #expect(editor.contains("onShowWhatChanged: (editorAutosaveStop?.offersDiff ?? false)"),
                "the header's door is no longer gated on EditorAutosaveStop.offersDiff")
        #expect(editor.contains("? { showEditorDivergenceDiff() } : nil"),
                "the door is not withheld (nil) for the stops that have nothing to show")
    }

    /// Neither alert call site answers the question itself: `.showWhatChanged` resolves nothing, so an
    /// inline switch could fall through on it and leave the document latched with the question drawn
    /// nowhere. One function acts on the enum.
    @Test func bothAlertCallSitesRouteThroughTheOnePlaceThatAnswers() throws {
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        #expect(editor.components(separatedBy: "EditorAlerts.askAboutDivergence").count - 1 == 2,
                "the number of divergence alerts moved — the two checked below may not be them")
        #expect(editor.components(separatedBy: "applyDivergenceAnswer(").count - 1 >= 4,
                "expected the declaration plus a call from ⌘S, from autosave, from the header's door and from the overlay")
        // The inline shape `switch EditorAlerts.askAboutDivergence(` is absent from both, not merely
        // joined by the routed one.
        #expect(!editor.contains("switch EditorAlerts.askAboutDivergence"),
                "a call site still switches over the answer itself, where .showWhatChanged can fall through")
        #expect(!editor.contains("_ = writeEditorDocument(explicit: false)"),
                "the autosave path still writes from its own arm rather than through applyDivergenceAnswer")
    }

    /// The latch goes on before the overlay opens, so the debounce can't write one of two versions on
    /// screen, and dismissing the overlay equals Cancel, which Escape relies on.
    @Test func askingToSeeTheDiffStopsAutosaveFirst() throws {
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        // The `.showWhatChanged` arm alone, from its `case` to the next: a fixed-length window could
        // run into the `.cancel` arm, whose own latch would stand in for this one's.
        let answer = CodeText(try declarationBody(of: "func applyDivergenceAnswer(", in: editor))
        let arm = try #require(answer.range(of: "case .showWhatChanged:"), "the detour's arm is gone")
        let next = answer.normalized[arm.upperBound...].range(of: normalizedCode("case ."))?.lowerBound
            ?? answer.normalized.endIndex
        let window = CodeText(String(answer.normalized[arm.upperBound..<next]))
        let latch = try #require(window.range(of: "editorAutosaveStop = .diverged(divergence)"),
                                 "the detour does not latch autosave — the debounce could write under the overlay")
        let opens = try #require(window.range(of: "editorDivergenceReview = "),
                                 "the detour does not open the overlay")
        #expect(latch.lowerBound < opens.lowerBound,
                "the overlay is opened before the latch is set — a write could land in between")
    }

    /// The answer is dropped if the open document changed: the overlay's scrim absorbs clicks, but
    /// the menu bar stays live, so File ▸ Open or ⌘N could swap documents and Save Anyway would
    /// overwrite one on the strength of a comparison of another.
    @Test func anAnswerIsDroppedIfTheOpenDocumentChangedUnderIt() throws {
        let editor = sourceCodeOnly(try macAppFile("ContentView+Editor.swift"))
        #expect(editor.contains("var path: String"),
                "the pending review no longer records which document it is about")
        #expect(editor.contains("guard editorDocument.path == review.path else {"),
                "the overlay's answer is applied without checking it is still the same document")
        // Applied to the reviewed path, not whatever is open now, so the guard isn't the only thing
        // between a reload and the wrong file.
        #expect(editor.contains("path: review.path, explicit: review.explicit"),
                "the answer is routed with the live path rather than the reviewed one")
    }

    /// The overlay leads the overlay chain: a panel drawn over it would leave the document not saving
    /// (autosave is latched) with its question drawn nowhere.
    @Test func theOverlayLeadsTheWindowsOverlayChain() throws {
        let content = sourceCodeOnly(try macAppFile("ContentView.swift"))
        let chain = try #require(content.range(of: "EditorDivergenceDiffOverlay("),
                                 "the divergence overlay is not mounted in ContentView at all")
        let picker = try #require(content.range(of: "destinationOverlay"))
        #expect(chain.lowerBound < picker.lowerBound,
                "the divergence question no longer leads the overlay chain — something can cover it")
        #expect(content.contains("if editorDivergenceReview != nil {"),
                "the overlay is not gated on the pending question")
    }
}
