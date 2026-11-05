import Testing
import Foundation

/// The out-of-process Trash fallback exists only if the app wires it. Kept in its own file so a
/// reader looking for the Trash seam's check can find it.
@Suite struct TrashFallbackWiringTests {

    /// `FileSyncManager.trashViaWorkspace` defaults to doing nothing, because the engine may not
    /// import AppKit (`LayeringPinTests`). Drop the app's wiring and every test in `Modules/Sync`
    /// stays green while a refused delete silently loses its second attempt. The two confirmers
    /// beside it are wired the same way for the same reason.
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
