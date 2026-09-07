import Foundation
import SwiftUI
import AppKit
import Design
import Testing
@testable import FileExplorer

/// The "show me what changed" surface: what its two columns claim, and what it refuses to diff.
@Suite struct EditorDivergenceColumnTests {

    // MARK: The left column

    @Test func theEditorColumnCountsTheBufferSWords() {
        #expect(EditorDivergenceColumns.editor(words: 1_204) == "In the editor · 1,204 words")
    }

    /// **Singular is not a nicety on this line.** It is the same rule the status line under the
    /// document keeps, asked of the same function — a second spelling here is how "1 words" gets
    /// back in through a door nobody watches.
    @Test func oneWordIsOneWord() {
        #expect(EditorDivergenceColumns.editor(words: 1) == "In the editor · 1 word")
        #expect(EditorDivergenceColumns.editor(words: 0) == "In the editor · 0 words")
    }

    // MARK: The right column

    /// **What it says is when the bytes were written — never where they came from.**
    ///
    /// "changed on another machine" is the sentence this column is always tempted into, and from
    /// here a sync client, another app, a script and another Mac are indistinguishable. The mtime
    /// is a fact; the provenance is a guess the reader would act on.
    @Test func theDiskColumnDatesTheFileAndClaimsNothingElse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let caption = EditorDivergenceColumns.disk(modified: now.addingTimeInterval(-120), now: now)
        #expect(caption == "On disk · written 2m ago")
        for guess in ["machine", "device", "iCloud", "Dropbox", "someone"] {
            #expect(!caption.lowercased().contains(guess), "the column guessed at provenance: \(caption)")
        }
    }

    /// A file with no modification date says the honest nothing rather than an invented age.
    @Test func aFileWithNoDateGetsNoAge() {
        #expect(EditorDivergenceColumns.disk(modified: nil, now: Date()) == "On disk")
    }

    /// **Clock skew is ordinary in exactly the shared folders this overlay is about.** A file
    /// written by a machine whose clock runs ahead carries a future mtime, and "written -3s ago" is
    /// worse than no age at all.
    ///
    /// The property comes from `ScanFreshness.relative`, whose first bucket is `..<30` and swallows
    /// a negative interval into "0s ago" — stated here rather than clamped at the call site,
    /// because a `max(0, …)` there was measured to change nothing for any input and a redundant
    /// guard is a rule no test can hold. This is the assertion that the inherited behaviour is the
    /// one this caption actually gets.
    @Test func aFutureModificationDateDoesNotProduceANegativeAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let caption = EditorDivergenceColumns.disk(modified: now.addingTimeInterval(600), now: now)
        #expect(!caption.contains("-"), "got \(caption)")
        #expect(caption == "On disk · written 0s ago")
    }

    /// The two labels are what the pipeline's refusals name the sides, so a refused side reads as a
    /// thing rather than as a column.
    @Test func theColumnsAndTheRefusalsUseTheSameTwoNames() {
        #expect(EditorDivergenceColumns.editor(words: 3).hasPrefix(EditorDivergenceColumns.editorLabel))
        #expect(EditorDivergenceColumns.disk(modified: nil, now: Date()) == EditorDivergenceColumns.diskLabel)
    }
}

/// What the overlay does with a file `BoundedTextRead` will not read.
///
/// **The refusal has to name the reason, and the side.** The reader is being asked which of two
/// versions of their work wins; "there is no diff" tells them nothing about whether the file on
/// disk is a 90 MB log, a placeholder that has not come down from the cloud, or something that is
/// not text at all — and those want three different next moves.
@Suite struct EditorDivergenceRefusalTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("divergence-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pass the overlay runs, over a real file — the same call, with the same two labels.
    private func diff(buffer: String, diskPath: String) -> TextPairDiffPipeline.Outcome {
        TextPairDiffPipeline.diff(
            left: .text(buffer, lossy: false, encoding: .utf8),
            right: BoundedTextRead.read(path: diskPath),
            leftLabel: EditorDivergenceColumns.editorLabel,
            rightLabel: EditorDivergenceColumns.diskLabel,
            isCancelled: { false })
    }

    @Test func anOrdinaryChangedFileIsDiffedAgainstTheBuffer() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("note.md").path
        try Data("one\nthey typed this\n".utf8).write(to: URL(fileURLWithPath: path))

        let outcome = diff(buffer: "one\nI typed this\n", diskPath: path)
        let result = try #require(outcome.diff)
        #expect(result.changedLineCount == 1)
        #expect(outcome.notes.isEmpty, "an ordinary pair should have nothing to explain: \(outcome.notes)")
    }

    /// A file that is not text refuses, names the side, and gives the reason in the reader's words.
    @Test func aBinaryFileOnDiskIsRefusedWithItsReason() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("note.md").path
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: URL(fileURLWithPath: path))

        let outcome = diff(buffer: "one\n", diskPath: path)
        #expect(outcome.diff == nil)
        let note = try #require(outcome.notes.first)
        #expect(note.hasPrefix("On disk: "), "got \(note)")
        #expect(note.contains("Nothing readable as text here"), "got \(note)")
        // The buffer is never the refused side: it is in memory and always readable.
        #expect(!outcome.notes.contains { $0.hasPrefix("In the editor: ") })
    }

    /// A file that has vanished between the stat and the read refuses rather than diffing against
    /// nothing. (The alert does not offer the diff for a `.missing` divergence at all — this is the
    /// race where it goes after the question was asked.)
    @Test func aFileThatIsGoneByTheTimeItIsReadRefuses() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = diff(buffer: "one\n", diskPath: folder.appendingPathComponent("gone.md").path)
        #expect(outcome.diff == nil)
        #expect(outcome.notes.first?.hasPrefix("On disk: ") == true, "got \(outcome.notes)")
    }

    /// **An encoding that changed under the buffer is a real difference the rows cannot show.** The
    /// buffer is handed to the pipeline carrying the encoding the document was opened in, so the
    /// same note that reports this for two files reports it here.
    @Test func aFileRewrittenInAnotherEncodingSaysSo() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("note.md").path
        var bytes = Data([0xFF, 0xFE])                       // UTF-16 LE BOM
        bytes.append(contentsOf: Array("one\n".utf16).flatMap {
            [UInt8($0 & 0xFF), UInt8($0 >> 8)]
        })
        try bytes.write(to: URL(fileURLWithPath: path))

        let outcome = TextPairDiffPipeline.diff(
            left: .text("one\n", lossy: false, encoding: .utf8),
            right: BoundedTextRead.read(path: path),
            leftLabel: EditorDivergenceColumns.editorLabel,
            rightLabel: EditorDivergenceColumns.diskLabel,
            isCancelled: { false })
        #expect(outcome.diff?.changedLineCount == 0, "the text is the same; only the bytes differ")
        #expect(outcome.notes.contains { $0.contains("Encodings differ") },
                "nothing said the file was rewritten in another encoding: \(outcome.notes)")
    }
}

/// **Escape must be safe, and there is one way to check that from here.**
///
/// The keys are `.onKeyPress` handlers on a focusable card — deliberately, because a
/// `.keyboardShortcut` on an in-window overlay registers a WINDOW-level equivalent and would eat
/// bare esc and bare ⏎ typed into the editor behind the scrim (`BareKeyEquivalentScanTests` bans it
/// repo-wide). That also puts them out of reach of a hosted test: `swift test` has no key window to
/// type into, so a rendered assertion would pass whether the handler answered `cancel` or
/// `saveAnyway`. The source is the only place the answer is legible, which is the argument
/// `UnnamedControlScanTests` makes for the same shape.
@Suite struct EditorDivergenceDismissalTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/Tests/FileExplorer
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer/EditorDivergenceDiffOverlay.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read the overlay — every check below would be vacuous")
        try #require(text.count > 2000, "the overlay source is implausibly short")
        return text
    }

    /// The positive control: this scan is reading the file it names.
    @Test func theScanCanActuallyFail() throws {
        let source = try Self.source()
        #expect(source.contains("public struct EditorDivergenceDiffOverlay"))
        #expect(!source.contains("thisStringIsNotInTheFile"))
    }

    /// **Every way OUT of the surface that is not one of the three buttons answers `cancel`.**
    ///
    /// Escape, ⏎, the keypad's Enter and a click on the scrim: four dismissals, one answer, and it
    /// is the answer that changes nothing on disk. A keystroke is not how somebody says which
    /// version of their work to throw away.
    @Test func escapeAndReturnAndTheScrimAllAnswerCancel() throws {
        let source = try Self.source()
        #expect(source.contains(".onTapGesture { onAnswer(.cancel) }"),
                "clicking the scrim no longer answers Cancel")
        let keys = try #require(source.range(of: ".onKeyPress(keys: [.escape, .return, .keypadEnter]"),
                                "the dismissal keys are no longer esc/⏎/keypad-Enter on one handler")
        let handler = String(source[keys.upperBound...].prefix(300))
        #expect(handler.contains("onAnswer(.cancel)"), "the dismissal keys no longer answer Cancel")
        #expect(!handler.contains(".saveAnyway") && !handler.contains(".reloadFromDisk"),
                "a dismissal key reaches a destructive answer")
    }

    /// **Nothing on this surface writes**, and the check that comes closest to saying so at the
    /// source level: the file never touches the store's write path, and the only answers it can
    /// produce are the three the alert already offers.
    @Test func theOverlayHasNoWritePathOfItsOwn() throws {
        let source = try Self.source()
        for writer in ["EditorFileStore.write", "markSaved", "EditorAutosave."] {
            #expect(!source.contains(writer),
                    "the overlay reaches \(writer) — Save Anyway is supposed to be the host's write, not a second one")
        }
        // Exactly three answers leave here, and `.showWhatChanged` is not among them — a surface
        // that could reopen itself would leave the question unanswerable.
        #expect(!source.contains("showWhatChanged"))
    }
}

/// The header's amber words: a door when there is something behind them, plain state when not.
@MainActor
@Suite(.serialized) struct EditorStatusWordDoorTests {

    /// `width` pins the row so the height can be compared; passing `nil` lets the header find its
    /// own width, which is the axis the door's padding moves.
    private func size<V: View>(_ view: V, width: CGFloat?) -> CGSize {
        NSHostingView(rootView: AnyView(
            width.map { AnyView(view.frame(width: $0)) } ?? AnyView(view))).fittingSize
    }

    private func document(text: String = "hello") throws -> EditorDocument {
        let folder = NSTemporaryDirectory() + "status-word-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("note.md")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        // Dirty, because a stop is only ever interesting under an unsaved buffer — and `stopped`
        // outranks dirtiness in `EditorSaveStatus.resolve`, so this is the state the header draws.
        document.text = text + "typed\n"
        return document
    }

    private func workspace(_ document: EditorDocument, stopped: String?,
                           door: (() -> Void)?) -> EditorWorkspaceView {
        EditorWorkspaceView(
            document: document,
            autosavePolicy: EditorAutosavePolicy(),
            folder: "/n",
            entries: [],
            accent: .blue,
            onAccent: .white,
            mode: .constant(.edit),
            splitFraction: .constant(0.5),
            isNaming: .constant(false),
            typedName: .constant(""),
            railFilter: .constant(""),
            railFilterIsExpanded: .constant(false),
            railTab: .constant(.files),
            railOutlineAnchors: .constant([:]),
            undoManager: UndoManager(),
            stopped: stopped,
            onShowWhatChanged: door,
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            onOpen: { _ in },
            onCreate: { _ in true },
            onRevealInBrowse: { _ in })
    }

    /// **The header really branches on the door, at render time.**
    ///
    /// The two headers hold the identical words and differ only in whether one closure was handed
    /// over — so any measured difference between them can only come from the button branch being
    /// taken. Measured rather than read out of the source because the source scan beside this one
    /// (`EditorDivergenceWiringTests`) proves the HOST withholds the closure, and proves nothing
    /// about what the view does with it.
    @Test func thePillIsDrawnAsAControlOnlyWhenItIsOne() throws {
        let document = try document()
        let words = "not saving — changed on disk"
        // No width frame: at a pinned width the row's `Spacer` absorbs the padding and both
        // headers measure exactly the pin, which is a tautology rather than a measurement.
        let plain = size(workspace(document, stopped: words, door: nil).headerContent, width: nil)
        let control = size(workspace(document, stopped: words, door: {}).headerContent, width: nil)
        #expect(control.width > plain.width,
                "the same words measured \(control.width)pt with a door and \(plain.width)pt without — the button branch is not being taken")
    }

    /// The control is the same HEIGHT, so a header that grows a door does not push the document
    /// column below it down — the property the whole header is built around.
    @Test func theDoorDoesNotChangeTheHeadersHeight() throws {
        let document = try document()
        let words = "not saving — changed on disk"
        let plain = size(workspace(document, stopped: words, door: nil).headerContent, width: 520)
        let control = size(workspace(document, stopped: words, door: {}).headerContent, width: 520)
        #expect(abs(control.height - plain.height) < 0.51,
                "with a door the header is \(control.height)pt and without it \(plain.height)pt")
    }

    /// **No stop, no door**, whatever the host hands over: there are no amber words to click, so a
    /// closure passed here must draw nothing at all.
    @Test func aDocumentThatIsSavingHasNoWordsToClick() throws {
        let document = try document()
        let a = size(workspace(document, stopped: nil, door: nil).headerContent, width: nil)
        let b = size(workspace(document, stopped: nil, door: {}).headerContent, width: nil)
        #expect(abs(a.width - b.width) < 0.51,
                "a door appeared on a header with no stop on it (\(a.width)pt vs \(b.width)pt)")
    }
}
