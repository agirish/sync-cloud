import Testing
import Foundation
@testable import FileExplorer

/// The background half of autosave: what a write carries, what it commits, and what it refuses to
/// commit because something newer got there first.
///
/// **The whole point of these is the window the synchronous write did not have.** Autosave used to
/// run on the main actor, so from the moment it read the buffer to the moment it marked the document
/// saved, nothing could change underneath it. It now writes a *snapshot* off the main actor, and
/// three things can happen while those bytes are in flight: the typist can keep typing, a ⌘S or a
/// quit flush can write the newer buffer, and the user can open another file. Each of the three has
/// a wrong answer that is silent — a dirty document reading clean, an older version landing on top
/// of a newer one, an alert about a change the app made itself — so each gets a test.
@MainActor
@Suite struct EditorAutosaveSnapshotTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-snapshot-\(UUID().uuidString)")
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

    /// **The race the snapshot exists for.**
    ///
    /// A keystroke lands while the write is out. What went to disk is the snapshot, not what is in
    /// the buffer now — so marking the buffer saved would leave a document that has unwritten
    /// typing in it and reads as clean, with no dot, no pending debounce and nothing on screen
    /// saying so. Marking the *snapshot* saved leaves it correctly dirty, and the next pause writes
    /// the rest.
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

    /// The ordinary case, and the negative control for the test above: with no keystroke in the
    /// window, the same machinery leaves the document clean.
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

    /// Nothing to snapshot is nothing to dispatch — the same three questions the synchronous
    /// attempt asks before it writes.
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

    /// **A file that moved under the buffer still stops autosave**, and the check now happens off
    /// the main actor with the write rather than before it — so this is asserting that it happens
    /// at all, not only that the rule is written down.
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

    /// **A result about a document that is no longer open is dropped, silently.**
    ///
    /// Opening another file while the write is out means the outcome describes a state that has
    /// gone. Acting on it would either mark the new document saved against the old one's text, or —
    /// on the divergence arm — raise a modal about a file the user has already moved on from.
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
        // The bytes still went to the file they were aimed at — the snapshot named it.
        #expect(try String(contentsOf: first, encoding: .utf8) == "one\ntwo\n")
    }

    /// **The ordering guarantee, which is what makes a synchronous ⌘S or a quit flush safe beside a
    /// background write.**
    ///
    /// A background write takes its ticket when it is dispatched. If anything commits after that —
    /// and a synchronous write always commits, because it takes its ticket inside the lock — the
    /// older snapshot must write nothing at all. The failure this prevents is the one that cannot
    /// be seen: a two-second-old version of the document landing on top of what the user just
    /// pressed ⌘S on, or what they typed just before ⌘Q.
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

    /// The negative control for the ordering test: a ticket that has not been overtaken commits.
    /// Without this, a `perform` that refused everything would pass the test above.
    @Test func aBackgroundWriteThatWasNotOvertakenCommits() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        try Data("original\n".utf8).write(to: url)

        let ticket = EditorFileStore.issueWriteTicket()
        let stamp = try EditorFileStore.write("from autosave\n", toPath: url.path,
                                              encoding: .utf8, ticket: ticket)
        #expect(stamp != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "from autosave\n")
    }

    /// Two background writes in flight at once: the newer one wins whichever order they land in.
    ///
    /// The host only ever dispatches one at a time, so this is the store's guarantee rather than
    /// the host's — asserted here because the host's guard is a `@State` flag on a view, which a
    /// rebuilt view would start over; the store is what has to hold if that ever happens.
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

    /// Opens a note holding "one", types "one / two", dispatches autosave's background write of it,
    /// and returns once its bytes are on disk — with the main actor HELD from the moment it left, so
    /// the commit (a hop back onto the main actor) cannot have run. Whatever the caller does next,
    /// until its first `await`, happens inside the window between the swap and the commit.
    ///
    /// **Retried when the write never left the main actor.** Awaiting a task that has already
    /// finished does not suspend, so on a loaded machine — the main thread descheduled between
    /// starting the detached half and awaiting it — the bytes land, the commit runs in the same
    /// turn, and there is no window to stand in. That attempt is discarded and another note opened.
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

    /// **A save made between autosave's swap and its commit is not asked about** (FR50).
    ///
    /// ⌘S, the flush before another file opens, and the flush at ⌘Q all compare the disk with the
    /// document's stamp. In that window the disk holds autosave's own bytes under a stamp the
    /// document has not been told yet — so the flush answered "changed on disk", and Use Disk
    /// Version or Don't Save then threw away what was typed after the snapshot. The save now takes
    /// the landed write as the editor's own and writes the rest; the commit, arriving after,
    /// changes nothing.
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

    /// **And a real change in that window is still asked about** — the control for the test above:
    /// settling the editor's own write must not swallow somebody else's that landed after it.
    @Test func aChangeFromElsewhereAfterAutosavesWriteLandedIsStillAskedAbout() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (document, url, write) = try await landedAndUncommitted(in: folder)
        // Another Mac's version arrives over autosave's — longer, so its stamp differs whatever the
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
