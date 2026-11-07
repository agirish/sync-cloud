import Foundation
import SwiftUI
import AppKit
import Design
import Testing
@testable import FileExplorer
import FileExplorerTestSupport

/// The "show me what changed" surface: what its two columns claim, and what it refuses to diff.
@Suite struct EditorDivergenceColumnTests {

    // MARK: The left column

    /// Use Disk Version promises ⌘Z brings the typing back only where it does: while the banner
    /// stands, the host's take is one undoable step; elsewhere it reloads over the buffer and the
    /// typing is gone.
    @Test func useDiskVersionPromisesUndoOnlyWhereThereIsOne() {
        #expect(EditorDivergenceDiffOverlay.useDiskVersionHelp(undoable: true)
                == "Take the version on the right — ⌘Z brings your version back.")
        #expect(EditorDivergenceDiffOverlay.useDiskVersionHelp(undoable: false)
                == "Take the version on the right and lose what you typed.")
    }

    @Test func theEditorColumnCountsTheBufferSWords() {
        #expect(EditorDivergenceColumns.editor(words: 1_204) == "In Edit · 1,204 words")
    }

    /// Singular for one, by the same function the status line uses, so "1 words" can't slip in
    /// through a second spelling.
    @Test func oneWordIsOneWord() {
        #expect(EditorDivergenceColumns.editor(words: 1) == "In Edit · 1 word")
        #expect(EditorDivergenceColumns.editor(words: 0) == "In Edit · 0 words")
    }

    // MARK: The right column

    /// The column says when the bytes were written, never where they came from: from here a sync
    /// client, another app, a script and another Mac look the same. The mtime is a fact; the
    /// provenance would be a guess the reader acts on.
    @Test func theDiskColumnDatesTheFileAndClaimsNothingElse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let caption = EditorDivergenceColumns.disk(modified: now.addingTimeInterval(-120), now: now)
        #expect(caption == "On disk · written 2 minutes ago")
        for guess in ["machine", "device", "iCloud", "Dropbox", "someone"] {
            #expect(!caption.lowercased().contains(guess), "the column guessed at provenance: \(caption)")
        }
    }

    /// A file with no modification date says the honest nothing rather than an invented age.
    @Test func aFileWithNoDateGetsNoAge() {
        #expect(EditorDivergenceColumns.disk(modified: nil, now: Date()) == "On disk")
    }

    /// Clock skew is ordinary in shared folders: a machine whose clock runs ahead writes a future
    /// mtime, and "written -3s ago" is worse than no age. `ScanFreshness.spokenRelative`'s first
    /// bucket, `..<30`, swallows a negative interval into "just now"; this pins that the caption
    /// inherits that, with no redundant clamp at the call site.
    @Test func aFutureModificationDateDoesNotProduceANegativeAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let caption = EditorDivergenceColumns.disk(modified: now.addingTimeInterval(600), now: now)
        #expect(!caption.contains("-"), "got \(caption)")
        #expect(caption == "On disk · written just now")
    }

    /// The two labels are what the pipeline's refusals name the sides, so a refused side reads as a
    /// thing rather than as a column.
    @Test func theColumnsAndTheRefusalsUseTheSameTwoNames() {
        #expect(EditorDivergenceColumns.editor(words: 3).hasPrefix(EditorDivergenceColumns.editorLabel))
        #expect(EditorDivergenceColumns.disk(modified: nil, now: Date()) == EditorDivergenceColumns.diskLabel)
    }
}

/// What the overlay does with a file `BoundedTextRead` won't read. The refusal names the reason
/// and the side: a huge log, a cloud placeholder not yet downloaded and a file that isn't text each
/// want a different next move from someone choosing which version of their work wins.
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
        #expect(!outcome.notes.contains { $0.hasPrefix("In Edit: ") })
    }

    /// A file that vanished between the stat and the read refuses rather than diffing against
    /// nothing. The alert never offers the diff for a `.missing` divergence; this is the race where
    /// the file goes after the question was asked.
    @Test func aFileThatIsGoneByTheTimeItIsReadRefuses() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = diff(buffer: "one\n", diskPath: folder.appendingPathComponent("gone.md").path)
        #expect(outcome.diff == nil)
        #expect(outcome.notes.first?.hasPrefix("On disk: ") == true, "got \(outcome.notes)")
    }

    /// An encoding changed under the buffer is a real difference the rows can't show. The buffer
    /// goes to the pipeline with the encoding it was opened in, so the same note as for two files
    /// reports it.
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

/// Escape must be safe, and the source is the one place to check it. The keys are `.onKeyPress`
/// handlers on a focusable card, because a `.keyboardShortcut` on an in-window overlay registers a
/// window-level equivalent that would eat bare esc and ⏎ typed into the editor behind the scrim
/// (`BareKeyEquivalentScanTests` bans it). `swift test` has no key window to type into, so a
/// rendered check would pass whatever the handler answered (as `UnnamedControlScanTests` argues).
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

    /// Every way out that isn't one of the three buttons (Escape, ⏎, keypad Enter, a click on the
    /// scrim) answers `cancel`, which changes nothing on disk. A keystroke must never choose which
    /// version of someone's work to throw away.
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

    /// Nothing on this surface writes: the file never touches the store's write path, and its only
    /// answers are the three the alert already offers.
    @Test func theOverlayHasNoWritePathOfItsOwn() throws {
        let source = try Self.source()
        for writer in ["EditorFileStore.write", "markSaved", "EditorAutosave."] {
            #expect(!source.contains(writer),
                    "the overlay reaches \(writer) — Save Anyway is supposed to be the host's write, not a second one")
        }
        // `.showWhatChanged` is not among the answers: a surface that could reopen itself would
        // leave the question unanswerable.
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
        let document = try TestTextFiles.document(named: "note.md", text: text)
        // Dirty, because a stop only matters under an unsaved buffer; `stopped` outranks dirtiness
        // in `EditorSaveStatus.resolve`, so this is the state the header draws.
        document.text = text + "typed\n"
        return document
    }

    private func workspace(_ document: EditorDocument, stopped: String?,
                           door: (() -> Void)?) -> EditorWorkspaceView {
        .fixture(document: document, showsRail: true, stopped: stopped, onShowWhatChanged: door)
    }

    /// The header really branches on the door at render time. The two headers differ only in
    /// whether a closure was passed, so any measured difference is the button branch. Measured,
    /// because `EditorDivergenceWiringTests` proves only that the host withholds the closure, not
    /// what the view does with it.
    @Test func thePillIsDrawnAsAControlOnlyWhenItIsOne() throws {
        let document = try document()
        // Long enough that the meta row, which carries the door's padding, is the header's wider
        // row; with short words the first row (name, Find, Expand) sets the width and hides it.
        let words = "not saving — the file changed on disk underneath the buffer, and the words are long"
        // No width frame: at a pinned width the row's `Spacer` absorbs the padding and both
        // headers measure exactly the pin.
        let plain = size(workspace(document, stopped: words, door: nil).headerContent, width: nil)
        let control = size(workspace(document, stopped: words, door: {}).headerContent, width: nil)
        #expect(control.width > plain.width,
                "the same words measured \(control.width)pt with a door and \(plain.width)pt without — the button branch is not being taken")
    }

    /// The control is the same height, so a header that grows a door doesn't push the document
    /// column down, the property the whole header is built around.
    @Test func theDoorDoesNotChangeTheHeadersHeight() throws {
        let document = try document()
        let words = "not saving — changed on disk"
        let plain = size(workspace(document, stopped: words, door: nil).headerContent, width: 520)
        let control = size(workspace(document, stopped: words, door: {}).headerContent, width: 520)
        #expect(abs(control.height - plain.height) < 0.51,
                "with a door the header is \(control.height)pt and without it \(plain.height)pt")
    }

    /// No stop, no door, whatever the host passes: with no amber words to click, a closure must
    /// draw nothing.
    @Test func aDocumentThatIsSavingHasNoWordsToClick() throws {
        let document = try document()
        let a = size(workspace(document, stopped: nil, door: nil).headerContent, width: nil)
        let b = size(workspace(document, stopped: nil, door: {}).headerContent, width: nil)
        #expect(abs(a.width - b.width) < 0.51,
                "a door appeared on a header with no stop on it (\(a.width)pt vs \(b.width)pt)")
    }
}
