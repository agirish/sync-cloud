import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The row's trailing detail (a folder's date, a file's size) and which presentation carries it:
/// Columns withholds both, the tree keeps both. Measured in pixels, since the detail sits behind a
/// `Spacer` and a row is equally wide with or without it. The tree cases of
/// `eachPresentationPaintsOrWithholdsTheDetail` and `aRowWithoutAChevronDoesNotReachTheEdge` are
/// positive controls, so a harness that paints nothing can't pass the zero-difference checks.
///
/// Known boundary: these build `ColumnRowView` directly, so they don't pin that
/// `PaneColumnsView.columnRow` still uses it (`FileRowAccessoryStabilityTests` draws the same line).
@MainActor
@Suite struct ColumnRowDateTests {

    /// Wide enough that the name, a medium-style date and the chevron fit without truncation, so a
    /// difference can only be a missing date.
    private static let canvas = CGSize(width: 260, height: 24)

    /// A fixed instant, so the formatted string cannot vary with the day the suite runs.
    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// The tree's date is medium style with no time; "not nil" can't see a formatter that gained a
    /// time or dropped to `.short`. Built independently of the app's formatter: the string is
    /// locale- and timezone-dependent, so a literal would pin the suite to one Mac.
    private static let reference: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func folder(dated: Bool) -> FileNode {
        FileNode(id: "/root/Birth Certificate", name: "Birth Certificate", isDirectory: true,
                 modificationDate: dated ? Self.stamp : nil)
    }

    private func file(sized: Bool) -> FileNode {
        FileNode(id: "/root/notes.md", name: "notes.md", isDirectory: false,
                 fileSize: sized ? 1024 : nil)
    }

    private func row(_ node: FileNode) -> PaneRow {
        PaneRow(side: .left, version: 0, node: node, children: nil)
    }

    /// Renders a row and returns its bitmap. The window background matters: without it the row
    /// composites against a borderless window's buffer and every comparison reads zero, making the
    /// zero-difference claims vacuous.
    private func bitmap<V: View>(_ view: V, width: CGFloat? = nil) -> NSBitmapImageRep? {
        let size = CGSize(width: width ?? Self.canvas.width, height: Self.canvas.height)
        let subject = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        return PixelDiff.render(subject, size: size)
    }

    /// The rightmost pixel column holding anything other than the window background, or nil for a
    /// bitmap that painted nothing, which `#require` turns into a failure.
    private func rightmostPaintedColumn(_ rep: NSBitmapImageRep) -> Int? {
        guard let ground = rep.colorAt(x: 1, y: 1) else { return nil }
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - ground.redComponent),
                                max(abs(c.greenComponent - ground.greenComponent),
                                    abs(c.blueComponent - ground.blueComponent)))
                if delta > 0.02 { return x }
            }
        }
        return nil
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        PixelDiff.differingPixels(lhs, rhs, tolerance: 0.02)
    }

    // MARK: - The rule

    /// All four cases of `secondaryText`, the one place that picks a date or a size. The tree's
    /// answers are checked by kind (a date for the folder, the size for the file), so they can't
    /// swap while "not nil" stays true.
    @Test func theRuleWithholdsBothDetailsInColumnsAndNeitherInTheTree() {
        let datedFolder = FileRowInfo(folder(dated: true))
        let sizedFile = FileRowInfo(file(sized: true))

        #expect(FileRowView.secondaryText(for: datedFolder, showsSecondaryText: false) == nil,
                "Columns must not ask for a folder's date")
        #expect(FileRowView.secondaryText(for: sizedFile, showsSecondaryText: false) == nil,
                "Columns must not ask for a file's size")
        #expect(FileRowView.secondaryText(for: datedFolder, showsSecondaryText: true)
                    == Self.reference.string(from: Self.stamp),
                "The tree must still ask for the date — the flag is not a global removal")
        #expect(FileRowView.secondaryText(for: sizedFile, showsSecondaryText: true) == "1 KB",
                "The tree must still ask for the size")
    }

    /// A folder the scan never dated is nil under either setting.
    @Test func anUndatedFolderIsNilUnderEitherSetting() {
        let undated = FileRowInfo(folder(dated: false))
        #expect(FileRowView.secondaryText(for: undated, showsSecondaryText: true) == nil)
        #expect(FileRowView.secondaryText(for: undated, showsSecondaryText: false) == nil)
    }

    // MARK: - The call sites

    /// What withholding the date buys the name: the date ("Nov 14, 2023", `caption` with
    /// monospaced digits) plus its 10pt gap costs the name about 76pt, enough to truncate "Vehicle
    /// Registration Card" at the 210pt `PaneViewMode.defaultColumnWidth`.
    ///
    /// Asserted as a shape, not a pixel count: at 260pt only the date's region differs, and at
    /// 210pt the name's region differs too. Totals would pass if the date merely widened; exact
    /// counts would break on a font revision.
    @Test(.machinePinned(.pixelSampling)) func theFoldersDateCostsA210ptColumnItsName() throws {
        let name = "Vehicle Registration Card"
        func info(_ dated: Bool) -> FileRowInfo {
            FileRowInfo(FileNode(id: "/root/\(name)", name: name, isDirectory: true,
                                 modificationDate: dated ? Self.stamp : nil))
        }
        func rendered(_ dated: Bool, width: CGFloat) throws -> NSBitmapImageRep {
            try #require(bitmap(FileRowView(node: info(dated), isIgnored: false, diffStatus: nil,
                                            containedDiffCount: 0, density: .comfortable),
                                width: width))
        }
        /// Differing pixels strictly left of `x`, i.e. in the name's half of the row.
        func nameRegionDiff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, before x: Int) -> Int {
            PixelDiff.differingPixels(a, b, tolerance: 0.02, beforeX: x)
        }

        // The string this rests on, so a formatter change cannot quietly move the measurement.
        #expect(FileRowView.secondaryText(for: info(true), showsSecondaryText: true)
                    == Self.reference.string(from: Self.stamp))

        // Roomy: the date is drawn, and it is the only thing that changes.
        let wideDated = try rendered(true, width: 260)
        let wideUndated = try rendered(false, width: 260)
        #expect(pixelsDiffering(wideDated, wideUndated) > 0, "the date must actually be painted at 260pt")
        #expect(nameRegionDiff(wideDated, wideUndated, before: 150) == 0,
                "at 260pt the name has room either way, so its glyphs must be identical")

        // At the real column width, the name itself has to re-render — that is the truncation.
        let tightDated = try rendered(true, width: 210)
        let tightUndated = try rendered(false, width: 210)
        #expect(nameRegionDiff(tightDated, tightUndated, before: 150) > 0,
                """
                At the 210pt default column width the folder date no longer costs the name \
                anything — either the date stopped being drawn, or the name stopped truncating. \
                The date costs about 76pt, which truncates "Vehicle Registration Card" here.
                """)
    }

    /// Which presentation paints the detail: the tree row paints a folder's date and a file's
    /// size, and the Columns row paints neither, identically to a row without one. The tree cases
    /// are the positive controls, and pin the default: `FileTreeView.treeRow` passes no
    /// `showsSecondaryText`, so a default of false would strip dates from both tree panes and the
    /// Organize rail.
    @Test(.machinePinned(.pixelSampling), arguments: [
        (true, false, true),    // a folder's date, tree row: painted
        (true, true, false),    // a folder's date, Columns row: not painted
        (false, true, false),   // a file's size, Columns row: not painted
        (false, false, true),   // a file's size, tree row: painted
    ])
    func eachPresentationPaintsOrWithholdsTheDetail(isFolder: Bool, inColumns: Bool,
                                                     paints: Bool) throws {
        func rendered(_ withDetail: Bool) throws -> NSBitmapImageRep {
            let node = isFolder ? folder(dated: withDetail) : file(sized: withDetail)
            if inColumns {
                return try #require(bitmap(ColumnRowView(
                    row: row(node), isIgnored: false, diffStatus: nil,
                    containedDiffCount: 0, density: .comfortable, showsChevron: isFolder)))
            }
            return try #require(bitmap(FileRowView(
                node: FileRowInfo(node), isIgnored: false, diffStatus: nil,
                containedDiffCount: 0, density: .comfortable)))
        }
        let differing = pixelsDiffering(try rendered(true), try rendered(false))
        let detail = isFolder ? "folder date" : "file size"
        if paints {
            #expect(differing > 0,
                    "The tree row stopped drawing the \(detail) — the Columns change was not supposed to reach it")
        } else {
            #expect(differing == 0,
                    "ColumnRowView is painting the \(detail) — it must pass showsSecondaryText: false")
        }
    }

    /// The chevron reaches the row's trailing edge. It is flush by construction: `FileRowView` ends
    /// in a `Spacer` that takes the slack. Anything appended after the chevron, or a reserved slot
    /// on folder rows, would move it inward unnoticed. Measured as the rightmost painted column on a
    /// canvas with no trailing padding (the List supplies the inset); 3pt covers the glyph's bearing.
    @Test(.machinePinned(.pixelSampling)) func theChevronReachesTheTrailingEdge() throws {
        let rep = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: true)))
        let edge = try #require(rightmostPaintedColumn(rep))
        let gap = Double(rep.pixelsWide - 1 - edge) / (Double(rep.pixelsWide) / Self.canvas.width)
        #expect(gap <= 3,
                "The chevron is \(gap)pt short of the trailing edge — something is being drawn after it, or reserving width beside it")
    }

    /// The same measurement without the chevron, so "flush" is shown to be the chevron's doing and
    /// not every row's. The same folder with `showsChevron` flipped, not a file row, which reserves
    /// the cloud badge's slot (`reservesCloudSlot: !isDirectory`) and would confound it.
    @Test(.machinePinned(.pixelSampling)) func aRowWithoutAChevronDoesNotReachTheEdge() throws {
        let rep = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: false)))
        let edge = try #require(rightmostPaintedColumn(rep))
        let gap = Double(rep.pixelsWide - 1 - edge) / (Double(rep.pixelsWide) / Self.canvas.width)
        #expect(gap > 3,
                "A chevron-less row is flush to the edge too, so the trailing-edge measurement proves nothing")
    }
}
