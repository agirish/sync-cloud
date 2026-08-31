import Foundation
import Sync

/// The one open file: its text, whether that text has been changed, and what the editor is allowed
/// to do with it.
///
/// **One document per app, held above the workspace rather than inside it.** The editor's view is
/// torn down every time the user switches to another workspace, and a buffer that lived in the view
/// would take an unsaved edit with it. It began owned by `ContentView` for that reason and moved
/// one level further up, to `SyncCloudApp.editorDocument`, for a second: closing the window rebuilds
/// `ContentView` and everything it owns, so the red traffic light dropped an unsaved buffer with no
/// prompt. This is a reference type owned by the app, and every view is a rendering of it.
@MainActor
public final class EditorDocument: ObservableObject {

    public init() {}

    /// The file on screen, or `nil` when nothing is open.
    @Published public private(set) var path: String?
    /// The buffer. Written by the text view, read by everything else.
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
    public private(set) var textVersion: Int = 0
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
    @Published public private(set) var stamp: EditorFileStore.Stamp?
    /// How the bytes were decoded, and therefore how they must be written back. `nil` whenever
    /// there is nothing saveable open. Internal: only this module may name an encoding, which is
    /// what stops a caller writing a UTF-16 file back as UTF-8.
    private(set) var encoding: BoundedTextRead.TextEncoding?

    /// Whether the buffer differs from the file.
    ///
    /// The length check first is a real shortcut rather than a micro-optimisation: this is read
    /// several times per body pass and a body pass happens on every keystroke, against a buffer
    /// that can be 4 MiB. Most keystrokes change the length, so most of them never reach the
    /// byte comparison at all.
    public var isDirty: Bool {
        guard path != nil, readOnlyReason == nil else { return false }
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
    }

    /// Records that the buffer is now what is on disk.
    public func markSaved(stamp: EditorFileStore.Stamp) {
        savedText = text
        self.stamp = stamp
    }
}
