import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Every card's name starts at the same x, checked in pixels: width arithmetic proves room, only
/// pixels prove paint. `fileIcon`'s explicit `.frame(width: 17, height: 17)` is all that holds the
/// column. It looks redundant (`FileTypeGlyph.view(pointSize: 14)` seems to size itself), but
/// without it glyphs that differ by a point would shift each name differently.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct DuplicateGroupColumnAlignmentTests {

    private static let size = CGSize(width: 900, height: 72)

    private func card(_ matchType: DuplicateMatchType, name: String = "Wedding Gifts.pdf",
                      isDirectory: Bool = false) -> some View {
        let group = DuplicateGroup(
            matchType: matchType,
            name: name,
            isDirectory: isDirectory,
            copies: [],
            reclaimableBytes: 71_000)
        return DuplicateGroupCard(
            group: group, isExpanded: false, providerName: "iCloud Drive", scanRoot: "/d",
            densityMetrics: ListDensity.comfortable.metrics,
            onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
            onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
            .padding(12)
    }

    private func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        offscreenBitmap(view.frame(width: Self.size.width, height: Self.size.height)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.colorScheme, .light),
                        size: Self.size, appearance: .aqua, layoutPasses: 2)
    }

    /// Same match type and name, different glyph (a folder against a document): only the icon may
    /// differ, and the name after it must land on identical pixels.
    @Test func nameStartsAtOneXWhateverTheIconIs() throws {
        let asFile = try #require(render(card(.sameText, isDirectory: false)))
        let asFolder = try #require(render(card(.sameText, isDirectory: true)))
        // Device-pixel space: colorAt indexes the backing store, which is retina-scaled.
        let device = CGFloat(asFile.pixelsWide) / Self.size.width
        // Where the name begins: the card's 12pt padding, the header's 14pt, the icon's fixed
        // 17pt frame and the stack's 12pt spacing. Spelled out because it is the arithmetic under
        // test: if `fileIcon` stops being 17pt wide, the name no longer starts here.
        let nameStart = Int(ceil((12 + 14 + 17 + 12) * device))
        let zoneWidth = Int(130 * device)   // inside "Wedding Gifts.pdf" at 14pt semibold
        // The card's hairline edges sit at the top and bottom; the claim lives in the text band.
        let yBand = Int(20 * device)..<Int((Self.size.height - 20) * device)
        var differing = 0
        for x in nameStart..<(nameStart + zoneWidth) {
            for y in yBand {
                if asFile.colorAt(x: x, y: y) != asFolder.colorAt(x: x, y: y) { differing += 1 }
            }
        }
        #expect(differing == 0,
                "the name zone differs in \(differing) pixels — the icon is not holding a fixed width, so each file type starts its name at a different x")

        // The control for the zero above: the renders must differ in the icon zone, or
        // `isDirectory` stopped reaching the glyph and the zero would be a tautology.
        let iconStart = Int(floor((12 + 14) * device))
        let iconEnd = Int(ceil((12 + 14 + 17) * device))
        var iconDiffering = 0
        for x in iconStart..<iconEnd {
            for y in yBand {
                if asFile.colorAt(x: x, y: y) != asFolder.colorAt(x: x, y: y) { iconDiffering += 1 }
            }
        }
        #expect(iconDiffering > 20,
                "the folder and document glyphs painted \(iconDiffering) differing pixels — they are not actually drawing differently, so the alignment check compares a card with itself")
    }
}
