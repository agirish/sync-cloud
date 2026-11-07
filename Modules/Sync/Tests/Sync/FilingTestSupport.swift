import Foundation
import Testing
@testable import Sync

// Fixtures the filing, people and survey suites share.

/// Writes `bytes` copies of `fill` to `url`, creating its folder first.
func writeFilingFile(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
    try writeFilingFile(url, Data(repeating: fill, count: bytes))
}

func writeFilingFile(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

/// A temp root holding `filed` (and `loose`, when given) as `bytes`, and an `index` folder whose
/// content-hash index records `filed`'s byte hash, as a duplicates scan leaves it.
func indexedTree(prefix: String, filed: String, loose: String? = nil,
                 bytes: Data = Data(repeating: 0x50, count: 4096))
    async throws -> (root: URL, indexDir: URL, filed: URL, hex: String) {
    let root = try makeCanonicalTempRoot(prefix: prefix)
    let indexDir = root.appendingPathComponent("index")
    try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
    let filedURL = root.appendingPathComponent(filed)
    try writeFilingFile(filedURL, bytes)
    if let loose { try writeFilingFile(root.appendingPathComponent(loose), bytes) }
    let hex = await FileSyncManager.hashFiles([filedURL.path], fileManager: FileManager.default,
                                              cache: nil)[filedURL.path] ?? ""
    try #require(!hex.isEmpty, "the fixture could not hash its own file")
    ContentHashIndexStore.saveInBackground(
        [ContentHashRecord(path: filedURL.path, mtime: 0, size: bytes.count, hex: hex, storedAt: Date())],
        to: indexDir.appendingPathComponent("content-hash-index.json"))
    ContentHashIndexStore.waitForPendingWrites()
    return (root, indexDir, filedURL, hex)
}

/// A fresh temp folder holding an empty profile folder `id`, as the survey and people stores
/// expect to find it.
func makeProfilesDir(prefix: String, id: String = "p") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(id), withIntermediateDirectories: true)
    return dir
}

/// A provider with two destination folders (`Documents/Family`, `Archive/2026`) and `looseFiles`
/// loose files in `Downloads`. Two folders let the free and refine passes disagree.
func refineFixture(prefix: String, looseFiles count: Int = 2) throws -> URL {
    let root = try makeCanonicalTempRoot(prefix: prefix)
    try writeFilingFile(root.appendingPathComponent("Documents/Family/.keep"), bytes: 1)
    try writeFilingFile(root.appendingPathComponent("Archive/2026/.keep"), bytes: 1)
    for i in 0..<count { try writeFilingFile(root.appendingPathComponent("Downloads/mystery-\(i).pdf")) }
    return root
}
