import Combine
import Foundation
import Sync

/// The open file's buffer, on an object of its own so that typing invalidates the text and nothing
/// else.
///
/// Not a property of ``EditorDocument``: the document is observed by `SyncCloudApp` and
/// `ContentView`, so a `@Published` buffer there would announce every keystroke to the App scene
/// (rebuilding its `.commands` tree), to `ContentView.body` and its shortcut closures, and to the
/// workspace, none of which render from the text. Only `EditorWorkspaceView`, `PlainTextEditor` and
/// the autosave driver observe this; the identity (which file, whether it can be saved, what is on
/// disk) stays on the document, which the rest of the window watches.
///
/// Held by the document for its whole lifetime, so whatever the document survives (a workspace
/// teardown, a window close), the buffer survives too.
@MainActor
public final class EditorBuffer: ObservableObject {

    public init() {
        source.buffer = self
    }

    /// The text. Published from ``source`` on every character edit to the storage, whoever made it,
    /// and read by everything that renders it.
    ///
    /// A write from anywhere else is taken into the storage with no undo (see
    /// ``EditorSourceStorage/takeBufferText(_:)``), so the two can't disagree while attached. The
    /// document's own writes (a load, a close) happen while the storage is put away, and are not.
    @Published public var text: String = "" {
        didSet {
            textVersion &+= 1
            if !isPublishing, source.buffer === self { source.takeBufferText(text) }
        }
    }

    /// The open document's text storage: what every Source text view is built around, and what an
    /// edit from outside the text view goes through. See ``EditorSourceStorage``.
    ///
    /// Swapped on every load and close by ``follow(_:)``, to the storage ``EditorUndoStore`` keeps
    /// beside the incoming document's undo stack. Published, so a mounted text view is re-pointed
    /// at it even when the incoming text equals the outgoing.
    @Published public private(set) var source = EditorSourceStorage()

    /// Set while ``source`` is the writer, so its edit isn't taken straight back into it.
    private var isPublishing = false

    /// Says that an edit just converted the file to LF, once per conversion, through whichever door
    /// made it (``EditorSourceStorage/noteConversion(_:on:)``). The disk watch shows it on the
    /// status line for a few seconds: a Windows file changing every line ending on its first
    /// keystroke shouldn't happen silently.
    public let convertedToLF = PassthroughSubject<Void, Never>()

    /// Called by ``source`` on every edit to it.
    func publish(_ string: String) {
        isPublishing = true
        text = string
        isPublishing = false
    }

    /// Follows `incoming` from here on: the last step of every load and close, after
    /// ``EditorUndoStore/activate(path:text:)`` has chosen the storage that fits the loaded text.
    ///
    /// The outgoing storage stops publishing here; ``EditorUndoStore/remember(text:opening:)`` has
    /// already stopped it listening. The incoming one is either fresh from this text or kept beside
    /// a stack whose byte-hash fingerprint matched it, so the two agree by construction and are not
    /// compared here: at 4 MiB the byte comparison costs about 40 times the fingerprint, on every
    /// switch back.
    public func follow(_ incoming: EditorSourceStorage) {
        if source !== incoming {
            if source.buffer === self { source.buffer = nil }
            source = incoming
        }
        incoming.buffer = self
    }

    /// Bumped on every write to ``text``.
    ///
    /// A counter, so the preview's re-render can be keyed on it instead of the string: the buffer
    /// can be 4 MiB, and `.task(id:)` compares its id on every render pass. `&+=` because wrapping
    /// is fine: the value means "different from last time", never "how many edits".
    ///
    /// Not `@Published`: it moves in lockstep with ``text``, whose announcement has already
    /// happened, and a second publisher for the same event would double every render pass.
    public private(set) var textVersion: Int = 0
}

/// The one open file: its text, whether that text has been changed, and what the editor is allowed
/// to do with it.
///
/// One document per app, owned by the app (`SyncCloudApp.editorDocument`), not by a view. The
/// editor's view is torn down on every workspace switch, and a buffer in it would take an unsaved
/// edit with it; nothing in SwiftUI promises that closing the window keeps `ContentView` either.
/// Every view is a rendering of this object.
///
/// The text lives one level down, on ``buffer`` (see ``EditorBuffer``). Reading and writing
/// ``text`` here still works; what differs is who is told. A view that renders the characters
/// observes ``buffer``; one that renders the file's identity or saved state observes this object.
@MainActor
public final class EditorDocument: ObservableObject {

    public init() {}

    /// The characters. Observe this, not the document, from anything that renders them. Held for
    /// the document's whole life, so it survives everything the document survives.
    public let buffer = EditorBuffer()

    /// Where the caret was in each file this session; see ``EditorCaretAnchors``. Beside ``buffer``
    /// so it survives a workspace switch tearing down the editor's view. Not `@Published`: the
    /// caret moves at typing speed, and announcing it would put this document's observers back on
    /// the keystroke path.
    public let caretAnchors = EditorCaretAnchors()

    /// The file on screen, or `nil` when nothing is open.
    @Published public private(set) var path: String?

    /// The buffer. Written by the text view, read by everything else. A forwarding view onto
    /// ``buffer``: writing it announces to the buffer's observers, not this document's, so the
    /// window doesn't re-render because somebody typed.
    public var text: String {
        get { buffer.text }
        set { buffer.text = newValue }
    }

    /// Bumped on every write to ``text``; see ``EditorBuffer/textVersion``.
    public var textVersion: Int { buffer.textVersion }

    /// Why this file cannot be saved, or `nil` when it can.
    @Published public private(set) var readOnlyReason: String?
    /// Whether it turned read-only under the open document (a reload found the file no longer
    /// readable as text) rather than opening that way. What was drawn for a writable file then
    /// stays, greyed, so nothing moves under the pointer.
    @Published public private(set) var becameReadOnlyInPlace = false
    /// The reason nothing could be opened, shown where the text would be.
    @Published public private(set) var refusal: String?

    /// The text as it stands on disk, so "changed" is a comparison, not a flag; a flag would
    /// survive an undo back to the original text and claim the file dirty forever.
    ///
    /// `@Published` because everything on screen that says whether the work is on disk (the dirty
    /// dot, the meta line, whether File ▸ Save is enabled) derives from this and ``stamp``;
    /// unpublished, the dot would stay lit after ⌘S until some other state change re-rendered the
    /// window.
    @Published public private(set) var savedText: String = ""
    /// What the file looked like when it was read, `nil` for a read-only or unopened document.
    @Published public private(set) var stamp: EditorFileStore.Stamp? {
        didSet { sizeCaption = stamp.map { FileSyncManager.formatBytes($0.size) } }
    }

    /// What the file at ``path`` looked like the last time this app read or wrote it: the stamp the
    /// disk watch (``EditorDiskWatch``) compares against to tell a change from elsewhere from
    /// nothing.
    ///
    /// ``stamp`` for a saveable document, moved by every write, so the editor's own saves (autosave
    /// included) read back as "nothing happened". Kept for a read-only document too, where
    /// ``stamp`` is `nil` on purpose (one of the gates that keeps it from being written), because a
    /// read-only file still reloads when it changes. `nil` with nothing open, and for a refusal.
    /// Not published: nothing on screen is drawn from it.
    public private(set) var diskStamp: EditorFileStore.Stamp?

    /// How many autosave writes are out on a background thread for this document right now.
    ///
    /// The one window in which the editor's own write can look like somebody else's: autosave swaps
    /// the file off the main actor and marks it saved back on it, so in between the file on disk is
    /// newer than ``diskStamp`` says. The disk watch waits while this is above zero, then compares
    /// against the stamp the write left. A synchronous write (⌘S, a flush) needs no count: it
    /// stamps the document before the main actor can run anything else.
    public private(set) var backgroundWrites = 0 {
        didSet { onBackgroundWrites?(backgroundWrites) }
    }

    /// Told each count as it changes, for the tests: on a loaded machine a write can come and go
    /// between two looks.
    var onBackgroundWrites: ((Int) -> Void)?

    func beginBackgroundWrite() { backgroundWrites += 1 }
    func endBackgroundWrite() { backgroundWrites = max(0, backgroundWrites - 1) }

    /// What a background write installed, readable before its commit reaches the main actor, so a
    /// synchronous save can take the editor's own write as saved instead of asking about it
    /// (``EditorAutosave/settleLandedWrite(into:waitingUpTo:)``).
    nonisolated let landings = EditorAutosave.Landings()

    /// The text a write put on disk that couldn't be checked afterwards: the read-back failed, so
    /// the document holds no stamp for it and still reads unsaved. Without it, the next look would
    /// find Edit's own write newer than the stamp and ask about it as a change made elsewhere.
    /// ``EditorFileStore/settleUncheckedWrite(of:)`` compares the disk with it, and a match counts
    /// as saved. Cleared by any save, open, reload or close.
    public private(set) var uncheckedWrite: String?

    func noteUncheckedWrite(_ text: String) { uncheckedWrite = text }

    /// The open file's size as the status line shows it, or `nil` with no stamp. Formatted when the
    /// stamp moves, not when the line is drawn: `formatBytes` builds a `ByteCountFormatter` per
    /// call, and the status line is drawn on every keystroke.
    public private(set) var sizeCaption: String?
    /// How the bytes were decoded, and so how they must be written back; `nil` whenever nothing
    /// saveable is open. Internal: only this module may name an encoding, which stops a caller
    /// writing a UTF-16 file back as UTF-8.
    private(set) var encoding: BoundedTextRead.TextEncoding?

    /// Bumped whenever anything the dirty comparison reads, other than the buffer, moves. With
    /// ``EditorBuffer/textVersion`` it names one (buffer, saved state) pair exactly, which
    /// ``isDirty`` memoises against. Every writer of `savedText`, `path` and `readOnlyReason` is in
    /// this file, which is what makes the counter sufficient.
    private var savedVersion: Int = 0
    private var dirtyMemo: (textVersion: Int, savedVersion: Int, value: Bool)?

    /// How the bytes were decoded, as the status line names it, or `nil` when nothing decodable is
    /// open. A name, not the encoding: ``encoding`` stays internal so only this module can name
    /// one, and the status line only needs to say it.
    public var encodingName: String? { encoding?.rawValue }

    /// Whether the buffer differs from the file.
    ///
    /// A comparison, memoised, never a flag: it is derived from the two strings whenever either
    /// moves, so an undo back to the original text reads clean. The memo removes the repeat cost:
    /// one body pass asks this six times (both dots, an accessibility label, the meta row twice,
    /// the autosave driver), on every keystroke, over a buffer that can be 4 MiB and bridged from
    /// UTF-16 storage.
    ///
    /// Compared unit for unit by `NSString`, which asks whether the file's bytes would change.
    /// Swift's `!=` is canonical equivalence, so an accent written differently from the file would
    /// read clean and ⌘S, autosave, the close and quit prompts, and a disk reload would all pass
    /// over it. The UTF-16 length is the storage's own, so most edits are settled by length alone.
    public var isDirty: Bool {
        let key = (buffer.textVersion, savedVersion)
        if let memo = dirtyMemo, memo.textVersion == key.0, memo.savedVersion == key.1 {
            return memo.value
        }
        let value = computeIsDirty()
        dirtyMemo = (key.0, key.1, value)
        return value
    }

    private func computeIsDirty() -> Bool {
        guard path != nil, readOnlyReason == nil else { return false }
        return !(buffer.text as NSString).isEqual(to: savedText)
    }

    /// Whether ⌘S has anything to do.
    public var canSave: Bool { isDirty }
    public var isReadOnly: Bool { readOnlyReason != nil }
    public var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }
    /// Whether the preview toggle applies to what is open.
    public var isMarkdown: Bool { path.map { PairContentKind.isMarkdown(path: $0) } ?? false }

    /// Drops whatever was open. Callers prompt about a dirty buffer before calling this: the
    /// document doesn't ask, so every prompt is on one path rather than hidden in a setter.
    public func close() {
        uncheckedWrite = nil
        path = nil
        text = ""
        savedText = ""
        stamp = nil
        diskStamp = nil
        encoding = nil
        readOnlyReason = nil
        becameReadOnlyInPlace = false
        refusal = nil
        savedVersion &+= 1
    }

    /// Opens a file, replacing whatever was open.
    func open(_ opened: EditorFileStore.Opened, at path: String) {
        self.path = path
        becameReadOnlyInPlace = false
        take(opened, assigningTextAlways: true)
    }

    /// The file's newer contents, at the path already open: a reload, which keeps the document's
    /// identity. ``path`` isn't written, so nothing that follows the path treats this as another
    /// file.
    ///
    /// The caller has normally put the text in the storage already, as the smallest edit that gets
    /// there (``EditorSourceStorage/takeDiskText(_:)``), so the caret and scroll stay near where
    /// they were; the text is written here only when it still differs.
    func reload(_ opened: EditorFileStore.Opened) {
        if case .readOnly = opened {
            // Writable until now: it turned read-only here. Read-only already: as it was.
            if !isReadOnly { becameReadOnlyInPlace = true }
        } else {
            becameReadOnlyInPlace = false
        }
        take(opened, assigningTextAlways: false)
    }

    /// Everything ``open(_:at:)`` sets but the path.
    ///
    /// - Parameter assigningTextAlways: `true` for an open, which always writes the buffer; `false`
    ///   for a reload, which leaves an identical buffer alone rather than bump its version.
    private func take(_ opened: EditorFileStore.Opened, assigningTextAlways: Bool) {
        func assign(_ text: String) {
            if assigningTextAlways || !EditorSourceStorage.sameBytes(buffer.text, text) { self.text = text }
        }
        uncheckedWrite = nil
        switch opened {
        case .editable(let text, let stamp, let encoding):
            assign(text)
            self.savedText = text
            self.stamp = stamp
            self.diskStamp = stamp
            self.encoding = encoding
            self.readOnlyReason = nil
            self.refusal = nil
        case .readOnly(let text, let reason, let stamp):
            assign(text)
            self.savedText = text
            self.stamp = nil
            self.diskStamp = stamp
            self.encoding = nil
            self.readOnlyReason = reason
            self.refusal = nil
        case .refused(let reason):
            // Both fields carry the reason. `refusal` is what the view switches on, so the reader
            // sees one caption, not a caption and a banner. `readOnlyReason` is set too because
            // `isReadOnly` derives from it and gates the save path: a refused document must not be
            // saveable by any route.
            assign("")
            self.savedText = ""
            self.stamp = nil
            self.diskStamp = nil
            self.encoding = nil
            self.readOnlyReason = reason
            self.refusal = reason
        }
        savedVersion &+= 1
    }

    /// The file moved, and the document goes with it: Finder, Organize or another device renamed or
    /// moved it while open. Only the path changes; the buffer, saved text, stamps and encoding all
    /// describe the same file.
    func retarget(to newPath: String) {
        path = newPath
        savedVersion &+= 1
    }

    /// The file has a new stamp over the same contents (a `touch`, or a sync client re-stamping it
    /// after an upload). Only the stamps move; nothing is reloaded or asked. A read-only document
    /// keeps its `nil` ``stamp``.
    func restamp(_ stamp: EditorFileStore.Stamp) {
        if self.stamp != nil { self.stamp = stamp }
        diskStamp = stamp
    }

    /// "Use Disk Version": the buffer already holds the file's newer text, put there as a step ⌘Z
    /// can take back, and this records that it is what is on disk.
    func adoptDisk(text: String, stamp: EditorFileStore.Stamp, encoding: BoundedTextRead.TextEncoding) {
        uncheckedWrite = nil
        savedText = text
        self.stamp = stamp
        diskStamp = stamp
        self.encoding = encoding
        savedVersion &+= 1
    }

    /// What the document records about the file on disk: everything
    /// ``adoptDisk(text:stamp:encoding:)`` moves, as one value, so ⌘Z can undo "Use Disk Version"
    /// whole.
    struct DiskRecord {
        var savedText: String
        var stamp: EditorFileStore.Stamp?
        var diskStamp: EditorFileStore.Stamp?
        var encoding: BoundedTextRead.TextEncoding?
    }

    var diskRecord: DiskRecord {
        DiskRecord(savedText: savedText, stamp: stamp, diskStamp: diskStamp, encoding: encoding)
    }

    /// Puts back a record taken earlier: the undo and redo of "Use Disk Version".
    func restore(_ record: DiskRecord) {
        savedText = record.savedText
        stamp = record.stamp
        diskStamp = record.diskStamp
        encoding = record.encoding
        savedVersion &+= 1
    }

    /// Records that the buffer is now what is on disk.
    public func markSaved(stamp: EditorFileStore.Stamp) {
        markSaved(text: text, stamp: stamp)
    }

    /// Records that `text`, not necessarily what is in the buffer now, is what is on disk.
    ///
    /// For autosave, which writes off the main actor from a snapshot: a keystroke landing while the
    /// bytes are in flight isn't on disk, so marking the buffer's current text saved would leave a
    /// dirty document reading clean with no write scheduled. Marking the snapshot leaves it dirty,
    /// and the stamp this moves (which the debounce is keyed on) schedules the next write, even if
    /// the typing's own debounce fired while this write was out.
    public func markSaved(text: String, stamp: EditorFileStore.Stamp) {
        uncheckedWrite = nil
        savedText = text
        self.stamp = stamp
        diskStamp = stamp
        savedVersion &+= 1
    }
}
