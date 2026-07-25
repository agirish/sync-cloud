import Testing
import Foundation
import Events
@testable import Sync

/// Two small honesty fixes in the delete path.
@Suite struct DeleteFeedbackAndTransientClassificationTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    /// A delete gesture whose items all vanished between the scan and the click produced NOTHING:
    /// the success banner and the error report are both gated on non-empty results, so the user's
    /// press of ⌫ looked exactly like the app ignoring it.
    @MainActor
    @Test func aDeleteWhoseItemsAllVanishedSaysSoInsteadOfNothing() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Nothing at these paths — they left the disk since the tree was walked.
        manager.banner = nil

        let removed = await manager.deleteItems(at: ["/dst/a.txt", "/dst/b.txt"],
                                                fileManager: mockFM, reportsNothingToDo: true)

        #expect(removed == 0)
        #expect(manager.banner?.message == "Those 2 items were already gone")
        #expect(manager.banner?.severity == .warning)
    }

    @MainActor
    @Test func theSingularFormReadsNaturally() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        manager.banner = nil

        _ = await manager.deleteItems(at: ["/dst/only.txt"], fileManager: mockFM, reportsNothingToDo: true)

        #expect(manager.banner?.message == "That item was already gone")
    }

    /// The internal callers (duplicate resolve/merge, the review's trash) interpret a zero return
    /// themselves and post their own, better-scoped message, so the low-level banner must stay off
    /// by default or it talks over them.
    @MainActor
    @Test func theInternalCallersStayQuiet() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        manager.banner = nil

        _ = await manager.deleteItems(at: ["/dst/gone.txt"], fileManager: mockFM)

        #expect(manager.banner == nil)
    }

    /// `isTransientTrashFailure` read only the OUTERMOST error, but FileManager routinely reports a
    /// Cocoa-domain error that WRAPS the POSIX cause. A merely-busy item arriving in that shape was
    /// classified as a genuinely Trash-less volume and escalated to the permanent-delete prompt —
    /// the unrecoverable upgrade the classifier exists to prevent.
    @Test func aCocoaErrorWrappingEBUSYIsStillTransient() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(FileSyncManager.isTransientTrashFailure(wrapped))
    }

    @Test func aDoublyWrappedTransientCauseIsStillFound() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        let middle = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                             userInfo: [NSUnderlyingErrorKey: posix])
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: middle])
        #expect(FileSyncManager.isTransientTrashFailure(outer))
    }

    /// The other direction, which must not regress: a real Trash-less volume still escalates, so
    /// the permanent-delete fallback that makes those volumes usable at all keeps working.
    @Test func anUnsupportedVolumeErrorIsStillNonTransient() {
        let unsupported = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        #expect(!FileSyncManager.isTransientTrashFailure(unsupported))
        let wrappedUnsupported = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                         userInfo: [NSUnderlyingErrorKey: unsupported])
        #expect(!FileSyncManager.isTransientTrashFailure(wrappedUnsupported))
    }

    /// A cyclic underlying chain must terminate rather than spin.
    @Test func aSelfReferentialChainTerminates() {
        let a = NSMutableDictionary()
        let inner = NSError(domain: "X", code: 1, userInfo: a as? [String: Any])
        a[NSUnderlyingErrorKey] = inner
        let outer = NSError(domain: "X", code: 1, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(!FileSyncManager.isTransientTrashFailure(outer))
    }
}
