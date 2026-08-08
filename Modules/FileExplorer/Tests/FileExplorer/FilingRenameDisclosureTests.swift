import AppKit
import Design
import Foundation
import Sync
import SwiftUI
import Testing
@testable import FileExplorer

/// **The card must SAY that filing also renames.**
///
/// This suite exists because the first cut of the rename-on-the-way-in path shipped without it:
/// `FilingDestination.proposedName` was computed by the scan, honoured by the apply path, and
/// rendered by nothing at all — so "File here" moved *and renamed* the file with the card showing
/// only the move. Every unit test passed, because they all asked the model.
///
/// So this asks the pixels. `FilingLensTests` covers what the card decides; this covers that the
/// decision reaches the screen.
@Suite(.serialized, .machinePinned(.pixelSampling)) struct FilingRenameDisclosureTests {

    private static let canvas = CGSize(width: 520, height: 200)

    private static func suggestion(renamedTo proposed: String?) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/root/Inbox/DetailedBillApr2025.pdf", fileName: "DetailedBillApr2025.pdf",
            size: 4096, modificationDate: nil,
            candidates: [FilingDestination(path: "/root/Home/Utilities/PGE/2025",
                                           confidence: .high, reasons: ["matches PGE"],
                                           newSegments: [], proposedName: proposed)],
            providerRoot: "/root")
    }

    @MainActor
    private func mount(_ suggestion: FilingSuggestion) -> NSHostingView<AnyView> {
        let subject = FilingSuggestionCard(
            suggestion: suggestion, densityMetrics: ListDensity.comfortable.metrics,
            onFileHere: { _ in }, onChooseFolder: {}, onReveal: {}, onNotHere: {})
            .frame(width: Self.canvas.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Pixels differing from the window background, measured as delta-from-a-corner rather than by
    /// brightness — the repo's usual `brightness < 0.90` filter is blind to pale secondary text,
    /// which is exactly what this row is drawn in.
    @MainActor
    private func ink(_ host: NSHostingView<AnyView>) -> Int {
        host.layoutSubtreeIfNeeded()
        let band = CGRect(origin: .zero, size: Self.canvas)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return 0 }
        host.cacheDisplay(in: band, to: rep)
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    @Test("A card whose filing also renames paints the new name")
    func theRenameIsDisclosed() {
        let silent = ink(mount(Self.suggestion(renamedTo: nil)))
        let disclosed = ink(mount(Self.suggestion(renamedTo: "04. Apr 2025.pdf")))
        #expect(disclosed > silent, "the rename must reach the screen, not just the model")
        // A whole line of text, not a stray pixel of relayout.
        #expect(disclosed - silent > 150, "gained only \(disclosed - silent) inked pixels")
    }

    @MainActor
    @Test("A card that renames nothing says nothing")
    func noRenameNoRow() {
        // The other direction, and what makes the test above mean something: two mounts of the
        // no-rename card must be pixel-identical, so the difference measured there is the row.
        let a = ink(mount(Self.suggestion(renamedTo: nil)))
        let b = ink(mount(Self.suggestion(renamedTo: nil)))
        #expect(a == b)
    }
}
