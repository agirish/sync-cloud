import Testing
import AppKit
import EventsTestSupport
@testable import FileExplorer

/// **TE59: Edit notices a change to the open file from elsewhere when it happens.**
///
/// Against real files in a temp folder, through the same sequence `EditorDocumentLoad` runs, with
/// the document's real storage and undo stack — the rules have a cost when they are wrong (typing
/// reloaded over, or the editor's own save read as somebody else's), and neither announces itself.
@MainActor
@Suite struct EditorDiskWatchTests {

    // MARK: Rig

    @MainActor
    final class Rig {
        let folder: URL
        let document = EditorDocument()
        let undoStore = EditorUndoStore()
        let watch: EditorDiskWatch
        var moves: [(String, String)] = []
        var banners: [EditorDiskBanner?] = []
        /// Windows a test mounted a view in — held for the rig's life.
        var windows: [NSWindow] = []

        init(_ contents: String = "one\ntwo\nthree\n", name: String = "note.md",
             settle: Duration = .milliseconds(20),
             isCloudOnly: @escaping (String) -> Bool = { _ in false }) throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("editor-disk-watch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            watch = EditorDiskWatch(settle: settle, noticeDuration: .seconds(30), isCloudOnly: isCloudOnly)
            try Data(contents.utf8).write(to: url(name))
            watch.onMoved = { [unowned self] old, new, _ in self.moves.append((old, new)) }
            watch.onBannerChange = { [unowned self] in self.banners.append($0) }
            watch.attach(document: document, undoStore: undoStore)
            open(url(name).path)
        }

        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        var path: String { document.path ?? "" }
        var undo: UndoManager { undoStore.current }
        var text: String { document.buffer.text }

        /// `EditorDocumentLoad.run`'s four steps, as the app takes them.
        func open(_ path: String) {
            undoStore.remember(text: document.text)
            EditorFileStore.load(path: path, into: document)
            undoStore.activate(path: document.path, text: document.text)
            document.buffer.follow(undoStore.source)
        }

        /// Typing, as a step the stack holds — the storage edit every door into the text makes.
        func type(_ string: String) {
            let source = document.buffer.source
            source.replace(NSRange(location: source.textStorage.length, length: 0), with: string,
                           undoManager: undo)
        }

        /// Another app's atomic save: a new file renamed over the path.
        func saveElsewhere(_ contents: String, at path: String? = nil) throws {
            let target = path ?? self.path
            let staged = folder.appendingPathComponent(".other-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: staged)
            #expect(rename(staged.path, target) == 0)
        }

        /// Another app writing into the same inode.
        func writeInPlace(_ contents: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.close()
        }

        func onDisk(_ path: String? = nil) throws -> String {
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: path ?? self.path)), as: UTF8.self)
        }

        func closeUndoGroup() async {
            let undo = self.undo
            _ = await LayoutPumpWait.pump(NSView(), upTo: 2) { undo.groupingLevel == 0 }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: The rule, as values

    @Test func thePathDecidesBeforeTheDescriptor() {
        let known = EditorFileStore.Stamp(modifiedAt: Date(timeIntervalSince1970: 1), size: 4, fileID: 7)
        var other = known
        other.fileID = 8
        typealias O = EditorDiskChange.Observation
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known, observation: O(atPath: known)) == .none)
        // An atomic save: a new inode at the path, the old one moved aside under a backup name.
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: other, trackedPath: "/f/a.md~")) == .changed)
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: nil, trackedPath: "/g/b.md")) == .moved(to: "/g/b.md"))
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: nil, trackedPath: "/Users/x/.Trash/a.md")) == .deleted)
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known, observation: O(atPath: nil)) == .deleted)
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: other, isRegularFile: false)) == .deleted)
        // The same file, its name now spelled differently only in case.
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: known, trackedPath: "/f/A.md")) == .moved(to: "/f/A.md"))
        #expect(EditorDiskChange.assess(path: "/f/a.md", known: known,
                                        observation: O(atPath: known, trackedPath: "/f/a.md")) == .none)
    }

    @Test func unsavedTypingIsNeverReloadedOver() {
        typealias R = EditorDiskResponse
        #expect(R.to(.changed, hasUnsavedTyping: false, banner: nil) == .reload)
        #expect(R.to(.changed, hasUnsavedTyping: true, banner: nil) == .raise(.changed))
        #expect(R.to(.changed, hasUnsavedTyping: false, banner: .changed) == .raise(.changed))
        #expect(R.to(.changed, hasUnsavedTyping: false, banner: .deleted) == .reload)
        #expect(R.to(.moved(to: "/b"), hasUnsavedTyping: true, banner: nil) == .follow(to: "/b"))
        #expect(R.to(.deleted, hasUnsavedTyping: false, banner: nil) == .raise(.deleted))
        #expect(R.to(.none, hasUnsavedTyping: true, banner: nil) == .nothing)
        #expect(R.to(.none, hasUnsavedTyping: true, banner: .changed) == .clearBanner)
    }

    // MARK: Nothing typed: reload, and the history goes

    @Test func aCleanDocumentReloadsAndItsHistoryIsEmptied() async throws {
        let rig = try Rig()
        rig.type("four\n")
        await rig.closeUndoGroup()
        _ = EditorAutosave.attempt(rig.document)      // saved: clean, with a step on the stack
        #expect(!rig.document.isDirty)
        try #require(rig.undo.canUndo, "the fixture has no history to empty — nothing here is under test")
        let storage = rig.document.buffer.source

        try rig.saveElsewhere("one\nTWO\nthree\nfour\n")
        #expect(rig.watch.reconcile() == .reloaded)

        #expect(rig.text == "one\nTWO\nthree\nfour\n")
        #expect(!rig.document.isDirty, "the reload left the document dirty — autosave would write it straight back")
        #expect(rig.document.diskStamp == EditorFileStore.stamp(ofPath: rig.path))
        #expect(!rig.undo.canUndo, "⌘Z after a reload must do nothing")
        #expect(rig.document.buffer.source === storage, "a new storage rebuilds every view and loses the caret")
        #expect(rig.watch.banner == nil)
        #expect(rig.watch.notice?.text == EditorDiskWatch.reloadedNotice)
    }

    @Test func anInPlaceWriteReloadsToo() throws {
        let rig = try Rig()
        try rig.writeInPlace("rewritten where it stood\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(rig.text == "rewritten where it stood\n")
    }

    /// **`vim`'s save**: the file renamed aside to `note.md~`, then a new one written at the path.
    /// The descriptor follows the old file to its backup name; the path must win.
    @Test func aSaveThatRenamesTheOldFileAsideIsAChangeNotAMove() throws {
        let rig = try Rig()
        let path = rig.path
        #expect(rename(path, path + "~") == 0)
        try Data("new from vim\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(rig.path == path, "followed the backup the save left behind")
        #expect(rig.text == "new from vim\n")
    }

    /// **The reload is as the open path reads it**: a CRLF file comes back CRLF, byte for byte — LF
    /// conversion is for the first EDIT, and a reload is not one.
    @Test func aReloadKeepsTheFilesLineEndings() throws {
        let rig = try Rig("a\r\nb\r\n")
        try rig.saveElsewhere("a\r\nb\r\nc\r\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(Data(rig.text.utf8) == Data("a\r\nb\r\nc\r\n".utf8))
        #expect(!rig.document.isDirty)
    }

    @Test func aReadOnlyDocumentReloadsToo() throws {
        let rig = try Rig()
        try Data([0x68, 0x69, 0xFF, 0x0A]).write(to: rig.url("note.md"))
        rig.open(rig.url("note.md").path)
        try #require(rig.document.isReadOnly)
        try rig.saveElsewhere("fixed\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(rig.text == "fixed\n")
        #expect(!rig.document.isReadOnly, "a file that is valid text again opens for editing again")
    }

    /// **A clean note whose file turns into something Edit cannot read keeps its text**, read-only
    /// and saying why — not emptied, not announced as "Reloaded" — and the watch goes on looking,
    /// so the file reloads once it is text again. Reloading INTO the refusal emptied the screen and
    /// then deafened the watch for good (`reconcile` stops at a refusal).
    @Test func aNewVersionThatCannotBeReadKeepsTheTextAndKeepsLooking() async throws {
        let rig = try Rig()
        rig.type("four\n")
        await rig.closeUndoGroup()
        _ = EditorAutosave.attempt(rig.document)
        try #require(!rig.document.isDirty)
        let staged = rig.folder.appendingPathComponent(".bin")
        try Data([0x00, 0x01, 0x02, 0x00, 0x41]).write(to: staged)
        #expect(rename(staged.path, rig.path) == 0)

        #expect(rig.watch.reconcile() == .unreadable)
        #expect(rig.text == "one\ntwo\nthree\nfour\n", "the text on screen was emptied for a file it cannot show")
        #expect(rig.document.refusal == nil)
        #expect(rig.document.isReadOnly, "the last text could be saved over a file it no longer describes")
        #expect(rig.document.readOnlyReason?.hasPrefix(EditorDiskWatch.unreadableReasonLead) == true)
        #expect(rig.watch.notice?.text == EditorDiskWatch.unreadableNotice, "it said Reloaded, and nothing was")
        #expect(EditorAutosave.attempt(rig.document) == .nothingToDo)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rig.path)).first == 0x00, "the binary file was written over")
        // Looking again at the same unreadable file says nothing new.
        #expect(rig.watch.reconcile() == .nothing)

        try rig.saveElsewhere("back to text\n")
        #expect(rig.watch.reconcile() == .reloaded, "the watch stopped looking after the refusal")
        #expect(rig.text == "back to text\n")
        #expect(!rig.document.isReadOnly, "a file that is text again opens for editing again")
    }

    /// **Briefly unreadable, then readable again with nothing else changed** — permissions taken
    /// away and given back. The stamp is the same throughout, so only a document that keeps no
    /// stamp over the unreadable file looks again and gets back to editing.
    @Test func aFileThatIsReadableAgainOpensForEditingAgain() throws {
        let rig = try Rig()
        try rig.saveElsewhere("theirs\n")
        defer { chmod(rig.path, 0o644) }
        #expect(chmod(rig.path, 0) == 0)
        #expect(rig.watch.reconcile() == .unreadable)
        #expect(rig.text == "one\ntwo\nthree\n")
        #expect(chmod(rig.path, 0o644) == 0)
        #expect(rig.watch.reconcile() == .reloaded, "readable again, and still read-only")
        #expect(rig.text == "theirs\n")
        #expect(!rig.document.isReadOnly)
    }

    /// Edit in Preview follows the storage — so a reload, one edit to it, reaches Preview too.
    @Test func aReloadReachesEditInPreview() throws {
        let rig = try Rig("# Title\n\nbody\n")
        let session = PreviewEditSession(source: rig.document.buffer.source, undoManager: rig.undo)
        #expect(session.display.string.contains("body"))
        try rig.saveElsewhere("# Title\n\nchanged elsewhere\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(session.display.string.contains("changed elsewhere"))
    }

    /// The caret stays where it was when the change is somewhere else in the file — on **TextKit 2**,
    /// which is what the app's Source view is (`NSTextView.scrollableTextView()`), mounted on the
    /// shared storage the way the editor mounts it.
    @Test func theCaretStaysPutAcrossAReloadBelowIt() throws {
        let rig = try Rig("one\ntwo\nthree\n")
        let view = try Self.sourceView(on: rig)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        try rig.saveElsewhere("one\ntwo\nthree\nand a new last line\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(view.selectedRange() == NSRange(location: 2, length: 0))
        #expect(view.string == "one\ntwo\nthree\nand a new last line\n")
    }

    /// A TextKit 2 view over the document's shared storage, as `PlainTextEditor` builds Source, in a
    /// window so it can hold the first responder (an input method needs it).
    static func sourceView(on rig: Rig) throws -> NSTextView {
        let scroll = NSTextView.scrollableTextView()
        let view = try #require(scroll.documentView as? NSTextView)
        let content = try #require(view.textContentStorage, "not TextKit 2 — the app's Source view is")
        content.textStorage = rig.document.buffer.source.textStorage
        rig.document.buffer.source.textView = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scroll
        window.makeFirstResponder(view)
        rig.windows.append(window)
        return view
    }

    // MARK: Typing not on disk: ask, never reload

    @Test func unsavedTypingRaisesTheBannerAndKeepsEverything() async throws {
        let rig = try Rig()
        rig.type("typed\n")
        await rig.closeUndoGroup()
        try rig.saveElsewhere("theirs\n")

        #expect(rig.watch.reconcile() == .asked(.changed))
        #expect(rig.watch.banner == .changed)
        #expect(rig.banners == [.changed], "the host was not told — autosave would go on writing")
        #expect(rig.text == "one\ntwo\nthree\ntyped\n", "the typing was reloaded over")
        #expect(rig.undo.canUndo, "the history went while the question is still open")
        #expect(try rig.onDisk() == "theirs\n")
        // Asking again changes nothing — the banner is answered, never answered for you.
        #expect(rig.watch.reconcile() == .asked(.changed))
        #expect(rig.banners == [.changed])
    }

    /// **A word being composed is typing**, though the buffer does not hold it yet: right after a
    /// save the document reads clean, and only the input method's marked text stands between the
    /// word and a reload, which would end the composition. On TextKit 2, as Source is.
    @Test func composingInSourceRaisesTheBanner() throws {
        let rig = try Rig()
        let view = try Self.sourceView(on: rig)
        view.setSelectedRange(NSRange(location: (rig.text as NSString).length, length: 0))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.hasMarkedText(), "no composition — nothing here is under test")
        try #require(!rig.document.isDirty, "the fixture is dirty — the rule would ask without the IME guard")
        try rig.saveElsewhere("theirs\n")
        #expect(rig.watch.reconcile() == .asked(.changed), "a reload ended the word being composed")
        #expect(view.hasMarkedText())
    }

    /// **"Use the Disk's"** — the buffer becomes the file, clean, as ONE step ⌘Z takes back.
    @Test func useTheDisksVersionIsOneUndoableStep() async throws {
        let rig = try Rig("a\r\nb\r\n")
        rig.type("typed")                   // converts to LF, as a first edit does
        await rig.closeUndoGroup()
        let typed = rig.text
        try rig.saveElsewhere("theirs\r\n")
        #expect(rig.watch.reconcile() == .asked(.changed))

        #expect(rig.watch.useDisksVersion() == .used)
        #expect(Data(rig.text.utf8) == Data("theirs\r\n".utf8), "the disk's version was not taken verbatim")
        #expect(!rig.document.isDirty)
        #expect(rig.watch.banner == nil)
        #expect(rig.banners == [.changed, nil])
        #expect(rig.undo.undoActionName == EditorDiskWatch.useDisksActionName)
        await rig.closeUndoGroup()
        rig.undo.undo()
        #expect(rig.text == typed, "⌘Z did not bring the typing back")
        #expect(rig.document.isDirty)
    }

    /// **⌘Z of Use the Disk's puts the question back**, not only the typing: the other version is
    /// still on disk, so autosave must not write over it without Keep Mine's consent. Taken back
    /// whole — the banner, and the document's record of the disk — so the next look asks again
    /// rather than calling the disk in agreement. ⌘⇧Z takes the disk's version again.
    @Test func undoingUseTheDisksPutsTheQuestionBack() async throws {
        let rig = try Rig()
        rig.type("typed\n")
        await rig.closeUndoGroup()
        try rig.saveElsewhere("theirs\n")
        #expect(rig.watch.reconcile() == .asked(.changed))
        #expect(rig.watch.useDisksVersion() == .used)
        await rig.closeUndoGroup()

        rig.undo.undo()
        #expect(rig.text == "one\ntwo\nthree\ntyped\n")
        #expect(rig.watch.banner == .changed, "the question went with the undo — autosave would resume")
        #expect(rig.banners == [.changed, nil, .changed], "the host was not told — its autosave stop stays clear")
        #expect(EditorAutosave.attempt(rig.document) == .blocked(.changed),
                "autosave wrote the typing over the other version without asking")
        #expect(try rig.onDisk() == "theirs\n")
        #expect(rig.watch.reconcile() == .asked(.changed), "a look called the disk in agreement and cleared the question")

        await rig.closeUndoGroup()
        rig.undo.redo()
        #expect(rig.text == "theirs\n")
        #expect(rig.watch.banner == nil)
        #expect(!rig.document.isDirty)
        #expect(rig.watch.reconcile() == .nothing)
    }

    /// **Keep Mine is the host's write**; once it lands, the disk agrees and the banner goes.
    @Test func theBannerGoesOnceTheDiskAgrees() async throws {
        let rig = try Rig()
        rig.type("mine\n")
        try rig.saveElsewhere("theirs\n")
        #expect(rig.watch.reconcile() == .asked(.changed))
        rig.document.markSaved(stamp: try EditorFileStore.write(rig.document))
        #expect(rig.watch.reconcile() == .settled)
        #expect(rig.watch.banner == nil)
        #expect(try rig.onDisk() == "one\ntwo\nthree\nmine\n")
    }

    // MARK: A new stamp over the same bytes is not a change

    /// **A `touch` — or a sync client re-stamping the file after uploading the editor's own save —
    /// must not empty the history.** Reloading for it would reset ⌘Z after every pause in typing.
    @Test func aTouchKeepsTheHistoryAndSaysNothing() async throws {
        let rig = try Rig()
        rig.type("four\n")
        await rig.closeUndoGroup()
        _ = EditorAutosave.attempt(rig.document)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                              ofItemAtPath: rig.path)
        #expect(rig.watch.reconcile() == .restamped)
        #expect(rig.undo.canUndo, "a touch emptied the history")
        #expect(rig.watch.notice == nil)
        #expect(rig.document.diskStamp == EditorFileStore.stamp(ofPath: rig.path))
        #expect(rig.document.stamp == EditorFileStore.stamp(ofPath: rig.path), "the next save would stop on it")
    }

    /// The same text installed again under unsaved typing — a new inode, nothing to ask about.
    @Test func theSameTextInstalledAgainUnderTypingAsksNothing() throws {
        let rig = try Rig()
        rig.type("typed\n")
        try rig.saveElsewhere("one\ntwo\nthree\n")       // what the document has as saved
        #expect(rig.watch.reconcile() == .restamped)
        #expect(rig.watch.banner == nil)
        #expect(EditorAutosave.attempt(rig.document) == .wrote, "autosave stopped on a change that was not one")
    }

    /// **The same text in another encoding IS a change** — kept as the old one, the next save would
    /// write a UTF-16 file back as UTF-8.
    @Test func theSameTextInAnotherEncodingIsAChange() throws {
        let rig = try Rig("same\n")
        let utf16 = Data([0xFF, 0xFE]) + "same\n".data(using: .utf16LittleEndian)!
        let staged = rig.folder.appendingPathComponent(".utf16")
        try utf16.write(to: staged)
        #expect(rename(staged.path, rig.path) == 0)
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(rig.document.encodingName == BoundedTextRead.TextEncoding.utf16LittleEndian.rawValue)
    }

    // MARK: The editor's own writes are not a change from elsewhere

    @Test func theEditorsOwnSaveIsNotAChange() throws {
        let rig = try Rig()
        rig.type("mine\n")
        #expect(EditorAutosave.attempt(rig.document) == .wrote)
        #expect(rig.watch.reconcile() == .nothing)
        #expect(rig.watch.banner == nil && rig.watch.notice == nil)
        #expect(rig.text == "one\ntwo\nthree\nmine\n")
    }

    @Test func theEditorsOwnBackgroundWriteIsNotAChange() async throws {
        let rig = try Rig()
        rig.type("mine\n")
        let snapshot = try #require(EditorAutosave.snapshot(of: rig.document))
        #expect(await EditorAutosave.write(snapshot, into: rig.document) == .wrote)
        #expect(rig.document.backgroundWrites == 0)
        #expect(rig.watch.reconcile() == .nothing)
        #expect(rig.watch.banner == nil)
    }

    /// **The window between the swap and the commit**: the file on disk is the editor's own and
    /// newer than the stamp. A look in it must wait, not reload or ask.
    @Test func aLookWhileTheEditorsWriteIsOutWaits() throws {
        let rig = try Rig()
        rig.type("mine\n")
        rig.document.beginBackgroundWrite()
        let stamp = try EditorFileStore.write(rig.document.text, toPath: rig.path)
        #expect(rig.watch.reconcile() == .nothing)
        #expect(rig.watch.banner == nil, "the editor's own write was read as somebody else's")
        rig.document.markSaved(stamp: stamp)
        rig.document.endBackgroundWrite()
        #expect(rig.watch.reconcile() == .nothing)
    }

    // MARK: Moved or renamed: followed

    @Test func aRenamedFileIsFollowedWithItsHistory() async throws {
        let rig = try Rig()
        rig.type("typed\n")                 // dirty, and a step on the stack
        await rig.closeUndoGroup()
        rig.document.caretAnchors.remember(3, for: rig.path)
        let old = rig.path
        let new = rig.url("renamed.md").path
        #expect(rename(old, new) == 0)

        #expect(rig.watch.reconcile() == .followed(new))
        #expect(rig.path == new)
        #expect(rig.moves.count == 1 && rig.moves.first?.0 == old && rig.moves.first?.1 == new)
        #expect(rig.text == "one\ntwo\nthree\ntyped\n")
        #expect(rig.undo.canUndo, "the history did not follow the file")
        #expect(rig.document.caretAnchors.offset(for: new) == 3)
        #expect(rig.watch.banner == nil)
        // Editing carries on: autosave writes the typing at the new path.
        #expect(EditorAutosave.attempt(rig.document) == .wrote)
        #expect(try rig.onDisk(new) == "one\ntwo\nthree\ntyped\n")
        #expect(!FileManager.default.fileExists(atPath: old), "the old path was written again — two copies")
        // The history is filed under the new path: away to another file and back, it is handed back.
        let manager = rig.undo
        try Data("other\n".utf8).write(to: rig.url("other.md"))
        rig.open(rig.url("other.md").path)
        rig.open(new)
        #expect(rig.undo === manager, "the history stayed filed under the old path")
    }

    /// **A rename that only changes the case** — note.md to Note.md. On a case-insensitive volume the
    /// old spelling still finds the same file with the same stamp, so the look found "nothing" and
    /// the header kept the old name. The descriptor knows the name the file has now.
    @Test func aCaseOnlyRenameIsFollowed() throws {
        let rig = try Rig()
        let old = rig.path
        #expect(rename(old, rig.url("Note.md").path) == 0)
        guard case .followed(let followed) = rig.watch.reconcile() else {
            Issue.record("a case-only rename was not followed"); return
        }
        #expect((followed as NSString).lastPathComponent == "Note.md")
        #expect((rig.path as NSString).lastPathComponent == "Note.md")
        #expect(rig.moves.count == 1)
        #expect(EditorDiskWatch.followedNotice(from: old, to: followed) == "Renamed elsewhere — now “Note.md”")
        #expect(rig.watch.reconcile() == .nothing, "followed again and again")
    }

    /// **A save that renames the original aside and only then installs the new file** — JetBrains'
    /// `___jb_old___`, Word's `~WRL`, Emacs' backups — with a gap longer than the settle. Followed at
    /// the first look, the document went to the backup name, the backup's delete then raised the
    /// deleted banner, and the new file at the original path was never loaded. A rename within the
    /// folder, seen by an event, is looked at once more after another settle before it is followed.
    ///
    /// Each look is taken by hand, as an event would take it: the steps of the save have to fall
    /// BETWEEN two looks, and a settle measured in milliseconds cannot promise that on a loaded
    /// runner — this test once took 628 s in a full-package run and the clock won. The settle is
    /// long enough that no event looks on its own.
    @Test func aSaveThatRenamesAsideSlowlyIsAChangeNotAMove() throws {
        let rig = try Rig(settle: .seconds(3600))
        let original = rig.path
        let aside = original + "___jb_old___"
        #expect(rename(original, aside) == 0)
        // The first look sees the empty path and the file under its backup name, and waits.
        #expect(rig.watch.lookAsAnEventWould() == .nothing, "the rename aside was followed at the first look")
        #expect(rig.watch.isConfirmingRename)
        #expect(rig.path == original)
        // The save finishes: a new file at the original path, the backup gone.
        try Data("new version\n".utf8).write(to: URL(fileURLWithPath: original + "___jb_tmp___"))
        #expect(rename(original + "___jb_tmp___", original) == 0)
        try FileManager.default.removeItem(atPath: aside)
        #expect(rig.watch.lookAsAnEventWould() == .reloaded, "the new file at the original path was not loaded")
        #expect(rig.text == "new version\n")
        #expect(rig.watch.lookAsAnEventWould() == .nothing, "the backup's delete was read as the note's")
        #expect(rig.path == original, "followed the save's backup")
        #expect(rig.moves.isEmpty)
        #expect(rig.watch.banner == nil)

        // A real rename to the same name later is a rename: looked at twice, then followed.
        #expect(!rig.watch.isConfirmingRename, "the save's rename is still remembered — the next would count as its second look")
        #expect(rename(original, aside) == 0)
        #expect(rig.watch.lookAsAnEventWould() == .nothing, "the last save's rename was taken as this one's first look")
        #expect(rig.watch.isConfirmingRename)
        #expect(rig.watch.lookAsAnEventWould() == .followed(aside), "a rename that stayed was not followed")
        #expect(rig.path == aside)
    }

    /// **A move to another folder is followed at the first look** — no save moves its file out of
    /// the folder and back, so there is nothing to wait for.
    @Test func anEventFromTheFileSystemFollowsAMoveToAnotherFolderAtOnce() async throws {
        let rig = try Rig(settle: .milliseconds(100))
        let sub = rig.folder.appendingPathComponent("Filed")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }    // the mkdir's events settle
        #expect(rename(rig.path, sub.appendingPathComponent("note.md").path) == 0)
        var sawSecondLook = false
        let followed = await LayoutPumpWait.pump(NSView(), upTo: 5) {
            sawSecondLook = sawSecondLook || rig.watch.isConfirmingRename
            return rig.path.contains("/Filed/")
        }
        #expect(followed.held)
        #expect(!sawSecondLook, "a move to another folder waited for a second look")
    }

    /// **The host is told whose move it followed** — after the app's own file operation its full
    /// refresh has re-read the panes already, and a second re-read (logged as a write Edit never made)
    /// is a duplicate; a move from elsewhere has nothing else re-reading them.
    @Test func aFollowSaysWhetherTheMoveWasTheAppsOwn() throws {
        let rig = try Rig()
        var byThisApp: [Bool] = []
        rig.watch.onMoved = { _, _, mine in byThisApp.append(mine) }
        let renamed = rig.url("renamed.md").path
        #expect(rename(rig.path, renamed) == 0)
        #expect(rig.watch.reconcile(afterOwnFileOperation: true) == .followed(renamed))
        let sub = rig.folder.appendingPathComponent("Filed")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(rename(renamed, sub.appendingPathComponent("renamed.md").path) == 0)
        guard case .followed = rig.watch.reconcile() else { Issue.record("not followed"); return }
        #expect(byThisApp == [true, false])
    }

    @Test func aFileMovedToAnotherFolderIsFollowed() throws {
        let rig = try Rig()
        let sub = rig.folder.appendingPathComponent("Filed")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let new = sub.appendingPathComponent("note.md").path
        #expect(rename(rig.path, new) == 0)
        guard case .followed(let followed) = rig.watch.reconcile() else {
            Issue.record("the move was not followed"); return
        }
        #expect(EditorFileStore.resolved(followed) == EditorFileStore.resolved(new))
        #expect(EditorDiskWatch.followedNotice(from: rig.moves[0].0, to: followed) == "Moved elsewhere — now in “Filed”")
    }

    // MARK: Deleted: a banner, and the text stays

    @Test func aDeletedFileRaisesTheBannerAndKeepsTheText() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(atPath: rig.path)
        #expect(rig.watch.reconcile() == .asked(.deleted))
        #expect(rig.text == "one\ntwo\nthree\n")
        #expect(rig.path.hasSuffix("note.md"))
        // Save Again is the host's write at the old path; then the disk agrees.
        rig.document.markSaved(stamp: try EditorFileStore.write(rig.document))
        #expect(rig.watch.reconcile() == .settled)
        #expect(try rig.onDisk() == "one\ntwo\nthree\n")
    }

    /// **The folder deleted and made again — another device, a restore — is heard.** With the folder
    /// gone the watch could open neither the file nor its folder, so it held no descriptor at all
    /// and the file coming back was never heard: the deleted banner stood over a file that was there,
    /// and Save Again then wrote over it. The nearest folder that is still there is watched instead.
    @Test func aFileWhoseFolderIsMadeAgainIsHeard() async throws {
        let rig = try Rig()
        // Two levels down in the rig's own folder, so the folder above that is watched meanwhile is a
        // quiet one — the temporary folder hears every other test's files.
        let inner = rig.folder.appendingPathComponent("deep/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let path = inner.appendingPathComponent("note.md").path
        try Data("one\n".utf8).write(to: URL(fileURLWithPath: path))
        rig.open(path)
        try FileManager.default.removeItem(at: rig.folder.appendingPathComponent("deep"))
        let deleted = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.watch.banner == .deleted }
        try #require(deleted.held, "the folder's delete was not heard")
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }    // the delete's own events settle
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        // The folders' arrival is looked at before the file comes: the watch must move down into them.
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }
        try Data("another device's version\n".utf8).write(to: URL(fileURLWithPath: path))
        let heard = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "another device's version\n" }
        #expect(heard.held, "the file came back and nothing heard it")
        #expect(rig.watch.banner == nil)
    }

    /// **Save Again looks before it writes.** A file back at the path since the banner went up — one
    /// the events have not reached yet — is not written over: the banner changes to say so instead.
    @Test func saveAgainNeverWritesOverAFileThatCameBack() throws {
        let rig = try Rig(settle: .seconds(30))     // no event settles in time: only Save Again's look
        rig.type("typed\n")
        try FileManager.default.removeItem(atPath: rig.path)
        #expect(rig.watch.reconcile() == .asked(.deleted))
        try Data("came back\n".utf8).write(to: URL(fileURLWithPath: rig.path))

        #expect(rig.watch.prepareSaveAgain() == .notMissing)
        #expect(try rig.onDisk() == "came back\n")
        #expect(rig.watch.banner == .changed, "the banner still says the file is gone")
        #expect(rig.text == "one\ntwo\nthree\ntyped\n")
    }

    /// **Save Again puts the folder back too**, when the file went with it — the staging write had
    /// nowhere to go, and Close, which discards the only copy, was the one other answer.
    @Test func saveAgainMakesTheFolderAgain() async throws {
        let log = LogCapture()
        let rig = try Rig(settle: .seconds(30))
        rig.type("typed\n")
        try FileManager.default.removeItem(at: rig.folder)
        #expect(rig.watch.reconcile() == .asked(.deleted))

        #expect(rig.watch.prepareSaveAgain() == .write)
        #expect(FileManager.default.fileExists(atPath: rig.folder.path))
        rig.document.markSaved(stamp: try EditorFileStore.write(rig.document))     // the host's write
        #expect(rig.watch.reconcile() == .settled)
        #expect(try rig.onDisk() == "one\ntwo\nthree\ntyped\n")
        #expect(await log.holds(.info, containing: "made the folder \(rig.folder.path) again"),
                "the folder came back with nothing in the log saying so")
    }

    /// **Heard as well as seen** — the quiet reload's notice and the banner's question are both
    /// announced to VoiceOver, as the workspace's own hints are; and the banner for a file that is
    /// gone says what is known — it is no longer on disk — since a delete, the Trash, an ejected
    /// disk and the app's own Move to Trash all look the same from here.
    @Test func whatTheWatchDoesIsAnnouncedInWordsThatAreTrue() throws {
        let rig = try Rig()
        var announced: [String] = []
        rig.watch.announce = { announced.append($0) }
        try rig.saveElsewhere("theirs\n")
        #expect(rig.watch.reconcile() == .reloaded)
        #expect(announced == [EditorDiskWatch.reloadedNotice], "the quiet reload was not announced")
        try FileManager.default.removeItem(atPath: rig.path)
        #expect(rig.watch.reconcile() == .asked(.deleted))
        #expect(announced.last == "“note.md” is no longer on disk.", "the banner's question was not announced")
        #expect(rig.watch.reconcile() == .asked(.deleted))
        #expect(announced.count == 2, "a banner already up was announced again")
        #expect(EditorDiskBanner.changed.message(name: "a.md") == "“a.md” changed on disk while you were typing.")
    }

    /// **The log carries what is needed afterwards**: a reload names both stamps; a banner that goes
    /// on its own says so; a look put off because the file kept changing says so. Each fragment
    /// names this rig's own path, so no other test's line can satisfy it.
    @Test func theLogSaysWhatTheWatchDidAndWhy() async throws {
        let log = LogCapture()
        let rig = try Rig()
        let before = try #require(rig.document.diskStamp)
        try rig.saveElsewhere("theirs, longer\n")
        #expect(rig.watch.reconcile() == .reloaded)
        let after = try #require(rig.document.diskStamp)
        #expect(await log.holds(.info, containing: "Reloaded \(rig.path) — it changed elsewhere (was \(EditorDiskWatch.describe(before)); now \(EditorDiskWatch.describe(after)))"),
                "the reload line does not say which version replaced which")
        #expect(EditorDiskWatch.describe(before).hasPrefix("14 bytes, modified 20"))

        rig.type("mine\n")
        try rig.saveElsewhere("someone else's\n")
        #expect(rig.watch.reconcile() == .asked(.changed))
        rig.document.markSaved(stamp: try EditorFileStore.write(rig.document))
        #expect(rig.watch.reconcile() == .settled)
        #expect(await log.holds(.info, containing: "\(rig.path) agrees with the document again"),
                "the banner went with nothing in the log")

        #expect(rig.watch.reloadQuietly(rig.path, opened: .refused(reason: EditorFileStore.keptChangingReason)) == .nothing)
        #expect(await log.holds(.info, containing: "\(rig.path) kept changing while it was read"))
    }

    @Test func aFileMovedToTheTrashIsDeletedNotFollowed() throws {
        let rig = try Rig()
        let trash = rig.folder.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        #expect(rename(rig.path, trash.appendingPathComponent("note.md").path) == 0)
        #expect(rig.watch.reconcile() == .asked(.deleted))
        #expect(rig.moves.isEmpty)
    }

    // MARK: The events themselves

    /// No `reconcile()` from the test: the kernel's event, settled, has to get there on its own.
    @Test func anEventFromTheFileSystemReloadsOnItsOwn() async throws {
        let rig = try Rig()
        try rig.saveElsewhere("arrived on its own\n")
        let arrived = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "arrived on its own\n" }
        #expect(arrived.held, "no event reached the watch")
    }

    /// A write into the same inode is heard by the FILE's source — the folder sees no entry change.
    @Test func anInPlaceWriteIsHeardOnItsOwn() async throws {
        let rig = try Rig()
        try rig.writeInPlace("written where it stood\n")
        let arrived = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "written where it stood\n" }
        #expect(arrived.held, "an in-place write was not heard")
    }

    /// **After an atomic save the watch moves to the new inode** — or the next in-place write, which
    /// only the file's own source hears, would go unnoticed.
    @Test func theWatchMovesToTheNewFileAfterAnAtomicSave() async throws {
        let rig = try Rig()
        try rig.saveElsewhere("first\n")
        #expect(rig.watch.reconcile() == .reloaded)
        // The save's own events settle and are looked at first — or a late look at THEM would find
        // the in-place write below and pass this test whatever the watch is on.
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.5) { false }
        try rig.writeInPlace("second, in place\n")
        let arrived = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "second, in place\n" }
        #expect(arrived.held, "the watch stayed on the inode the atomic save replaced")
    }

    /// **The count is taken by autosave's own write**, not only honoured by the watch.
    @Test func autosavesBackgroundWriteIsCountedWhileItIsOut() async throws {
        let rig = try Rig()
        rig.type("mine\n")
        let snapshot = try #require(EditorAutosave.snapshot(of: rig.document))
        let document = rig.document
        // Recorded as it changes, not caught by looking: a fast write can come and go between two
        // looks on a loaded machine (708 s, 2026-10-12, never seen at 1).
        var counts: [Int] = []
        document.onBackgroundWrites = { counts.append($0) }
        let write = Task { await EditorAutosave.write(snapshot, into: document) }
        #expect(await write.value == .wrote)
        document.onBackgroundWrites = nil
        #expect(counts == [1, 0], "autosave's write was counted as \(counts) — the watch could read it as somebody else's")
        #expect(rig.watch.reconcile() == .nothing)
        #expect(rig.watch.banner == nil)
        #expect(document.backgroundWrites == 0)
    }

    @Test func anEventFromTheFileSystemFollowsARenameOnItsOwn() async throws {
        let rig = try Rig()
        let new = rig.url("renamed.md").path
        #expect(rename(rig.path, new) == 0)
        let followed = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.path == new }
        #expect(followed.held, "the rename was not followed")
    }

    /// A question about one file is over when another is opened — and the host is told, so it does
    /// not keep autosave stopped for the next one.
    @Test func openingAnotherFileEndsTheQuestion() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(atPath: rig.path)
        #expect(rig.watch.reconcile() == .asked(.deleted))
        try Data("other\n".utf8).write(to: rig.url("other.md"))
        rig.open(rig.url("other.md").path)
        #expect(rig.watch.banner == nil)
        #expect(rig.banners == [.deleted, nil])
    }

    /// **Closing cancels the kernel sources**, not only the document: a write afterwards reaches no
    /// event at all. `reconcile()` answering `.nothing` with no path open proves nothing about that —
    /// it answers so whether or not the watcher is still armed.
    @Test func closingTheDocumentStopsTheWatch() async throws {
        let rig = try Rig()
        let path = rig.path
        // The control: the same write while open IS heard, so silence below means something.
        try rig.writeInPlace("while open\n")
        let heard = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.watch.eventsHeard > 0 }
        try #require(heard.held, "no event while open — the silence after closing would prove nothing")
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }    // that write's events settle

        rig.undoStore.remember(text: rig.document.text)
        rig.document.close()
        let before = rig.watch.eventsHeard
        try Data("after close\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.removeItem(atPath: path)
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.5) { false }
        #expect(rig.watch.eventsHeard == before, "the watch still hears a file that is no longer open")
        #expect(rig.watch.reconcile() == .nothing)
        #expect(rig.document.path == nil && rig.text == "")
    }

    // MARK: Cloud

    /// A newer version still in the cloud is fetched, not refused onto the screen.
    @Test func aCloudOnlyNewVersionIsDownloadedNotRefused() throws {
        let rig = try Rig(isCloudOnly: { $0.hasSuffix("note.md") })
        try rig.saveElsewhere("in the cloud\n")
        #expect(rig.watch.reconcile() == .downloading)
        #expect(rig.text == "one\ntwo\nthree\n")
        #expect(rig.document.refusal == nil)
    }

    /// **A newer version still in the cloud, under the banner**: it is asked for when the banner goes
    /// up, and Use the Disk's waits for it and then takes it — where it used to say the file could
    /// not be read, with nothing anywhere fetching it.
    @Test func aCloudOnlyVersionUnderTheBannerIsFetchedAndUseTheDisksWaitsForIt() async throws {
        let flag = CloudFlag()
        flag.isCloudOnly = false
        let log = DownloadLog()
        let rig = try Rig(isCloudOnly: { _ in flag.isCloudOnly })
        rig.watch.startDownload = { log.ask($0) }
        rig.watch.downloadPoll = .milliseconds(20)
        rig.type("typed\n")
        await rig.closeUndoGroup()
        let typed = rig.text
        try rig.saveElsewhere("theirs\n")
        flag.isCloudOnly = true

        #expect(rig.watch.reconcile() == .asked(.changed))
        #expect(log.asked == [rig.path], "the newer version is in the cloud and nothing asked for it")
        #expect(rig.watch.useDisksVersion() == .downloading)
        #expect(rig.text == typed)
        #expect(rig.watch.banner == .changed)
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }    // the save's events settle
        flag.isCloudOnly = false
        let taken = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "theirs\n" }
        #expect(taken.held, "the version arrived and Use the Disk's never took it")
        #expect(rig.watch.banner == nil)
        #expect(!rig.document.isDirty)
        await rig.closeUndoGroup()
        rig.undo.undo()
        #expect(rig.text == typed, "⌘Z did not bring the typing back")
    }

    /// What the download seams saw — written from the read's own queue, so locked.
    final class DownloadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads: [String] = []
        private var _asked: [String] = []
        let release = DispatchSemaphore(value: 0)
        var reads: [String] { lock.withLock { _reads } }
        var asked: [String] { lock.withLock { _asked } }
        func read(onQueue label: String) { lock.withLock { _reads.append(label) } }
        func ask(_ path: String) { lock.withLock { _asked.append(path) } }
    }

    /// A cloud-only flag a test can flip — the file "arrives" when it goes false.
    final class CloudFlag { var isCloudOnly = true }

    /// **iCloud is asked through its own API, which does not block — and nothing is read.** The file
    /// is looked at again when it lands, with no event (materialising one sends none).
    @Test func anICloudDownloadIsAskedForAndNotRead() async throws {
        let flag = CloudFlag()
        let log = DownloadLog()
        let rig = try Rig(isCloudOnly: { _ in flag.isCloudOnly })
        rig.watch.startDownload = { log.ask($0) }
        rig.watch.readFirstByte = { _ in log.read(onQueue: "read") }
        rig.watch.downloadPoll = .milliseconds(20)
        try rig.saveElsewhere("in the cloud\n")
        #expect(rig.watch.reconcile() == .downloading)
        #expect(log.asked == [rig.path])
        // The save's own events settle first — a late look at THEM would find the file landed and
        // pass this test whatever the download does.
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.3) { false }
        try #require(rig.text == "one\ntwo\nthree\n")
        flag.isCloudOnly = false
        let landed = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "in the cloud\n" }
        #expect(landed.held, "the download landed and nothing looked at it")
        #expect(log.reads.isEmpty, "a byte was read from a file iCloud had been asked for")
    }

    /// **A provider that never answers costs one blocked read, on a queue of its own — never one a
    /// minute on the shared pool.** The 60 s patience used to clear the download while the read was
    /// still blocked, and the next look started another: one stuck thread a minute, on the pool
    /// autosave's write needs. The download now stays out until its read returns, and that read is
    /// the only one, whatever looks and events come meanwhile.
    @Test func aStuckDownloadHoldsOneReadOnItsOwnQueue() async throws {
        let flag = CloudFlag()
        let log = DownloadLog()
        let rig = try Rig(isCloudOnly: { _ in flag.isCloudOnly })
        struct NotICloud: Error {}
        rig.watch.startDownload = { log.ask($0); throw NotICloud() }
        rig.watch.readFirstByte = { _ in
            log.read(onQueue: String(cString: __dispatch_queue_get_label(nil)))
            // Held until the test lets go — never by a clock. A 10 s limit here was shorter than this
            // test takes in a loaded full-package run (726 s, 2026-10-12): the "stuck" read returned
            // on its own, the download rightly ended, and 29 reads looked like the leak it guards.
            log.release.wait()
        }
        rig.watch.downloadPatience = .milliseconds(60)
        rig.watch.downloadPoll = .milliseconds(20)
        defer { log.release.signal() }
        try rig.saveElsewhere("in the cloud\n")
        #expect(rig.watch.reconcile() == .downloading)
        // Several patiences, with looks and events through them.
        for _ in 0..<5 {
            _ = await LayoutPumpWait.pump(NSView(), upTo: 0.1) { false }
            _ = rig.watch.reconcile()
            rig.watch.eventArrived()
        }
        _ = await LayoutPumpWait.pump(NSView(), upTo: 0.2) { false }
        #expect(log.reads.count == 1, "another read was started while the first was still blocked")
        #expect(log.asked.count == 1, "the download was ended by the clock while its read was out, and asked for again")
        #expect(log.reads.first == EditorDiskWatch.downloadQueueLabel, "the read ran on a shared pool thread")
        // The provider answers at last, and the file is local: looked at, and reloaded.
        flag.isCloudOnly = false
        log.release.signal()
        let landed = await LayoutPumpWait.pump(NSView(), upTo: 5) { rig.text == "in the cloud\n" }
        #expect(landed.held, "the read returned and nothing looked again")
    }

    // MARK: The pieces

    @Test func theSmallestEditSplitsNeitherASurrogatePairNorACRLF() {
        let emoji = EditorSourceStorage.smallestEdit(from: "a😀b", to: "a😁b")
        #expect(emoji.range == NSRange(location: 1, length: 2) && emoji.text == "😁")
        let crlf = EditorSourceStorage.smallestEdit(from: "x\r\ny", to: "x\ny")
        #expect(crlf.range == NSRange(location: 1, length: 2) && crlf.text == "\n")
        let tail = EditorSourceStorage.smallestEdit(from: "one\ntwo\n", to: "one\ntwo\nthree\n")
        #expect(tail.range == NSRange(location: 8, length: 0) && tail.text == "three\n")
    }

    @Test func theUndoStoreFilesAMovedHistoryUnderItsNewPath() {
        let store = EditorUndoStore()
        store.activate(path: "/f/a.md", text: "a")
        let manager = store.current
        // Something to undo: a history with nothing in it is not kept, at any path (2026-10-09).
        store.source.replace(NSRange(location: 1, length: 0), with: "b", undoManager: manager)
        store.move(from: "/f/a.md", to: "/f/b.md")
        store.remember(text: "ab")
        store.activate(path: "/f/b.md", text: "ab")
        #expect(store.current === manager, "the history was not handed back at the new path")
    }

    @Test func autosaveSwitchedOffStaysOffAcrossAMove() {
        let policy = EditorAutosavePolicy()
        policy.setOn(false, for: "/f/a.md")
        policy.move(from: "/f/a.md", to: "/f/b.md")
        #expect(!policy.isOn("/f/b.md"))
        #expect(policy.isOn("/f/a.md"))
    }

    /// **The destination picker's New Folder says it made one, before the transfer is asked about** —
    /// so the host lists it even when that transfer is then declined. Read from the source: the
    /// picker is a view no test can press.
    @Test func thePickerTellsTheHostAboutANewFolderBeforeTheTransfer() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FileExplorer/DestinationPicker.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(code.range(of: "private func createFolderAndCommit() {"))
        let body = code[start.upperBound...]
        let told = try #require(body.range(of: "onFolderCreated(created)"))
        let commit = try #require(body.range(of: "onCommit(created)"))
        #expect(told.lowerBound < commit.lowerBound)
    }

    @Test func theDeletedBannerOffersSaveAgainOnlyWhereItCouldWrite() {
        #expect(EditorDiskBannerView.actions(for: .changed, canSaveAgain: true) == [.compare, .keepMine, .useDisks])
        #expect(EditorDiskBannerView.actions(for: .deleted, canSaveAgain: true) == [.close, .saveAgain])
        #expect(EditorDiskBannerView.actions(for: .deleted, canSaveAgain: false) == [.close])
    }
}
