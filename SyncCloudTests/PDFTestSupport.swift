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
    for _ in 0..<1000 where pdf.phase == .loading {
        await PDFKitSerialAccess.perform {}
        try? await Task.sleep(for: .milliseconds(5))
    }
    try #require(pdf.phase == .open)
    return pdf
}
