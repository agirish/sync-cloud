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
    /// downloaded file, so the measurement is the blank after the name: slot + 10pt gap + slack —
    /// about 27pt.
    ///
    /// **With no size to draw**, so the last painted run is the name on the old layout as well as
    /// this one. Given a size, the old row painted it last, 34.5pt from the edge — inside a looser
    /// bound — and this passed against the very spacing it exists to catch; the name itself sat
    /// ~52pt short.
    @Test(.machinePinned(.pixelSampling)) func aLongFileNameRunsToTheCloudSlot() throws {
        let node = FileNode(id: "/root/\(longFile)", name: longFile, isDirectory: false)
        for width in Self.widths {
            let rep = try #require(bitmap(ColumnRowView(
                row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: false), width: width))
            let nameEnd = try #require(runs(rep, width: width).last?.upperBound)
            let blank = Double(width) - nameEnd
            #expect(blank <= 32, "at \(width)pt a file name leaves \(blank)pt blank after it")
        }
    }

    /// **A search hit keeps its match on screen.** "Individual" sits left of the middle of this
    /// name, which is exactly what a middle cut removes: at 240pt the hit row drew the same pixels as
    /// the same name with no match — the emboldened run cut away, the row a hit with nothing to show
    /// for it. Cut at the tail instead (`FileRowView.nameTruncation`), part of the match survives,
    /// bold, and the two rows differ.
    @Test(.machinePinned(.pixelSampling)) func aSearchHitKeepsItsMatchOnScreen() throws {
        let node = FileNode(id: "/root/\(longFile)", name: longFile, isDirectory: false)
        let start = try #require(longFile.range(of: "Individual"))
        let lower = longFile.distance(from: longFile.startIndex, to: start.lowerBound)
        var hit = PaneSearchRowContext.none
        hit.match = lower..<(lower + "Individual".count)
        func rendered(_ context: PaneSearchRowContext) throws -> NSBitmapImageRep {
            try #require(bitmap(ColumnRowView(
                row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: false, searchContext: context), width: 240))
        }
        let withMatch = try rendered(hit), plain = try rendered(.none)
        var differing = 0
        for y in 0..<min(withMatch.pixelsHigh, plain.pixelsHigh) {
            for x in 0..<min(withMatch.pixelsWide, plain.pixelsWide) {
                guard let a = withMatch.colorAt(x: x, y: y), let b = plain.colorAt(x: x, y: y) else { continue }
                if max(abs(a.redComponent - b.redComponent),
                       max(abs(a.greenComponent - b.greenComponent),
                           abs(a.blueComponent - b.blueComponent))) > 0.02 { differing += 1 }
            }
        }
        #expect(differing > 0, "the hit row painted exactly what the plain row did — its match was cut away")
    }

    /// Where a name is cut: in the middle, except on a hit, which is cut at the end away from its
    /// match — the tail for a match in the first half, the head for one in the second.
    @Test func aHitIsCutAwayFromItsMatch() {
        let name = String(repeating: "x", count: 60)
        #expect(FileRowView.nameTruncation(match: nil, in: name) == .middle)
        #expect(FileRowView.nameTruncation(match: 0..<5, in: name) == .tail)
        #expect(FileRowView.nameTruncation(match: 22..<32, in: name) == .tail)
        #expect(FileRowView.nameTruncation(match: 50..<58, in: name) == .head)
        #expect(FileRowView.nameTruncation(match: 28..<34, in: name) == .head)
        #expect(FileRowView.nameTruncation(match: 0..<1, in: "") == .middle)
    }

    /// **In Tree, a long name runs to the size beside it.** The same zero-spaced row, with the
    /// trailing detail Columns withholds: the name stops one 10pt gap short of the file's size, and
    /// the size keeps only its gap and the ☁ slot after it. They were 28pt and 20pt while the row was
    /// spaced 10pt around children that draw nothing — the Tree gained the name room too.
    @Test(.machinePinned(.pixelSampling)) func aLongTreeNameRunsToItsSize() throws {
        let node = FileNode(id: "/root/\(longFile)", name: longFile, isDirectory: false, fileSize: 96_256)
        for width in [300, 360, 420] as [CGFloat] {
            let rep = try #require(bitmap(FileRowView(node: FileRowInfo(node), isIgnored: false, diffStatus: nil,
                                                      containedDiffCount: 0, density: .comfortable), width: width))
            let r = runs(rep, width: width)
            try #require(r.count >= 3, "expected icon, name and size runs at \(width)pt, got \(r)")
            let size = r[r.count - 1], nameEnd = r[r.count - 2].upperBound
            #expect(size.lowerBound - nameEnd <= 16,
                    "at \(width)pt the name stops \(size.lowerBound - nameEnd)pt short of its size")
            #expect(Double(width) - size.upperBound <= 28,
                    "at \(width)pt the size sits \(Double(width) - size.upperBound)pt from the row's end")
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
