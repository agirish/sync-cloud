import Testing
import Foundation

/// **The out-of-process Trash fallback exists only if the app wires it.**
///
/// This scan lives in its own file for a reason the squash made visible: it spent one commit
/// inside `LensProviderNameCallSiteTests`, a suite whose name and doc are about which of a pane's
/// two names Organize uses. Nothing failed — the test ran and passed there — but a reader looking
/// for the Trash seam's confirmer had no reason to open that file, and a reader of that file had
/// no reason to expect a Trash test in it. A scan nobody can find is one nobody maintains.
@Suite struct TrashFallbackWiringTests {

    /// **An unwired seam is a no-op, and this one's default is "do nothing".**
    ///
    /// `FileSyncManager.trashViaWorkspace` defaults to returning nothing, because the engine may
    /// not import AppKit (`LayeringPinTests` enforces that, and caught the first version of this
    /// fix). So the entire out-of-process Trash fallback exists only if the app wires it — and if
    /// that line is ever dropped, every test in `Modules/Sync` stays green while a refused delete
    /// silently stops getting its second attempt. The two confirmers beside it are wired the same
    /// way for the same reason.
    @Test func theAppWiresTheOutOfProcessTrash() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SyncCloudApp.swift — this check would be vacuous")
        try #require(source.count > 500, "SyncCloudApp.swift is implausibly short")
        #expect(source.contains("manager.trashViaWorkspace = "), """
                the app no longer wires `trashViaWorkspace`, so its default — do nothing — stands,                 and a Trash refused in-process gets no second attempt
                """)
        #expect(source.contains("NSWorkspace.shared.recycle("),
                "`trashViaWorkspace` is wired to something that is not the system Trash service")
    }
}
