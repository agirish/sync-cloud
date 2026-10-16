import Foundation
import Testing
import Sync
import FileExplorerTestSupport
@testable import FileExplorer

/// **Edit's file rail and the filing card's item count read a folder whose cloud app does not
/// answer without hanging** — the FileExplorer half of `UnansweredListingTests` (Sync).
///
/// Both did a bare `contentsOfDirectory` on a detached task: with the app that syncs the folder not
/// running, that never returns, and each re-read — the rail re-lists after every autosave; the card
/// on every appearance — left one more thread stuck in it. Both now list through Sync's shared
/// `listing(of:)`, and ask the folder through `waitForContents` first, so the wait holds no thread.
@Suite struct UnansweredFolderListingTests {

    /// A real folder holding `note.md` and `scan.pdf`, behind a disk that calls it dataless.
    static func disk(answering: Bool = false,
                     deadline: Duration = .milliseconds(250)) throws -> (UnansweredRealDisk, String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unanswered-listing-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: folder.appendingPathComponent("note.md"))
        try Data().write(to: folder.appendingPathComponent("scan.pdf"))
        let disk = UnansweredRealDisk(unanswered: folder.path, reads: .init(deadline: deadline))
        if answering { disk.answerAtOnce() }
        return (disk, folder.path)
    }

    /// Off the main actor, on the pool, where these run. "In time" is asserted as "while the provider
    /// is still parked", never against a clock: in a full run of this package, cases that never park
    /// took 43 s.
    static func offThePool<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        await Task.detached { await body() }.value
    }

    // MARK: - The rail

    @Test func theRailCannotReadAFolderThatNeverAnswersAndSaysSo() async throws {
        let (disk, folder) = try Self.disk()
        defer { disk.finish(removing: folder) }

        let survey = await Self.offThePool {
            EditorRail.survey(in: folder, showsHidden: false, fileManager: disk, isCloudOnly: { _ in false })
        }
        #expect(disk.isParked, "it came back only once the provider answered")
        #expect(survey == EditorRail.Survey(rows: [], otherFileCount: nil),
                "a folder nobody could read was described as holding something, or nothing")
        #expect(disk.providerReads == 1)
    }

    /// The rail's own refresh suspends while the provider is asked.
    @Test func theRailsRefreshHoldsNoThreadWhileItAsks() async throws {
        let (disk, folder) = try Self.disk(deadline: .seconds(300))
        defer { disk.finish(removing: folder) }

        let refresh = await OneThreadExecutor.letsAnotherJobRun(whileAsking: disk) {
            await EditorRail.surveySuspending(in: folder, showsHidden: false, fileManager: disk)
        }
        #expect(refresh.asked, "the provider was never asked")
        #expect(refresh.ranWhileWaiting, "the refresh held its thread while the provider was asked")
        #expect(refresh.value.rows.map(\.name) == ["note.md"], "the answered folder was not listed")
        #expect(disk.providerReads == 1, "the survey after the ask asked the provider again")
    }

    /// The control: once the provider answers, the rail lists the folder as it would any other.
    @Test func theRailListsADatalessFolderThatAnswers() async throws {
        let (disk, folder) = try Self.disk(answering: true, deadline: .seconds(300))
        defer { disk.finish(removing: folder) }

        let survey = await Self.offThePool {
            await EditorRail.surveySuspending(in: folder, showsHidden: false, fileManager: disk)
        }
        #expect(survey.rows.map(\.name) == ["note.md"])
        #expect(disk.providerReads == 1)
    }

    // MARK: - The filing card's peek

    @Test func thePeekPublishesNothingForAFolderThatNeverAnswers() async throws {
        let (disk, folder) = try Self.disk()
        defer { disk.finish(removing: folder) }

        let count = await Self.offThePool { await DestinationPeek.itemCount(atPath: folder, fileManager: disk) }
        #expect(disk.isParked, "it came back only once the provider answered")
        #expect(count == nil, "a count was published for a folder nobody could read")
        #expect(disk.providerReads == 1)
    }

    /// The peek suspends while the provider is asked. (Its listing then runs in a detached task of
    /// its own, which this harness cannot see into — so this pins the ask, not the listing.)
    @Test func thePeekHoldsNoThreadWhileItAsks() async throws {
        let (disk, folder) = try Self.disk(deadline: .seconds(300))
        defer { disk.finish(removing: folder) }

        let peek = await OneThreadExecutor.letsAnotherJobRun(whileAsking: disk) {
            await DestinationPeek.itemCount(atPath: folder, fileManager: disk)
        }
        #expect(peek.asked, "the provider was never asked")
        #expect(peek.ranWhileWaiting, "the peek held its thread while the provider was asked")
        #expect(peek.value == 2)
    }

    @Test func thePeekCountsADatalessFolderThatAnswers() async throws {
        let (disk, folder) = try Self.disk(answering: true, deadline: .seconds(300))
        defer { disk.finish(removing: folder) }

        let count = await Self.offThePool { await DestinationPeek.itemCount(atPath: folder, fileManager: disk) }
        #expect(count == 2)
    }
}
