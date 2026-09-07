import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **Which autosave stops have a second version to show, and which are only words.**
///
/// The header's amber line is the only thing on screen once the modal alert has been dismissed, and
/// Cancel leaves the latch set — so it is the natural door back to "which version wins". It is a
/// door for exactly one of the three stops. The other two would be buttons that cannot do what they
/// say: a file that has been moved or renamed has nothing at its path to put in the right-hand
/// column, and a write that failed outright is not a disagreement between two versions at all.
@Suite struct EditorAutosaveStopDoorTests {

    @Test func onlyAChangedFileOffersTheDiff() {
        #expect(EditorAutosaveStop.diverged(.changed).offersDiff)
        #expect(!EditorAutosaveStop.diverged(.missing).offersDiff,
                "a moved or renamed file has nothing at its path to show on the right")
        #expect(!EditorAutosaveStop.failed("No space left on device").offersDiff,
                "a failed write is one version and an error, not two versions to compare")
    }

    /// **Every stop still says something, whether or not it is a door.** The two are independent:
    /// making the words clickable must not have changed what they say, and a stop that is not a
    /// door must still be a legible piece of state rather than an empty line.
    @Test func everyStopStillCarriesItsOwnWords() {
        let stops: [EditorAutosaveStop] = [.diverged(.changed), .diverged(.missing),
                                           .failed("No space left on device")]
        for stop in stops {
            #expect(!stop.caption.isEmpty)
            #expect(stop.caption.hasPrefix("not saving"), "got “\(stop.caption)”")
        }
        // Distinct, so the door's case is identifiable on screen and not just in the type.
        #expect(Set(stops.map(\.caption)).count == stops.count)
    }

    /// The one stop that is a door is the one whose words say the file CHANGED — so the sentence the
    /// reader clicks and the thing they are shown are about the same event.
    @Test func theDoorIsOnTheWordsThatNameTheChange() {
        #expect(EditorAutosaveStop.diverged(.changed).caption == "not saving — changed on disk")
    }
}

/// The editor's divergence wiring inside `ContentView`, which nothing else in the suite can see.
///
/// `ContentView` declares private stored properties, so its memberwise initializer is private and
/// `@testable` cannot raise it — the reason `BrowseWorkspaceCallSiteTests` gives at length. These
/// are the properties that cannot be reached any other way, checked at the source level with that
/// file's guards: name what you read, fail loudly when it cannot be read, and keep a positive
/// control so a rename cannot hollow the scan out.
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

    /// **The header's door is guarded by the stop's own rule, not by a condition written twice.**
    ///
    /// `EditorAutosaveStop.offersDiff` is where "which stops have something to show" is stated and
    /// tested; a call site that spelled out `if case .diverged(.changed)` instead would be a second
    /// copy of that rule, free to drift from the tested one.
    @Test func theHeaderIsHandedTheDoorOnlyWhenTheStopOffersOne() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("onShowWhatChanged: (editorAutosaveStop?.offersDiff ?? false)"),
                "the header's door is no longer gated on EditorAutosaveStop.offersDiff")
        #expect(editor.contains("? { showEditorDivergenceDiff() } : nil"),
                "the door is not withheld (nil) for the stops that have nothing to show")
    }

    /// **Neither alert call site may answer the question itself.**
    ///
    /// Both used to `switch` over the answer inline, which was fine while there were three cases
    /// that each resolved something. `.showWhatChanged` resolves nothing, so a call site that fell
    /// through on it would leave the document latched-stopped with the question drawn nowhere. One
    /// function acts on the enum; this is what keeps it one.
    @Test func bothAlertCallSitesRouteThroughTheOnePlaceThatAnswers() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.components(separatedBy: "EditorAlerts.askAboutDivergence").count - 1 == 2,
                "the number of divergence alerts moved — the two checked below may not be them")
        #expect(editor.components(separatedBy: "applyDivergenceAnswer(").count - 1 >= 4,
                "expected the declaration plus a call from ⌘S, from autosave, from the header's door and from the overlay")
        // The old inline shape is gone from both, not merely joined by the new one. Both call sites
        // opened `switch EditorAlerts.askAboutDivergence(`, so its absence is the whole check —
        // and it is whitespace-free, unlike matching the arms themselves.
        #expect(!editor.contains("switch EditorAlerts.askAboutDivergence"),
                "a call site still switches over the answer itself, where .showWhatChanged can fall through")
        #expect(!editor.contains("_ = writeEditorDocument(explicit: false)"),
                "the autosave path still writes from its own arm rather than through applyDivergenceAnswer")
    }

    /// **The latch goes on before the overlay opens.** While two versions are on screen the
    /// debounce must not quietly write one of them — and it is what makes dismissing the overlay
    /// identical to Cancel, which is the property Escape has to have.
    @Test func askingToSeeTheDiffStopsAutosaveFirst() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        let marker = "case .showWhatChanged:"
        let body = try #require(editor.range(of: marker)).upperBound
        let window = String(editor[body...].prefix(600))
        let latch = try #require(window.range(of: "editorAutosaveStop = .diverged(divergence)"),
                                 "the detour does not latch autosave — the debounce could write under the overlay")
        let opens = try #require(window.range(of: "editorDivergenceReview = "),
                                 "the detour does not open the overlay")
        #expect(latch.lowerBound < opens.lowerBound,
                "the overlay is opened before the latch is set — a write could land in between")
    }

    /// **The answer is about the file the diff showed, and only that one.**
    ///
    /// The overlay leads the overlay chain and its scrim absorbs clicks, but the menu bar stays
    /// live — File ▸ Open and ⌘N can hand the editor another document while two versions of this
    /// one are on screen. Save Anyway would then overwrite that document on the strength of a
    /// comparison of something else, which is the one way this surface could cost work.
    @Test func anAnswerIsDroppedIfTheOpenDocumentChangedUnderIt() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        #expect(editor.contains("var path: String"),
                "the pending review no longer records which document it is about")
        #expect(editor.contains("guard editorDocument.path == review.path else {"),
                "the overlay's answer is applied without checking it is still the same document")
        // And the answer is applied to the reviewed path, not to whatever is open now — otherwise
        // the guard would be the only thing standing between a reload and the wrong file.
        #expect(editor.contains("path: review.path, explicit: review.explicit"),
                "the answer is routed with the live path rather than the reviewed one")
        #expect(!editor.contains("path: editorDocument.path ?? \"\", explicit: review.explicit"),
                "the old shape is still there — the guard can be true and the path still wrong")
    }

    /// **The overlay is mounted where nothing can cover it.** It is on screen only because a modal
    /// alert asked and the reader chose to look first, with autosave latched stopped behind it; an
    /// ambient panel drawn over it would leave the document not saving with the question it waits
    /// on drawn nowhere.
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
