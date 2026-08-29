import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// **Every card's name starts at the same x**, asserted in pixels — width arithmetic proves room,
/// only pixels prove paint.
///
/// What guarantees it has changed, and so has this test. It used to be the badge's fixed slot
/// absorbing the width difference between one badge and another; the badge is gone with the
/// sectioning, so the icon is now the first thing in the header and `fileIcon`'s explicit
/// `.frame(width: 17, height: 17)` is the whole of what holds the column. That frame is easy to
/// drop as redundant — `FileTypeGlyph.view(pointSize: 14)` looks like it sizes itself — and a
/// glyph vocabulary whose members differ by a point would then shift every name by a different
/// amount, which is the one thing a stack of cards must not do.
///
/// **The previous version of this test could not fail.** It rendered `card(.sameText)` against
/// `card(.sameText)` — the same card twice — while its own comment described comparing two
/// different badges, so the zone was identical by construction and the count was always zero.
/// Two genuinely different file types, whose glyphs really do differ, is what makes the
/// comparison mean anything.
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
            onChooseKeeper: { _ in }, onMerge: {}, headerLayout: .row)
            .padding(12)
    }

    private func render<V: View>(_ view: V) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: Self.size.width, height: Self.size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)))
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Same match type, same name, **different glyph** — a folder against a document. Only the
    /// icon may differ; the name after it must land on identical pixels.
    @Test func nameStartsAtOneXWhateverTheIconIs() throws {
        let asFile = try #require(render(card(.sameText, isDirectory: false)))
        let asFolder = try #require(render(card(.sameText, isDirectory: true)))
        // Device-pixel space: colorAt indexes the backing store, which is retina-scaled.
        let device = CGFloat(asFile.pixelsWide) / Self.size.width
        // Where the name begins: the card's own 12pt padding, the header's 14pt, the icon's
        // fixed 17pt frame and the header stack's 12pt spacing. Spelled out rather than measured
        // because it is precisely the arithmetic under test — if `fileIcon` stops being 17pt wide,
        // the name no longer starts here, and that is the failure.
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
    }

    /// **The positive control, and the half that makes the zero above mean something.** A zone
    /// comparison that returns zero proves nothing unless the two renders differ SOMEWHERE: if
    /// `isDirectory` had stopped reaching the glyph, both cards would be the same card and the
    /// test above would pass on a tautology — which is exactly how its predecessor passed, having
    /// rendered `.sameText` against `.sameText`.
    @Test func theTwoCardsReallyDoDrawDifferentIcons() throws {
        let asFile = try #require(render(card(.sameText, isDirectory: false)))
        let asFolder = try #require(render(card(.sameText, isDirectory: true)))
        let device = CGFloat(asFile.pixelsWide) / Self.size.width
        let iconStart = Int(floor((12 + 14) * device))
        let iconEnd = Int(ceil((12 + 14 + 17) * device))
        let yBand = Int(20 * device)..<Int((Self.size.height - 20) * device)
        var differing = 0
        for x in iconStart..<iconEnd {
            for y in yBand {
                if asFile.colorAt(x: x, y: y) != asFolder.colorAt(x: x, y: y) { differing += 1 }
            }
        }
        #expect(differing > 20,
                "the folder and document glyphs painted \(differing) differing pixels — they are not actually drawing differently, so the alignment test above compares a card with itself")
    }
}
