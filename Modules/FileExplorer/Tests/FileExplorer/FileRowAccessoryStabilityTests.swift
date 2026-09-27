import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// A row must not change shape when its cloud badge lands.
///
/// `FileRowView` resolves `isCloudOnly` with a per-row `lstat` off the main actor, so the answer
/// arrives after the row is already on screen — one row at a time, in bursts, whenever a column
/// opens or the list scrolls. Anything the row's geometry does at that moment it does long after
/// the user has stopped expecting the pane to move.
///
/// These measure the LAID-OUT result (`NSHostingView.fittingSize`), not the declaration: the
/// question is what AppKit ends up with, and a reservation that doesn't survive layout is no
/// reservation at all.
@MainActor
@Suite struct FileRowAccessoryStabilityTests {

    /// - Parameter leadingGap: the gap each drawn item keeps before it — 10pt in a comfortable row,
    ///   which is what the rows pass, so that is what is measured unless a case says otherwise.
    private func size(cloudOnly: Bool, reserves: Bool, diff: FileDifference.DifferenceType? = nil,
                      contained: Int = 0, leadingGap: CGFloat = 10) -> NSSize {
        let view = HStack(spacing: 8) {
            FileRowAccessories(isCloudOnly: cloudOnly, reservesCloudSlot: reserves,
                               diffStatus: diff, containedDiffCount: contained, leadingGap: leadingGap)
        }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The reservation's whole point: a file row's badge zone is the same size before and after the
    /// lstat answers.
    @Test func testAFileRowsBadgeZoneIsTheSameSizeWithAndWithoutTheCloudBadge() {
        // At the gap the rows use, and at none: a gap applied in only one cloud state would shift
        // the row by exactly that gap when the answer lands.
        for gap: CGFloat in [10, 8, 0] {
            let before = size(cloudOnly: false, reserves: true, leadingGap: gap)
            let after = size(cloudOnly: true, reserves: true, leadingGap: gap)
            #expect(before == after,
                    "at a \(gap)pt gap the badge zone resized when the cloud badge landed: \(before) → \(after)")
            #expect(before.width > 0, "nothing laid out — the measurement is vacuous")
        }
    }

    /// **The ☁ is painted** — in the slot a file row holds for it, and not for a downloaded file. The
    /// zone's SIZE cannot see this: an overlay that drew nothing measures exactly the same, and the
    /// render tests that did see it went with the ⌂ badge they were written for.
    @Test(.machinePinned(.pixelSampling)) func testTheCloudBadgePaintsInItsSlot() throws {
        func rendered(_ cloudOnly: Bool) throws -> NSBitmapImageRep {
            let subject = FileRowAccessories(isCloudOnly: cloudOnly, reservesCloudSlot: true,
                                             diffStatus: nil, containedDiffCount: 0, leadingGap: 10)
                .frame(width: 60, height: 26, alignment: .trailing)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: AnyView(subject))
            host.frame = CGRect(x: 0, y: 0, width: 60, height: 26)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.colorSpace = .sRGB
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let cloud = try rendered(true), downloaded = try rendered(false)
        var differing = 0
        for y in 0..<min(cloud.pixelsHigh, downloaded.pixelsHigh) {
            for x in 0..<min(cloud.pixelsWide, downloaded.pixelsWide) {
                guard let a = cloud.colorAt(x: x, y: y), let b = downloaded.colorAt(x: x, y: y) else { continue }
                if max(abs(a.redComponent - b.redComponent),
                       max(abs(a.greenComponent - b.greenComponent),
                           abs(a.blueComponent - b.blueComponent))) > 0.02 { differing += 1 }
            }
        }
        #expect(differing > 20, "a cloud-only file's slot painted \(differing) pixels differently — no ☁ was drawn")
    }

    /// …and with a difference badge alongside it, which is the common case in a compared folder.
    @Test func testTheZoneIsStableWithADifferenceBadgeToo() {
        let before = size(cloudOnly: false, reserves: true, diff: .differentDates)
        let after = size(cloudOnly: true, reserves: true, diff: .differentDates)
        #expect(before == after, "the badge zone resized: \(before) → \(after)")
    }

    /// Directories never show the badge (`FileRowView` forces it false for them), so they must not
    /// pay for a slot that can never be filled — a folder-heavy pane would otherwise gain a column
    /// of permanent blank space.
    @Test func testDirectoryRowsDoNotReserveASlotTheyCanNeverFill() {
        let reserved = size(cloudOnly: false, reserves: true, contained: 3)
        let unreserved = size(cloudOnly: false, reserves: false, contained: 3)
        #expect(unreserved.width < reserved.width,
                "a directory row is holding space for a badge it can never show")
    }

    /// The measurement is only meaningful if an UNRESERVED zone genuinely does change size — this
    /// is the behaviour being fixed, and it is what the reservation above is worth.
    @Test func testWithoutTheReservationTheZoneReallyDoesResize() {
        let before = size(cloudOnly: false, reserves: false)
        let after = size(cloudOnly: true, reserves: false)
        let why = "unreserved zone did not resize either — the reservation fixes nothing, and every"
            + " assertion above would pass vacuously if the reservation were removed"
        #expect(before != after, "\(why)")
    }
}
