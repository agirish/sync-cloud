import Testing
import Foundation
import Sync

/// The two closures `ContentView` hands `FileSyncManager` so it can answer questions about the
/// panes' sources. The manager doesn't know which source each pane is on, and both closures
/// default to `""`, so package tests that don't set them behave as before, and an unwired app
/// looks fine until it matters. Unset `paneOpenAt` sends linked navigation's sibling to a folder two
/// components off; unset `paneSourceId` anchors the durable ignores to the left source, so a pane
/// swap brings every ignored row back. Neither throws or logs, so this reads the source; the
/// behaviour is tested in `PersistentIgnoresTests`.
@Suite struct IgnoreAnchorWiringTests {

    static func contentViewSource() throws -> String { try macAppFile("ContentView.swift") }

    /// Both closures are assigned in the action that creates the handler, the one moment the manager
    /// exists and the view's own state is readable.
    @Test func bothPaneSourceClosuresAreWired() throws {
        let source = try Self.contentViewSource()
        #expect(source.contains("syncManager.paneOpenAt = paneOpenAtForSyncManager"),
                "the manager cannot tell where either pane's source opens — linked navigation will drive a mixed pair with one path")
        #expect(source.contains("syncManager.paneSourceId = paneSourceIdForSyncManager"),
                "the manager cannot tell which source each pane is on — the durable ignore set falls back to left-anchored and a swap loses it")
    }

    /// Both read live. A captured `String` goes stale on the next provider switch or discovery pass,
    /// translating onto the folder a source used to open at, which looks like a navigation bug.
    /// Checked by reading each body, since `{ [openAt] _ in openAt }` is still a closure and
    /// compiles.
    @Test func neitherClosureCapturesAStoredCopy() throws {
        let source = try Self.contentViewSource()
        for name in ["paneOpenAtForSyncManager", "paneSourceIdForSyncManager"] {
            let body = try declarationBody(of: "private var \(name): (Bool) -> String {", in: source)
            #expect(body.contains("self.leftProviderId") && body.contains("self.rightProviderId"),
                    "\(name) does not read the pane's provider id at call time")
        }
    }
}
