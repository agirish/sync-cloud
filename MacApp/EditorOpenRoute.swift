import Foundation
import Combine
import Events
import FileExplorer

/// What is open in Edit: the text document or a PDF, only one at once.
///
/// The two models sit side by side (``EditorPDFDocument`` says why a PDF is not an
/// `EditorDocument`), so "the open file" is whichever holds a path. This answers that, and picks
/// the model for a load before any text read, so a PDF never reaches `EditorFileStore.open` and
/// its lossy-decode fallback, which would show it read-only as garbled text. Kept out of
/// `ContentView` so a test can run it.
@MainActor
enum EditorOpenRoute {

    /// Which model a path goes to.
    enum Kind: Equatable { case text, pdf }

    nonisolated static func kind(of path: String) -> Kind {
        EditableText.isPDF(path: path) ? .pdf : .text
    }

    /// The open file, whichever model holds it: what "already open" and the pane's owed selection
    /// are asked against.
    static func openPath(document: EditorDocument, pdf: EditorPDFDocument) -> String? {
        pdf.path ?? document.path
    }

    /// Whether the open file was refused, so a second open of it is let through (a file downloaded
    /// since is one click away), for a PDF as for text.
    static func isRefused(document: EditorDocument, pdf: EditorPDFDocument) -> Bool {
        pdf.path != nil ? pdf.refusal != nil : document.refusal != nil
    }

    /// Loads `path` into the model that takes it, and empties the other. The caller has already
    /// settled the text document (`settleEditorDocument()`), so a dirty note is written before a
    /// PDF replaces it.
    ///
    /// The text document is emptied as `EditorDocumentClose.run` empties it: undo stack filed
    /// against the outgoing text, then the empty storage followed. With `path == nil`, every save
    /// path (⌘S, autosave, the settle, the quit flush) has nothing to write.
    @discardableResult
    static func load(path: String, document: EditorDocument, undoStore: EditorUndoStore,
                     pdf: EditorPDFDocument, log: @escaping (EditorLogLine) -> Void) -> Kind {
        switch kind(of: path) {
        case .pdf:
            emptyText(document, undoStore: undoStore)
            pdf.open(path: path, log: log)
            return .pdf
        case .text:
            // Released before the text is read, so a long scan's pages are not held across it.
            if let open = pdf.path {
                pdf.close()
                log(.info("Editor closed \(open) (PDF) to open \(path)"))
            }
            EditorDocumentLoad.run(path: path, document: document, undoStore: undoStore, log: log)
            return .text
        }
    }

    /// Lists what a load opened in Edit's recent files: the open file, whichever model took it, and
    /// nothing for a refused load, since an unreadable file is no file to offer again. Asked of the
    /// models after the load, because `load` reports only the route.
    ///
    /// A PDF is listed once the lane has read it, because PDFKit refuses an unreadable one only
    /// after `load` returns. A text file, or a PDF refused before the lane (still in the cloud), is
    /// answered at once.
    static func recordOpen(kind: Kind, document: EditorDocument, pdf: EditorPDFDocument,
                           in recents: EditorRecentFiles, at date: Date = Date()) {
        pendingPDFRecord = nil
        guard let path = openPath(document: document, pdf: pdf) else { return }
        if kind == .pdf, pdf.phase == .loading {
            // The first phase past `.loading`, read from the value sent: `@Published` sends before
            // it stores, so `pdf.phase` would still say `.loading` here.
            pendingPDFRecord = pdf.$phase.first { $0 != .loading }.sink { [weak pdf] phase in
                if case .refused = phase { return }
                // Sent on the main actor, where the PDF model sets its phase.
                MainActor.assumeIsolated {
                    guard pdf?.path == path else { return }
                    recents.record(path: path, kind: .pdf, at: date)
                }
            }
            return
        }
        guard !isRefused(document: document, pdf: pdf) else { return }
        recents.record(path: path, kind: kind == .pdf ? .pdf : .text, at: date)
    }

    /// The wait for a PDF's answer, replaced by the next open, which is the one that counts.
    private static var pendingPDFRecord: AnyCancellable?

    /// Empties the text document, keeping its undo stack for when it is opened again.
    static func emptyText(_ document: EditorDocument, undoStore: EditorUndoStore) {
        guard document.path != nil else { return }
        if let tally = EditorAutosaveTally.closeOut(document.path) { Logger.shared.info(tally) }
        undoStore.remember(text: document.text)
        document.close()
        undoStore.activate(path: nil, text: "")
        document.buffer.follow(undoStore.source)
    }

    /// The header's × and File ▸ Close Document, for a PDF. Nothing to settle, since it is never
    /// written to, so the document and its pages go, and the pane's selection of it is cleared as
    /// `EditorDocumentClose.run` clears a text file's.
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
