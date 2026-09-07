import AppKit
import SwiftUI
import Design
import Events
import FileExplorer
import Sync

/// File ▸ Print… and File ▸ Export as PDF… — what the two items do, and when they are offered
/// (roadmap RD9).
///
/// **Two doors onto one render.** ``DocumentPDF`` produces the pages; this decides where they go —
/// the print panel, or a file the reader names. Everything about *what* is on the page lives over
/// there, and everything about the window, the panel and the log lives here, which is the same
/// split the editor's save path already has between `EditorFileStore` and `ContentView+Editor`.
struct DocumentPrintActions {
    /// Renders the document and puts the system print panel up over the window.
    let print: () -> Void
    /// Asks where to put it, then writes the same render there.
    let export: () -> Void

    /// Whether the two items are offered at all, as a pure rule.
    ///
    /// **The same gate the Text and Markup menus use, and deliberately the same one.** Edit must be
    /// the workspace on screen, not merely the owner of a document: the document outlives a
    /// workspace switch, so a test on the path alone would leave File ▸ Print… live from Browse,
    /// aimed at a file nobody is looking at. A refused document — too large, cloud-only, not text —
    /// has nothing to print either.
    ///
    /// **A read-only document is NOT excluded**, which is the one place this parts from the verbs.
    /// Read-only is about writing back to the file; printing reads. A note that opened read-only
    /// because one byte of it is not valid text still prints exactly what the preview shows.
    static func isOffered(workspace: Workspace, hasDocument: Bool, isRefused: Bool) -> Bool {
        EditorVerbs.isOffered(workspace: workspace, hasDocument: hasDocument, isRefused: isRefused)
    }
}

extension ContentView {

    /// The two items' actions, or `nil` when they are not offered — see
    /// ``DocumentPrintActions/isOffered(workspace:hasDocument:isRefused:)``.
    var shortcutDocumentPrint: DocumentPrintActions? {
        guard DocumentPrintActions.isOffered(workspace: selectedWorkspace,
                                             hasDocument: editorDocument.path != nil,
                                             isRefused: editorDocument.refusal != nil) else {
            return nil
        }
        return DocumentPrintActions(print: { printEditorDocument() },
                                    export: { exportEditorDocumentAsPDF() })
    }

    /// What is being printed, snapshotted at the moment the menu item fires.
    ///
    /// **The buffer, not the file.** The two differ exactly when there is unsaved typing, and a
    /// print of the version on disk while a newer one is on screen would be a quiet wrong answer —
    /// the one thing the reader cannot check without printing it. The preview shows the buffer, and
    /// this is the preview.
    var editorPrintJob: DocumentPDF.Job? {
        guard let path = editorDocument.path else { return nil }
        return DocumentPDF.Job(
            name: editorDocument.name,
            text: editorDocument.text,
            isMarkdown: editorDocument.isMarkdown,
            folder: (path as NSString).deletingLastPathComponent,
            // Settings ▸ Text size, so the page is set in the type the reader reads in.
            fontScale: appFontScale,
            accent: glassHue.accentColor)
    }

    /// ⌘P — render, then hand the pages to the system print panel.
    func printEditorDocument() {
        guard let job = editorPrintJob else { return }
        guard let operation = DocumentPrinting.operation(for: job) else {
            syncManager.banner = .error("Couldn't prepare “\(job.name)” for printing.")
            Logger.shared.warning("Editor print produced no pages for \(job.name)")
            return
        }
        Logger.shared.info("Editor printing \(job.name)")
        // A sheet on the window the document is in, rather than a dialog belonging to nothing.
        // `runModal()` without a window is the fallback for a state that should not arise.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// File ▸ Export as PDF… — the same render, written where the reader says.
    ///
    /// **The panel opens on the folder the rail is reading**, with the document's own name and a
    /// `.pdf` extension, so the ordinary answer is one Return. That is the roadmap's "into the
    /// folder the rail is reading"; the panel is what makes it a suggestion rather than a place
    /// files appear without being asked for.
    ///
    /// **The bytes go through `EditorFileStore`**, not through `Data.write(to:)`. Everything this
    /// app puts on disk is staged, flushed and swapped, and an export is not the place to start
    /// making exceptions — a half-written PDF over a good one is the same loss as a half-written
    /// note.
    func exportEditorDocumentAsPDF() {
        guard let job = editorPrintJob else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.exportName
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.message = "Export “\(job.name)” as PDF"
        if !editorFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: editorFolder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Rendered AFTER the panel is answered, so a cancel costs nothing — on a long document
        // that is seconds rather than milliseconds.
        guard let data = DocumentPDF.data(for: job,
                                          geometry: .from(NSPrintInfo.shared)) else {
            syncManager.banner = .error("Couldn't render “\(job.name)” as a PDF.")
            Logger.shared.warning("Editor PDF export produced no pages for \(job.name)")
            return
        }
        do {
            try EditorFileStore.write(data, toPath: url.path)
            Logger.shared.info("Editor exported \(job.name) as PDF to \(url.path)")
            syncManager.banner = .success("Exported “\(url.lastPathComponent)”")
            // The rail lists the folder it is reading, and the export may have landed in it.
            Task { await refreshEditorRail() }
        } catch {
            // Banner rather than log-only, on the save path's own argument: a write the user asked
            // for that silently did nothing is the failure they will not notice until it matters.
            syncManager.banner = .error(
                "Couldn't export “\(url.lastPathComponent)” — \(error.localizedDescription)")
        }
    }
}
