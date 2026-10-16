import Foundation
import Testing
import Sync
import FileExplorerTestSupport
@testable import Dashboard

/// **The Details sidebar's folder size does not walk into a folder whose cloud app never answers**
/// — see `DetailsSidebar.computeDirectorySizeString(path:fileManager:)`.
///
/// The real disk, behind `UnansweredRealDisk`: one folder in the tree is dataless and listing it
/// parks until the test lets the provider answer. Paths are canonical (`/private/var/…`), because
/// that is how the real enumerator spells what it yields, and the double knows its folder by path.
@Suite struct DetailsSidebarUnansweredTests {

    /// `<scratch>/folder` holding `a.bin` (4,000 bytes) and `Archive/old.bin` (6,000 bytes), with
    /// `Archive` the folder that does not answer.
    static func fixture(answering: Bool = false, deadline: Duration = .milliseconds(250))
        throws -> (disk: UnansweredRealDisk, folder: URL, archive: URL, scratch: URL) {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailsSidebarUnansweredTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let canonical = try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? raw.path
        let scratch = URL(fileURLWithPath: canonical, isDirectory: true)
        let folder = scratch.appendingPathComponent("folder")
        let archive = folder.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4000).write(to: folder.appendingPathComponent("a.bin"))
        try Data(repeating: 0x41, count: 6000).write(to: archive.appendingPathComponent("old.bin"))
        let disk = UnansweredRealDisk(unanswered: archive.path, reads: .init(deadline: deadline))
        if answering { disk.answerAtOnce() }
        return (disk, folder, archive, scratch)
    }

    /// **The total skips the folder and says it is a floor** — "+", as for a locked subfolder.
    @Test func aFolderInsideThatNeverAnswersLeavesTheTotalAFloor() async throws {
        let f = try Self.fixture()
        defer { f.disk.finish(removing: f.archive.path); try? FileManager.default.removeItem(at: f.scratch) }

        let size = await DetailsSidebar.computeDirectorySizeString(path: f.folder.path, fileManager: f.disk)
        // "In time" as "while the provider is still parked", never against a clock — see
        // `UnansweredFolderListingTests.offThePool`.
        #expect(f.disk.isParked, "it came back only once the provider answered")
        let text = try #require(size)
        #expect(text.hasSuffix("+"), "a total that left a folder out did not say so: \(text)")
        #expect(text.contains("4"), "4,000 bytes outside the folder: \(text)")
        #expect(f.disk.providerReads == 1)
    }

    /// The folder itself: nothing could be read, so there is no number — "--", never "Zero KB".
    @Test func aSelectedFolderThatNeverAnswersHasNoSize() async throws {
        let f = try Self.fixture()
        defer { f.disk.finish(removing: f.archive.path); try? FileManager.default.removeItem(at: f.scratch) }

        let size = await DetailsSidebar.computeDirectorySizeString(path: f.archive.path, fileManager: f.disk)
        #expect(f.disk.isParked, "it came back only once the provider answered")
        #expect(size == nil)
    }

    /// The walk suspends while the provider is asked: on a one-thread executor, a job queued behind
    /// it still runs.
    @Test func theSizeWalkHoldsNoThreadWhileItAsks() async throws {
        let f = try Self.fixture(deadline: .seconds(300))
        defer { f.disk.finish(removing: f.archive.path); try? FileManager.default.removeItem(at: f.scratch) }

        let walk = await OneThreadExecutor.letsAnotherJobRun(whileAsking: f.disk) {
            await DetailsSidebar.computeDirectorySizeString(path: f.folder.path, fileManager: f.disk)
        }
        #expect(walk.asked, "the provider was never asked")
        #expect(walk.ranWhileWaiting, "the size walk held its thread while the provider was asked")
        #expect(walk.value?.contains("10") == true, "the answered folder was not counted: \(walk.value ?? "nil")")
    }

    /// The control: answered, the folder is walked like any other and the total is whole.
    @Test func aFolderInsideThatAnswersIsCounted() async throws {
        let f = try Self.fixture(answering: true, deadline: .seconds(300))
        defer { f.disk.finish(removing: f.archive.path); try? FileManager.default.removeItem(at: f.scratch) }

        let size = try #require(await DetailsSidebar.computeDirectorySizeString(path: f.folder.path, fileManager: f.disk))
        #expect(!size.hasSuffix("+"), "a folder that answered was left out: \(size)")
        #expect(size.contains("10"), "10,000 bytes across both: \(size)")
        #expect(f.disk.providerReads == 1)
    }
}
