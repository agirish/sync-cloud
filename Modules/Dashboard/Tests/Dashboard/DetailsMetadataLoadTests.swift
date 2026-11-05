import Testing
import Foundation
@testable import Dashboard

/// Pins that the Details inspector's stat tells "nothing to show" from "not allowed to look". Both
/// render as an empty card, so the failure must leave a breadcrumb, or a permissions or IO failure
/// on a cloud path looks like an empty selection. Follows `FolderJump.siblings`, which surfaces
/// the same class of failure.
///
/// **Not** `@MainActor`, on purpose: the loader must stay `nonisolated`. A `.task` closure inherits
/// a `View`'s main-actor isolation, so an isolated loader would stat on the main thread and a
/// wedged `getxattr` would freeze the UI. Put the isolation back and this file stops compiling.
@Suite struct DetailsMetadataLoadTests {

    /// An item that exists but whose attributes can't be read: a locked folder, a cloud placeholder
    /// that won't materialize, a volume that went away mid-read.
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

        // The card stays empty, but the reason comes back in the return value rather than going to
        // a log sink, since the loader runs where no `@MainActor` sink can be reached.
        // `DetailsMetadataCache` logs it, rate-limited per path.
        #expect(load.metadata == nil)
        // The two things a breadcrumb has to carry: which item, and why.
        #expect(load.failure?.contains(path) == true)
        #expect(load.failure?.contains("permission") == true)
    }

    @Test func aPathThatIsSimplyNotThereIsNotReportedAsAFailure() {
        // The common case: the selection cleared, or the item was just moved or deleted. Not a
        // failure, so no warning in the log.
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
