import Testing
import SwiftUI
import AppKit
import Sync
import Design
@testable import FileExplorer

/// **The Storage section header, rendered.**
///
/// Nothing mounted `StorageLensView` at all, so the header's two shapes — a fold control on the
/// All page, a plain row on a page the rail has narrowed — were only ever source-scanned. A scan
/// can say `if canCollapse` is present; it cannot say the row still fills its width, or that the
/// chevron is really gone, which is exactly what changed when the header stopped being a button.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct StorageSectionHeaderRenderTests {

    static let canvas = CGSize(width: 620, height: 420)

    static func report() -> StorageLensReport {
        let entries = (1...4).map {
            StorageEntry(path: "/root/Files/file\($0).mov", name: "file\($0).mov",
                         bytes: 900_000_000 / $0,
                         modified: Date(timeIntervalSince1970: 1_600_000_000))
        }
        return StorageLensReport(treemap: [TreemapNode(name: "Files", path: "Files", bytes: 2_000_000_000)],
                                 largest: entries, stale: entries, reclaimCandidates: entries,
                                 totalBytes: 2_400_000_000)
    }

    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(host: NSHostingView<AnyView>, window: NSWindow) { self.host = host; self.window = window }
    }

    /// The window background is not decoration: without one the content composites against the
    /// borderless window's own buffer and every comparison reads as zero difference.
    private func mount(section: StorageSection?) -> Mounted {
        let manager = FileSyncManager()
        manager.storageLensReport = Self.report()
        let subject = StorageLensView(syncManager: manager, providerName: "Projects",
                                      onBuild: {}, onReveal: { _ in }, section: section)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
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
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
    }

    private func bitmap(_ m: Mounted, _ band: CGRect) -> NSBitmapImageRep? {
        m.host.layoutSubtreeIfNeeded()
        guard let rep = m.host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        m.host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels that differ from the window background — "something is painted here".
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        let background = rep.colorAt(x: 1, y: 1)
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - (background?.redComponent ?? 1)) > 0.06
                    || abs(c.greenComponent - (background?.greenComponent ?? 1)) > 0.06
                    || abs(c.blueComponent - (background?.blueComponent ?? 1)) > 0.06 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The section header's own band, found by the row where its **tint** is painted.
    ///
    /// **Located by the icon's colour, not by "the first painted row".** The two pages do not put
    /// the header in the same place (the All page has a treemap card above it), and the first
    /// painted row on either is the lens header card, not this. Two earlier versions of this test
    /// were wrong in both directions because of that: one compared full-height strips between the
    /// pages and passed with the chevron drawn unconditionally, the next measured the wrong band
    /// and failed on correct code. `StorageSection.tint` is unique to this row.
    private func headerBand(_ m: Mounted, tint: NSColor) throws -> CGRect {
        let full = try #require(bitmap(m, CGRect(origin: .zero, size: Self.canvas)))
        let scale = max(full.pixelsHigh / Int(Self.canvas.height), 1)
        for row in 0..<full.pixelsHigh {
            var hits = 0
            for x in stride(from: 0, to: min(full.pixelsWide, 80), by: 1) {
                guard let c = full.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - tint.redComponent) < 0.14,
                   abs(c.greenComponent - tint.greenComponent) < 0.14,
                   abs(c.blueComponent - tint.blueComponent) < 0.14 { hits += 1 }
            }
            if hits >= 3 {
                let mid = CGFloat(row / scale)
                return CGRect(x: 0, y: max(0, mid - 12), width: Self.canvas.width, height: 26)
            }
        }
        Issue.record("the section tint was never painted — the header did not render")
        return .zero
    }

    private func isInk(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y), let bg = rep.colorAt(x: 1, y: 1) else { return false }
        return abs(c.redComponent - bg.redComponent) > 0.06
            || abs(c.greenComponent - bg.greenComponent) > 0.06
            || abs(c.blueComponent - bg.blueComponent) > 0.06
    }

    /// **The All page keeps its chevron; a narrowed page has none.** The fold does not apply there,
    /// and a control that cannot act must not offer to.
    @Test func theChevronIsDrawnOnlyWhereTheFoldApplies() throws {
        let tint = try #require(NSColor(SemanticColor.info).usingColorSpace(.sRGB))
        for (section, expectsChevron) in [(StorageSection?.none, true), (.largest, false)] {
            let m = mount(section: section)
            // `.largest` is the section whose tint we locate, and it is present on both pages.
            let band = try headerBand(m, tint: tint)
            let trailing = CGRect(x: Self.canvas.width - 46, y: band.minY, width: 42, height: band.height)
            let leading = CGRect(x: 0, y: band.minY, width: 140, height: band.height)

            let leadingInk = inked(try #require(bitmap(m, leading)))
            let trailingInk = inked(try #require(bitmap(m, trailing)))
            // Non-vacuity: the band really is the header — its icon and title are painted.
            #expect(leadingInk > 0,
                    "no header content at the leading edge for \(String(describing: section))")

            if expectsChevron {
                #expect(trailingInk > 0, "the All page lost its fold chevron")
            } else {
                #expect(trailingInk == 0,
                        "a narrowed page still paints \(trailingInk) chevron pixels for a fold it cannot perform")
            }
        }
    }

    /// And the row still spans the width. The header lost an explicit `maxWidth: .infinity` when it
    /// was extracted; the trailing `Spacer` is what actually claims the row, and if that stopped
    /// being true the title would drift toward the centre.
    @Test func theHeaderRowStillStartsAtTheLeadingEdge() throws {
        let tint = try #require(NSColor(SemanticColor.info).usingColorSpace(.sRGB))
        for section in [StorageSection?.none, .largest] {
            let m = mount(section: section)
            let band = try headerBand(m, tint: tint)
            let leading = try #require(bitmap(m, CGRect(x: 0, y: band.minY, width: 60, height: band.height)))
            #expect(inked(leading) > 0,
                    "nothing painted at the leading edge for section \(String(describing: section))")
        }
    }
}
