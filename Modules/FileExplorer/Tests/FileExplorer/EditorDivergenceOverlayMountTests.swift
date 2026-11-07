import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FileExplorer

/// The overlay, actually drawn: mounted in a real window and read back as pixels. It opens from a
/// modal `NSAlert` button, which a script can't drive without assistive access, so a hosted render
/// is the only check that the card comes up at all.
///
/// It does not cover the diff: `.task` doesn't fire in a hosted `NSHostingView` under `swift test`,
/// so the pane is always its resting spinner. `EditorDivergenceRefusalTests` drives
/// `TextPairDiffPipeline` with this overlay's labels; this suite covers the chrome around it.
///
/// Ink is counted as dark pixels, not inked rows: the full-bleed scrim inks every row before the
/// card draws anything. The ink count is `.pixelSampling` because it reads a live renderer's
/// pixels; the empty-document check reads no pixel value, so it runs everywhere.
@MainActor
@Suite(.serialized) struct EditorDivergenceOverlayMountTests {

    private static let width: CGFloat = 900
    private static let height: CGFloat = 620

    /// A document opened from a real file, with the file then rewritten underneath it: the state
    /// the alert asks about.
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

    /// The card comes up, with words on it: the header sentence, two column captions and three foot
    /// buttons (the rows can't arrive here). An empty view through the same harness measures 0 dark
    /// pixels, which is the positive control.
    @Test(.machinePinned(.pixelSampling)) func theOverlayMountsAndDrawsItsChrome() throws {
        let (document, folder) = try divergedDocument()
        defer { try? FileManager.default.removeItem(at: folder) }

        let blank = darkPixels(Color.clear)
        let card = darkPixels(EditorDivergenceDiffOverlay(document: document) { _ in })
        #expect(blank == 0, "the harness reports ink on an empty view — every count below is noise")
        #expect(card > 500,
                "the card drew \(card) dark pixels — its header, columns and three buttons alone should be far more than that")
    }

    /// A document with nothing open draws its card and doesn't trap: `refresh` returns early on a
    /// nil path, the branch a surface opened over no document takes.
    @Test func anEmptyDocumentDoesNotTrapTheSurface() {
        let card = darkPixels(EditorDivergenceDiffOverlay(document: EditorDocument()) { _ in })
        #expect(card >= 0, "hosting the overlay with no document open failed outright")
    }
}
