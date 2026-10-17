import PDFKit

/// A `PDFDocument` crossing back from `PDFKitSerialAccess` to the view that shows it.
///
/// `@unchecked` for the same reason ``SendableImage`` is: PDFKit's types carry no conformance, and
/// every one wrapped here is created inside the lane and handed to exactly one view. Shared by the
/// mounted `PDFView`s — `PDFPairView`, `PDFPagePreview` and Edit's `EditorPDFDocument` — rather than
/// copied into each.
struct SendableDocument: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}
