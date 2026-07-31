import Testing
import Foundation
@testable import Dashboard

/// Pins that the Details inspector's stat distinguishes "there is nothing to show" from "I was not
/// allowed to look".
///
/// `loadMetadata` answers both with an empty `metadata`, and the inspector renders both as an empty
/// card — so the failure case has to leave a breadcrumb, or a permissions/IO failure on a cloud path
/// is indistinguishable from an empty selection with nothing recorded anywhere. Follows
/// `FolderJump.siblings`, which surfaces the same class of failure to its caller.
///
/// This suite is deliberately **not** `@MainActor`. It used to have to be — `loadMetadata` was a
/// static on a SwiftUI `View`, which isolates the whole type, so calling it off the main actor
/// trapped at runtime. That isolation is exactly what froze the app: a `.task` closure inherits it,
/// so the stat ran on the main thread and a wedged `getxattr` took the UI down with it. The loader
/// is now `nonisolated`, and these tests running off the main actor is what holds that open — put
/// the isolation back and this file stops compiling.
@Suite struct DetailsMetadataLoadTests {

    /// An item that exists but whose attributes cannot be read — a locked folder, a cloud
    /// placeholder that won't materialize, a volume that went away mid-read.
    private final class UnreadableAttributesFileManager: FileManager, @unchecked Sendable {
        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            isDirectory?.pointee = ObjCBool(false)
            return true
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                          userInfo: [NSLocalizedDescriptionKey: "You do not have permission to view it."])
        }
    }

    @Test func anUnreadableItemIsReportedRatherThanRenderedAsAnEmptyInspector() {
        let path = "/Volumes/Cloud/Statements/locked.pdf"

        let load = DetailsSidebar.loadMetadata(
            for: path,
            fileManager: UnreadableAttributesFileManager())

        // The inspector still falls silent — the card has nothing to render and this is not worth
        // failing a UI over — but the reason is no longer lost. It comes back in the return value
        // rather than going to a log sink, because the loader now runs where no `@MainActor` sink
        // can be reached; `DetailsMetadataCache` logs it, rate-limited per path.
        #expect(load.metadata == nil)
        // The two things a breadcrumb has to carry: which item, and why.
        #expect(load.failure?.contains(path) == true)
        #expect(load.failure?.contains("permission") == true)
    }

    @Test func aPathThatIsSimplyNotThereIsNotReportedAsAFailure() {
        // The common case by far: the selection cleared, or the item was just moved/deleted. That
        // is not a failure and must not put a warning in the log every time it happens.
        let load = DetailsSidebar.loadMetadata(for: "/no/such/path-\(UUID().uuidString)")

        #expect(load.metadata == nil)
        #expect(load.failure == nil)
    }

    @Test func areadableItemLoadsItsMetadataAndSaysNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("details-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let load = DetailsSidebar.loadMetadata(for: url.path)

        #expect(load.metadata?.name == url.lastPathComponent)
        #expect(load.metadata?.isDirectory == false)
        #expect(load.failure == nil)
    }
}
