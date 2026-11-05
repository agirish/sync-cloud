import Testing
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// Which autosave stops have a second version to show, and which are only words.
///
/// Once the modal alert is dismissed the header's amber line is all that's on screen, and Cancel
/// leaves the latch set, so it is the natural door back to "which version wins". It is a door for
/// one stop only. A moved or renamed file has nothing at its path for the right-hand column, and a
/// write that failed outright is not a disagreement between two versions.
@Suite struct EditorAutosaveStopDoorTests {

    @Test func onlyAChangedFileOffersTheDiff() {
        #expect(EditorAutosaveStop.diverged(.changed).offersDiff)
        #expect(!EditorAutosaveStop.diverged(.missing).offersDiff,
                "a moved or renamed file has nothing at its path to show on the right")
        #expect(!EditorAutosaveStop.failed("No space left on device").offersDiff,
                "a failed write is one version and an error, not two versions to compare")
    }

    /// Every stop says something, whether or not it is a door: a stop that isn't a door must still
    /// be legible state, not an empty line.
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

    /// A save that landed is not reported as one that failed. The banner says "Saved “x”, but …"
    /// as a warning, the header says it couldn't check the save rather than couldn't write, and
    /// both stops carry their reason for the word's tooltip.
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

    /// Every save failure in the editor (⌘S's write, the flush on leaving, the autosave) is said
    /// through the stop, so none composes "Couldn't save — Saved, but…". The header is handed the
    /// reason for its tooltip.
    @Test func everySaveFailureIsSaidThroughTheStop() throws {
        let editor = CodeText(try EditorDivergenceWiringTests.source("ContentView+Editor.swift"))
        #expect(!editor.contains("\"Couldn't save “\\(editorDocument.name)” — \\(message)\""),
                "a save failure composes its own banner again")
        #expect(editor.contains("let stop = EditorAutosaveStop(saveError: error)"))
        #expect(editor.count(of: "case .savedUnchecked(let clause): editorAutosaveStop = .unchecked(clause)") == 2)
        let call = try CallArguments(of: "EditorWorkspaceView(", in: normalizedCode(EditorDivergenceWiringTests.source("ContentView+Editor.swift")))
        #expect(call.passes("stoppedDetail", "editorAutosaveStop?.detail"))
    }

    /// The one stop that is a door is the one whose words say the file changed, so the sentence
    /// the reader clicks and what they are shown are about the same event.
    @Test func theDoorIsOnTheWordsThatNameTheChange() {
        #expect(EditorAutosaveStop.diverged(.changed).caption == "not saving — changed on disk")
    }
}

/// The editor's divergence wiring inside `ContentView`, which nothing else in the suite can see.
///
/// `ContentView` declares private stored properties, so its memberwise initializer is private
/// and `@testable` can't raise it (see `BrowseWorkspaceCallSiteTests`). So these are checked at
/// the source level with that file's guards: name what you read, fail loudly when it can't be
/// read, and keep a positive control so a rename can't hollow the scan out.
@Suite struct EditorDivergenceWiringTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/SyncCloudTests
            .deletingLastPathComponent()                   // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        try #require(text.count > 500,
                     "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// The positive control: this scan is reading real text, so an assertion that finds nothing is
    /// a finding rather than an empty haystack.
    @Test func theScanCanActuallyFail() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("func saveEditorDocument()"),
                "the scan is not looking at ContentView+Editor.swift")
        #expect(!editor.contains("thisStringIsNotInTheFile"))
    }

    /// Which stops save from the header and which are Save Again: the stop's rule, by which the
    /// host hands the closures over.
    @Test func whichStopsSaveFromTheHeader() throws {
        #expect(EditorAutosaveStop.failed("No space left on device").savesFromTheHeader)
        #expect(!EditorAutosaveStop.unchecked("x").savesFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.changed).savesFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.missing).savesFromTheHeader)
        #expect(EditorAutosaveStop.diverged(.missing).savesAgainFromTheHeader)
        #expect(!EditorAutosaveStop.diverged(.changed).savesAgainFromTheHeader)
        #expect(!EditorAutosaveStop.unchecked("x").savesAgainFromTheHeader)
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("onSaveNow: (editorAutosaveStop?.savesFromTheHeader ?? true) ? { _ = saveEditorDocument() } : nil,"))
        #expect(editor.contains("onSaveAgain: (editorAutosaveStop?.savesAgainFromTheHeader ?? false)"))
        #expect(editor.contains("? { saveEditorDocumentAgain(explicit: true) } : nil,"))
    }

    /// Try Again reads the refused file once more, where it is, not as a new open, so its place in
    /// the recent files stays.
    @Test func tryAgainReReadsTheRefusedFile() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("onTryAgain: { if let path = editorDocument.path, editorDocument.refusal != nil { loadIntoEditor(path: path, recordsRecent: false) } },"))
    }

    /// The header's door is guarded by the stop's own rule, not a condition written twice.
    ///
    /// `EditorAutosaveStop.offersDiff` states and tests "which stops have something to show"; a
    /// call site spelling out `if case .diverged(.changed)` would be a second copy, free to drift.
    @Test func theHeaderIsHandedTheDoorOnlyWhenTheStopOffersOne() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("onShowWhatChanged: (editorAutosaveStop?.offersDiff ?? false)"),
                "the header's door is no longer gated on EditorAutosaveStop.offersDiff")
        #expect(editor.contains("? { showEditorDivergenceDiff() } : nil"),
                "the door is not withheld (nil) for the stops that have nothing to show")
    }

    /// Neither alert call site may answer the question itself.
    ///
    /// `.showWhatChanged` resolves nothing, so a call site switching over the answer inline could
    /// fall through on it and leave the document latched-stopped with the question drawn nowhere.
    /// One function acts on the enum; this keeps it one.
    @Test func bothAlertCallSitesRouteThroughTheOnePlaceThatAnswers() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.components(separatedBy: "EditorAlerts.askAboutDivergence").count - 1 == 2,
                "the number of divergence alerts moved — the two checked below may not be them")
        #expect(editor.components(separatedBy: "applyDivergenceAnswer(").count - 1 >= 4,
                "expected the declaration plus a call from ⌘S, from autosave, from the header's door and from the overlay")
        // The inline shape is absent from both, not merely joined by the routed one. It opens
        // `switch EditorAlerts.askAboutDivergence(`, so its absence is the check, and it is
        // whitespace-free, unlike matching the arms.
        #expect(!editor.contains("switch EditorAlerts.askAboutDivergence"),
                "a call site still switches over the answer itself, where .showWhatChanged can fall through")
        #expect(!editor.contains("_ = writeEditorDocument(explicit: false)"),
                "the autosave path still writes from its own arm rather than through applyDivergenceAnswer")
    }

    /// The latch goes on before the overlay opens. While two versions are on screen the debounce
    /// must not quietly write one of them, and the latch makes dismissing the overlay identical to
    /// Cancel, which Escape relies on.
    @Test func askingToSeeTheDiffStopsAutosaveFirst() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        // The `.showWhatChanged` arm and nothing else: from its `case` to the next, inside the one
        // function that answers. A fixed-length window could run into the `.cancel` arm, whose
        // own latch would stand in for this one's.
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

    /// The answer is about the file the diff showed, and only that one.
    ///
    /// The overlay leads the chain and its scrim absorbs clicks, but the menu bar stays live: File
    /// ▸ Open and ⌘N can hand the editor another document meanwhile. Save Anyway would then
    /// overwrite that document on the strength of a comparison of something else.
    @Test func anAnswerIsDroppedIfTheOpenDocumentChangedUnderIt() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("var path: String"),
                "the pending review no longer records which document it is about")
        #expect(editor.contains("guard editorDocument.path == review.path else {"),
                "the overlay's answer is applied without checking it is still the same document")
        // The answer is applied to the reviewed path, not whatever is open now; otherwise the
        // guard alone would stand between a reload and the wrong file.
        #expect(editor.contains("path: review.path, explicit: review.explicit"),
                "the answer is routed with the live path rather than the reviewed one")
        #expect(!editor.contains("path: editorDocument.path ?? \"\", explicit: review.explicit"),
                "the old shape is still there — the guard can be true and the path still wrong")
    }

    /// The overlay is mounted where nothing can cover it. It is up because a modal alert asked and
    /// the reader chose to look first, with autosave latched behind it; a panel drawn over it would
    /// leave the document not saving with its question drawn nowhere.
    @Test func theOverlayLeadsTheWindowsOverlayChain() throws {
        let content = try Self.source("ContentView.swift")
        let chain = try #require(content.range(of: "EditorDivergenceDiffOverlay("),
                                 "the divergence overlay is not mounted in ContentView at all")
        let picker = try #require(content.range(of: "destinationOverlay"))
        #expect(chain.lowerBound < picker.lowerBound,
                "the divergence question no longer leads the overlay chain — something can cover it")
        #expect(content.contains("if editorDivergenceReview != nil {"),
                "the overlay is not gated on the pending question")
    }
}
