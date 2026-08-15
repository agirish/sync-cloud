import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The folder date, and which presentation carries it: Columns withholds it, the tree keeps it,
/// and a file's size survives in both.
///
/// **Pixels, not geometry, for the call site.** `FileRowView` lays the secondary text out behind a
/// `Spacer`, so a row with no date is exactly as wide as one with a date — `fittingSize` cannot
/// tell them apart, and neither can a width assertion on the column. Only what is painted can.
///
/// The suite deliberately holds a POSITIVE control (`theTreeRowStillPaintsTheFolderDate`) beside
/// the zero-difference assertions. A bitmap harness that renders nothing at all reports "no
/// difference" for every pair, which would pass the two claims below while measuring nothing; the
/// control fails first in that case, and it is the reason a broken harness cannot read as a green
/// suite here. `aRowWithoutAChevronDoesNotReachTheEdge` is the same guard for the trailing-edge
/// measurement.
///
/// **Known boundary:** these construct `ColumnRowView` directly, so they pin what that row paints,
/// not that `PaneColumnsView.columnRow` is still the thing building it. A refactor that stopped
/// routing column rows through `ColumnRowView` would leave every test here green — and nothing else
/// closes that: a dozen suites do mount a real `PaneColumnsView`, but every one of them asserts
/// navigation, selection, scrolling or layout, and not one asserts anything a row draws. Rendering
/// a whole pane per assertion is what closing it would cost, on the package's slowest suite; this
/// suite's neighbours (`HomeOnlyBadgeTests`) draw the line in the same place for the same reason.
@MainActor
@Suite struct ColumnRowDateTests {

    /// Wide enough that a medium-style date has somewhere to land: at 260pt the name, the date and
    /// the chevron all fit without truncation, so a missing date is the only thing a difference can
    /// be attributed to.
    private static let canvas = CGSize(width: 260, height: 24)

    /// A fixed instant, so the formatted string cannot vary with the day the suite runs.
    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

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

    /// Renders a row and returns its bitmap.
    ///
    /// The window background is not decoration: without one the row composites against a borderless
    /// window's own buffer and every comparison reads as zero — the "diffs against BLACK" trap that
    /// would make every claim here vacuous in the direction they are asserted.
    private func bitmap<V: View>(_ view: V) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
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

    /// The rightmost pixel column holding anything other than the window background, or nil for a
    /// bitmap that painted nothing at all — which `#require` then turns into a failure rather than
    /// a silently passing measurement.
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
        var differing = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    // MARK: - The rule

    /// All four cases of `secondaryText`, so the one place that decides between a date and a size
    /// is pinned independently of anything that draws it.
    @Test func theRuleWithholdsAFoldersDateAndNothingElse() {
        let datedFolder = FileRowInfo(folder(dated: true))
        let sizedFile = FileRowInfo(file(sized: true))

        #expect(FileRowView.secondaryText(for: datedFolder, showsFolderDate: false) == nil,
                "Columns must not ask for a folder's date")
        #expect(FileRowView.secondaryText(for: datedFolder, showsFolderDate: true) != nil,
                "The tree must still ask for it — the flag is not a global removal")
        // The flag is about FOLDERS. Asserting the file case under BOTH settings is what stops a
        // future `guard showsFolderDate` from being hoisted above the isDirectory branch, which
        // would silently take every file's size with it. The literal pins that the answer is the
        // SIZE; the equality pins that the flag cannot reach it, without this test also owning
        // how `FileSizeFormat` rounds.
        #expect(FileRowView.secondaryText(for: sizedFile, showsFolderDate: true) == "1 KB")
        #expect(FileRowView.secondaryText(for: sizedFile, showsFolderDate: false)
                    == FileRowView.secondaryText(for: sizedFile, showsFolderDate: true))
    }

    /// The tree's date is the SAME date it always was — medium, no time.
    ///
    /// Extracting the rule into a static function moved the formatter reference; the refactor is
    /// only behaviour-preserving if the string is unchanged, and "not nil" cannot see a formatter
    /// that quietly gained a time or dropped to `.short`. The expectation is built from an
    /// independently constructed formatter rather than a hardcoded literal, because the app's
    /// string is locale- and timezone-dependent and a literal would pin this suite to whichever
    /// Mac wrote it.
    @Test func theTreesDateKeepsItsFormat() {
        let reference = DateFormatter()
        reference.dateStyle = .medium
        reference.timeStyle = .none

        #expect(FileRowView.secondaryText(for: FileRowInfo(folder(dated: true)), showsFolderDate: true)
                    == reference.string(from: Self.stamp))
    }

    /// A folder the scan never dated is nil either way — the fallback must not be confusable with
    /// the withheld answer by anything reading this rule.
    @Test func anUndatedFolderIsNilUnderEitherSetting() {
        let undated = FileRowInfo(folder(dated: false))
        #expect(FileRowView.secondaryText(for: undated, showsFolderDate: true) == nil)
        #expect(FileRowView.secondaryText(for: undated, showsFolderDate: false) == nil)
    }

    // MARK: - The call sites

    /// The positive control, and the reason the zero-difference claims below mean anything: the
    /// tree's row DOES paint a folder date, so this harness demonstrably renders one.
    ///
    /// It also pins the DEFAULT, which is the whole of what the tree's date rests on:
    /// `FileTreeView.treeRow` passes no `showsFolderDate` at all, so flipping the default to false
    /// would strip dates from both tree panes and the Organize rail — and this test, which likewise
    /// passes nothing, is what fails. What no test here covers is `treeRow` starting to pass `false`
    /// explicitly; that is a deliberate design change rather than a regression, and guarding it
    /// would only make the flag harder to use for the thing it exists for.
    @Test func theTreeRowStillPaintsTheFolderDate() throws {
        let dated = try #require(bitmap(FileRowView(
            node: FileRowInfo(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable)))
        let undated = try #require(bitmap(FileRowView(
            node: FileRowInfo(folder(dated: false)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable)))
        #expect(pixelsDiffering(dated, undated) > 0,
                "The tree row stopped drawing folder dates — the Columns change was not supposed to reach it")
    }

    /// The change itself: in Columns a dated folder is painted identically to an undated one.
    @Test func theColumnRowPaintsNoFolderDate() throws {
        let dated = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: true)))
        let undated = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: false)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: true)))
        #expect(pixelsDiffering(dated, undated) == 0,
                "ColumnRowView is painting the folder date — it must pass showsFolderDate: false")
    }

    /// The chevron reaches the row's trailing edge — the other half of what this change is for.
    ///
    /// It is placed by construction rather than by a spacer of its own: `FileRowView` ends in a
    /// `Spacer` and takes all the slack, so the chevron that follows it in `ColumnRowView`'s HStack
    /// is pushed flush. "By construction" is precisely the kind of claim that stops being true
    /// without anyone noticing — anything appended after the chevron, or a reserved slot that grows
    /// on folder rows, moves it inward and no other test here would fail.
    ///
    /// Measured as the rightmost painted column, against a canvas whose own trailing padding is
    /// zero (the List supplies the row inset in the app, not the row). 3pt of tolerance covers the
    /// glyph's own right side bearing.
    @Test func theChevronReachesTheTrailingEdge() throws {
        let rep = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: true)))
        let edge = try #require(rightmostPaintedColumn(rep))
        let gap = Double(rep.pixelsWide - 1 - edge) / (Double(rep.pixelsWide) / Self.canvas.width)
        #expect(gap <= 3,
                "The chevron is \(gap)pt short of the trailing edge — something is being drawn after it, or reserving width beside it")
    }

    /// The same measurement with the chevron taken away, which is what makes the one above mean
    /// something: "flush" has to be a property of the chevron rather than of every row this harness
    /// renders.
    ///
    /// The A/B is the SAME folder with `showsChevron` flipped, not a file row. A file row is the
    /// more realistic subject but a confounded one — it reserves the cloud badge's slot
    /// (`reservesCloudSlot: !isDirectory`), so its gap would be evidence about that slot, and
    /// removing the reservation later would fail this test for a reason having nothing to do with
    /// the chevron. Production always pairs a folder with a chevron, so this configuration is
    /// synthetic on purpose: it changes exactly one thing.
    @Test func aRowWithoutAChevronDoesNotReachTheEdge() throws {
        let rep = try #require(bitmap(ColumnRowView(
            row: row(folder(dated: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: false)))
        let edge = try #require(rightmostPaintedColumn(rep))
        let gap = Double(rep.pixelsWide - 1 - edge) / (Double(rep.pixelsWide) / Self.canvas.width)
        #expect(gap > 3,
                "A chevron-less row is flush to the edge too, so the trailing-edge measurement proves nothing")
    }

    /// The half of layout B that is a keep, not a removal: a file's size survives in Columns.
    @Test func theColumnRowKeepsAFileSize() throws {
        let sized = try #require(bitmap(ColumnRowView(
            row: row(file(sized: true)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: false)))
        let unsized = try #require(bitmap(ColumnRowView(
            row: row(file(sized: false)), isIgnored: false, diffStatus: nil,
            containedDiffCount: 0, density: .comfortable, showsChevron: false)))
        #expect(pixelsDiffering(sized, unsized) > 0,
                "Columns stopped drawing file sizes — the date removal took the size with it")
    }
}
