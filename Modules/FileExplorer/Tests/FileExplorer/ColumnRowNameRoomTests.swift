import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// How much of a column row the NAME gets — measured in painted pixels, at three row widths.
///
/// A truncated name used to stop 39.5–50pt short of the next thing painted on its row, at every
/// width from 200pt to 284pt: the row was a 10pt-spaced HStack, and it paid that spacing around two
/// children that draw nothing (a `Spacer`'s 8pt minimum and an empty search note on every row). A
/// width that is constant across row widths is spacing, not layout — and spacing is exactly what a
/// later edit reintroduces without noticing, which is why it is pinned here rather than trusted.
///
/// **Painted pixels, not geometry.** The name is a `Text` inside a hosted row; nothing outside
/// `FileRowView` can read its frame, and the frame is not the claim anyway — the claim is where the
/// glyphs stop. The runs are the same measurement that found the gap.
///
/// Tolerances carry the one thing that is not layout: a truncated `Text` ends up to one glyph short
/// of its frame, because the ellipsis lands on a character boundary (1.5–12pt measured with the old
/// tail truncation; middle truncation keeps it under a glyph).
@MainActor
@Suite(.serialized) struct ColumnRowNameRoomTests {
    private static let height: CGFloat = 26
    private static let widths: [CGFloat] = [200, 240, 284]

    private let longFolder = "Creative Cloud Files - Personal Account Archive"
    private let longFile = "Brokerage Statement - Individual Account - January 2024.pdf"

    private func row(_ node: FileNode) -> PaneRow {
        PaneRow(side: .left, version: 0, node: node, children: nil)
    }

    private func bitmap<V: View>(_ view: V, width: CGFloat) -> NSBitmapImageRep? {
        let size = CGSize(width: width, height: Self.height)
        let subject = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Painted runs along x, in POINTS, with gaps narrower than `merge` folded in (the space
    /// between glyphs and words). Empty for a bitmap that painted nothing.
    private func runs(_ rep: NSBitmapImageRep, width: CGFloat, merge: Double = 3.5) -> [ClosedRange<Double>] {
        let scale = Double(rep.pixelsWide) / Double(width)
        guard let ground = rep.colorAt(x: 1, y: 1) else { return [] }
        var painted = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let d = max(abs(c.redComponent - ground.redComponent),
                            max(abs(c.greenComponent - ground.greenComponent),
                                abs(c.blueComponent - ground.blueComponent)))
                if d > 0.02 { painted[x] = true; break }
            }
        }
        var out: [ClosedRange<Double>] = []
        var start: Int?
        var last = -1
        for x in painted.indices where painted[x] {
            if let s = start, Double(x - last) / scale > merge {
                out.append(Double(s) / scale...Double(last + 1) / scale)
                start = x
            } else if start == nil { start = x }
            last = x
        }
        if let s = start { out.append(Double(s) / scale...Double(last + 1) / scale) }
        return out
    }

    /// A long folder name runs to one gap short of its chevron: the chevron is the last run, the
    /// name ends in the run before it, and between them sits only `ColumnRowView`'s 6pt plus the
    /// ellipsis slack. It was 43pt here, from 200pt to 284pt.
    @Test(.machinePinned(.pixelSampling)) func aLongFolderNameRunsToItsChevron() throws {
        let node = FileNode(id: "/root/\(longFolder)", name: longFolder, isDirectory: true)
        for width in Self.widths {
            let rep = try #require(bitmap(ColumnRowView(
                row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: true), width: width))
            let r = runs(rep, width: width)
            try #require(r.count >= 3, "expected icon, name and chevron runs at \(width)pt, got \(r)")
            let chevron = r[r.count - 1], nameEnd = r[r.count - 2].upperBound
            let gap = chevron.lowerBound - nameEnd
            #expect(gap <= 16, "at \(width)pt the name stops \(gap)pt short of its chevron — spacing is back")
        }
    }

    /// A long file name runs to one gap short of the ☁ slot every file row holds (14.5pt at this
    /// text size, reserved so names do not shift when a cloud answer lands). Nothing trails a
    /// downloaded file, so the measurement is the blank after the name: slot + 10pt gap + slack.
    /// It was 102pt at 284 while the size was drawn.
    @Test(.machinePinned(.pixelSampling)) func aLongFileNameRunsToTheCloudSlot() throws {
        let node = FileNode(id: "/root/\(longFile)", name: longFile, isDirectory: false, fileSize: 96_256)
        for width in Self.widths {
            let rep = try #require(bitmap(ColumnRowView(
                row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: false), width: width))
            let nameEnd = try #require(runs(rep, width: width).last?.upperBound)
            let blank = Double(width) - nameEnd
            #expect(blank <= 36, "at \(width)pt a file name leaves \(blank)pt blank after it")
        }
    }

    /// The positive control for both: a SHORT name leaves most of the row blank, so "the name runs
    /// to the end" is a statement about long names and not something every render satisfies.
    @Test(.machinePinned(.pixelSampling)) func aShortNameLeavesTheRowBlank() throws {
        let node = FileNode(id: "/root/a.pdf", name: "a.pdf", isDirectory: false, fileSize: 1)
        let rep = try #require(bitmap(ColumnRowView(
            row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, showsChevron: false), width: 284))
        let nameEnd = try #require(runs(rep, width: 284).last?.upperBound)
        #expect(284 - nameEnd > 150, "a five-letter name filled the row — the measurement proves nothing")
    }

    /// **Middle truncation keeps names that share a long prefix apart.** Cut at the end, these two
    /// render identically in a 284pt row — the month, the one thing that differs, is what goes —
    /// which is a column of look-alike rows. Cut in the middle, the endings survive and differ.
    @Test(.machinePinned(.pixelSampling)) func namesSharingAPrefixStayDistinguishable() throws {
        func rendered(_ name: String) throws -> NSBitmapImageRep {
            try #require(bitmap(ColumnRowView(
                row: row(FileNode(id: "/root/\(name)", name: name, isDirectory: false)),
                isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: false), width: 284))
        }
        let january = try rendered("Brokerage Statement - Individual Account - January 2024.pdf")
        let february = try rendered("Brokerage Statement - Individual Account - February 2024.pdf")
        var differing = 0
        for y in 0..<min(january.pixelsHigh, february.pixelsHigh) {
            for x in 0..<min(january.pixelsWide, february.pixelsWide) {
                guard let a = january.colorAt(x: x, y: y), let b = february.colorAt(x: x, y: y) else { continue }
                if max(abs(a.redComponent - b.redComponent),
                       max(abs(a.greenComponent - b.greenComponent),
                           abs(a.blueComponent - b.blueComponent))) > 0.02 { differing += 1 }
            }
        }
        #expect(differing > 0,
                "two names that differ only near their end render identically — the end is being cut")
    }
}
