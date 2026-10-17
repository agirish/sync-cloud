import Foundation
import FileExplorer

/// **What is open in Edit: the text document, or a PDF — one switch, and only one of them at once.**
///
/// The two models sit side by side (``EditorPDFDocument``'s doc says why a PDF is not a kind of
/// `EditorDocument`), so "the open file" is whichever holds a path. This is where the window asks
/// that, and where a load chooses which one takes the file — **before** any text read, so a PDF
/// never reaches `EditorFileStore.open` and its lossy-decode fallback (which used to open a small
/// PDF from Open With ▸ Other… read-only, as garbled text).
///
/// Extracted for `EditorDocumentLoad`'s reason: `ContentView` cannot be built in a test, so an act
/// written inline there is one nothing executes.
@MainActor
enum EditorOpenRoute {

    /// Which model a path goes to.
    enum Kind: Equatable { case text, pdf }

    nonisolated static func kind(of path: String) -> Kind {
        EditableText.isPDF(path: path) ? .pdf : .text
    }

    /// The open file, whichever model holds it — what "already open" and the pane's owed selection
    /// are asked against.
    static func openPath(document: EditorDocument, pdf: EditorPDFDocument) -> String? {
        pdf.path ?? document.path
    }

    /// Whether the open file was refused — so a second open of it is let through (a file
    /// downloaded since is one click away), for a PDF as for text.
    static func isRefused(document: EditorDocument, pdf: EditorPDFDocument) -> Bool {
        pdf.path != nil ? pdf.refusal != nil : document.refusal != nil
    }

    /// **Loads `path` into the model that takes it, and empties the other.** The caller has already
    /// settled the text document (`settleEditorDocument()`), exactly as for text → text — so a
    /// dirty note is written before a PDF replaces it.
    ///
    /// The text document is emptied the way File ▸ Close Document empties it
    /// (`EditorDocumentClose.run`): its undo stack filed against the text it is parted from, then
    /// the empty storage followed. With `path == nil`, every save path — ⌘S, autosave, the settle,
    /// the quit flush — has nothing to write.
    @discardableResult
    static func load(path: String, document: EditorDocument, undoStore: EditorUndoStore,
                     pdf: EditorPDFDocument, log: @escaping (String) -> Void) -> Kind {
        switch kind(of: path) {
        case .pdf:
            emptyText(document, undoStore: undoStore)
            pdf.open(path: path, log: log)
            return .pdf
        case .text:
            // Released before the text is read, so a long scan's pages are not held across it.
            if let open = pdf.path {
                pdf.close()
                log("Editor closed \(open) (PDF) to open \(path)")
            }
            EditorDocumentLoad.run(path: path, document: document, undoStore: undoStore, log: log)
            return .text
        }
    }

    /// Empties the text document, keeping its undo stack for when it is opened again.
    static func emptyText(_ document: EditorDocument, undoStore: EditorUndoStore) {
        guard document.path != nil else { return }
        undoStore.remember(text: document.text)
        document.close()
        undoStore.activate(path: nil, text: "")
        document.buffer.follow(undoStore.source)
    }

    /// The header's × and File ▸ Close Document, for a PDF: nothing to settle — it was never
    /// written to — so the document goes, its pages with it, and the pane's selection of it is
    /// cleared as `EditorDocumentClose.run` clears a text file's.
    @discardableResult
    static func closePDF(_ pdf: EditorPDFDocument,
                         paneSelection: () -> Set<String>,
                         setPaneSelection: (Set<String>) -> Void,
                         log: (String) -> Void) -> Bool {
        guard let path = pdf.path else { return false }
        pdf.close()
        if let next = EditorDocumentClose.paneSelection(afterClosing: path, selection: paneSelection()) {
            setPaneSelection(next)
        }
        log("Editor closed \(path)")
        return true
    }
}
