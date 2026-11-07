import AppKit
import PDFKit
import Sync

/// File ▸ Print…: the rendered document, handed to the system's print panel.
///
/// The pages are rendered before the panel opens. A SwiftUI hosting view drawn into a print
/// context draws blank pages, so `NSPrintOperation` can't repaginate a view; `ImageRenderer`
/// renders into a PDF context instead. The paper is ``NSPrintInfo/shared``'s, and a paper changed
/// in the panel scales the pages (`.pageScaleToFit`) rather than re-breaking them; Page Setup and a
/// fresh print does repaginate.
///
/// The PDF is opened in ``PDFKitSerialAccess``'s lane, like every PDFKit parse, so the panel comes
/// a moment after ⌘P and the caller is handed the operation. See ``prepare(_:info:then:)``.
@MainActor
public enum DocumentPrinting {

    /// Whether a print is being prepared: ⌘P pressed, the panel not up yet.
    public private(set) static var isPreparing = false

    /// Renders `job`, opens the pages in the lane, and hands `present` the print operation, or
    /// `nil` when the document could not be rendered. Returns `false`, doing nothing, while another
    /// print is being prepared.
    ///
    /// The flag is set here, on the press, not inside the task: two presses in one run-loop turn
    /// would both start a task first, and a second ⌘P during the lane wait would put up two panels.
    ///
    /// `present` should run it with `runModal(for:delegate:didRun:contextInfo:)`, so the panel is a
    /// sheet on the document's window.
    @discardableResult
    public static func prepare(_ job: DocumentPDF.Job, info: NSPrintInfo = .shared,
                               then present: @escaping @MainActor (NSPrintOperation?) -> Void) -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        Task { @MainActor in
            let operation = await operation(for: job, info: info)
            isPreparing = false
            present(operation)
        }
        return true
    }

    /// A print operation for `job`, or `nil` when the document could not be rendered.
    ///
    /// Only the parse goes to the lane. `ImageRenderer` and the AppKit operation are main-thread,
    /// so the document crosses back as a ``SendableDocument``. What the operation draws while it
    /// prints is AppKit drawing on its own schedule, covered on ``PDFKitSerialAccess``.
    static func operation(for job: DocumentPDF.Job, info: NSPrintInfo) async -> NSPrintOperation? {
        // A copy, so one document's print settings aren't left on the app's shared info.
        guard let settings = info.copy() as? NSPrintInfo else { return nil }
        let geometry = DocumentPDF.PageGeometry.from(settings)
        guard let data = DocumentPDF.data(for: job, geometry: geometry) else { return nil }
        guard let opened = await PDFKitSerialAccess.perform({
            PDFDocument(data: data).map(SendableDocument.init)
        }) else { return nil }
        let operation = opened.document.printOperation(for: settings, scalingMode: .pageScaleToFit,
                                                       autoRotate: false)
        // The name in the print queue and on the panel; without it the job takes the app's name.
        operation?.jobTitle = job.name
        return operation
    }
}
