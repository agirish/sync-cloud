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

    private func size(cloudOnly: Bool, reserves: Bool, diff: FileDifference.DifferenceType? = nil,
                      contained: Int = 0) -> NSSize {
        let view = HStack(spacing: 8) {
            FileRowAccessories(isCloudOnly: cloudOnly, reservesCloudSlot: reserves,
                               diffStatus: diff, containedDiffCount: contained)
        }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The reservation's whole point: a file row's badge zone is the same size before and after the
    /// lstat answers.
    @Test func testAFileRowsBadgeZoneIsTheSameSizeWithAndWithoutTheCloudBadge() {
        let before = size(cloudOnly: false, reserves: true)
        let after = size(cloudOnly: true, reserves: true)
        #expect(before == after,
                "the badge zone resized when the cloud badge landed: \(before) → \(after)")
        #expect(before.width > 0, "nothing laid out — the measurement is vacuous")
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
