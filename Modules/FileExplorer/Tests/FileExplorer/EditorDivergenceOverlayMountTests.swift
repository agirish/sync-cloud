import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FileExplorer

/// **The overlay, actually drawn** — mounted in a real window and read back as pixels.
///
/// It exists because this surface cannot be reached by hand: it opens from a modal `NSAlert` button,
/// and driving an `NSAlert` from a script needs assistive access this machine refuses (`-25211`). So
/// "does the card come up at all" is a question only a hosted render can answer, and without one the
/// feature's entire evidence would be that its rules are right.
///
/// **What this does NOT cover, stated so nobody reads more into a green than is there: the DIFF.**
/// `.task` does not fire in a hosted `NSHostingView` under `swift test` — measured, with a probe
/// view whose `.task` set a flag that would have painted 40pt text: it painted nothing at rest and
/// nothing after 1.5 seconds of a spun main run loop, and the overlay likewise rendered
/// byte-identically before and after settling, in the refusal case as well as the ordinary one. So
/// the pane here is always its resting spinner. What produces the rows is `TextPairDiffPipeline`,
/// and `EditorDivergenceRefusalTests` drives it over real files with this overlay's own two labels;
/// this suite covers the chrome around it.
///
/// **Ink is counted as DARK PIXELS, not as inked rows.** The overlay draws a full-bleed scrim, so
/// every row of the frame carries ink before the card has drawn anything at all — the row measure
/// the pane-header suites use saturates here and reports 1240 of 1240 for a blank card. Dark pixels
/// separate them, because what is being asked is how much TEXT is on the card.
///
/// `.pixelSampling`, because it reads painted pixels out of a live renderer. CI runs this family;
/// only the reference-image suites are excluded there.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct EditorDivergenceOverlayMountTests {

    private static let width: CGFloat = 900
    private static let height: CGFloat = 620

    /// A document opened from a real file, with the file then rewritten underneath it — the exact
    /// state the alert asks about.
    private func divergedDocument() throws -> (EditorDocument, URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("divergence-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.md")
        try Data("# Notes\n\nthe line as it was\n\nand a tail\n".utf8).write(to: file)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: file.path, into: document)
        // What arrived from elsewhere, after the buffer was opened.
        try Data("# Notes\n\nthe line as THEY changed it\n\nand a tail\n".utf8).write(to: file)
        // What was typed here, which is what the left column shows.
        document.text = "# Notes\n\nthe line as I changed it\n\nand a tail\n"
        return (document, folder)
    }

    /// Hosts `view` in a real (offscreen) window and counts the dark pixels in the frame.
    private func darkPixels<V: View>(_ view: V) -> Int {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: Self.width, height: Self.height).background(Color.white)))
        host.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000,
                                                  width: Self.width, height: Self.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Read the buffer directly: `colorAt` over two million pixels takes several seconds.
        guard let bytes = rep.bitmapData, rep.bitsPerPixel == 32 || rep.bitsPerPixel == 24 else {
            return -1
        }
        let stride: Int = rep.bitsPerPixel / 8
        let rowBytes: Int = rep.bytesPerRow
        let wide: Int = rep.pixelsWide
        let high: Int = rep.pixelsHigh
        var dark = 0
        for y in 0..<high {
            let row = bytes + y * rowBytes
            for x in 0..<wide {
                let p = row + x * stride
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                if r + g + b < 270 { dark += 1 }
            }
        }
        return dark
    }

    /// **The card comes up, with words on it.**
    ///
    /// The floor is not a chosen number: an empty view through the same harness measures exactly 0
    /// dark pixels, so the positive control is inside the test rather than in a comment beside it.
    /// What is drawn at this point is the header sentence, the two column captions and the three
    /// foot buttons — everything except the rows, which cannot arrive here (see the suite note).
    @Test func theOverlayMountsAndDrawsItsChrome() throws {
        let (document, folder) = try divergedDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        let blank = darkPixels(Color.clear)
        let card = darkPixels(EditorDivergenceDiffOverlay(document: document) { _ in })
        #expect(blank == 0, "the harness reports ink on an empty view — every count below is noise")
        #expect(card > 500,
                "the card drew \(card) dark pixels — its header, columns and three buttons alone should be far more than that")
    }

    /// **A document with nothing open draws its card and does not trap.** `refresh` returns early on
    /// a nil path, which is the branch a surface opened over no document would take.
    @Test func anEmptyDocumentDoesNotTrapTheSurface() {
        let card = darkPixels(EditorDivergenceDiffOverlay(document: EditorDocument()) { _ in })
        #expect(card >= 0, "hosting the overlay with no document open failed outright")
    }
}
