import AppKit
import PDFKit

/// File ▸ Print… — the rendered document, handed to the system's print panel (roadmap RD9).
///
/// **The pages are rendered before the panel opens, not by it.** AppKit's own route is to give
/// `NSPrintOperation` a view and let it repaginate for whatever paper the panel ends up choosing;
/// that route is closed here, because the view being printed is a SwiftUI hosting view and a
/// hosting view drawn into a print context draws *nothing* — measured, on this app's own preview:
/// three pages of correctly numbered, entirely blank paper. `ImageRenderer` is the API that renders
/// SwiftUI into an arbitrary `CGContext`, and it renders into a PDF context rather than into a
/// print operation.
///
/// **So the paper is decided by ``NSPrintInfo/shared`` — the reader's default — and a different
/// paper chosen in the panel scales rather than repaginates.** `.pageScaleToFit` is what makes that
/// honest: a Letter-shaped page sent to A4 arrives whole and slightly smaller, rather than losing
/// its right-hand margin. The cost is real and worth naming: the number of pages is settled before
/// the panel opens, so a reader who changes paper size *in* the panel gets scaled pages rather than
/// re-broken ones. Changing the default paper in Page Setup and printing again does repaginate.
@MainActor
public enum DocumentPrinting {

    /// A print operation for `job`, or `nil` when the document could not be rendered.
    ///
    /// The caller runs it — `runModal(for:delegate:didRun:contextInfo:)` against the window, so the
    /// panel arrives as a sheet on the window the document is in rather than as a free-floating
    /// dialog belonging to nothing.
    public static func operation(for job: DocumentPDF.Job,
                                 info: NSPrintInfo = .shared) -> NSPrintOperation? {
        // A copy: `NSPrintInfo.shared` is the app's, and a print of one document must not leave
        // its own settings behind for the next one.
        guard let settings = info.copy() as? NSPrintInfo else { return nil }
        let geometry = DocumentPDF.PageGeometry.from(settings)
        guard let data = DocumentPDF.data(for: job, geometry: geometry),
              let document = PDFDocument(data: data) else { return nil }
        let operation = document.printOperation(for: settings, scalingMode: .pageScaleToFit,
                                                autoRotate: false)
        // The name in the print queue and on the panel. Without it the job is called by the
        // process name, which is the app rather than the document.
        operation?.jobTitle = job.name
        return operation
    }
}
