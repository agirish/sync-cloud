import CoreGraphics
import FileExplorer
import Sync
import Foundation
import Testing
@testable import SyncCloud

/// A real PDF of `pages` blank US Letter pages named `name` in `folder`; its path.
func blankPDF(_ name: String, pages: Int, in folder: String) -> String {
    let path = (folder as NSString).appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
    for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
    return path
}

/// A blank PDF of `pages` pages written into `folder` and opened in Edit's PDF model on `defaults`,
/// waited for until it is open. The caller closes it.
@MainActor
func openBlankPDF(_ name: String, pages: Int, in folder: String,
                  defaults: UserDefaults) async throws -> EditorPDFDocument {
    let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
    pdf.open(path: blankPDF(name, pages: pages, in: folder), log: { _ in })
    await awaitPDFLane("the PDF load of \(name) never came back") { pdf.phase != .loading }
    try #require(pdf.phase == .open)
    return pdf
}

/// Waits until `done` holds while the PDF lane works, bounded in lane turns rather than seconds
/// (`docs/flaky-tests.md`, "The wait that hangs instead of failing"), and records `what` rather
/// than hanging when it never does.
@MainActor
func awaitPDFLane(_ what: Comment, sourceLocation: SourceLocation = #_sourceLocation,
                  until done: () -> Bool) async {
    for _ in 0..<1000 {
        if done() { return }
        await PDFKitSerialAccess.perform {}
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("\(what.rawValue) in 1000 lane turns", sourceLocation: sourceLocation)
}
