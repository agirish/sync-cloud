import AppKit
import Design
import Foundation
import Sync
import SwiftUI
import Testing
@testable import FileExplorer

/// The card must say that filing also renames: `FilingDestination.proposedName` is honoured by the
/// apply path, so a card that didn't render it would let "File here" rename the file while showing
/// only the move. Pixels, because every model-level test would still pass.
@Suite(.serialized, .machinePinned(.pixelSampling)) struct FilingRenameDisclosureTests {

    private static let canvas = CGSize(width: 520, height: 320)

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
            onFileHere: { _ in }, onChooseFolder: {}, onNotHere: {})
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
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
    /// brightness: the repo's usual `brightness < 0.90` filter is blind to pale secondary text,
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
        // The file's row says the name it takes: a longer one paints a longer line. A card that
        // didn't draw it would paint the two alike.
        let short = ink(mount(Self.suggestion(renamedTo: "Apr.pdf")))
        let long = ink(mount(Self.suggestion(renamedTo: "04. Apr 2025 PG&E Detailed Bill.pdf")))
        #expect(long - short > 150, "the longer new name gained only \(long - short) inked pixels")
        // Two mounts of one card are pixel-identical, so the difference above is the name.
        #expect(ink(mount(Self.suggestion(renamedTo: "Apr.pdf"))) == short)
    }
}
