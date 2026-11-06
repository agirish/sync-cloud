import Testing
import Foundation
@testable import Sync

/// A refresh that loads the panes without comparing them. Entering a single-source workspace
/// (Organize, Storage, the editor) re-homes the source rail, which is a pane move and so a refresh,
/// but `FileTreeView` draws no differences there, so a comparison would cost a double walk, about a
/// second on a real pair, for nothing. Load and comparison are asserted separately, since skipping
/// the load too would look the same to a test that only counted scans.
@Suite struct RefreshWithoutComparingTests {

    /// Two roots that differ, so a comparison has something to find and its absence is visible.
    private static func makeFixture() throws -> (root: URL, left: URL, right: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccloud-no-compare-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try "L".write(to: left.appendingPathComponent("left-only.txt"), atomically: true, encoding: .utf8)
        try "R".write(to: right.appendingPathComponent("right-only.txt"), atomically: true, encoding: .utf8)
        let resolved = root.resolvingSymlinksInPath()
        return (resolved,
                resolved.appendingPathComponent("left", isDirectory: true),
                resolved.appendingPathComponent("right", isDirectory: true))
    }

    private static func providers(_ fixture: (root: URL, left: URL, right: URL))
        -> (CloudProvider, CloudProvider) {
        (CloudProvider(id: "L", displayName: "L", imageName: "folder",
                       rootPath: fixture.left.path, type: .localFolder),
         CloudProvider(id: "R", displayName: "R", imageName: "folder",
                       rootPath: fixture.right.path, type: .localFolder))
    }

    /// `comparing: false` loads the trees and makes no comparison. `hasScanned` decides, not
    /// `differences.isEmpty`, which two identical folders also produce. The fixture is unequal, and
    /// the control at the end proves it.
    @MainActor
    @Test func aRefreshThatDoesNotCompareStillLoadsBothPanes() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (left, right) = Self.providers(fixture)
        let m = FileSyncManager()

        await m.refreshTreesAndScan(left: left, right: right, comparing: false)

        #expect(m.leftItemCount > 0, "the left pane was not loaded — the skip took the walk with it")
        #expect(m.rightItemCount > 0, "the right pane was not loaded — the skip took the walk with it")
        #expect(!m.hasScanned, "the comparison ran anyway")
        #expect(m.differences.isEmpty)
        #expect(m.lastScanDate == nil, "a scan completed and stamped itself")

        // The control: the same call, comparing, finds the two files that differ, so the fixture
        // can be compared at all.
        await m.refreshTreesAndScan(left: left, right: right)
        #expect(m.hasScanned, "the comparing refresh did not scan either — this fixture proves nothing")
        #expect(m.differences.count == 2,
                "the comparing refresh found \(m.differences.count) differences in a fixture with two")
    }

    /// The default still compares, so every other caller (a file operation, a forced rescan, a
    /// provider switch, ordinary navigation) keeps its scan.
    @MainActor
    @Test func theDefaultStillCompares() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (left, right) = Self.providers(fixture)
        let m = FileSyncManager()

        await m.refreshTreesAndScan(left: left, right: right)

        #expect(m.hasScanned, "the default no longer compares, so every caller silently lost its scan")
        #expect(m.differences.count == 2)
    }

    /// A skipped comparison is owed, and `scanDirectories`, the app's Compare-entry path, settles it
    /// without another double walk, since the trees are already loaded. The app's flag relies on it.
    @MainActor
    @Test func theSkippedComparisonCanBeMadeGoodWithoutReloading() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (left, right) = Self.providers(fixture)
        let m = FileSyncManager()

        await m.refreshTreesAndScan(left: left, right: right, comparing: false)
        let loadedLeft = m.leftPaneTree.version
        let loadedRight = m.rightPaneTree.version
        #expect(!m.hasScanned)

        await m.scanDirectories(left: left, leftPath: fixture.left.path,
                                right: right, rightPath: fixture.right.path)

        #expect(m.hasScanned, "the deferred comparison could not be made good")
        #expect(m.differences.count == 2)
        #expect(m.leftPaneTree.version == loadedLeft,
                "settling the comparison re-walked the left pane, which the deferral exists to avoid")
        #expect(m.rightPaneTree.version == loadedRight,
                "settling the comparison re-walked the right pane")
    }
}
