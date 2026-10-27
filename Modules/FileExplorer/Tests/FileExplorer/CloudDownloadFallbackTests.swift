import Foundation
import Testing
@testable import FileExplorer

/// A Download the system refuses is not silent (BR1).
///
/// **The row menu's and File ▸ Download's click used to do nothing on screen** when the request
/// threw — the only trace was a log line — while the preview's Download and Compare Copies revealed
/// the file in Finder. It now does what those do. A plain local file is the refused case here: it is
/// not a ubiquitous item, so `startDownloadingUbiquitousItem` throws for it.
@MainActor
@Suite struct CloudDownloadFallbackTests {

    @Test func aRefusedDownloadRevealsTheFileInsteadOfDoingNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.txt")
        try Data("here".utf8).write(to: file)
        let channel = NotificationCenter()
        var posted = 0
        let token = channel.addObserver(forName: .cloudDownloadRequested, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { channel.removeObserver(token) }
        var revealed: [URL] = []

        let requested = CloudDownloadRequest.requestDownload(
            path: file.path, name: "local.txt", from: .singleSource, through: channel,
            whenUnavailable: { revealed.append($0) })

        #expect(!requested, "premise: a local file is not a ubiquitous item, so the request is refused")
        #expect(revealed.map(\.path) == [file.path], "a refused Download did nothing on screen")
        #expect(posted == 0, "a watch was started for a download nobody started")
    }
}

/// Download All hands its files to the pane's badge watch, as one file's Download does, and a
/// folder whose provider refused everything is revealed rather than left silent.
@MainActor
@Suite struct FolderDownloadRequestTests {

    /// The requests a pane on `channel` would latch.
    @MainActor private final class Recorder {
        var accepted: [String] = []
        var heardOtherPanes = 0
    }

    private func listening(on channel: NotificationCenter, as pane: PaneToken) -> (Recorder, NSObjectProtocol) {
        let recorder = Recorder()
        let token = channel.addObserver(forName: .cloudDownloadRequested, object: nil, queue: nil) { note in
            if let request = CloudDownloadRequest.accepted(from: note, paneToken: pane) {
                MainActor.assumeIsolated { recorder.accepted.append(request.path) }
            } else {
                MainActor.assumeIsolated { recorder.heardOtherPanes += 1 }
            }
        }
        return (recorder, token)
    }

    @Test func everyRequestedFileIsWatchedByThePaneThatAsked() async {
        let channel = NotificationCenter()
        let (recorder, token) = listening(on: channel, as: .left)
        defer { channel.removeObserver(token) }
        var revealed: [URL] = []

        let result = await CloudDownloadRequest.requestFolderDownload(
            path: "/P/Folder", name: "Folder", from: .left, through: channel,
            walk: { _ in .init(requested: ["/P/Folder/a", "/P/Folder/sub/b"], refused: ["/P/Folder/c"], unreadable: 0) },
            whenUnavailable: { revealed.append($0) })

        #expect(result.requested.count == 2)
        #expect(recorder.accepted == ["/P/Folder/a", "/P/Folder/sub/b"])
        #expect(recorder.heardOtherPanes == 0)
        #expect(revealed.isEmpty, "a folder some of whose files were requested was revealed in Finder")
    }

    @Test func aHugeFolderIsWatchedOnlyUpToTheCap() async {
        let channel = NotificationCenter()
        let (recorder, token) = listening(on: channel, as: .singleSource)
        defer { channel.removeObserver(token) }
        let files = (0..<(CloudDownloadRequest.folderWatchCap + 50)).map { "/P/F/\($0)" }

        let result = await CloudDownloadRequest.requestFolderDownload(
            path: "/P/F", name: "F", from: .singleSource, through: channel,
            walk: { _ in .init(requested: files, refused: [], unreadable: 0) },
            whenUnavailable: { _ in })

        #expect(result.requested.count == files.count, "the cap limits the watches, never the downloads")
        #expect(recorder.accepted == Array(files.prefix(CloudDownloadRequest.folderWatchCap)))
    }

    @Test func aFolderWhoseEveryFileWasRefusedIsRevealed() async {
        let channel = NotificationCenter()
        let (recorder, token) = listening(on: channel, as: .right)
        defer { channel.removeObserver(token) }
        var revealed: [URL] = []

        await CloudDownloadRequest.requestFolderDownload(
            path: "/P/Folder", name: "Folder", from: .right, through: channel,
            walk: { _ in .init(requested: [], refused: ["/P/Folder/a"], unreadable: 0) },
            whenUnavailable: { revealed.append($0) })

        #expect(revealed.map(\.path) == ["/P/Folder"])
        #expect(recorder.accepted.isEmpty, "a watch was started for a download nobody started")
    }

    /// A folder with nothing cloud-only in it is a quiet no-op: nothing to reveal, nothing to watch.
    @Test func aFolderWithNothingCloudOnlyDoesNothingOnScreen() async {
        let channel = NotificationCenter()
        let (recorder, token) = listening(on: channel, as: .left)
        defer { channel.removeObserver(token) }
        var revealed: [URL] = []

        await CloudDownloadRequest.requestFolderDownload(
            path: "/P/Folder", name: "Folder", from: .left, through: channel,
            walk: { _ in .init(requested: [], refused: [], unreadable: 0) },
            whenUnavailable: { revealed.append($0) })

        #expect(revealed.isEmpty)
        #expect(recorder.accepted.isEmpty)
    }
}
