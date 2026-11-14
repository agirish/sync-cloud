import Foundation
import Testing
@testable import SyncCloudCLICore

/// The one production default in `CommandRunner.Environment` every other CommandRunner test
/// overrides: `performFileSync` reads "an existing destination was replaced" from "a previous
/// version reached the Trash", which feeds the summary's "recoverable from the Trash" line.
///
/// Known and open (docs/backports.md): on a Trash-less volume (exFAT, most SMB) the replace still
/// happens but `trashed` is nil, so the CLI under-reports replacements where recovery matters.
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
        let dst = root.appendingPathComponent("dst.txt")
        // The overwrite below trashes the old destination as a `.rollback_<UUID>` backup. This
        // Trash is inside `root`, so no run leaves a stray file in the real one.
        let trash = ScratchTrash(in: root)
        try Data("new contents".utf8).write(to: src)

        let env = makeDefaultEnvironment()

        // A fresh copy replaced nothing: the summary must not promise a Trash recovery that
        // does not exist.
        let fresh = try env.performFileSync(src, dst, trash)
        #expect(!fresh, "a copy onto an empty destination reported a replacement")
        #expect(try String(contentsOf: dst, encoding: .utf8) == "new contents")
        #expect(trash.names.isEmpty, "a copy onto an empty destination trashed something: \(trash.names)")

        // Overwriting an existing destination: the previous version goes to the Trash and the
        // seam says so — the fact the recoverable-from-Trash line rests on.
        try Data("old contents".utf8).write(to: dst)
        let replaced = try env.performFileSync(src, dst, trash)
        #expect(replaced, "an overwrite of an existing destination reported no replacement")
        #expect(trash.names.count == 1 && trash.names.allSatisfy { $0.hasPrefix(".rollback_") },
                "the replaced file's backup never reached the test's own Trash: \(trash.names)")
        #expect(try String(contentsOf: dst, encoding: .utf8) == "new contents",
                "the destination does not hold the source's contents after the sync")
    }
}
