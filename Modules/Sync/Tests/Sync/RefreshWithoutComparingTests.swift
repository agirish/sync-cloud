import Testing
import Foundation
@testable import Sync

/// **A refresh that loads the panes without comparing them.**
///
/// Entering a lens from the workspace bar re-homes the source rail to the provider root. That is a
/// pane move, a pane move is a refresh, and the refresh was walking BOTH providers and diffing
/// them — on the way into a workspace that draws one tree and no differences at all (`FileTreeView`
/// empties the difference index for every single-source workspace, so the rows the scan produced
/// rendered nowhere). On a real pair that is a full double walk and about a second, paid on every
/// entry into Organize, Storage or the editor.
///
/// The two halves are asserted separately, because a change that skipped the *load* as well would
/// look identical from a test that only counted scans: the pane must still be showing the folder it
/// was moved to.
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

    /// **`comparing: false` loads the trees and makes no comparison.**
    ///
    /// `hasScanned` is the discriminator rather than `differences.isEmpty`: an empty list is also
    /// what two identical folders produce, so a fixture that happened to match would pass either
    /// way. This fixture is deliberately unequal, and the control at the end proves it.
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

        // The control: the same call, comparing, finds the two files that differ. Without this the
        // assertions above pass for a fixture nothing could ever have compared.
        await m.refreshTreesAndScan(left: left, right: right)
        #expect(m.hasScanned, "the comparing refresh did not scan either — this fixture proves nothing")
        #expect(m.differences.count == 2,
                "the comparing refresh found \(m.differences.count) differences in a fixture with two")
    }

    /// **The default is unchanged**, which is what keeps every existing caller — a file operation, a
    /// forced rescan, a provider switch, ordinary navigation — comparing exactly as it did.
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

    /// **A skipped comparison is owed, and `scanDirectories` is what settles it** — the app's
    /// Compare-entry path. Asserted here because that is the claim the app's flag depends on: the
    /// trees are already loaded, so the debt can be paid without another double walk.
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
