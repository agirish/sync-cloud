import AppKit

/// **The editor's text view: AppKit's own, plus the two doors no delegate method reaches** — a
/// paste (TE55, TE56) and a drop (TE56).
///
/// Return and Tab arrive through the delegate (`textView(_:doCommandBy:)`), which is why the rest of
/// `PlainTextEditor` still says "the delegate hook, not a subclass". Paste and drop do not: AppKit
/// reads the pasteboard inside `paste(_:)` and `performDragOperation(_:)` with no delegate in the
/// way. So this overrides exactly those two, asks ``handler`` first, and otherwise calls `super` —
/// every paste and drop the handler does not claim is AppKit's, unchanged.
///
/// **Built by `EditorTextView.scrollableTextView()`**, the same factory as before: measured
/// 2026-10-04, it builds the subclass and the view still comes up on TextKit 2
/// (`textLayoutManager` non-nil).
final class EditorTextView: NSTextView {

    /// What decides whether a paste or a drop is Markdown's business. Weak: the coordinator owns
    /// the view's delegate relationship, not this view.
    weak var handler: EditorTextViewHandling?

    override func paste(_ sender: Any?) {
        if handler?.handlePaste(from: .general, in: self) == true { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A drag that started in this view is text being moved, never a file.
        if let handler, (sender.draggingSource as AnyObject?) !== self,
           let files = Self.imageFiles(on: sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            switch handler.handleDrop(imageFiles: files, at: index, in: self) {
            case .handled: return true
            case .refused: return false
            case .notMine: break
            }
        }
        return super.performDragOperation(sender)
    }

    /// The dragged files when EVERY item on the pasteboard is an image file, or `nil`.
    ///
    /// **All or nothing.** A drop holding a PDF beside two photos is not an image drop, and gets
    /// what a drop of files has always got here — their paths, as text — rather than half of each.
    /// A FOLDER named like an image (`Trip.png`, a package) is not an image file either.
    static func imageFiles(on pasteboard: NSPasteboard) -> [String]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var paths: [String] = []
        for item in items {
            guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
                  EditorImageImport.isImageFile(url.path),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { return nil }
            paths.append(url.path)
        }
        return paths
    }
}

/// What a drop came to.
enum EditorDropOutcome: Equatable {
    /// Written and linked.
    case handled
    /// Ours, but refused — the host has said why; the drag is rejected and nothing changes.
    case refused
    /// Not ours: AppKit's drop goes ahead.
    case notMine
}

/// The coordinator's half of ``EditorTextView``.
@MainActor
protocol EditorTextViewHandling: AnyObject {
    /// Whether the paste was taken. `false` sends it to AppKit's own paste.
    func handlePaste(from pasteboard: NSPasteboard, in view: NSTextView) -> Bool
    func handleDrop(imageFiles: [String], at index: Int, in view: NSTextView) -> EditorDropOutcome
}

/// **Where a note's dropped and pasted images go, and who hears about it** — handed to the editor
/// only for a writable Markdown document. `nil` means images are not this editor's business, and a
/// drop or paste of one does what it always did.
public struct EditorImageImporter {
    /// The open note. Its folder's `Images` folder is where the images go.
    public var notePath: String
    /// Told about every import — what was written, so the panes can be re-read and Compare told,
    /// or why nothing was, for the banner.
    public var report: (EditorImageImport.Report) -> Void

    public init(notePath: String, report: @escaping (EditorImageImport.Report) -> Void) {
        self.notePath = notePath
        self.report = report
    }
}
