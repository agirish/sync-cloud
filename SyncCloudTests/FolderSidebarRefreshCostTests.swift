@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// The sidebar refresh's cost: how often it runs, where its `stat`s run, and how often the volumes
/// are walked. One Edit↔Organize switch fires `refreshFolderSidebarRows` two to four times, and each
/// walk `stat`s every provider root, pin, recent, volume and place, a hundred or more `stat` chains
/// with many sources. On the main actor, a sleeping external disk or a wedged network mount in any
/// one of them would block the window. The walk is a `nonisolated static` taking its inputs, so most
/// of this suite measures it rather than scanning source.
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

    /// The walk runs off the main actor, and it really is the walk. The `Task.detached` is the
    /// assertion: calling `resolveFolderSidebarRows` from a non-isolated context compiles only while
    /// it is `nonisolated`, and every blocking `stat` of a refresh is inside it. The row assertions
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

    /// A missing root answers "everything remembered, unchecked" rather than dropping the rows: the
    /// sleeping-drive rule, asserted through the off-main walk so the two can't drift.
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

    /// The mounted-volume walk happens once per mount event, not once per refresh: a
    /// `resourceValues` read per volume can block under an unreachable network mount, and mounts
    /// change only when macOS says so (the app subscribes to all four notifications). The cache is
    /// poisoned with a volume the filesystem can't produce, so an answer naming it came from the
    /// cache; the last two lines are the control.
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

    /// `ContentView` can't be instantiated, so the coalescing inside `refreshFolderSidebarRows` is
    /// read off its source. Comments are stripped so prose explaining the mechanism can't stand in
    /// for it.
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

    /// One refresh per turn, and the ticket is checked twice: after the hop, which collapses the
    /// calls one workspace switch fires into one walk; and after the walk returns, so an overtaken
    /// answer isn't drawn over a newer one. Dropping either leaves a refresh that still works, but
    /// costs more or is occasionally stale, and nothing else would notice.
    @Test func theRefreshTakesATicketAndChecksItOnBothSidesOfTheWalk() throws {
        let body = try Self.refreshBody()
        #expect(body.contains("sidebarRefresh.ticket &+= 1"),
                "no ticket is taken, so the four triggers of one workspace switch each do a full walk")
        let checks = body.components(separatedBy: "guard ticket == sidebarRefresh.ticket else { return }").count - 1
        #expect(checks == 2,
                "the ticket is checked \(checks) time(s): it must be checked after the hop (which coalesces) AND after the walk returns (which drops an overtaken answer)")
    }

    /// The on-screen guard comes first, before the ticket and before anything is read. The triggers
    /// fire in every workspace, so scheduling work before asking whether the column is on screen
    /// would pay for a walk in Compare with the sidebar switched off.
    @Test func theOnScreenGuardStillPrecedesEverything() throws {
        let body = try Self.refreshBody()
        let guardIndex = try #require(body.range(of: "guard folderSidebarIsShowing else { return }"),
                                      "the on-screen guard is gone — every pane move walks eleven roots again")
        let ticketIndex = try #require(body.range(of: "sidebarRefresh.ticket &+= 1"))
        #expect(guardIndex.lowerBound < ticketIndex.lowerBound,
                "work is scheduled before the column is known to be on screen")
    }

    /// The disk work is handed to a detached task, not awaited on the main actor. An `async` member
    /// of a main-actor type hops straight back, so the detach is what's under test, as
    /// `EjectWiringTests.ejectingDoesNotRunOnTheMainActor` pins for the eject.
    @Test func theWalkIsDetachedRatherThanMerelyAwaited() throws {
        let body = try Self.refreshBody()
        #expect(body.contains("Task.detached(priority: .userInitiated)"),
                "the walk runs inline on the main actor, where a sleeping disk blocks the window")
        #expect(body.contains("Self.resolveFolderSidebarRows("),
                "the refresh no longer goes through the off-main walk")
    }
}
