import AppKit
import SwiftUI
import Design
import Events
import FileExplorer
import Sync

/// File ▸ Print… and File ▸ Export as PDF…: what the two items do, and when they are offered.
///
/// Two doors onto one render. ``DocumentPDF`` produces the pages and owns what is on them; this
/// sends them to the print panel or a file the reader names, and owns the window, panel and log,
/// the same split the save path has between `EditorFileStore` and `ContentView+Editor`.
struct DocumentPrintActions {
    /// Renders the document and puts the system print panel up over the window.
    let print: () -> Void
    /// Asks where to put it, then writes the same render there. `nil` for a PDF, which already is
    /// one: Export as PDF… is not offered for it, while Print… is.
    let export: (() -> Void)?
    /// The document's name, which Export's title carries; `nil` where Export is not offered.
    var exportName: String? = nil

    /// Whether the two items are offered at all, as a pure rule: the Text and Markup menus' gate.
    /// Edit must be on screen, since the document outlives a workspace switch and Print… must not
    /// be live from Browse; a refused document has nothing to print. A read-only document still
    /// prints: read-only is about writing back, and printing only reads.
    static func isOffered(workspace: Workspace, hasDocument: Bool, isRefused: Bool) -> Bool {
        EditorVerbs.isOffered(workspace: workspace, hasDocument: hasDocument, isRefused: isRefused)
    }
}

extension ContentView {

    /// The two items' actions, or `nil` when they are not offered — see
    /// ``DocumentPrintActions/isOffered(workspace:hasDocument:isRefused:)``.
    var shortcutDocumentPrint: DocumentPrintActions? {
        // A PDF prints its own pages once they are open, not while it is locked or refused.
        if editorPDF.path != nil {
            guard selectedWorkspace == .editor, editorPDF.canPrint else { return nil }
            return DocumentPrintActions(print: { printEditorPDF() }, export: nil)
        }
        guard DocumentPrintActions.isOffered(workspace: selectedWorkspace,
                                             hasDocument: editorDocument.path != nil,
                                             isRefused: editorDocument.refusal != nil) else {
            return nil
        }
        return DocumentPrintActions(print: { printEditorDocument() },
                                    export: { exportEditorDocumentAsPDF() },
                                    exportName: editorDocument.name)
    }

    /// What is being printed, snapshotted at the moment the menu item fires. The buffer, not the
    /// file: they differ when there is unsaved typing, and printing the saved version while a newer
    /// one is on screen would be a quiet wrong answer. The preview shows the buffer, and so does
    /// this.
    var editorPrintJob: DocumentPDF.Job? {
        guard let path = editorDocument.path else { return nil }
        return DocumentPDF.Job(
            name: editorDocument.name,
            text: editorDocument.text,
            isMarkdown: editorDocument.isMarkdown,
            // Where the preview reads the note's images from: the note file's folder, through a
            // symlink to the note.
            folder: EditorImageImport.linkFolder(ofNote: path),
            // Settings ▸ Text size, so the page is set in the type the reader reads in.
            fontScale: appFontScale,
            accent: glassHue.accentColor)
    }

    /// ⌘P: render, then hand the pages to the system print panel. The pages open in the PDFKit
    /// lane, so the panel arrives a moment later (longer while a scan holds the lane), and a second
    /// ⌘P meanwhile is dropped rather than starting a second print (`DocumentPrinting.prepare`).
    func printEditorDocument() {
        guard let job = editorPrintJob else { return }
        // Taken at the press, not when the pages arrive, when another window may be key. Running
        // without a window is the fallback for a state that shouldn't arise.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let started = DocumentPrinting.prepare(job) { operation in
            guard let operation else {
                syncManager.banner = .error("Couldn’t prepare “\(job.name)” for printing.", log: .loggedAtSite)
                Logger.shared.warning("Editor print produced no pages for \(job.name)")
                return
            }
            guard let window else { operation.run(); return }
            guard window.isVisible else {
                Logger.shared.info("Editor print of \(job.name) dropped — its window closed before the pages were ready")
                return
            }
            Logger.shared.info("Editor printing \(job.name)")
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
        if !started {
            Logger.shared.info("Editor print of \(job.name) ignored — another print is still being prepared")
        }
    }

    /// ⌘P for a PDF open in Edit: its own pages, through `PDFDocument.printOperation`, not
    /// `DocumentPDF`, which renders text. The document is the page view's, opened (and unlocked)
    /// through `PDFKitSerialAccess`; the print panel runs on the main thread, the lane's documented
    /// exception for drawing.
    func printEditorPDF() {
        guard let operation = editorPDF.printOperation() else {
            syncManager.banner = .error("Couldn’t prepare “\(editorPDF.name)” for printing.", log: .loggedAtSite)
            Logger.shared.warning("Editor print produced no operation for \(editorPDF.path ?? "") (PDF)")
            return
        }
        Logger.shared.info("Editor printing \(editorPDF.name) (PDF)")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// File ▸ Export as PDF…: the same render, written where the reader says. The panel opens on
    /// the rail's folder with the document's name and a `.pdf` extension, so the usual answer is
    /// one Return.
    ///
    /// The bytes go through `EditorFileStore`, not `Data.write(to:)`, so they are staged, flushed
    /// and swapped like every write: a half-written PDF over a good one is a real loss.
    func exportEditorDocumentAsPDF() {
        guard let job = editorPrintJob else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.exportName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.message = "Export “\(job.name)” as PDF"
        if !editorFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: editorFolder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Rendered after the panel is answered, so a cancel costs nothing; on a long document the
        // render takes seconds.
        guard let data = DocumentPDF.data(for: job,
                                          geometry: .from(NSPrintInfo.shared)) else {
            syncManager.banner = .error("Couldn’t render “\(job.name)” as a PDF.", log: .loggedAtSite)
            Logger.shared.warning("Editor PDF export produced no pages for \(job.name)")
            return
        }
        do {
            try EditorFileStore.write(data, toPath: url.path)
            Logger.shared.info("Editor exported \(job.name) as PDF to \(url.path)")
            syncManager.banner = .success("Exported “\(url.lastPathComponent)”")
            // The export may have landed in the rail's folder, and with the pane open the pane is
            // Edit's list, so re-read both: the rail, and whichever pane's folder holds the PDF.
            Task { await refreshEditorRail() }
            rereadPanesAfterEditorWrite(url.path)
        } catch {
            // A banner, not just a log line: a requested write that silently did nothing is a
            // failure the user won't notice until it matters.
            syncManager.banner = .error(
                "Couldn’t export “\(url.lastPathComponent)” — \(error.localizedDescription)", log: .error)
        }
    }
}
