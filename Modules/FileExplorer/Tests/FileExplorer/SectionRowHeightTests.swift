import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Pins the height a section header reaches inside the table, at both densities.
/// `SectionHeaderMetricsTests` measures what the header asks for (`fittingSize`); this measures
/// what it gets. A SwiftUI Table adds ~8pt of chrome around a hosted header and floors the row at
/// 28pt, and the collapsed summary's spacing is judged against this number. The floor is SwiftUI's:
/// padding below 2 changes nothing, and lowering Compact's `tableMinRowHeight` lowers its data rows
/// but not the header, so both densities agree here while their data rows don't.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct SectionRowHeightTests {

    /// The floor SwiftUI imposes on a section header row. Both densities sit on it.
    private static let headerRowHeight: CGFloat = 28

    private func differences() -> [FileDifference] {
        ["Documents", "Photos", "Projects"].flatMap { folder in
            (1...4).map { index in
                FileDifference(relativePath: "\(folder)/file-\(index).txt",
                               leftItemPath: "/left/\(folder)/file-\(index).txt",
                               rightItemPath: "/right/\(folder)/file-\(index).txt",
                               type: .missingOnRight, action: .copyToRight,
                               description: "Only on the left", leftFileSize: 1024)
            }
        }
    }

    /// Mounts the real view at `density` and reports (header row, data row), waiting until the pair
    /// settles at `expectedData` under the header floor or the timeout runs out. The preferences go
    /// into a fresh `ScratchDefaults` suite read via `.defaultAppStorage`, never
    /// `UserDefaults.standard`: `@AppStorage`'s process-wide location for a standard-domain key can
    /// re-attach to a fresh view without re-reading defaults and show another run's density. A
    /// location born from this mount's own store can't (see `DifferencesTableIdentityTests`).
    private func rowHeights(_ density: ListDensity,
                            expectingData expectedData: CGFloat)
        async -> (heights: (header: CGFloat, data: CGFloat)?, pumps: Int) {
        let store = ScratchDefaults("SectionRowHeightTests")
        store.set(true, forKey: "differencesGroupByFolder")
        store.set(density.rawValue, forKey: ListDensity.defaultsKey)

        let manager = FileSyncManager()
        manager.differences = differences()
        manager.hasScanned = true
        let host = NSHostingView(rootView: AnyView(
            DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore())
                .defaultAppStorage(store)))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        func table(_ view: NSView) -> NSTableView? {
            if let found = view as? NSTableView { return found }
            for subview in view.subviews { if let found = table(subview) { return found } }
            return nil
        }
        // Row 0 of a sectioned Table is the section header, not the first file.
        //
        // The table first lays row 0 out at the data-row height and gives the header its own only
        // when SwiftUI's row-height invalidation runs, which a full parallel run can starve past
        // any fixed window. So wait for the settled pair the assertions expect (as
        // PaneColumnsScrollTests' `waitForOrigin` does), and on timeout return the last
        // measurement so a regression fails with the numbers on screen. Bounded by
        // `LayoutPumpWait`'s pass floor as well as its deadline, since the invalidation needs
        // main-actor turns (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
        let settled = (header: Self.headerRowHeight, data: expectedData)
        var last: (header: CGFloat, data: CGFloat)?
        let outcome = await LayoutPumpWait.pump(host, upTo: 15) {
            guard let t = table(host), t.numberOfRows >= 2 else { return false }
            last = (header: t.rect(ofRow: 0).height, data: t.rect(ofRow: 1).height)
            return last! == settled
        }
        return (last, outcome.pumps)
    }

    @Test func comfortableDrawsTheHeaderAtTheFloor() async throws {
        let measured = await rowHeights(.comfortable, expectingData: 24)
        let heights = try #require(measured.heights,
                                   "table never produced rows after \(measured.pumps) passes")
        #expect(heights.header == Self.headerRowHeight)
        // Named so a failure says which number moved: the data row is the yardstick, and a header
        // that grew because the whole table grew is a different bug. 24, not a floor: comfortable
        // sets no `tableMinRowHeight`, so the tallest cell, a text cell, decides.
        #expect(heights.data == 24)
    }

    @Test func compactDrawsTheSameHeaderOverShorterRows() async throws {
        let measured = await rowHeights(.compact, expectingData: 20)
        let heights = try #require(measured.heights,
                                   "table never produced rows after \(measured.pumps) passes")
        #expect(heights.header == Self.headerRowHeight)
        #expect(heights.data == 20)
        // The rule the padding constant's doc rests on: the densities agree on their header (both
        // pinned to `headerRowHeight`) and differ in their data rows, compact below comfortable's 24.
        #expect(heights.data < 24)
    }
}
