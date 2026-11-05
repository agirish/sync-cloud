import Testing
import Foundation
import Dashboard
@testable import SyncCloud

/// The palette's folder lists are resolved before they are drawn. `FolderJumpStore.reachable` is
/// pinned in the Dashboard suite, but those tests stay green if `paletteIndex` hands the raw stored
/// lists to the router. `paletteIndex` lives on a `ContentView` extension no test can instantiate,
/// so the wiring is checked in source: name the file, fail if it can't be read, and assert strings
/// whose absence is the regression.
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
        // The asleep-root half: resolving isn't enough if the answer is thrown away.
        #expect(host.contains("foldersUnavailable: remembered.rootIsAvailable ? nil : \"Not available\""),
                "an asleep root drops every recent and every pin silently — \u{2318}K opens blank with nothing saying why")
    }

    @Test func theHostsResolverIsTheStoresRuleAndNotASecondCopy() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        // Two copies of "is this folder still there" would diverge as soon as one learned
        // something (a root check, a symlink rule, a cache).
        #expect(host.contains("FolderJumpStore.reachable(recents: recents, pinned: pinned, underRoot: root,"),
                "the host resolves folders with its own rule rather than the store's")
    }

    /// The rule the call site depends on, asserted here too, so this target fails if the store
    /// drops the root guard even without the Dashboard suite.
    @Test func theStoresRuleStopsAtAMissingRoot() {
        var asked = 0
        let resolved = FolderJumpStore.reachable(recents: ["A", "B"], pinned: [], underRoot: "/asleep") { _ in
            asked += 1
            return false
        }
        #expect(asked == 1, "a folder was stat'ed under a root already known to be gone")
        // Kept, not emptied: the caller marks them unavailable. Dropping them would make ⌘K open
        // blank on a sleeping drive.
        #expect(resolved.rootIsAvailable == false)
        #expect(resolved.recents == ["A", "B"])
    }
}
