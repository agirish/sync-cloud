// Prints what a CI host's environment answers for the things machine-pinned tests depend on:
// screens, print paper, the rich-text route's pagination, Vision text recognition and iCloud
// Drive. Run by .github/workflows/hosted-probe.yml on GitHub's hosted macOS runners, to tell a
// test's environment dependency from a defect before marking it. `swift scripts/hosted-environment.swift`.
import AppKit
import Vision

for screen in NSScreen.screens {
    print("screen \(screen.frame) visible \(screen.visibleFrame) scale \(screen.backingScaleFactor)")
}
if NSScreen.screens.isEmpty { print("screen none") }
let info = NSPrintInfo.shared
print("paper \(info.paperName?.rawValue ?? "nil") \(info.paperSize) printer \(info.printer.name) "
      + "margins \(info.topMargin) \(info.leftMargin) \(info.bottomMargin) \(info.rightMargin)")
print("printers \(NSPrinter.printerNames)")
// Save as PDF's rich-text route prints through a fresh NSPrintInfo (SaveAsPDFRender.printInfo);
// DocumentPDF.PageGeometry.from already falls back when this box is empty with no printer.
let fresh = NSPrintInfo()
print("fresh NSPrintInfo imageable \(fresh.imageablePageBounds) paper \(fresh.paperSize)")

// The rich-text route itself, on the Memo.rtf fixture: the view's frame, the paper the print
// operation ends up with, AppKit's page breaks and the page count (SaveAsPDFRenderTests.richTextIsText).
final class PagingProbe: NSTextView {
    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat,
                                      bottom oldBottom: CGFloat, limit bottomLimit: CGFloat) {
        super.adjustPageHeightNew(newBottom, top: oldTop, bottom: oldBottom, limit: bottomLimit)
        print("rtf page break top \(oldTop) bottom \(oldBottom) -> \(newBottom.pointee)")
    }
    override func beginDocument() {
        let i = NSPrintOperation.current!.printInfo
        print("rtf operation paper \(i.paperName?.rawValue ?? "nil") \(i.paperSize) margins \(i.topMargin) "
              + "\(i.leftMargin) \(i.bottomMargin) \(i.rightMargin) imageable \(i.imageablePageBounds)")
        super.beginDocument()
    }
}
let memo = URL(fileURLWithPath: "Modules/FileExplorer/Tests/FileExplorer/Fixtures/SaveAsPDF/Memo.rtf")
if let text = try? NSAttributedString(url: memo, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil) {
    let view = PagingProbe(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainer?.widthTracksTextView = true
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(text)
    view.sizeToFit()
    print("rtf view frame \(view.frame)")
    let paging = NSPrintInfo()
    paging.paperSize = CGSize(width: 612, height: 792)
    paging.orientation = .portrait
    (paging.topMargin, paging.leftMargin, paging.bottomMargin, paging.rightMargin) = (36, 36, 36, 36)
    paging.horizontalPagination = .clip
    paging.verticalPagination = .automatic
    print("rtf set paper \(paging.paperName?.rawValue ?? "nil") \(paging.paperSize)")
    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "hosted-environment-\(UUID().uuidString).pdf")
    paging.jobDisposition = .save
    paging.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
    let operation = NSPrintOperation(view: view, printInfo: paging)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    let ran = operation.run()
    print("rtf ran \(ran) pages \(CGPDFDocument(file as CFURL)?.numberOfPages ?? -1)")
} else {
    print("rtf fixture unreadable at \(memo.path)")
}

let size = NSSize(width: 800, height: 140)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()
("Harvest moon festival" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [
    .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
image.unlockFocus()
if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    do {
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        print("vision recognised \(words)")
    } catch {
        print("vision error \(error)")
    }
}
let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
print("iCloud Drive \(FileManager.default.fileExists(atPath: drive) ? "present" : "absent") at \(drive)")
