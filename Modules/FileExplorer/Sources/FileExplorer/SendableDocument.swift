import PDFKit

/// A `PDFDocument` crossing back from `PDFKitSerialAccess` to the view that shows it.
///
/// `@unchecked` for ``SendableImage``'s reason: PDFKit's types carry no conformance, and each one
/// wrapped here is created inside the lane and handed to exactly one view. Shared by the mounted
/// `PDFView`s (`PDFPairView`, `PDFPagePreview`, Edit's `EditorPDFDocument`).
struct SendableDocument: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}
