import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Pins the height a section header actually REACHES inside the table, at both densities.
///
/// `SectionHeaderMetricsTests` measures the header view's own `fittingSize`, which is what the
/// header asks for. This measures what it gets, and the two are not the same number: a SwiftUI
/// Table adds ~8pt of chrome around a hosted section header and floors the row at 28pt. Every
/// spacing decision made about the collapsed summary was made about THIS number, so this is the
/// one worth pinning — twice now, a padding value has been chosen against the view's height and
/// been surprised by the row's.
///
/// The 28pt floor is SwiftUI's own and is not reachable from either lever we own: padding below 2
/// changes nothing, and dropping Compact's `tableMinRowHeight` from 20 to 16 takes its DATA rows
/// to 16pt while leaving the header at 28. That is why both densities are expected to agree here
/// while their data rows do not.
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

    /// Mounts the real view at `density` and reports (header row, data row), waiting until the
    /// pair settles at `expectedData` under the header floor (or the timeout runs out).
    ///
    /// Both preferences are seeded into a fresh `ScratchDefaults` suite the view reads via
    /// `.defaultAppStorage` — `UserDefaults.standard` is never touched, so nothing is inherited
    /// from other suites, nothing leaks to them, and no restore is owed on the way out.
    /// `@AppStorage`'s process-wide storage location for a standard-domain key can re-attach to
    /// a fresh view without re-reading the defaults, and a loaded run of this suite proved the
    /// grouping key was not special: it drew Comfortable's 25pt data rows for Compact's entire
    /// 15s wait. A location born from this mount's own store cannot hold a foreign value. Full
    /// account: `DifferencesTableIdentityTests`.
    private func rowHeights(_ density: ListDensity,
                            expectingData expectedData: CGFloat) async -> (header: CGFloat, data: CGFloat)? {
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
        // Row 0 of a sectioned Table is the section HEADER, not the first file.
        //
        // The header does not get its height in the pass that materializes the rows: the table
        // first lays row 0 out at the data-row height and only differentiates it when SwiftUI's
        // row-height invalidation runs. Under a full parallel test run that invalidation can be
        // starved well past any polite fixed window — measuring as soon as rows existed is how
        // this test flaked, catching the header still at the data row's 25. So wait for the
        // settled pair the assertions expect, `waitForOrigin`-style (PaneColumnsScrollTests),
        // and on timeout return the last measurement so a real regression fails with the
        // numbers actually on screen rather than hanging the assertions on a nil.
        let settled = (header: Self.headerRowHeight, data: expectedData)
        let deadline = Date().addingTimeInterval(15)
        var last: (header: CGFloat, data: CGFloat)?
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if let t = table(host), t.numberOfRows >= 2 {
                last = (header: t.rect(ofRow: 0).height, data: t.rect(ofRow: 1).height)
                if last! == settled { return last }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return last
    }

    @Test func comfortableDrawsTheHeaderAtTheFloor() async throws {
        let heights = try #require(await rowHeights(.comfortable, expectingData: 25),
                                   "table never produced rows")
        #expect(heights.header == Self.headerRowHeight)
        // Named so a failure says which number moved. The data row is the yardstick the header is
        // judged against — a header that grew because the whole table grew is a different bug.
        #expect(heights.data == 25)
    }

    @Test func compactDrawsTheSameHeaderOverShorterRows() async throws {
        let heights = try #require(await rowHeights(.compact, expectingData: 20),
                                   "table never produced rows")
        #expect(heights.header == Self.headerRowHeight)
        #expect(heights.data == 20)
    }

    /// The claim the padding constant's doc rests on, asserted rather than left as a comment: the
    /// densities differ in their data rows and agree on their header.
    @Test func theTwoDensitiesAgreeOnTheHeaderAndDisagreeOnTheRow() async throws {
        let comfortable = try #require(await rowHeights(.comfortable, expectingData: 25))
        let compact = try #require(await rowHeights(.compact, expectingData: 20))
        #expect(comfortable.header == compact.header)
        #expect(comfortable.data > compact.data)
    }
}
