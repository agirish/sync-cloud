import Foundation
import Testing
@testable import Sync

/// **A one-sided row's path is composed with the item's own type, and is byte-identical to the
/// path the engine composed before.**
///
/// `computeDifferences` builds the other side's expected path for every entry present on one side
/// only — about 200,000 of them per scan of his Home pair, before the collapse keeps the top-level
/// folders. `appendingPathComponent(_:)` without `isDirectory:` asks the file system whether the
/// result is a directory, so each of them cost a probe. The hint answers that from what the entry
/// already knows.
///
/// **Composition stays URL composition.** It decomposes precomposed names such as `é` where plain
/// concatenation keeps them, so swapping it for `root + "/" + key` would change the bytes of
/// thousands of row paths on a non-ASCII tree. The hint only decides a trailing slash, which `.path`
/// drops — `theHintNeverChangesThePath` pins that across names, spellings of the root and what is
/// really on disk, and `rowPathsAreTheOnesTheProbeComposed` pins it through the engine, the re-aimed
/// rows under a name-conflicted folder included.
@Suite struct OneSidedRowPathTests {

    /// Names that have each broken some path or key in this app before: precomposed and decomposed
    /// accents, a name opening with a combining mark, Hangul, a trailing space, characters URL
    /// encoding treats specially — at the top and deep down.
    private static let names = [
        "plain.txt", "caf\u{00E9}.txt", "cafe\u{0301}.txt", "\u{0301}lead", "한국어/문서.txt", "Ω≈ç√/x",
        "trailing /x.txt", "a%20b.txt", "a:b.txt", "#hash", "q?x", "semi;colon", ".hidden",
        "deep/er/still/caf\u{00E9}/x",
    ]

    /// Two roots holding something real at a few of the paths composed under them, so the unhinted
    /// form's probe finds each: under the right a directory, a package, a link to a directory and a
    /// file; under the left a directory where a right-only FILE's path lands. Each root has a link to
    /// it beside it. Removed again if building it fails, since no caller's `defer` exists yet.
    private static func roots() throws -> (base: URL, right: URL, left: URL, onDisk: [String]) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "OneSidedRowPathTests")
        do {
            let right = base.appendingPathComponent("root", isDirectory: true)
            try fm.createDirectory(at: right.appendingPathComponent("existingDir/caf\u{00E9}"), withIntermediateDirectories: true)
            try fm.createDirectory(at: right.appendingPathComponent("Thing.app/Contents"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: right.appendingPathComponent("linkToDir"),
                                      withDestinationURL: right.appendingPathComponent("existingDir"))
            try Data("x".utf8).write(to: right.appendingPathComponent("existingFile.txt"))
            let left = base.appendingPathComponent("left", isDirectory: true)
            try fm.createDirectory(at: left.appendingPathComponent("re\u{0301}sume\u{0301}.pdf"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: base.appendingPathComponent("linkedRoot"), withDestinationURL: right)
            try fm.createSymbolicLink(at: base.appendingPathComponent("linkedLeft"), withDestinationURL: left)
            return (base, right, left, ["existingDir", "existingDir/caf\u{00E9}", "Thing.app", "linkToDir", "existingFile.txt"])
        } catch {
            try? fm.removeItem(at: base)
            throw error
        }
    }

    /// A root three ways: canonical, its `/var` spelling (the temp directory's `/private/var` is a
    /// link from `/var`), and through the link beside it.
    private static func spellings(of real: URL, link: String, base: URL) throws -> [URL] {
        let varSpelling = real.path.hasPrefix("/private/") ? String(real.path.dropFirst("/private".count)) : real.path
        let all = [real, URL(fileURLWithPath: varSpelling, isDirectory: true),
                   base.appendingPathComponent(link, isDirectory: true)]
        try #require(Set(all.map(\.path)).count == 3,
                     "premise: three different spellings — this temp directory is not under /private: \(all.map(\.path))")
        return all
    }

    @Test func theHintNeverChangesThePath() throws {
        let fixture = try Self.roots()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // Premise: the unhinted form really does consult the disk — a directory comes back with a
        // trailing slash, a missing path does not. Without this the hint would save nothing.
        #expect(fixture.right.appendingPathComponent("existingDir").hasDirectoryPath)
        #expect(!fixture.right.appendingPathComponent("plain.txt").hasDirectoryPath)

        var checked = 0
        let roots = try Self.spellings(of: fixture.right, link: "linkedRoot", base: fixture.base)
            + Self.spellings(of: fixture.left, link: "linkedLeft", base: fixture.base)
        for root in roots {
            for name in Self.names + fixture.onDisk {
                let probed = Array(root.appendingPathComponent(name).path.utf8)
                for isDirectory in [false, true] {
                    let hinted = Array(root.appendingPathComponent(name, isDirectory: isDirectory).path.utf8)
                    #expect(hinted == probed, "\(name.debugDescription) under \(root.path), hinted \(isDirectory)")
                    checked += 1
                }
            }
        }
        #expect(checked == 6 * (Self.names.count + fixture.onDisk.count) * 2)
        // And the reason composition stays URL composition: concatenation is not the same bytes.
        let precomposed = fixture.right.appendingPathComponent("caf\u{00E9}.txt", isDirectory: false).path
        #expect(Array(precomposed.utf8) != Array((fixture.right.path + "/caf\u{00E9}.txt").utf8),
                "premise: URL composition decomposes a precomposed name, so concatenation would change row paths")
    }

    /// Through the engine: every one-sided row's expected path, and the re-aimed ones under a folder
    /// whose two spellings differ invisibly, compared byte for byte with the unhinted composition the
    /// engine used before. Run on each spelling of both roots, with real things on disk at some of
    /// the composed paths — the case where the old probe found a directory and the hint now says file.
    @Test func rowPathsAreTheOnesTheProbeComposed() throws {
        let fixture = try Self.roots()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func info(_ root: URL, _ key: String, dir: Bool) -> FileDiffEngine.FileInfo {
            FileDiffEngine.FileInfo(url: root.appendingPathComponent(key, isDirectory: dir),
                                    modificationDate: date, fileSize: dir ? nil : 1, isDirectory: dir)
        }
        let left = CloudProvider(id: "L", displayName: "L", imageName: "", rootPath: "/l", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "", rootPath: "/r", type: .dropBox)

        let rightRoots = try Self.spellings(of: fixture.right, link: "linkedRoot", base: fixture.base)
        let leftRoots = try Self.spellings(of: fixture.left, link: "linkedLeft", base: fixture.base)
        for (rightRoot, leftRoot) in zip(rightRoots, leftRoots) {
            // Left-only: files and folders, some of whose expected paths EXIST under the right root
            // — `existingDir` and `Thing.app` as directories, `existingFile.txt` as a file — but are
            // absent from the right map, as a filtered or near-name-ambiguous entry would be.
            var leftInfo: [String: FileDiffEngine.FileInfo] = [:]
            // One spelling of an accented name per map: Swift compares strings by canonical
            // equivalence, so a precomposed and a decomposed `café` are ONE dictionary key — the
            // precomposed one is here, a decomposed name is on the right.
            for key in ["plain.txt", "caf\u{00E9}.txt", "한국어", "한국어/문서.txt",
                        "existingFile.txt", "trailing /x.txt"] {
                leftInfo[key] = info(leftRoot, key, dir: !key.contains("."))
            }
            leftInfo["trailing "] = info(leftRoot, "trailing ", dir: true)
            for key in ["existingDir", "Thing.app"] { leftInfo[key] = info(leftRoot, key, dir: false) }
            // The name-conflicted pair: "Docs " on the left, "Docs" on the right. The left's
            // one-sided child is re-aimed at the right's real spelling, and the right's at the left's.
            leftInfo["Docs "] = info(leftRoot, "Docs ", dir: true)
            leftInfo["Docs /left-only.txt"] = info(leftRoot, "Docs /left-only.txt", dir: false)
            var rightInfo: [String: FileDiffEngine.FileInfo] = [:]
            rightInfo["Docs"] = info(rightRoot, "Docs", dir: true)
            rightInfo["Docs/right-only.txt"] = info(rightRoot, "Docs/right-only.txt", dir: false)
            rightInfo["Ω≈ç√"] = info(rightRoot, "Ω≈ç√", dir: true)
            rightInfo["Ω≈ç√/x"] = info(rightRoot, "Ω≈ç√/x", dir: false)
            rightInfo["\u{0301}lead.txt"] = info(rightRoot, "\u{0301}lead.txt", dir: false)
            // A FILE whose path under the left root is a directory on disk (`roots()`).
            rightInfo["re\u{0301}sume\u{0301}.pdf"] = info(rightRoot, "re\u{0301}sume\u{0301}.pdf", dir: false)

            let rows = FileDiffEngine.computeDifferences(
                left: left, leftURL: leftRoot, right: right, rightURL: rightRoot,
                leftFilesInfo: leftInfo, rightFilesInfo: rightInfo,
                caseInsensitive: true, dateToleranceSeconds: 1)

            // The re-aimed rows' keys, rewritten the way `remappedPath` rewrites them.
            let reaimed = ["Docs /left-only.txt": "Docs/left-only.txt", "Docs/right-only.txt": "Docs /right-only.txt"]
            var seen: [String] = []
            var pathsChecked = 0
            for row in rows {
                switch row.type {
                case .missingOnRight:
                    let expected = rightRoot.appendingPathComponent(reaimed[row.relativePath] ?? row.relativePath).path
                    #expect(Array(row.rightItemPath.utf8) == Array(expected.utf8),
                            "\(row.relativePath.debugDescription) under \(rightRoot.path): \(row.rightItemPath)")
                    pathsChecked += 1
                case .missingOnLeft:
                    let expected = leftRoot.appendingPathComponent(reaimed[row.relativePath] ?? row.relativePath).path
                    #expect(Array(row.leftItemPath.utf8) == Array(expected.utf8),
                            "\(row.relativePath.debugDescription) under \(leftRoot.path): \(row.leftItemPath)")
                    pathsChecked += 1
                case .differentDates, .nameConflict:
                    break
                }
                seen.append(row.relativePath)
            }
            // Every row but the name conflict is one-sided, so all but one had its path checked.
            #expect(pathsChecked == 12, "\(pathsChecked) one-sided paths checked under \(rightRoot.path)")
            // Premise: every shape above produced its row — a missing row would make the loop vacuous.
            // `한국어/문서.txt` and `trailing /x.txt` collapse into their folders' rows.
            #expect(seen.sorted() == ["plain.txt", "caf\u{00E9}.txt", "한국어", "existingFile.txt", "trailing ",
                                      "existingDir", "Thing.app", "Docs ", "Docs /left-only.txt",
                                      "Docs/right-only.txt", "Ω≈ç√", "\u{0301}lead.txt",
                                      "re\u{0301}sume\u{0301}.pdf"].sorted(),
                    "\(seen.sorted())")
        }
    }
}
