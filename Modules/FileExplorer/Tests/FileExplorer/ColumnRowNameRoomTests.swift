import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// How much of a column row the name gets, measured in painted pixels at three row widths: spacing
/// paid around children that draw nothing (a `Spacer`'s minimum, an empty search note) shows as a
/// gap that stays constant across widths. Pixels, because nothing outside `FileRowView` can read
/// the `Text`'s frame. Tolerances allow for a truncated `Text` ending up to a glyph short of it.
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
        return PixelDiff.render(subject, size: size)
    }

    /// Painted runs along x, in points, with gaps narrower than `merge` (between glyphs and words)
    /// folded in. Empty for a bitmap that painted nothing.
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

    /// A long folder name runs to one gap short of its chevron: between the name's last run and the
    /// chevron sits only `ColumnRowView`'s 6pt plus the ellipsis slack.
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

    /// A long file name runs to one gap short of the ☁ slot every file row holds (14.5pt here,
    /// reserved so names don't shift when a cloud answer lands). The blank after the name is slot +
    /// 10pt gap + slack, about 27pt. No size is given, so the last painted run is surely the name.
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

    /// A search hit keeps its match on screen. "Individual" sits left of this name's middle, which a
    /// middle cut would remove at 240pt, leaving a hit row identical to a plain one. Cut at the tail
    /// (`FileRowView.nameTruncation`), part of the bold match survives and the rows differ.
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
        let differing = PixelDiff.differingPixels(withMatch, plain, tolerance: 0.02)
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

    /// In Tree, a long name runs to the size beside it: the same row with the detail Columns
    /// withholds. The name stops one 10pt gap short of the size, and the size keeps only its gap and
    /// the ☁ slot after it.
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

    /// Positive control: a short name leaves most of the row blank, so "the name runs to the end" is
    /// about long names, not something every render satisfies.
    @Test(.machinePinned(.pixelSampling)) func aShortNameLeavesTheRowBlank() throws {
        let node = FileNode(id: "/root/a.pdf", name: "a.pdf", isDirectory: false, fileSize: 1)
        let rep = try #require(bitmap(ColumnRowView(
            row: row(node), isIgnored: false, diffStatus: nil, containedDiffCount: 0,
            density: .comfortable, showsChevron: false), width: 284))
        let nameEnd = try #require(runs(rep, width: 284).last?.upperBound)
        #expect(284 - nameEnd > 150, "a five-letter name filled the row — the measurement proves nothing")
    }

    /// Middle truncation keeps names that share a long prefix apart. Cut at the end, these two would
    /// render identically at 284pt, losing the month; cut in the middle, the endings survive.
    @Test(.machinePinned(.pixelSampling)) func namesSharingAPrefixStayDistinguishable() throws {
        func rendered(_ name: String) throws -> NSBitmapImageRep {
            try #require(bitmap(ColumnRowView(
                row: row(FileNode(id: "/root/\(name)", name: name, isDirectory: false)),
                isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                density: .comfortable, showsChevron: false), width: 284))
        }
        let january = try rendered("Brokerage Statement - Individual Account - January 2024.pdf")
        let february = try rendered("Brokerage Statement - Individual Account - February 2024.pdf")
        let differing = PixelDiff.differingPixels(january, february, tolerance: 0.02)
        #expect(differing > 0,
                "two names that differ only near their end render identically — the end is being cut")
    }
}
