import AppKit
import Foundation
import Quartz
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The second host — ROADMAP §11's diff pane, which is the Duplicates compare surface above its
/// verdict bar.
@MainActor
@Suite struct DifferencesPairCompareTests {

    private let paneNames = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")

    private func difference(type: FileDifference.DifferenceType = .differentDates,
                            enclosed: Int? = nil,
                            left: String = "/L/Reports/Q3.pdf",
                            right: String = "/R/Reports/Q3.pdf") -> FileDifference {
        FileDifference(relativePath: "Reports/Q3.pdf", leftItemPath: left, rightItemPath: right,
                       type: type, action: .copyToRight, description: "differs",
                       enclosedItemCount: enclosed)
    }

    // MARK: What can be compared

    @Test func aChangedFilePairIsComparable() throws {
        let pair = try #require(DifferencesPairCompare.pair(for: difference(),
                                                            paneNames: paneNames))
        #expect(pair.leftPath == "/L/Reports/Q3.pdf")
        #expect(pair.rightPath == "/R/Reports/Q3.pdf")
        #expect(pair.title == "Q3.pdf")
        #expect(pair.subtitle == "iCloud vs Dropbox")
    }

    /// **A row missing on a side has nothing to compare.** Offering it would open a surface whose
    /// pane says "no longer at its scanned location" — a worse answer than not offering the item.
    @Test func aRowMissingOnASideIsNotOffered() {
        #expect(DifferencesPairCompare.pair(for: difference(type: .missingOnLeft),
                                            paneNames: paneNames) == nil)
        #expect(DifferencesPairCompare.pair(for: difference(type: .missingOnRight),
                                            paneNames: paneNames) == nil)
    }

    /// **And a folder is out.** There is no page to raster, no text to diff, and Quick Look draws
    /// an icon — while Compare already has a whole workspace for two folders. `enclosedItemCount`
    /// is the row's own folder marker.
    @Test func aFolderRowIsNotOffered() {
        #expect(DifferencesPairCompare.pair(for: difference(enclosed: 42),
                                            paneNames: paneNames) == nil)
    }

    /// A name conflict is two REAL items under names that differ only invisibly — exactly the pair
    /// a reader most wants side by side.
    @Test func aNameConflictIsComparable() {
        #expect(DifferencesPairCompare.pair(for: difference(type: .nameConflict),
                                            paneNames: paneNames) != nil)
    }

    /// Opening the same row twice is the same surface, not a second one sliding in over the first.
    @Test func thePairIdIsTheTwoPathsWhicheverOrderTheyArrive() {
        let a = DifferencePair(relativePath: "x", leftPath: "/L/x", rightPath: "/R/x",
                               leftPaneName: "A", rightPaneName: "B")
        let b = DifferencePair(relativePath: "x", leftPath: "/R/x", rightPath: "/L/x",
                               leftPaneName: "B", rightPaneName: "A")
        #expect(a.id == b.id)
    }

    // MARK: The facts come from a fresh stat

    private final class Fixture {
        let dir: URL
        let left: String
        let right: String
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DifferencesPairCompareTests-\(UUID().uuidString)")
            let l = dir.appendingPathComponent("L"), r = dir.appendingPathComponent("R")
            try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            let one = l.appendingPathComponent("note.txt"), two = r.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: one)
            try Data("hello there".utf8).write(to: two)
            left = one.path
            right = two.path
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    /// **A stat, not the row's recorded sizes.** `FileDifference` carries no dates at all, so a
    /// strip built from the row would print "—" on both date rows — the surface admitting it did
    /// not look, at the top of a viewer whose job is to say what is true now.
    @Test func theFactsComeFromAFreshStatOfBothSides() async throws {
        let fixture = try Fixture()
        let pair = DifferencePair(relativePath: "note.txt", leftPath: fixture.left,
                                  rightPath: fixture.right, leftPaneName: "iCloud",
                                  rightPaneName: "Dropbox")
        let copies = await DifferencesPairCompare.copies(for: pair)
        #expect(copies.left.size == 5)
        #expect(copies.right.size == 11)
        #expect(copies.left.modificationDate != nil, "the date row would read “—” on both sides")
        #expect(copies.right.modificationDate != nil)
        #expect(copies.left.isRecommendedKeeper == false, "there is no keeper concept in this host")
    }

    /// A vanished side stats to nothing rather than trapping — the row can go stale between the
    /// menu being drawn and the item being clicked, which is the same window every other menu here
    /// resolves against live rows for.
    @Test func aVanishedSideStatsToZeroRatherThanFailing() async {
        let pair = DifferencePair(relativePath: "gone.txt", leftPath: "/nope/gone.txt",
                                  rightPath: "/nope/also.txt", leftPaneName: "A", rightPaneName: "B")
        let copies = await DifferencesPairCompare.copies(for: pair)
        #expect(copies.left.size == 0)
        #expect(copies.left.modificationDate == nil)
    }

    // MARK: Mounted

    /// The shared viewer really mounts here, with two panes and no keeper picker — the whole claim
    /// of the extraction. Without this, "one component, two hosts" would be a sentence in a commit
    /// message.
    @Test func theSharedViewerMountsWithTwoPanesAndNoKeeper() async throws {
        let fixture = try Fixture()
        let pair = DifferencePair(relativePath: "note.txt", leftPath: fixture.left,
                                  rightPath: fixture.right, leftPaneName: "iCloud",
                                  rightPaneName: "Dropbox")
        let copies = await DifferencesPairCompare.copies(for: pair)
        let view = FilePairCompareView(
            left: copies.left, right: copies.right, title: pair.title, subtitle: pair.subtitle,
            claimHeadline: nil, offersVerify: false, keeperPath: nil, allowsKeeperChoice: false,
            notice: nil, scanRoot: nil, providerName: nil, hue: .blue,
            availableSize: CGSize(width: 1200, height: 800),
            onClose: {},
            verdict: { Text("Done") })
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func previews() -> [QLPreviewView] {
            func walk(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + walk($0) } }
            return walk(host).compactMap { $0 as? QLPreviewView }
        }
        // Through `LayoutPumpWait`: the panes mount on main-actor turns, and a wall-clock deadline
        // buys almost none of them under full-package congestion — the way this test first failed.
        let (held, pumps) = await LayoutPumpWait.pump(window, upTo: 5) { previews().count == 2 }
        #expect(held, "expected two preview panes, found \(previews().count) (\(pumps) pumps)")
    }
}
