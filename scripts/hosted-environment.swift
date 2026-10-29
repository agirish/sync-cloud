// Prints what a CI host's environment answers for the things machine-pinned tests depend on:
// screens, print paper, Vision text recognition and iCloud Drive. Run by .github/workflows/
// hosted-probe.yml on GitHub's hosted macOS runners, to tell a test's environment dependency from
// a defect before marking it. `swift scripts/hosted-environment.swift`.
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
