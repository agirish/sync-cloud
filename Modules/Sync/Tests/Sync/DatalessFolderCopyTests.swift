import Foundation
import Testing
@testable import Sync

/// **A copy of a folder whose contents are not on this Mac asks its cloud app first, and refuses
/// when it does not answer** (FR34).
///
/// The copy's recursive walk lists every folder it reaches, and a dataless folder's listing blocks
/// for good when its provider is not running. The copy has no deadline, Cancel is heard only in
/// callbacks that never fire while a listing blocks, and it runs on the serial operation queue —
/// so one such copy stalled every file operation after it. The disk here is
/// `UnansweredFolderDisk`: its dataless folder parks the listing that reaches it until released.
/// Its `copyItem` is the mock's and never parks, so without the check the copy "succeeds"; the
/// assertion is that it is refused instead, before anything is staged.
@Suite struct DatalessFolderCopyTests {

    @Test(.parksAThread) func copyingAFolderWhoseCloudAppDoesNotAnswerIsRefused() throws {
        let f = UnansweredFolderTests.Fixture(root: "/dataless-copy")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        defer { gate.release.signal() }
        let landing = URL(fileURLWithPath: f.root + "/elsewhere")

        // The dataless folder itself, and the folder holding it: both are refused, by the name of
        // the folder that did not answer.
        for source in [f.unanswered, f.root + "/home/Cloud"] {
            let sourceURL = URL(fileURLWithPath: source)
            let target = landing.appendingPathComponent(sourceURL.lastPathComponent)
            #expect(throws: FileSyncManager.FileOperationError.folderNotAnswered(folderName: "Archive")) {
                try FileSyncManager.safeCopyItem(at: sourceURL, to: target, fileManager: disk)
            }
            #expect(!disk.fileExists(atPath: target.path), "the refused copy put \(target.lastPathComponent) at the destination")
            #expect(try disk.listing(of: landing).urls.isEmpty, "the refused copy left something in the destination folder")
        }
        #expect(disk.providerReads == 1, "the folder's cloud app was asked more than once")
    }

    /// The control: once the folder's app answers, it is on this Mac and the copy goes ahead — the
    /// check defers a copy, it never drops one. And a folder with nothing dataless in it is not held.
    /// The mock copies a folder as its own entry only (it stores flat paths), so the folder's
    /// arrival is what is read.
    @Test(.parksAThread) func aFolderThatAnswersIsCopied() async throws {
        let f = UnansweredFolderTests.Fixture(root: "/dataless-copy-answered")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        let landing = URL(fileURLWithPath: f.root + "/elsewhere")

        try FileSyncManager.safeCopyItem(at: URL(fileURLWithPath: f.root + "/home/Notes"),
                                         to: landing.appendingPathComponent("Notes"), fileManager: disk)
        #expect(disk.fileExists(atPath: landing.appendingPathComponent("Notes").path))
        #expect(disk.providerReads == 0, "a folder with nothing dataless in it asked a cloud app")

        #expect(throws: FileSyncManager.FileOperationError.folderNotAnswered(folderName: "Archive")) {
            try FileSyncManager.safeCopyItem(at: URL(fileURLWithPath: f.unanswered),
                                             to: landing.appendingPathComponent("Archive"), fileManager: disk)
        }
        // The app answers at last: the read it was holding comes back and leaves the registry.
        gate.release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while disk.datalessFolderReads.isOutstanding(f.unanswered), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(!disk.datalessFolderReads.isOutstanding(f.unanswered), "the late answer never came back")
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")

        try FileSyncManager.safeCopyItem(at: URL(fileURLWithPath: f.unanswered),
                                         to: landing.appendingPathComponent("Archive"), fileManager: disk)
        #expect(disk.fileExists(atPath: landing.appendingPathComponent("Archive").path))
    }
}
