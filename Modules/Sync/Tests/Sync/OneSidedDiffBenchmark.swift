import Foundation
import Testing
@testable import Sync

/// Times `computeDifferences` on a pair shaped like his Home vs Dropbox Documents scan: 200,001
/// entries against 13,766, nearly all of them on one side only, collapsing to about 200 rows.
///
/// Inert unless `SYNCCLOUD_DIFF_BENCHMARK` is set, so an ordinary `swift test` — and CI — never
/// runs it:
///
/// ```sh
/// SYNCCLOUD_DIFF_BENCHMARK=1 swift test -c release --filter OneSidedDiffBenchmark
/// ```
///
/// Synthetic rather than real (`TreeWalkBenchmark.diffPhase` takes real roots) because the shape
/// is the point, and walking a real Home folder unbounded is minutes of disk. Both roots exist on
/// disk, as his do, so a path probe walks into a real folder before it misses.
@Suite(.serialized) struct OneSidedDiffBenchmark {

    private static var enabled: Bool { ProcessInfo.processInfo.environment["SYNCCLOUD_DIFF_BENCHMARK"] != nil }

    /// `count` entries under `tops` top-level folders, three folder levels deep with files at the
    /// bottom. Every twentieth folder name carries an accent, so composition has decomposing to do.
    private static func tree(under root: URL, tops: [String], count: Int) -> [String: FileDiffEngine.FileInfo] {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var map: [String: FileDiffEngine.FileInfo] = [:]
        map.reserveCapacity(count)
        func add(_ key: String, dir: Bool) {
            guard map.count < count else { return }
            map[key] = FileDiffEngine.FileInfo(url: root.appendingPathComponent(key, isDirectory: dir),
                                               modificationDate: date, fileSize: dir ? nil : key.utf8.count,
                                               isDirectory: dir)
        }
        var serial = 0
        outer: while map.count < count {
            for top in tops {
                add(top, dir: true)
                for a in 0..<6 {
                    let one = "\(top)/\(serial % 20 == 0 ? "Caf\u{00E9}" : "folder")-\(serial)-\(a)"
                    add(one, dir: true)
                    for b in 0..<4 {
                        let two = "\(one)/sub-\(b)"
                        add(two, dir: true)
                        for c in 0..<8 { add("\(two)/file-\(c).dat", dir: false) }
                    }
                }
                serial += 1
                if map.count >= count { break outer }
            }
        }
        return map
    }

    @Test func homeShapedPair() throws {
        guard Self.enabled else { return }
        let base = try makeCanonicalTempRoot(prefix: "OneSidedDiffBenchmark")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let documents = base.appendingPathComponent("documents", isDirectory: true)
        for root in [home, documents] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let homeTops = ["Library", "Pictures", "Music", "Movies", "Developer", "Downloads", "Public",
                        "Applications", "Sites", "Projects"] + (0..<30).map { "Folder \($0)" }
        let documentTops = ["Finance", "Health", "Travel", "Work", "Home", "Taxes", "Projects"]
                         + (0..<23).map { "Box \($0)" }
        let left = Self.tree(under: home, tops: homeTops, count: 200_001)
        let right = Self.tree(under: documents, tops: documentTops, count: 13_766)
        let l = CloudProvider(id: "l", displayName: "Home", imageName: "", rootPath: home.path, type: .iCloud)
        let r = CloudProvider(id: "r", displayName: "Dropbox", imageName: "", rootPath: documents.path, type: .dropBox)

        var times: [Double] = []
        var rows = 0
        for _ in 0..<6 {
            let start = CFAbsoluteTimeGetCurrent()
            let d = FileDiffEngine.computeDifferences(left: l, leftURL: home, right: r, rightURL: documents,
                                                      leftFilesInfo: left, rightFilesInfo: right,
                                                      caseInsensitive: true, dateToleranceSeconds: 1)
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            rows = d.count
        }
        let sorted = times.sorted()
        let runs = times.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        print("[bench] computeDifferences \(left.count) vs \(right.count) entries → \(rows) rows: "
              + "median \(String(format: "%.0f", sorted[sorted.count / 2])) ms (runs \(runs) ms)")
    }
}
