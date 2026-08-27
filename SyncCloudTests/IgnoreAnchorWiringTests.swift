import Testing
import Foundation
import Sync

/// The two closures `ContentView` hands `FileSyncManager` so it can answer questions about the
/// panes' *sources* — and the reason forgetting either is silent.
///
/// `FileSyncManager` owns the panes and knows nothing about which source each is on; the app owns
/// that mapping. Both closures default to an answer that reproduces the pre-roots behaviour exactly
/// — `paneOpenAt` answers `""` for both panes, `paneSourceId` answers `""` — which is what makes
/// every package test that does not set them still ask the old question and get the old answer.
///
/// **It is also what makes an unwired app indistinguishable from a working one until it matters.**
/// With `paneOpenAt` unset, linked navigation drives a mixed pair with one root-relative path and
/// sends the sibling to a folder two components off. With `paneSourceId` unset, the durable ignore
/// store quotes its entries against whichever source is on the left, so a pane swap re-reads them
/// against the other source's root and every ignored row comes back. Neither throws, neither logs,
/// and neither is reachable from a package test — the closures are wired in the app target, which
/// has no `SettingsManager` a package can stand up.
///
/// So this reads the source. It is the narrowest check that fails when the wiring is dropped, and
/// the behaviour on the far side of it is tested properly in `PersistentIgnoresTests`.
@Suite struct IgnoreAnchorWiringTests {

    static func contentViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SyncCloudTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("MacApp/ContentView.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read ContentView.swift — every check below would be vacuous")
    }

    /// Both closures are assigned, and in the same place: the action that creates the handler, which
    /// is the one moment the manager exists and the view's own state is readable.
    @Test func bothPaneSourceClosuresAreWired() throws {
        let source = try Self.contentViewSource()
        #expect(source.contains("syncManager.paneOpenAt = paneOpenAtForSyncManager"),
                "the manager cannot tell where either pane's source opens — linked navigation will drive a mixed pair with one path")
        #expect(source.contains("syncManager.paneSourceId = paneSourceIdForSyncManager"),
                "the manager cannot tell which source each pane is on — the durable ignore set falls back to left-anchored and a swap loses it")
    }

    /// **Read live, both of them.** A captured `String` goes stale on the next provider switch or
    /// the next discovery pass, and the failure is a translation onto the folder a source *used* to
    /// open at — which looks like a navigation bug rather than a caching one.
    ///
    /// Asserted as the absence of a stored copy rather than the presence of a closure, because the
    /// tempting mistake is `syncManager.paneOpenAt = { [openAt] _ in openAt }`, which is still a
    /// closure and still compiles.
    @Test func neitherClosureCapturesAStoredCopy() throws {
        let source = try Self.contentViewSource()
        for name in ["paneOpenAtForSyncManager", "paneSourceIdForSyncManager"] {
            let start = try #require(source.range(of: "private var \(name): (Bool) -> String {"),
                                     "cannot find \(name) — the wiring test above is checking a name that no longer exists")
            let tail = source[start.upperBound...]
            let end = try #require(tail.range(of: "\n    }"), "cannot find the end of \(name)")
            let body = String(tail[..<end.lowerBound])
            #expect(body.contains("self.leftProviderId") && body.contains("self.rightProviderId"),
                    "\(name) does not read the pane's provider id at call time")
        }
    }
}
