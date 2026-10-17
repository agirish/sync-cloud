import AppKit
import PDFKit
import Sync

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
///
/// **The rendered PDF is opened in ``PDFKitSerialAccess``'s lane, like every other PDFKit parse in
/// the process.** So the panel arrives a moment after ⌘P — longer while a scan holds the lane — and
/// the caller is handed the operation rather than returned it. See ``prepare(_:info:then:)``.
@MainActor
public enum DocumentPrinting {

    /// Whether a print is being prepared: ⌘P pressed, the panel not up yet.
    public private(set) static var isPreparing = false

    /// Renders `job`, opens the pages in the lane, and hands `present` the print operation — or
    /// `nil` when the document could not be rendered. Returns `false`, and does nothing, while
    /// another print is still being prepared.
    ///
    /// **One at a time, settled before this returns.** The wait for the lane is the window a second
    /// ⌘P can land in, and two presses there would put up two panels. The flag is set here, on the
    /// press, rather than inside the task, because two presses in one run-loop turn would both
    /// start a task before either task ran.
    ///
    /// `present` runs the operation — `runModal(for:delegate:didRun:contextInfo:)` against the
    /// window, so the panel arrives as a sheet on the window the document is in rather than as a
    /// free-floating dialog belonging to nothing.
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
    /// **Only the parse goes to the lane.** The render is `ImageRenderer`, which is main-actor; and
    /// the operation is AppKit's, built round a view and run on the main thread, so it is built
    /// here too and the document crosses back as a ``SendableDocument``. What the operation draws
    /// while it prints is the mounted `PDFView`s' case — AppKit drawing on its own schedule — and is
    /// named on the lane rather than here.
    static func operation(for job: DocumentPDF.Job, info: NSPrintInfo) async -> NSPrintOperation? {
        // A copy: `NSPrintInfo.shared` is the app's, and a print of one document must not leave
        // its own settings behind for the next one.
        guard let settings = info.copy() as? NSPrintInfo else { return nil }
        let geometry = DocumentPDF.PageGeometry.from(settings)
        guard let data = DocumentPDF.data(for: job, geometry: geometry) else { return nil }
        guard let opened = await PDFKitSerialAccess.perform({
            PDFDocument(data: data).map(SendableDocument.init)
        }) else { return nil }
        let operation = opened.document.printOperation(for: settings, scalingMode: .pageScaleToFit,
                                                       autoRotate: false)
        // The name in the print queue and on the panel. Without it the job is called by the
        // process name, which is the app rather than the document.
        operation?.jobTitle = job.name
        return operation
    }
}
