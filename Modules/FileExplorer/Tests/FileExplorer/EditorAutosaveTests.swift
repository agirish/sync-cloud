import Testing
import Foundation
@testable import FileExplorer

/// Autosave's decision, against real files.
///
/// **Every branch here is one the user never sees happen**, which is exactly why they are worth
/// executing rather than reading: an autosave that writes when it should have stopped costs
/// somebody the version that arrived from another device, and one that stops when it should have
/// written costs them their typing. Neither announces itself.
@MainActor
@Suite struct EditorAutosaveTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func opened(_ contents: String, named name: String = "note.md",
                        in folder: URL) throws -> (EditorDocument, URL) {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let document = EditorDocument()
        EditorFileStore.load(path: url.path, into: document)
        return (document, url)
    }

    @Test func aCleanDocumentIsNotWritten() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("hello\n", in: folder)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(EditorAutosave.attempt(document) == .nothingToDo)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after, "a clean document was rewritten — every pause in typing would touch the file")
    }

    @Test func nothingOpenIsNotWritten() {
        #expect(EditorAutosave.attempt(EditorDocument()) == .nothingToDo)
    }

    /// A lossy decode opens read-only, and read-only must reach the disk by no route at all —
    /// autosave included, which is the route that never asks anybody first.
    ///
    /// **What actually stops it here is the absent STAMP, not the `canSave` guard**, and that is
    /// worth writing down because the test's name suggests otherwise: `EditorDocument.open` leaves
    /// `stamp` nil for a read-only decode, so the `guard let stamp` refuses before dirtiness is
    /// ever consulted. Measured, not assumed — removing `canSave` from the guard leaves this test
    /// green and fails the two clean-document tests instead. Three independent gates hold this
    /// path, and the assertion below names the one doing the work so a future change to any of
    /// them cannot quietly leave the other two carrying a claim they do not support.
    @Test func aReadOnlyDocumentIsNeverWritten() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("lossy.md")
        let original = Data([0x68, 0x69, 0xFF, 0x0A])
        try original.write(to: url)
        let document = EditorDocument()
        EditorFileStore.load(path: url.path, into: document)
        try #require(document.isReadOnly, "the fixture did not open read-only — nothing here is under test")
        #expect(document.stamp == nil, "the gate that refuses this write is gone; the others are untested here")
        #expect(!document.canSave, "a read-only document reports itself saveable")

        document.text = "typed over it\n"
        #expect(EditorAutosave.attempt(document) == .nothingToDo)
        #expect(try Data(contentsOf: url) == original, "autosave wrote a read-only document")
    }

    @Test func anEditIsWrittenAndTheDocumentIsCleanAfterwards() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("hello\n", in: folder)

        document.text = "hello there\n"
        #expect(document.isDirty)
        #expect(EditorAutosave.attempt(document) == .wrote)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello there\n")
        #expect(!document.isDirty, "the buffer still reads dirty after a write that succeeded")
        // And the stamp moved with it, or the NEXT attempt would report a divergence against the
        // file this one just wrote.
        #expect(EditorAutosave.attempt(document) == .nothingToDo)
    }

    /// **The case autosave exists to refuse.** Something else wrote the file while the buffer was
    /// open; writing now would discard it, and nobody asked.
    @Test func aFileChangedOnDiskStopsAutosaveRatherThanOverwritingIt() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("hello\n", in: folder)

        document.text = "my edit\n"
        try Data("arrived from another device\n".utf8).write(to: url)

        #expect(EditorAutosave.attempt(document) == .blocked(.changed))
        #expect(try String(contentsOf: url, encoding: .utf8) == "arrived from another device\n",
                "autosave overwrote a file that had changed underneath the buffer")
        #expect(document.isDirty, "the buffer was marked saved despite nothing being written")
    }

    /// The missing case is separate and worse: writing would put the file back at the old path and
    /// leave the moved one where it is — two copies, from a background write nobody asked for.
    @Test func aFileMovedAwayStopsAutosaveRatherThanRecreatingIt() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("hello\n", in: folder)

        document.text = "my edit\n"
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("filed-away.md"))

        #expect(EditorAutosave.attempt(document) == .blocked(.missing))
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "autosave recreated the file at the path it was moved away from")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["filed-away.md"], "the folder holds \(left)")
    }

    /// A write that cannot happen is reported rather than swallowed — the host turns this into a
    /// banner and, crucially, into a latch, so a read-only volume does not produce one every two
    /// seconds for the rest of the session.
    @Test func aWriteThatFailsIsReported() throws {
        let folder = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let (document, _) = try opened("hello\n", in: folder)
        document.text = "my edit\n"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        guard case .failed = EditorAutosave.attempt(document) else {
            Issue.record("a write into a read-only directory did not report a failure")
            return
        }
        #expect(document.isDirty, "the buffer was marked saved after a failed write")
    }

    /// **The debounce key has to carry the path, not just the version.**
    ///
    /// Two documents can sit at the same version — a file opened at version 0 after another was
    /// closed at version 0 — and a key that could not tell them apart would leave a pending write
    /// aimed at the file that is no longer open. `.task(id:)` only restarts when the id CHANGES.
    @Test func theDebounceKeyDistinguishesTwoDocumentsAtTheSameVersion() {
        let a = EditorAutosave.Key(version: 4, path: "/a/one.md")
        let b = EditorAutosave.Key(version: 4, path: "/a/two.md")
        #expect(a != b, "two files at one version share a debounce key — a pending write can land on the wrong one")
        #expect(a == EditorAutosave.Key(version: 4, path: "/a/one.md"))
        // And the version still moves it, or typing would not restart the wait at all.
        #expect(a != EditorAutosave.Key(version: 5, path: "/a/one.md"))
    }

    // MARK: What the header says

    /// **Every combination of the three inputs, and the two that matter most are the ordinary
    /// ones.** The header shipped for a few minutes saying "saved" whether or not anything had been
    /// written — the dot tracked only the stopped state — which is precisely the reassurance a
    /// person should not have to take on trust. Watching "unsaved" become "saved" is the entire
    /// visible evidence that autosave is running.
    @Test func theHeaderDistinguishesPendingFromWrittenFromStopped() {
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: true, stopped: nil) == .unsaved)
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: false, stopped: nil) == .saved)
        #expect(EditorSaveStatus.resolve(isReadOnly: true, isDirty: false, stopped: nil) == .readOnly)

        // The two states a person reads to answer "did my typing land": different words AND a
        // different dot, so neither the glance nor the read can confuse them.
        let pending = EditorSaveStatus.unsaved
        let written = EditorSaveStatus.saved
        #expect(pending.caption != written.caption)
        #expect(pending.showsDot && !written.showsDot,
                "pending and written draw the same dot — the only glanceable difference is gone")
        #expect(!pending.isWarning, "ordinary pending work is being shown as a problem")
    }

    /// A stop outranks dirtiness, and read-only outranks both. A stopped document is dirty by
    /// definition, so "unsaved" there would be the same fact in its less useful spelling.
    @Test func aStopOutranksTheOrdinaryPendingState() {
        let stopped = EditorSaveStatus.resolve(isReadOnly: false, isDirty: true,
                                               stopped: "not saving — changed on disk")
        #expect(stopped == .stopped("not saving — changed on disk"))
        #expect(stopped.caption == "not saving — changed on disk")
        #expect(stopped.showsDot && stopped.isWarning,
                "a stopped document does not warn — it looks exactly like ordinary pending work")
        // Read-only wins even over a stop: nothing can be written, so nothing is pending.
        #expect(EditorSaveStatus.resolve(isReadOnly: true, isDirty: true, stopped: "x") == .readOnly)
    }

    /// **The guard that says the bytes really landed.**
    ///
    /// `write` re-stats the file it just installed — it needs the new stamp anyway — and now checks
    /// that the length matches what it handed over. This is the premise that check rests on, across
    /// every encoding: a byte-order mark is part of the file, so a guard that forgot one would
    /// refuse every UTF-16 save. Driven off `allCases` so a seventh encoding cannot skip it.
    @Test(arguments: BoundedTextRead.TextEncoding.allCases)
    func aSavedFileIsExactlyAsLongAsWhatWasWritten(encoding: BoundedTextRead.TextEncoding) throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = "hello there\n"
        let bytes = try #require(EditorFileStore.encode(body, as: encoding))
        let path = folder.appendingPathComponent("note.md").path
        try bytes.write(to: URL(fileURLWithPath: path))

        let stamp = try EditorFileStore.write(body, toPath: path, encoding: encoding)
        #expect(stamp.size == bytes.count,
                "\(encoding.rawValue): the stamp reports \(stamp.size)B for \(bytes.count)B written")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == bytes.count)
    }

    /// The quiet interval is a decision, not an accident: short enough that little is at risk,
    /// long enough that an ordinary paragraph is one write rather than a dozen uploads.
    @Test func theQuietIntervalIsAPauseForThoughtRatherThanAKeystroke() {
        #expect(EditorAutosave.quietInterval >= .milliseconds(500),
                "the debounce is short enough to write mid-word — every pause becomes a cloud upload")
        #expect(EditorAutosave.quietInterval <= .seconds(10),
                "the debounce is long enough that a crash costs real work")
    }
}
