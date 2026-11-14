import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// A row must not change shape when its cloud badge lands: `FileRowView` resolves `isCloudOnly`
/// with a per-row `lstat` off the main actor, so the answer arrives after the row is on screen.
///
/// These measure the laid-out result (`NSHostingView.fittingSize`), not the declaration: a
/// reservation that doesn't survive layout is no reservation at all.
@MainActor
@Suite struct FileRowAccessoryStabilityTests {

    /// - Parameter leadingGap: the gap before each drawn item; 10pt is what a comfortable row passes.
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

    /// A file row's badge zone is the same size before and after the lstat answers.
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

    /// The ☁ is painted, in the slot a file row holds for it, and not for a downloaded file. The
    /// zone's size cannot see this: an overlay that drew nothing measures exactly the same.
    @Test(.machinePinned(.pixelSampling)) func testTheCloudBadgePaintsInItsSlot() throws {
        func rendered(_ cloudOnly: Bool) throws -> NSBitmapImageRep {
            let subject = FileRowAccessories(isCloudOnly: cloudOnly, reservesCloudSlot: true,
                                             diffStatus: nil, containedDiffCount: 0, leadingGap: 10)
                .frame(width: 60, height: 26, alignment: .trailing)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            return try #require(PixelDiff.render(subject, size: CGSize(width: 60, height: 26)))
        }
        let differing = PixelDiff.differingPixels(try rendered(true), try rendered(false), tolerance: 0.02)
        #expect(differing > 20, "a cloud-only file's slot painted \(differing) pixels differently — no ☁ was drawn")
    }

    /// And with a difference badge alongside it, the common case in a compared folder.
    @Test func testTheZoneIsStableWithADifferenceBadgeToo() {
        let before = size(cloudOnly: false, reserves: true, diff: .differentDates)
        let after = size(cloudOnly: true, reserves: true, diff: .differentDates)
        #expect(before == after, "the badge zone resized: \(before) → \(after)")
    }

    /// Directories never show the badge (`FileRowView` forces it false for them), so they must not
    /// reserve a slot that can never be filled.
    @Test func testDirectoryRowsDoNotReserveASlotTheyCanNeverFill() {
        let reserved = size(cloudOnly: false, reserves: true, contained: 3)
        let unreserved = size(cloudOnly: false, reserves: false, contained: 3)
        #expect(unreserved.width < reserved.width,
                "a directory row is holding space for a badge it can never show")
    }

    /// The positive control: an unreserved zone does change size, so the measurements above mean
    /// something.
    @Test func testWithoutTheReservationTheZoneReallyDoesResize() {
        let before = size(cloudOnly: false, reserves: false)
        let after = size(cloudOnly: true, reserves: false)
        let why = "unreserved zone did not resize either — the reservation fixes nothing, and every"
            + " assertion above would pass vacuously if the reservation were removed"
        #expect(before != after, "\(why)")
    }
}
