import Foundation
import Testing
@testable import SyncCloudCLICore

/// The one production default in `CommandRunner.Environment` that carries a SEMANTIC mapping.
/// Every CommandRunner test overrides the seams, so the shipped `performFileSync` default —
/// "an existing destination was replaced" inferred from "a previous version reached the Trash"
/// (`performFileSyncIO(...).trashed != nil`) — never executed in any suite. That inference feeds
/// `recordCopied(replacedExisting:)`, which drives the summary's "previous versions are
/// recoverable from the Trash" line.
///
/// Known and deliberately open (docs/backports.md tracks the review): on a Trash-less volume
/// (exFAT, most SMB) the replace still happens but `trashed` is nil, so the CLI under-reports
/// replacements exactly where recovery matters. This suite pins the mapping's two honest answers
/// on an ordinary volume, so the seam is at least no longer dead code — fixing the Trash-less
/// case means changing the mapping, and now something fails when it changes silently.
@Suite struct EnvironmentDefaultsTests {

    private func makeDefaultEnvironment() -> CommandRunner.Environment {
        CommandRunner.Environment(
            discoverSnapshot: { AppSettingsSnapshot(providers: [], ignoreGoogleDriveNewerDateOnly: false) },
            logError: { _ in })
    }

    @Test func theDefaultCopySeamAnswersReplacementThroughTheTrash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src.txt")
        // The overwrite below routes the old destination through the real `trashItem`, which
        // lands in the developer's actual Trash — one stray file per run, forever, that the
        // temp-dir cleanup cannot reach. The run-unique name is what makes the sweep safe: only
        // a file THIS run created can match it.
        let marker = "cli-env-dst-\(UUID().uuidString)"
        let dst = root.appendingPathComponent("\(marker).txt")
        defer {
            let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent.hasPrefix(marker) {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
        try Data("new contents".utf8).write(to: src)

        let env = makeDefaultEnvironment()

        // A fresh copy replaced nothing: the summary must not promise a Trash recovery that
        // does not exist.
        let fresh = try env.performFileSync(src, dst, .default)
        #expect(!fresh, "a copy onto an empty destination reported a replacement")
        #expect(try String(contentsOf: dst, encoding: .utf8) == "new contents")

        // Overwriting an existing destination: the previous version goes to the Trash and the
        // seam says so — the fact the recoverable-from-Trash line rests on.
        try Data("old contents".utf8).write(to: dst)
        let replaced = try env.performFileSync(src, dst, .default)
        #expect(replaced, "an overwrite of an existing destination reported no replacement")
        #expect(try String(contentsOf: dst, encoding: .utf8) == "new contents",
                "the destination does not hold the source's contents after the sync")
    }
}
