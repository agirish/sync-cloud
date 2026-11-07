import Testing
import Foundation
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// The editor's small pure seams: the ones the app target calls, and the ones a doc comment calls
/// "the one place that decides it".
///
/// Each is two or three lines of production code that another file's doc comment leans on: too
/// small to look wrong in review, and load-bearing enough that inverting it changes what the app
/// does with somebody's file.
@Suite struct EditorSeamTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: The seam the app target actually calls

    /// `load(path:into:)` maps each `Opened` to the right `OpenResult`.
    ///
    /// `EditorFileStoreTests` covers `open` → `Opened` and stops there; this mapping is what the
    /// host switches on to decide what to log and show. Swapping the `.readOnly` and `.refused`
    /// arms must make this test fail.
    @MainActor
    @Test func loadingReportsWhatActuallyHappenedToTheDocument() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = EditorDocument()

        let plain = folder.appendingPathComponent("plain.md")
        try Data("hello\n".utf8).write(to: plain)
        #expect(EditorFileStore.load(path: plain.path, into: document) == .opened)
        #expect(document.path == plain.path)
        #expect(document.readOnlyReason == nil && document.refusal == nil)

        // Invalid UTF-8 with no NUL in it: decoded lossily, so shown but not saveable.
        let lossy = folder.appendingPathComponent("lossy.md")
        try Data([0x68, 0x69, 0xFF, 0x0A]).write(to: lossy)
        let lossyResult = EditorFileStore.load(path: lossy.path, into: document)
        #expect(lossyResult == .readOnly(EditorFileStore.lossyReason))
        #expect(document.readOnlyReason == EditorFileStore.lossyReason)
        #expect(document.refusal == nil, "a read-only document is shown, not refused")

        // A NUL in the first kilobyte: nothing to show at all.
        let binary = folder.appendingPathComponent("blob.txt")
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        guard case .refused(let reason) = EditorFileStore.load(path: binary.path, into: document) else {
            Issue.record("a binary file did not come back refused")
            return
        }
        #expect(!reason.isEmpty)
        #expect(document.refusal == reason)
        // A refused document is read-only too, deliberately: `isReadOnly` gates the save path, and
        // the view shows `refusal` so the reader still sees one caption rather than two.
        #expect(document.isReadOnly, "a refused document could be saved over")
        #expect(document.text.isEmpty, "a refused document kept the previous file's text")
    }

    /// `write(_ document:)` refuses a document with no encoding rather than assuming UTF-8.
    ///
    /// That guard is the only thing between a read-only or closed document and the disk.
    @MainActor
    @Test func writingRefusesADocumentThatWasNeverOpenedForWriting() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = EditorDocument()

        // Nothing open.
        #expect(throws: EditorFileStore.Failure.self) { try EditorFileStore.write(document) }

        // Open, then read-only: the encoding is cleared with everything else, so the save path
        // cannot reach the disk even if a caller got past the host's own guards.
        let lossy = folder.appendingPathComponent("lossy.md")
        try Data([0x68, 0x69, 0xFF, 0x0A]).write(to: lossy)
        EditorFileStore.load(path: lossy.path, into: document)
        #expect(document.isReadOnly)
        #expect(throws: EditorFileStore.Failure.self) { try EditorFileStore.write(document) }
        #expect(try Data(contentsOf: lossy) == Data([0x68, 0x69, 0xFF, 0x0A]),
                "a read-only document reached the disk")
    }

    /// Closing clears every field a later save could act on, the encoding above all, since that is
    /// what `write(_ document:)` gates on.
    @MainActor
    @Test func closingClearsTheFieldsASaveWouldRead() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = EditorDocument()
        let path = folder.appendingPathComponent("note.md")
        try Data("hi\n".utf8).write(to: path)
        EditorFileStore.load(path: path.path, into: document)
        #expect(document.stamp != nil)

        document.close()
        #expect(document.path == nil)
        #expect(document.text.isEmpty && document.savedText.isEmpty)
        #expect(document.stamp == nil)
        #expect(document.readOnlyReason == nil && document.refusal == nil)
        #expect(throws: EditorFileStore.Failure.self, "the encoding survived close()") {
            try EditorFileStore.write(document)
        }
    }

    /// `textVersion` bumps on every write to the buffer.
    ///
    /// The preview's `.task(id:)` is keyed on it, so without the `didSet` the parse stops
    /// restarting and the rendered document silently freezes while you type.
    @MainActor
    @Test func everyEditBumpsTheVersionThePreviewIsKeyedOn() {
        let document = EditorDocument()
        let start = document.textVersion
        document.text = "a"
        document.text = "ab"
        #expect(document.textVersion == start + 2)
        // Writing the same value again is still a write: `didSet` fires, and one more re-parse is
        // harmless where missing a real edit is not.
        document.text = "ab"
        #expect(document.textVersion == start + 3)
    }

    // MARK: The mode a file opens in

    /// `EditorMode.resolved` narrows for display and nothing else.
    ///
    /// Both mutations are silent: `isMarkdown ? stored : .preview` leaves a `.txt` showing a
    /// preview with no way back to the text, and `isMarkdown ? .edit : stored` throws away the
    /// remembered mode on every Markdown file.
    @Test func aNonMarkdownFileIsAlwaysEditAndAMarkdownFileKeepsTheMode() {
        for stored in EditorMode.allCases {
            #expect(EditorMode.resolved(stored, isMarkdown: true) == stored,
                    "\(stored) was narrowed for a Markdown file")
            #expect(EditorMode.resolved(stored, isMarkdown: false) == .edit,
                    "\(stored) survived onto a file with no preview")
        }
    }

    // MARK: The text surface

    /// The editor's font goes through the app's ramp, not a bare multiply.
    ///
    /// `base * scale` agrees with the ramp at and below 1.0, so it reads fine at Small and Default
    /// and parts company only at the larger sizes, the ones people choose because they need them.
    @MainActor
    @Test func theEditorsFontFollowsTheAppsTypeRampAtEverySize() {
        var divergedSomewhere = false
        for size in FontSize.allCases {
            let expected = FontSize.scaledPointSize(PlainTextEditor.baseFontSize, scale: size.scale)
            #expect(abs(PlainTextEditor.font(scale: size.scale).pointSize - expected) < 0.01,
                    "at \(size) the editor draws \(PlainTextEditor.font(scale: size.scale).pointSize)pt, not \(expected)pt")
            if abs(PlainTextEditor.baseFontSize * size.scale - expected) > 0.01 { divergedSomewhere = true }
        }
        #expect(divergedSomewhere,
                "the ramp and a bare multiply agree at every size the app offers — this test cannot fail")
    }

    /// The wipe must not come back: with a stack per document, `removeAllActions()` on a
    /// document change would silently throw away the history this feature exists to keep.
    @Test func theEditorNoLongerWipesTheStackWhenTheDocumentChanges() throws {
        let source = try SourceText.fileExplorer("PlainTextEditor.swift")
        try #require(source.contains("func updateNSView"), "the scan is not reading updateNSView")
        try #require(source.contains("context.coordinator.documentID != documentID"),
                     "the document-identity branch is gone — this scan is checking nothing")

        // Comments are stripped first, so a note that names `removeAllActions()` can't pass for
        // code.
        let code = SourceText.codeOnly(source)
        #expect(!code.contains("removeAllActions()"),
                "the per-document undo history is being wiped on a document change again")
    }
}
