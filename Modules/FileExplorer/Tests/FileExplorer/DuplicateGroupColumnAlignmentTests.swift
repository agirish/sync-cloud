import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The invisible columns, asserted in pixels: with the badge in a fixed slot, everything after
/// it — icon, name — must render at the same x whatever the badge says. Two cards identical in
/// every respect except their badge are rendered and compared column-by-column across the
/// icon+name zone; if the slot ever stops absorbing the badge's width difference, those columns
/// diverge and this fails. Width arithmetic alone cannot see that (width proves room, only
/// pixels prove paint).
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct DuplicateGroupColumnAlignmentTests {

    private static let size = CGSize(width: 900, height: 72)

    private func card(_ matchType: DuplicateMatchType) -> some View {
        let group = DuplicateGroup(
            matchType: matchType,
            name: "Wedding Gifts.pdf",
            isDirectory: false,
            copies: [],
            reclaimableBytes: 71_000)
        return DuplicateGroupCard(
            group: group, isExpanded: false, providerName: "iCloud Drive", scanRoot: "/d",
            densityMetrics: ListDensity.comfortable.metrics,
            onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
            onChooseKeeper: { _ in }, onMerge: {})
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

    @Test func nameStartsAtOneXWhateverTheBadgeSays() throws {
        // Two badge-WEARING types with different badge widths ("needs review" vs "needs a
        // choice") but the same severity colour, so the wash tints both renders identically and
        // any zone difference is the slot leaking width. The identical row is deliberately not
        // in this comparison any more: it wears no badge at all (ROADMAP.md, the Identical-badge
        // item), so its name starts at the icon — a different x by design, not a leak.
        let narrow = try #require(render(card(.sameText)))
        let wide = try #require(render(card(.nameOnly)))
        // Device-pixel space: colorAt indexes the backing store, which is retina-scaled.
        let device = CGFloat(narrow.pixelsWide) / Self.size.width
        let slotEndPoints = DuplicateGroupColumns.badgeSlotWidth(scale: 1) + 12 + 14 + 12
        let slotEnd = Int(ceil(slotEndPoints * device))
        let zoneWidth = Int(180 * device)   // icon + "Wedding Gifts.pdf" — same in both renders
        // The two badge SYMBOLS differ in height by a hair, which re-centers the card by one
        // device pixel and moves its hairline edges — a card-height fact, not a column fact.
        // The claim under test lives in the inner text band, so the edges stay out of it.
        let yBand = Int(20 * device)..<Int((Self.size.height - 20) * device)
        var differing = 0
        for x in slotEnd..<(slotEnd + zoneWidth) {
            for y in yBand {
                let a = narrow.colorAt(x: x, y: y)
                let b = wide.colorAt(x: x, y: y)
                if a != b { differing += 1 }
            }
        }
        #expect(differing == 0,
                "icon+name zone differs in \(differing) pixels — the badge slot is leaking width")
    }
}
