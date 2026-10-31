import Foundation
import Testing
@testable import Sync

/// **The `folder(_:holds:)` split preserves behaviour** — the proof `CLAUDE.md` §5 asks of a
/// refactor. The folder watcher needed the function's string-math half on its own
/// (`listedRoots` / `tail` / `listedTail`), so `folder(_:holds:)` became that half plus its
/// symlink-resolving second try. `reference` below is the body as it stood before the split,
/// verbatim; every input in the matrix must get the same answer from both.
///
/// The matrix crosses folders and paths spelled every way the callers spell them (`~`, trailing
/// slash, `/var` against `/private/var`, the root itself, a sibling sharing a prefix, empty), a link
/// table with a container and without, followed-link targets, and real symlinks on disk so the
/// resolving branch runs.
@Suite struct FolderHoldsSplitEquivalenceTests {

    private static func reference(_ folder: String, holds path: String,
                                  links: PathBoundary.LinkedFolders, linkTargets: Set<String>) -> Bool {
        let expanded = PathBoundary.normalizedRoot(folder)
        guard !expanded.isEmpty, !path.isEmpty else { return false }
        let roots = [expanded] + linkTargets
        var listed = roots
        for (container, targets) in links
        where roots.contains(where: { PathBoundary.lexicalRelativize(container, under: $0) != nil }) {
            listed.append(contentsOf: targets.values)
        }
        func lists(_ candidate: String) -> Bool {
            listed.contains { PathBoundary.lexicalRelativize(candidate, under: $0) != nil }
        }
        let raw = PathBoundary.normalizedRoot(path)
        if lists(raw) { return true }
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        return resolved != raw && lists(resolved)
    }

    @Test func everyInputGetsTheAnswerItGotBeforeTheSplit() throws {
        let fm = FileManager.default
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("synccloud-holds-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: base) }
        // A real tree with a folder link out of the root, so resolution has something to resolve.
        try fm.createDirectory(atPath: base + "/root/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/outside/deep", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base + "/root/link", withDestinationPath: base + "/outside")
        let privateBase = URL(fileURLWithPath: base).resolvingSymlinksInPath().path  // /var → /private/var off
        let realBase = FolderWatcher.resolve(base) ?? base                            // /private/var/…

        let folders = ["", "/", base + "/root", base + "/root/", realBase + "/root", base + "/root/sub",
                       base + "/outside", "~", "~/Documents", "/Users/x/Library/Mobile Documents/com~apple~CloudDocs"]
        let paths = ["", "/", base + "/root", base + "/root/sub/f.txt", base + "/rootx/f.txt",
                     base + "/root/link/deep/f.txt", base + "/root/link/deep", realBase + "/root/sub/f.txt", privateBase + "/root/sub",
                     base + "/outside/deep", "~/Documents/Tax/a.pdf", "/Users/x/Documents/Tax/a.pdf",
                     "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Documents/Tax/a.pdf", base + "/root/sub/"]
        let tables: [PathBoundary.LinkedFolders] = [
            [:],
            ["/Users/x/Library/Mobile Documents/com~apple~CloudDocs": ["Documents": "/Users/x/Documents"]],
            [base + "/root": ["link": base + "/outside"]],
        ]
        let targetSets: [Set<String>] = [[], [base + "/outside"], [realBase + "/outside", "/Users/x/Documents"]]

        var compared = 0
        var differ: [String] = []
        for folder in folders {
            for path in paths {
                for links in tables {
                    for targets in targetSets {
                        let before = Self.reference(folder, holds: path, links: links, linkTargets: targets)
                        let after = FileSyncManager.folder(folder, holds: path, links: links, linkTargets: targets)
                        compared += 1
                        if before != after { differ.append("\(folder) holds \(path) [\(links.count) table, \(targets.count) targets]: \(before) → \(after)") }
                    }
                }
            }
        }
        #expect(compared == folders.count * paths.count * tables.count * targetSets.count)
        #expect(differ.isEmpty, "the split changed \(differ.count) of \(compared) answers:\n\(differ.prefix(10).joined(separator: "\n"))")
        // And the matrix is not one-sided: both answers occur, through both branches.
        #expect(Self.reference(base + "/root", holds: base + "/root/sub/f.txt", links: [:], linkTargets: []))
        #expect(!Self.reference(base + "/root", holds: base + "/rootx/f.txt", links: [:], linkTargets: []))
        // An existing path through the link: `resolvingSymlinksInPath` resolves only what is there.
        #expect(Self.reference(base + "/outside", holds: base + "/root/link/deep", links: [:], linkTargets: []),
                "no input reached the resolving branch — the matrix does not test it")
    }
}
