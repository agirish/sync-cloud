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
