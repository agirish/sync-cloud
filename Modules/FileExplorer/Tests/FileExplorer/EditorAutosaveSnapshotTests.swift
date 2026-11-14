import Testing
import Foundation
@testable import FileExplorer

/// The background half of autosave: what a write carries, what it commits, and what it refuses to
/// commit because something newer got there first. While the bytes are in flight there may be more
/// typing, a ⌘S or quit flush, or another file opening; each has a silent wrong answer (a dirty
/// document reading clean, an older version landing on a newer one, an alert about the app's own
/// change).
@MainActor
@Suite struct EditorAutosaveSnapshotTests {

    private func scratch() throws -> URL { try EditorScratchFolder.make("editor-snapshot") }

    private func opened(_ contents: String, named name: String = "note.md",
                        in folder: URL) throws -> (EditorDocument, URL) {
        try EditorScratchFolder.opened(contents, named: name, in: folder)
    }

    /// A keystroke lands while the write is out. The snapshot went to disk, not the buffer, so
    /// marking the buffer saved would leave unwritten typing reading as clean, with nothing to
    /// write it. Marking the snapshot saved leaves it dirty, and the next pause writes the rest.
    @Test func aKeystrokeDuringTheWriteLeavesTheDocumentDirty() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("one\n", in: folder)

        document.text = "one\ntwo\n"
        let snapshot = try #require(EditorAutosave.snapshot(of: document))
        // The keystroke, landing after the write was dispatched and before it commits.
        document.text = "one\ntwo\nthree\n"

        #expect(await EditorAutosave.write(snapshot, into: document) == .wrote)
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n",
                "the file holds something other than the snapshot that was written")
        #expect(document.savedText == "one\ntwo\n",
                "the document was marked saved against text that never reached the disk")
        #expect(document.isDirty,
                "a document with unwritten typing in it read as clean — nothing would write it")
        #expect(document.canSave)
    }

    /// The control for the test above: with no keystroke in the window, the document ends clean.
    @Test func anUndisturbedWriteLeavesTheDocumentClean() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("one\n", in: folder)

        document.text = "one\ntwo\n"
        let snapshot = try #require(EditorAutosave.snapshot(of: document))
        #expect(await EditorAutosave.write(snapshot, into: document) == .wrote)
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
        #expect(!document.isDirty)
        #expect(document.stamp != nil)
    }

    /// Nothing to snapshot is nothing to dispatch: the same three checks the synchronous attempt
    /// makes before it writes.
    @Test func thereIsNothingToSnapshotWhenThereIsNothingToWrite() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(EditorAutosave.snapshot(of: EditorDocument()) == nil)

        let (clean, _) = try opened("one\n", in: folder)
        #expect(EditorAutosave.snapshot(of: clean) == nil, "a clean document was snapshotted")

        let lossy = folder.appendingPathComponent("lossy.md")
        try Data([0x68, 0x69, 0xFF, 0x0A]).write(to: lossy)
        let readOnly = EditorDocument()
        EditorFileStore.load(path: lossy.path, into: readOnly)
        readOnly.text = "anything"
        #expect(EditorAutosave.snapshot(of: readOnly) == nil,
                "a read-only decode was snapshotted for writing")
    }

    /// A file that changed under the buffer still stops autosave, though the check now runs off
    /// the main actor with the write.
    @Test func aFileChangedOnDiskStopsTheBackgroundWriteToo() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url) = try opened("one\n", in: folder)
        document.text = "one\ntwo\n"
        let snapshot = try #require(EditorAutosave.snapshot(of: document))
        // Somebody else's version arrives between the dispatch and the write.
        try Data("from another machine\n".utf8).write(to: url)

        #expect(await EditorAutosave.write(snapshot, into: document) == .blocked(.changed))
        #expect(try String(contentsOf: url, encoding: .utf8) == "from another machine\n",
                "autosave overwrote a version that arrived while it was writing")
        #expect(document.isDirty, "the buffer was marked saved over a divergence")
    }

    /// A result about a document no longer open is dropped silently. Acting on it would mark the
    /// new document saved against the old one's text or, on divergence, raise a modal about a file
    /// the user has left.
    @Test func aResultForADocumentThatHasMovedOnIsDiscarded() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, first) = try opened("one\n", named: "first.md", in: folder)
        document.text = "one\ntwo\n"
        let snapshot = try #require(EditorAutosave.snapshot(of: document))

        // The user opens another file before the write comes back.
        let second = folder.appendingPathComponent("second.md")
        try Data("second\n".utf8).write(to: second)
        EditorFileStore.load(path: second.path, into: document)

        #expect(await EditorAutosave.write(snapshot, into: document) == .nothingToDo)
        #expect(document.path == second.path)
        #expect(document.savedText == "second\n",
                "the new document was marked saved against the previous one's text")
        // The bytes still went to the file the snapshot named.
        #expect(try String(contentsOf: first, encoding: .utf8) == "one\ntwo\n")
    }

    /// The ordering guarantee that makes a synchronous ⌘S or quit flush safe beside a background
    /// write. A background write takes its ticket at dispatch; if anything commits after that (a
    /// synchronous write always does, taking its ticket inside the lock), the older snapshot writes
    /// nothing, so a stale version can't land on what was just saved.
    @Test func aBackgroundWriteOvertakenByASynchronousOneWritesNothing() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        try Data("original\n".utf8).write(to: url)

        // The background write's ticket, taken at dispatch.
        let ticket = EditorFileStore.issueWriteTicket()
        // ⌘S happens first: a write with no ticket, which always wins.
        try EditorFileStore.write("from command-S\n", toPath: url.path, encoding: .utf8)
        #expect(try String(contentsOf: url, encoding: .utf8) == "from command-S\n")

        // Now the background write lands, carrying the older snapshot.
        let stamp = try EditorFileStore.write("from autosave\n", toPath: url.path,
                                              encoding: .utf8, ticket: ticket)
        #expect(stamp == nil, "an overtaken write reported a stamp, so it would be marked saved")
        #expect(try String(contentsOf: url, encoding: .utf8) == "from command-S\n",
                "an older background write overwrote a newer synchronous one")
    }

    /// Two background writes in flight: the newer wins whichever lands first. The host dispatches
    /// one at a time, but its guard is a `@State` flag a rebuilt view would reset, so the store
    /// must hold this on its own. The newer write is also the ordering test's control: a ticket
    /// nothing overtook commits, or a store that refused everything would pass.
    @Test func theNewerOfTwoBackgroundWritesWins() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        try Data("original\n".utf8).write(to: url)

        let older = EditorFileStore.issueWriteTicket()
        let newer = EditorFileStore.issueWriteTicket()
        #expect(try EditorFileStore.write("newer\n", toPath: url.path,
                                          encoding: .utf8, ticket: newer) != nil)
        #expect(try EditorFileStore.write("older\n", toPath: url.path,
                                          encoding: .utf8, ticket: older) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "newer\n")
    }

    // MARK: - A synchronous save meeting a background write that has landed (FR50)

    /// Opens a note, types, dispatches autosave's background write, and returns once its bytes are
    /// on disk, holding the main actor so the commit (a main-actor hop) can't have run: until its
    /// first `await`, the caller is between swap and commit. Retried when there is no window:
    /// awaiting a finished task doesn't suspend, so under load the commit can run in the write's turn.
    private func landedAndUncommitted(in folder: URL)
        async throws -> (EditorDocument, URL, Task<EditorAutosave.Outcome, Never>) {
        for attempt in 0..<8 {
            let (document, url) = try opened("one\n", named: "note-\(attempt).md", in: folder)
            document.text = "one\ntwo\n"
            let snapshot = try #require(EditorAutosave.snapshot(of: document))
            var dispatched = false
            document.onBackgroundWrites = { if $0 > 0 { dispatched = true } }
            defer { document.onBackgroundWrites = nil }
            let write = Task { await EditorAutosave.write(snapshot, into: document) }
            // The write's first lines run on the main actor, so it has to be let in once.
            for _ in 0..<10_000 where !dispatched { await Task.yield() }
            try #require(dispatched, "the background write never left")
            // No `await` from here: the main actor is this loop's until the bytes are on disk.
            let deadline = Date().addingTimeInterval(10)
            while (try? String(contentsOf: url, encoding: .utf8)) != "one\ntwo\n", Date() < deadline { usleep(1_000) }
            try #require(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n",
                         "the background write never landed")
            guard document.backgroundWrites == 1 else {
                // The commit ran in the write's own turn: no window this time.
                _ = await write.value
                continue
            }
            try #require(document.stamp != EditorFileStore.stamp(ofPath: url.path),
                         "the premise: the disk is newer than the document's stamp")
            return (document, url, write)
        }
        struct NoWindow: Error, CustomStringConvertible {
            var description: String { "the premise: every attempt's commit ran before the window could be held" }
        }
        throw NoWindow()
    }

    /// A save between autosave's swap and its commit is not asked about. ⌘S and the flushes before
    /// another file opens or at ⌘Q compare the disk with the document's stamp, and in that window
    /// the disk holds autosave's own bytes under a stamp the document hasn't seen. Asking would
    /// risk losing what was typed after the snapshot, so the save takes the landed write as its
    /// own and writes the rest; the late commit changes nothing.
    @Test func aSaveWhileAutosavesWriteIsUncommittedIsNotAskedAbout() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url, write) = try await landedAndUncommitted(in: folder)
        // Typed after the snapshot, still inside the window.
        document.text = "one\ntwo\nthree\n"

        #expect(EditorAutosave.attempt(document) == .wrote,
                "a flush took autosave's own write for a change made elsewhere")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\nthree\n")
        #expect(!document.isDirty)

        // The commit arrives to find a newer save, and leaves it alone.
        #expect(await write.value == .nothingToDo)
        #expect(!document.isDirty)
        #expect(document.stamp == EditorFileStore.stamp(ofPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\nthree\n")
    }

    /// The control for the test above: a real change in that window is still asked about, so
    /// settling the editor's own write doesn't swallow someone else's that landed after it.
    @Test func aChangeFromElsewhereAfterAutosavesWriteLandedIsStillAskedAbout() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url, write) = try await landedAndUncommitted(in: folder)
        // Another Mac's version arrives over autosave's, longer so its stamp differs whatever the
        // clock's resolution.
        let theirs = "theirs, from another Mac, longer than either\n"
        let other = folder.appendingPathComponent("incoming.md")
        try Data(theirs.utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        document.text = "one\ntwo\nthree\n"

        #expect(EditorAutosave.attempt(document) == .blocked(.changed))
        #expect(try String(contentsOf: url, encoding: .utf8) == theirs, "the version from elsewhere was overwritten")
        _ = await write.value
    }
}
