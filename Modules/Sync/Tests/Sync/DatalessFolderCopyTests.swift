import Foundation
import Testing
@testable import Sync

/// A copy of a folder whose contents aren't on this Mac asks its cloud app first, and refuses when
/// it doesn't answer. The copy's walk lists every folder it reaches, and a dataless folder's
/// listing blocks for good when its provider isn't running. The copy has no deadline, Cancel isn't
/// heard while a listing blocks, and it runs on the serial operation queue, so one such copy would
/// stall every file operation after it. `UnansweredFolderDisk` parks that listing until released;
/// its `copyItem` never parks, so the assertion is that the copy is refused before anything is staged.
@Suite struct DatalessFolderCopyTests {

    @Test(.parksAThread) func copyingAFolderWhoseCloudAppDoesNotAnswerIsRefused() throws {
        let f = UnansweredFolderTests.Fixture(root: "/dataless-copy")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        defer { gate.release.signal() }
        let landing = URL(fileURLWithPath: f.root + "/elsewhere")

        // The dataless folder and the folder holding it are both refused, naming the folder that
        // didn't answer.
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

    /// The control: once the folder's app answers, the copy goes ahead (the check defers a copy,
    /// never drops one), and a folder with nothing dataless in it isn't held. The mock copies a
    /// folder as its own entry only, so the folder's arrival is what is read.
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
