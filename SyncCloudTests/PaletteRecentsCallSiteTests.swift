import Testing
import Foundation
import Dashboard
@testable import SyncCloud

/// The palette's folder lists are resolved before they are drawn.
///
/// `FolderJumpStore.reachable` is pinned from both sides in the Dashboard suite — but a rule
/// extracted for testability is one revert from being unused, and every one of those tests stays
/// green if `paletteIndex` hands the raw stored lists straight to the router. `paletteIndex` is a
/// computed property on a `ContentView` extension: nothing on an instance of it is reachable from a
/// test (the same reason `isMountedFolder` is `static`), so the wiring is checked at source level,
/// with the two habits that keep such a scan honest — name the file, fail if it cannot be read, and
/// assert strings whose absence IS the regression.
@Suite struct PaletteRecentsCallSiteTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    @Test func bothStoredListsAreResolvedBeforeTheyReachTheRouter() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        // The raw hand-off is the regression: it offers a row whose destination is not there.
        #expect(!host.contains("recentFolders: FolderJumpStore.shared.recentPaths"),
                "recents go to the router unresolved — a folder that has gone is offered as a destination")
        #expect(!host.contains("pinnedFolders: FolderJumpStore.shared.pinnedPaths"),
                "pins go to the router unresolved — same defect, and a pin outlives a recent")
        #expect(host.contains("let remembered = Self.reachableFolders("),
                "the lists are no longer resolved before they reach the router")
        #expect(host.contains("recentFolders: remembered.recents"))
        #expect(host.contains("pinnedFolders: remembered.pinned"))
        // The asleep-root half: resolving is not enough if the answer is thrown away.
        #expect(host.contains("foldersUnavailable: remembered.rootIsAvailable ? nil : \"Not available\""),
                "an asleep root drops every recent and every pin silently — \u{2318}K opens blank with nothing saying why")
    }

    @Test func theHostsResolverIsTheStoresRuleAndNotASecondCopy() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        // Two copies of "is this folder still there" would be two answers the first time one of
        // them learns something (a root check, a symlink rule, a cache).
        #expect(host.contains("FolderJumpStore.reachable(recents: recents, pinned: pinned, underRoot: root,"),
                "the host resolves folders with its own rule rather than the store's")
    }

    /// The rule the call site depends on, asserted here too: this suite is what fails if the store
    /// drops the root guard, on a target that does not run the Dashboard suite.
    @Test func theStoresRuleStopsAtAMissingRoot() {
        var asked = 0
        let resolved = FolderJumpStore.reachable(recents: ["A", "B"], pinned: [], underRoot: "/asleep") { _ in
            asked += 1
            return false
        }
        #expect(asked == 1, "a folder was stat'ed under a root already known to be gone")
        // **Kept, not emptied** — the caller marks them unavailable. Dropping them is what made
        // \u{2318}K open blank on a sleeping drive.
        #expect(resolved.rootIsAvailable == false)
        #expect(resolved.recents == ["A", "B"])
    }
}
