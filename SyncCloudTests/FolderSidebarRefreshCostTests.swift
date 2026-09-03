@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// **The sidebar refresh's cost: how often it runs, where its `stat`s run, and how often the
/// volumes are walked.**
///
/// One Edit↔Organize switch fires `refreshFolderSidebarRows` two to four times — the lens entry
/// re-homes the rail (`onChange(of: leftRelativePath)`), the workspace changes, the pane-hiding
/// changes because Editor defaults to hidden and Organize does not, and `FolderJumpStore` publishes
/// through a `DispatchQueue.main.async`. Each of those was a `fileExists` per provider root plus one
/// per surviving pin and recent, a `mountedVolumeURLs` with a `resourceValues` read per volume, an
/// `isMountedFolder` per place and per source root, and a `resolvingSymlinksInPath` — an `lstat` per
/// path component — for every place against every root. Synchronously, on the main actor. With
/// eleven sources that is upwards of a hundred `stat` chains, up to four times, and on a sleeping
/// external disk or a wedged network mount any single one of them blocks the window.
///
/// The walk itself is testable now that it is a `nonisolated static` taking its inputs, so most of
/// what is below is a measurement rather than a source scan.
@Suite struct FolderSidebarRefreshCostTests {

    /// A provider root holding one folder that exists and none named `Gone`.
    private static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccloud-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Kept"),
                                                withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private static func inputs(root: URL) -> ContentView.FolderSidebarWalkInputs {
        ContentView.FolderSidebarWalkInputs(
            providers: [CloudProvider(id: "P", displayName: "P", imageName: "folder",
                                      rootPath: root.path, type: .localFolder)],
            remembered: [ContentView.RememberedSource(root: root.path, name: "P",
                                                      recents: [], pinned: ["Kept", "Gone"])],
            recents: [], favoriteOrder: [], favoritePlaces: [])
    }

    /// **The walk runs off the main actor, and it really is the walk.**
    ///
    /// The `Task.detached` is the assertion: `resolveFolderSidebarRows` is called from a
    /// non-isolated context, which only compiles while it is `nonisolated` — the whole point of the
    /// change, since every blocking `stat` in a refresh is inside it. The row assertions are what
    /// stop that being a compile-time claim about an empty function.
    @Test func theWholeWalkResolvesOffTheMainActorAndStillChecksTheDisk() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = Self.inputs(root: root)

        let resolved = await Task.detached {
            ContentView.resolveFolderSidebarRows(inputs, volumes: [])
        }.value

        let favorites = resolved.rows.filter { $0.group == .pinned }
        #expect(favorites.map(\.relativePath) == ["Kept"],
                "the walk listed \(favorites.map(\.relativePath)) — a favourite that is not on disk was not checked, or one that is was dropped")
        #expect(favorites.first?.isAvailable == true)
        #expect(resolved.locations.contains { $0.id == "P" },
                "the source's own Locations row is missing, so the place-row build did not run")
        #expect(resolved.volumes.isEmpty, "the walk invented volumes it was not given")
    }

    /// A root that is not there answers "everything remembered, unchecked" rather than dropping the
    /// rows — the sleeping-drive rule, asserted through the off-main walk so the two cannot drift.
    @Test func anAbsentRootKeepsItsRowsAndMarksThemUnavailable() async throws {
        let root = try Self.makeRoot()
        try FileManager.default.removeItem(at: root)
        let resolved = await Task.detached {
            ContentView.resolveFolderSidebarRows(Self.inputs(root: root), volumes: [])
        }.value

        let favorites = resolved.rows.filter { $0.group == .pinned }
        #expect(favorites.map(\.relativePath) == ["Kept", "Gone"],
                "an unreachable root dropped its remembered folders instead of listing them unchecked")
        #expect(favorites.allSatisfy { !$0.isAvailable })
    }

    /// **The mounted-volume walk happens once per mount event, not once per refresh.**
    ///
    /// `mountedVolumeURLs` plus a `resourceValues` read per volume is not free, and under an
    /// unreachable network mount each of those reads can block. What is mounted changes only when
    /// macOS says so, and the app subscribes to all four notifications that say it.
    ///
    /// Proved by poisoning the cache with a volume the real filesystem cannot produce: an answer
    /// that names it can only have come from the cache. The last two lines are the control — with
    /// the cache dropped, the same call goes back to the disk and the sentinel is gone.
    @MainActor
    @Test func theVolumeWalkIsServedFromTheCacheUntilSomethingDropsIt() {
        defer { ContentView.forgetMountedVolumes() }
        ContentView.forgetMountedVolumes()

        let walked = ContentView.mountedVolumesAsLastSeen()
        #expect(!walked.isEmpty, "no volumes at all — the startup disk should be here, so this test is measuring nothing")
        #expect(ContentView.knownMountedVolumes != nil, "the walk was not cached, so every refresh makes its own")

        let sentinel = SidebarSourceModel.Volume(name: "SENTINEL", path: "/Volumes/SENTINEL",
                                                 isRemovable: true, isInternal: false)
        ContentView.knownMountedVolumes = [sentinel]
        #expect(ContentView.mountedVolumesAsLastSeen() == [sentinel],
                "the cache is not consulted — every reader walks the volumes again")

        ContentView.forgetMountedVolumes()
        #expect(ContentView.mountedVolumesAsLastSeen() != [sentinel],
                "forgetting the cache did not send the next reader back to the disk, so a mount or an unmount would never be noticed")
    }

    // MARK: The parts of the refresh no test can reach

    /// `ContentView` is a `View` with `@State` and cannot be instantiated, so the coalescing —
    /// which lives inside `refreshFolderSidebarRows` — is read off its own source, the way this
    /// codebase reads the rest of that file's wiring. Comments are stripped so the prose explaining
    /// the mechanism cannot stand in for it.
    private static func refreshBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 5000, "the file is implausibly short — the scan is vacuous")
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
        let start = try #require(code.range(of: "func refreshFolderSidebarRows() {"),
                                 "the refresh was renamed — this scan now reads nothing")
        let rest = String(code[start.upperBound...])
        let end = rest.range(of: #"\n {4}(nonisolated )?(private )?(static )?(func|var|struct) "#,
                             options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    /// **One refresh per turn, and the ticket is checked TWICE.**
    ///
    /// Once after the hop, which is what collapses the two-to-four calls a single workspace switch
    /// fires into one walk. Once after the walk returns, which is what stops an answer that was
    /// overtaken while it was out being drawn over a newer one — the stale list this column's whole
    /// trigger set exists to prevent. Dropping either leaves a refresh that still works and is
    /// either as expensive as it was or occasionally wrong, and nothing else would notice.
    @Test func theRefreshTakesATicketAndChecksItOnBothSidesOfTheWalk() throws {
        let body = try Self.refreshBody()
        #expect(body.contains("sidebarRefresh.ticket &+= 1"),
                "no ticket is taken, so the four triggers of one workspace switch each do a full walk")
        let checks = body.components(separatedBy: "guard ticket == sidebarRefresh.ticket else { return }").count - 1
        #expect(checks == 2,
                "the ticket is checked \(checks) time(s): it must be checked after the hop (which coalesces) AND after the walk returns (which drops an overtaken answer)")
    }

    /// **The guard comes first**, before the ticket and before anything is read. The refresh
    /// `stat`s a provider root and its triggers fire on every workspace, so a coalescing scheme
    /// that scheduled work before asking whether the column is on screen would pay for a walk in
    /// Compare with the sidebar switched off — the exact cost the guard was added for.
    @Test func theOnScreenGuardStillPrecedesEverything() throws {
        let body = try Self.refreshBody()
        let guardIndex = try #require(body.range(of: "guard folderSidebarIsShowing else { return }"),
                                      "the on-screen guard is gone — every pane move walks eleven roots again")
        let ticketIndex = try #require(body.range(of: "sidebarRefresh.ticket &+= 1"))
        #expect(guardIndex.lowerBound < ticketIndex.lowerBound,
                "work is scheduled before the column is known to be on screen")
    }

    /// **The disk work is handed to a detached task, not awaited on the main actor.** An `async`
    /// member of a main-actor type hops straight back, so the detach is the thing under test —
    /// the same rule `EjectWiringTests.ejectingDoesNotRunOnTheMainActor` pins for the eject.
    @Test func theWalkIsDetachedRatherThanMerelyAwaited() throws {
        let body = try Self.refreshBody()
        #expect(body.contains("Task.detached(priority: .userInitiated)"),
                "the walk runs inline on the main actor, where a sleeping disk blocks the window")
        #expect(body.contains("Self.resolveFolderSidebarRows("),
                "the refresh no longer goes through the off-main walk")
    }
}
