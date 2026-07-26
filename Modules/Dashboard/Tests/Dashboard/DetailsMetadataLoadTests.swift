import Testing
import Foundation
@testable import Dashboard

/// Pins that the Details inspector's stat distinguishes "there is nothing to show" from "I was not
/// allowed to look".
///
/// `loadMetadata` answers both with nil, and the inspector renders both as an empty card — so the
/// failure case has to leave a breadcrumb, or a permissions/IO failure on a cloud path is
/// indistinguishable from an empty selection with nothing recorded anywhere. Follows
/// `FolderJump.siblings`, which logs the same class of failure through an injected closure.
///
/// `@MainActor` because `loadMetadata` is a static on a SwiftUI `View`, which isolates the whole
/// type — calling it off the main actor traps at runtime rather than failing to compile.
@MainActor
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
        var logged: [String] = []
        let path = "/Volumes/Cloud/Statements/locked.pdf"

        let metadata = DetailsSidebar.loadMetadata(
            for: path,
            fileManager: UnreadableAttributesFileManager(),
            logError: { logged.append($0) })

        // The inspector still falls silent — the card has nothing to render and this is not worth
        // failing a UI over — but the reason is no longer lost.
        #expect(metadata == nil)
        #expect(logged.count == 1)
        // The two things a breadcrumb has to carry: which item, and why.
        #expect(logged.first?.contains(path) == true)
        #expect(logged.first?.contains("permission") == true)
    }

    @Test func aPathThatIsSimplyNotThereIsNotReportedAsAFailure() {
        // The common case by far: the selection cleared, or the item was just moved/deleted. That
        // is not a failure and must not put a warning in the log every time it happens.
        var logged: [String] = []
        let metadata = DetailsSidebar.loadMetadata(
            for: "/no/such/path-\(UUID().uuidString)",
            logError: { logged.append($0) })

        #expect(metadata == nil)
        #expect(logged.isEmpty)
    }

    @Test func areadableItemLoadsItsMetadataAndSaysNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("details-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var logged: [String] = []
        let metadata = DetailsSidebar.loadMetadata(for: url.path, logError: { logged.append($0) })

        #expect(metadata?.name == url.lastPathComponent)
        #expect(metadata?.isDirectory == false)
        #expect(logged.isEmpty)
    }
}
