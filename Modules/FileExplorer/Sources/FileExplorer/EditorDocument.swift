import Foundation
import Sync

/// The open file's **buffer**, on an object of its own so that typing invalidates the text and
/// nothing else.
///
/// **Why this is not a property of ``EditorDocument``.** It was, and the cost was structural rather
/// than incidental: the document is held as `@StateObject` by `SyncCloudApp` and as `@ObservedObject`
/// by `ContentView`, so a `@Published` buffer announced every keystroke to the App scene (rebuilding
/// its whole `.commands` tree), to `ContentView.body` (four thousand lines, ending in a modifier that
/// rebuilds ~25 shortcut closures and republishes them through `focusedSceneValue`), and to the
/// workspace. None of those render from the text — they render from ``EditorDocument/path``,
/// ``EditorDocument/refusal``, ``EditorDocument/isReadOnly`` and the saved/dirty comparison.
///
/// So the buffer moved down here and only the three things that genuinely follow the text observe
/// it: `EditorWorkspaceView`, `PlainTextEditor`, and the autosave driver. The identity — which file
/// is open, whether it can be saved, what is on disk — stays on the document, which is what the rest
/// of the window watches.
///
/// It is a **reference type held by the document for the document's lifetime**, so every invariant
/// the document states about surviving a workspace teardown or a window close holds for the buffer
/// unchanged: the document outlives both, and this comes with it.
@MainActor
public final class EditorBuffer: ObservableObject {

    public init() {}

    /// The text. Written by the text view, read by everything that renders it.
    @Published public var text: String = "" {
        didSet { textVersion &+= 1 }
    }

    /// Bumped on every write to ``text``.
    ///
    /// **A counter, so the preview's re-render can be keyed on it instead of on the string.** The
    /// buffer can be 4 MiB, and `.task(id:)` compares its id on every render pass — keying on the
    /// text itself would run a whole-buffer comparison per keystroke to answer a question an
    /// integer answers for nothing. `&+=` because wrapping at `Int.max` is fine: this value means
    /// "different from last time", never "how many edits".
    ///
    /// Deliberately **not** `@Published`: it moves in lockstep with ``text``, whose announcement has
    /// already happened by the time this is read, and a second publisher for the same event would
    /// double every render pass the buffer causes.
    public private(set) var textVersion: Int = 0
}

/// The one open file: its text, whether that text has been changed, and what the editor is allowed
/// to do with it.
///
/// **One document per app, held above the workspace rather than inside it.** The editor's view is
/// torn down every time the user switches to another workspace, and a buffer that lived in the view
/// would take an unsaved edit with it. It began owned by `ContentView` for that reason and moved
/// one level further up, to `SyncCloudApp.editorDocument`, for a second: closing the window rebuilds
/// `ContentView` and everything it owns, so the red traffic light dropped an unsaved buffer with no
/// prompt. This is a reference type owned by the app, and every view is a rendering of it.
///
/// **The text itself lives one level down, on ``buffer``** — see ``EditorBuffer`` for why. Reading
/// and writing ``text`` here still works and means exactly what it did; what changed is *who is
/// told*. A view that renders the characters must observe ``buffer``; a view that renders the file's
/// identity or its saved-ness observes this object.
@MainActor
public final class EditorDocument: ObservableObject {

    public init() {}

    /// The characters. **Observe this** — not the document — from anything that renders them.
    ///
    /// Held for the document's whole life, so it survives everything the document survives.
    public let buffer = EditorBuffer()

    /// The file on screen, or `nil` when nothing is open.
    @Published public private(set) var path: String?

    /// The buffer. Written by the text view, read by everything else.
    ///
    /// **A forwarding view onto ``buffer``, and writing it announces to the buffer's observers
    /// rather than to this document's.** That is the whole point of the split: the window does not
    /// re-render because somebody typed a character.
    public var text: String {
        get { buffer.text }
        set { buffer.text = newValue }
    }

    /// Bumped on every write to ``text`` — see ``EditorBuffer/textVersion``.
    public var textVersion: Int { buffer.textVersion }

    /// Why this file cannot be saved, or `nil` when it can.
    @Published public private(set) var readOnlyReason: String?
    /// The reason nothing could be opened — shown where the text would be.
    @Published public private(set) var refusal: String?

    /// The text as it stands on disk, so "changed" is a comparison rather than a flag that can be
    /// left set. A flag would survive an undo back to the original text and go on claiming the file
    /// was dirty forever.
    ///
    /// **`@Published`, and that is not decoration.** Everything on screen that says whether the
    /// work is on disk — the dirty dot, the meta line, whether File ▸ Save is enabled — is derived
    /// from this and from ``stamp``. Left unpublished, `markSaved` changed the answer and announced
    /// nothing: the dot stayed lit after a successful ⌘S until some *other* state write happened to
    /// re-render the window.
    @Published public private(set) var savedText: String = ""
    /// What the file looked like when it was read, `nil` for a read-only or unopened document.
    @Published public private(set) var stamp: EditorFileStore.Stamp? {
        didSet { sizeCaption = stamp.map { FileSyncManager.formatBytes($0.size) } }
    }

    /// The open file's size in the words the status line shows, or `nil` when there is no stamp.
    ///
    /// **Formatted when the stamp moves, not when the line is drawn.** `formatBytes` builds a fresh
    /// `ByteCountFormatter` per call, and the status line asked it once per body pass — which is
    /// once per keystroke, to render a number that only changes when the file is written. The stamp
    /// is the thing that moves, so the caption is derived where it moves.
    public private(set) var sizeCaption: String?
    /// How the bytes were decoded, and therefore how they must be written back. `nil` whenever
    /// there is nothing saveable open. Internal: only this module may name an encoding, which is
    /// what stops a caller writing a UTF-16 file back as UTF-8.
    private(set) var encoding: BoundedTextRead.TextEncoding?

    /// Bumped whenever anything the dirty comparison reads — other than the buffer — moves.
    ///
    /// Paired with ``EditorBuffer/textVersion`` it names one (buffer, saved state) pair exactly, and
    /// that pair is what ``isDirty`` memoises against. Every writer of `savedText`, `path` and
    /// `readOnlyReason` is in this file, which is what makes the counter sufficient rather than
    /// hopeful.
    private var savedVersion: Int = 0
    private var dirtyMemo: (textVersion: Int, savedVersion: Int, value: Bool)?

    /// How the bytes were decoded, in the words the status line shows — or `nil` when nothing
    /// decodable is open.
    ///
    /// **A name, not the encoding.** ``encoding`` stays private so that only this module can name
    /// one, which is what stops a caller writing a UTF-16 file back as UTF-8; the status line needs
    /// to *say* what it is, not to have it. Publishing the string rather than the value is what
    /// keeps those two apart.
    public var encodingName: String? { encoding?.rawValue }

    /// Whether the buffer differs from the file.
    ///
    /// **A comparison, memoised — never a flag.** The answer is still derived from the two strings
    /// every time either of them moves, so an undo back to the original text still reads as clean;
    /// what the memo removes is the *repeat* cost. One body pass of the editor asks this six times
    /// (the rail's dot, the header's dot, its accessibility label, the meta row's word twice, and
    /// the autosave driver), a body pass happens on every keystroke, and each ask walked a buffer
    /// that can be 4 MiB — `text.utf8.count` is only O(1) for a natively-stored string, and the one
    /// the text view hands back is bridged from UTF-16 text storage, so it transcoded the whole
    /// document to answer. Now it walks once per edit and the other five reads are a tuple compare.
    ///
    /// The length check inside is kept for the same reason it was written: most keystrokes change
    /// the length, so most edits never reach the byte comparison at all.
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
        let text = buffer.text
        return text.utf8.count != savedText.utf8.count || text != savedText
    }

    /// Whether ⌘S has anything to do.
    public var canSave: Bool { isDirty }
    public var isReadOnly: Bool { readOnlyReason != nil }
    public var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }
    /// Whether the preview toggle applies to what is open.
    public var isMarkdown: Bool { path.map { PairContentKind.isMarkdown(path: $0) } ?? false }

    /// Drops whatever was open. Callers prompt about a dirty buffer *before* calling this — the
    /// document does not ask, so that every prompt is on one path rather than hidden in a setter.
    public func close() {
        path = nil
        text = ""
        savedText = ""
        stamp = nil
        encoding = nil
        readOnlyReason = nil
        refusal = nil
        savedVersion &+= 1
    }

    /// Opens a file, replacing whatever was open.
    func open(_ opened: EditorFileStore.Opened, at path: String) {
        switch opened {
        case .editable(let text, let stamp, let encoding):
            self.path = path
            self.text = text
            self.savedText = text
            self.stamp = stamp
            self.encoding = encoding
            self.readOnlyReason = nil
            self.refusal = nil
        case .readOnly(let text, let reason):
            self.path = path
            self.text = text
            self.savedText = text
            self.stamp = nil
            self.encoding = nil
            self.readOnlyReason = reason
            self.refusal = nil
        case .refused(let reason):
            // **Both fields carry the reason, and that is deliberate.** `refusal` is what the view
            // switches on, so the reader sees one caption rather than a caption and a banner saying
            // the same thing. `readOnlyReason` is set as well because `isReadOnly` is derived from
            // it and gates the save path: a refused document must not be saveable by any route,
            // and one flag standing on its own is one edit away from not being checked.
            self.path = path
            self.text = ""
            self.savedText = ""
            self.stamp = nil
            self.encoding = nil
            self.readOnlyReason = reason
            self.refusal = reason
        }
        savedVersion &+= 1
    }

    /// Records that the buffer is now what is on disk.
    public func markSaved(stamp: EditorFileStore.Stamp) {
        markSaved(text: text, stamp: stamp)
    }

    /// Records that **`text`** — not necessarily what is in the buffer now — is what is on disk.
    ///
    /// **The overload autosave needs, and the reason it exists is a race the synchronous write did
    /// not have.** Autosave writes off the main actor from a snapshot taken when the write was
    /// dispatched; a keystroke landing while those bytes are in flight is *not* on disk, so marking
    /// the buffer's current text as saved would leave a dirty document reading clean and no further
    /// write scheduled for it. Marking the snapshot instead leaves the document correctly dirty and
    /// the next debounce writes the rest.
    public func markSaved(text: String, stamp: EditorFileStore.Stamp) {
        savedText = text
        self.stamp = stamp
        savedVersion &+= 1
    }
}
