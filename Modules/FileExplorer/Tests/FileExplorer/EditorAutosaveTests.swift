import Testing
import Foundation
import Design
@testable import FileExplorer

/// Autosave's decision, against real files.
///
/// Every branch here is one the user never sees happen: writing when it should stop loses the
/// version from another device, and stopping when it should write loses the typing. Neither
/// announces itself, so each is run against real files.
@MainActor
@Suite struct EditorAutosaveTests {

    private func scratch() throws -> URL { try EditorScratchFolder.make("editor-autosave") }

    private func opened(_ contents: String, named name: String = "note.md",
                        in folder: URL) throws -> (EditorDocument, URL) {
        try EditorScratchFolder.opened(contents, named: name, in: folder)
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

    /// A lossy decode opens read-only, and read-only must never reach the disk, autosave included.
    /// The absent stamp stops it here, before the `canSave` guard (removing that leaves this green);
    /// the checks below name the gate doing the work.
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
        // The stamp moved with it, or the next attempt would report a divergence against the file
        // this one just wrote.
        #expect(EditorAutosave.attempt(document) == .nothingToDo)
    }

    /// Something else wrote the file while the buffer was open: autosave stops, because writing
    /// now would discard that version unasked.
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

    /// A file moved away is worse: writing would recreate it at the old path beside the moved one,
    /// two copies from a background write nobody asked for.
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

    /// A write that can't happen is reported, not swallowed. The host turns it into a banner and a
    /// latch, so a read-only volume doesn't raise one every two seconds.
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

    /// The debounce key carries the path, not just the version: two documents can share a version,
    /// and `.task(id:)` restarts only when the id changes, so a pending write could land on a file
    /// no longer open.
    @Test func theDebounceKeySeparatesDocumentsAndMovesWithAWrite() {
        let a = EditorAutosave.Key(version: 4, path: "/a/one.md")
        let b = EditorAutosave.Key(version: 4, path: "/a/two.md")
        #expect(a != b, "two files at one version share a debounce key — a pending write can land on the wrong one")
        #expect(a == EditorAutosave.Key(version: 4, path: "/a/one.md"))
        // The version still moves it, or typing wouldn't restart the wait.
        #expect(a != EditorAutosave.Key(version: 5, path: "/a/one.md"))
        // A write that commits moves the key, so typing whose debounce was turned away while that
        // write was out is waited for again rather than left with nothing scheduled.
        let before = EditorFileStore.Stamp(modifiedAt: Date(timeIntervalSince1970: 1), size: 4, fileID: 7)
        let after = EditorFileStore.Stamp(modifiedAt: Date(timeIntervalSince1970: 2), size: 9, fileID: 8)
        #expect(EditorAutosave.Key(version: 4, path: "/a/one.md", stamp: before)
                != EditorAutosave.Key(version: 4, path: "/a/one.md", stamp: after))
    }

    // MARK: A save that landed and could not be checked (TE114)

    /// The store says when the bytes are on disk, and the outcome keeps that apart from a failed
    /// write, so the host says "Saved “x”, but …", not "Couldn't save “x” — Saved, but …". Both
    /// of the store's after-the-swap failures are landed ones.
    @Test func aWriteThatLandedIsNotAFailedOne() {
        #expect(EditorFileStore.Failure.unchecked.savedBut == "couldn’t read it back to check it.")
        #expect(EditorFileStore.Failure.unchecked.message == "Saved, but couldn’t read it back to check it.")
        #expect(EditorFileStore.Failure.changedAgain.savedBut?.hasPrefix("it changed again") == true)
        #expect(EditorAutosave.Outcome.of(EditorFileStore.Failure.unchecked)
                == .savedUnchecked("couldn’t read it back to check it."))
        #expect(EditorAutosave.Outcome.of(EditorFileStore.Failure(message: "Permission denied"))
                == .failed("Permission denied"))
        #expect(EditorAutosave.Outcome.of(CocoaError(.fileWriteOutOfSpace)) == .failed(CocoaError(.fileWriteOutOfSpace).localizedDescription))
    }

    /// The red word carries its reason as a tooltip, on a stop only.
    @Test func theStopWordCarriesItsReason() {
        let stopped = EditorSaveStatus.stopped("not saving — couldn't write")
        #expect(EditorWorkspaceView.stopTooltip(status: stopped, detail: "Permission denied") == "Permission denied")
        #expect(EditorWorkspaceView.stopTooltip(status: stopped, detail: nil) == nil)
        #expect(EditorWorkspaceView.stopTooltip(status: .readOnly, detail: "Permission denied") == nil,
                "a read-only document wears a stop's reason")
        #expect(EditorWorkspaceView.stopTooltip(status: .heldUnsaved, detail: "Permission denied") == nil)
    }

    /// The words you can act on are controls that say what they do: "unsaved — ⌘S" and "couldn't
    /// write" save, "no longer on disk" is Save Again, "changed on disk" opens the comparison.
    /// "couldn't check the save" and "read only" stay words: the host hands them no closure.
    @Test func theStatusWordsYouCanActOnAreControls() {
        typealias V = EditorWorkspaceView
        let held = EditorSaveStatus.heldUnsaved
        let stopped = EditorSaveStatus.stopped("not saving — couldn't write")
        #expect(V.statusWordAction(status: held, offersDiff: false, offersSave: true, offersSaveAgain: false) == .saveNow)
        #expect(V.statusWordAction(status: stopped, offersDiff: false, offersSave: true, offersSaveAgain: false) == .saveNow)
        #expect(V.statusWordAction(status: stopped, offersDiff: false, offersSave: false, offersSaveAgain: true) == .saveAgain)
        #expect(V.statusWordAction(status: stopped, offersDiff: true, offersSave: false, offersSaveAgain: false) == .showWhatChanged)
        #expect(V.statusWordAction(status: stopped, offersDiff: false, offersSave: false, offersSaveAgain: false) == nil)
        #expect(V.statusWordAction(status: .readOnly, offersDiff: true, offersSave: true, offersSaveAgain: true) == nil)
        #expect(V.statusWordAction(status: .unsaved, offersDiff: false, offersSave: true, offersSaveAgain: false) == nil)
        #expect(V.statusWordHelp(.saveNow, status: held, detail: nil) == "Save now — autosave is off for this file")
        #expect(V.statusWordHelp(.saveNow, status: stopped, detail: "No space left on device") == "No space left on device",
                "couldn’t write lost its reason")
        #expect(V.statusWordHelp(.saveAgain, status: stopped, detail: nil) == "Write the text back where the file was")
        #expect(V.statusWordHelp(.showWhatChanged, status: stopped, detail: nil) == "Show what changed on disk while you were typing")
        #expect(V.statusWordKeycap(.saveNow, status: held) == "⌘S")
        #expect(V.statusWordKeycap(.saveNow, status: stopped) == nil)
    }

    /// VoiceOver reads the visible words: the status word's button has no label of its own.
    @Test func theStatusWordIsReadAsItsWords() throws {
        let code = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        let start = try #require(code.range(of: "private func statusWord(_ word: String) -> some View {"))
        let end = try #require(code.range(of: "private func statusWordPerform", range: start.upperBound..<code.endIndex))
        #expect(!code[start.upperBound..<end.lowerBound].contains(".accessibilityLabel("))
    }

    /// A file Edit can't open still offers what can be done with it: Download for one still in the
    /// cloud, Try Again for one that kept changing (where the host offers it), then Quick Look and
    /// Reveal in Finder for every refusal.
    @Test func aRefusalOffersWhatCanStillBeDoneWithTheFile() throws {
        typealias V = EditorWorkspaceView
        let tooLarge = "Too large to open in Edit — 12.3 MB, and Edit opens text files up to 4.2 MB."
        #expect(V.refusalButtons(for: tooLarge, canTryAgain: true) == [.quickLook, .revealInFinder])
        #expect(V.refusalButtons(for: try #require(BoundedTextRead.Outcome.cloudOnly.caption), canTryAgain: true)
                == [.download, .quickLook, .revealInFinder])
        #expect(V.refusalButtons(for: EditorFileStore.keptChangingReason, canTryAgain: true)
                == [.tryAgain, .quickLook, .revealInFinder])
        #expect(V.refusalButtons(for: EditorFileStore.keptChangingReason, canTryAgain: false)
                == [.quickLook, .revealInFinder], "Try Again drawn with nothing behind it")
        #expect(V.RefusalButton.quickLook.title == "Quick Look")
        #expect(V.RefusalButton.revealInFinder.title == "Reveal in Finder")
        #expect(V.RefusalButton.tryAgain.title == "Try Again")
        #expect(V.RefusalButton.download.title == V.downloadTitle)
    }

    // MARK: What the header says

    /// The dot alone separates pending from written. Neither state has a word: "saved" would
    /// reassure whether or not anything was written, and "unsaved" would label a state that
    /// resolves itself in about two seconds. So the dot is the only glanceable difference.
    @Test func theDotAloneSeparatesPendingFromWritten() {
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: true, stopped: nil) == .unsaved)
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: false, stopped: nil) == .saved)
        #expect(EditorSaveStatus.resolve(isReadOnly: true, isDirty: false, stopped: nil) == .readOnly)

        let pending = EditorSaveStatus.unsaved
        let written = EditorSaveStatus.saved
        #expect(pending.showsDot && !written.showsDot,
                "pending and written draw the same dot — the only glanceable difference is gone")
        #expect(pending.word == nil && written.word == nil,
                "the header is labelling the two states that need no label")
        #expect(!pending.isWarning, "ordinary pending work is being shown as a problem")
    }

    /// With autosave off a dirty buffer is a different state: nothing is coming to write it, so the
    /// reader must act, and this state speaks.
    @Test func aDocumentWithAutosaveOffAsksToBeSaved() {
        let held = EditorSaveStatus.resolve(isReadOnly: false, isDirty: true, stopped: nil,
                                            autosaveOff: true)
        #expect(held == .heldUnsaved)
        #expect(held.showsDot, "held work draws no dot")
        #expect(!held.isWarning, "a deliberate setting is being shown as a failure")
        #expect(held.word?.hasPrefix("unsaved") == true, "the word read \(held.word ?? "nothing")")
        #expect(held.word?.contains(AppChord.saveDocument.display) == true,
                "the word does not name the key that settles it: \(held.word ?? "nothing")")

        // Switched off with nothing pending is simply saved: nothing is owed.
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: false, stopped: nil,
                                         autosaveOff: true) == .saved)
    }

    /// A stop outranks dirtiness, and read-only outranks both. A stopped document is dirty by
    /// definition, so "unsaved" there would be the same fact in its less useful spelling.
    @Test func aStopOutranksTheOrdinaryPendingState() {
        let stopped = EditorSaveStatus.resolve(isReadOnly: false, isDirty: true,
                                               stopped: "not saving — changed on disk")
        #expect(stopped == .stopped("not saving — changed on disk"))
        #expect(stopped.word == "not saving — changed on disk")
        #expect(stopped.showsDot && stopped.isWarning,
                "a stopped document does not warn — it looks exactly like ordinary pending work")
        // Read-only wins even over a stop: nothing can be written, so nothing is pending.
        #expect(EditorSaveStatus.resolve(isReadOnly: true, isDirty: true, stopped: "x") == .readOnly)
        #expect(EditorSaveStatus.readOnly.word?.isEmpty == false, "read-only says nothing and should speak")
        // A stop outranks the switch too: it is the more specific reason nothing is being written.
        #expect(EditorSaveStatus.resolve(isReadOnly: false, isDirty: true, stopped: "x",
                                         autosaveOff: true) == .stopped("x"))
    }

    /// The quiet interval is short enough that little is at risk, and long enough that a paragraph
    /// is one write rather than a dozen uploads.
    @Test func theQuietIntervalIsAPauseForThoughtRatherThanAKeystroke() {
        #expect(EditorAutosave.quietInterval >= .milliseconds(500),
                "the debounce is short enough to write mid-word — every pause becomes a cloud upload")
        #expect(EditorAutosave.quietInterval <= .seconds(10),
                "the debounce is long enough that a crash costs real work")
    }
}
