import Foundation
import Testing
@testable import Sync

/// A `FileManaging` that hands every call to `inner`. A test double subclasses it and overrides
/// only the calls it intercepts.
///
/// It declares all sixteen members, the five the protocol extension defaults included, because
/// Swift calls a subclass's override through the protocol only when the base class declares the
/// member. Those five keep the protocol's default behaviour (they call `self`, not `inner`), as
/// every hand-written forwarder had: forwarding them would give a double over `FileManager.default`
/// the real observed copy and metadata-taking replace.
class ForwardingFileManaging<Inner: FileManaging>: FileManaging, @unchecked Sendable {
    let inner: Inner

    init(inner: Inner) { self.inner = inner }

    func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
    func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        inner.fileExists(atPath: p, isDirectory: d)
    }
    func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
    func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
    func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
        try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
    }
    func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
    func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
    func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try inner.trashItem(at: u, resultingItemURL: o)
    }
    func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
    func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
        try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
    }
    func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions,
                    errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
    }

    // The protocol's defaults, declared so an override is reached.
    func copyItem(at s: URL, to d: URL, observer: CopyObserver) throws {
        guard observer.shouldContinue() else { throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: s.path]) }
        try copyItem(at: s, to: d)
    }
    func isDataless(at url: URL) -> Bool { false }
    func setModificationDate(_ date: Date, ofItemAtPath path: String) throws {
        try setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
    func installReplacement(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
        try replaceItem(at: d, withItemAt: s, backupItemName: n)
    }
    var datalessFolderReads: FileSyncManager.DatalessFolderReads { .shared }
}

/// The real disk with the Trash refused (`CocoaError(.featureUnsupported)`), as a volume without
/// one answers. A `FileManager` subclass, not a forwarder: the merge and duplicate walks read
/// sizes and dates only through a real `FileManager` (`fileManager is FileManager`), so a wrapper
/// would plan from nothing and the removal gate's drift re-walk would see every folder as changed.
final class TrashRefusingVolume: FileManager, @unchecked Sendable {
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw CocoaError(.featureUnsupported)
    }
}

extension FileSyncManager {
    /// A manager for a test. `nil` resolvers keep the production defaults (skip); the permanent
    /// delete confirmer answers `confirmsPermanentDelete`.
    static func forTests(fileManager: FileManaging = FileManager.default,
                         undo: Bool = true,
                         manualUndoGrouping: Bool = false,
                         collision: CollisionResolution? = nil,
                         bulk: (CollisionResolution, Bool)? = nil,
                         confirmsPermanentDelete: Bool = false,
                         historyPrefix: String? = nil) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fileManager)
        if let historyPrefix { manager.syncHistoryStore = makeTempHistoryStore(prefix: historyPrefix) }
        if undo {
            let um = UndoManager()
            if manualUndoGrouping { um.groupsByEvent = false }
            manager.undoManager = um
        }
        if let collision { manager.collisionResolver = { _ in collision } }
        if let bulk { manager.bulkCollisionResolver = { _ in bulk } }
        manager.permanentDeleteConfirmer = { _ in confirmsPermanentDelete }
        return manager
    }
}

extension MockFileManager.FileStub {
    /// A file of `size` bytes, dated `modified` when one is given.
    static func file(_ size: Int, modified: Date? = nil) -> Self {
        var attributes: [FileAttributeKey: Any] = [.size: size]
        if let modified { attributes[.modificationDate] = modified }
        return Self(isDirectory: false, attributes: attributes, contents: nil)
    }
}

/// Writes `text` to `url` on the real disk, creating its folder.
func writeText(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// The UTF-8 text at `url`, or nil when nothing readable is there.
func readText(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
}

/// Whether any entry, a dangling link included, is at `url`.
func entryExists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
}

/// `same.txt` identical on both sides and `diff.txt` the same size with different bytes, in a
/// fresh temp folder: the minimal real-disk fixture for a same-size checksum pass, with a
/// different-dates row for each pair.
struct SameSizePairFixture {
    let base: URL
    let identical: FileDifference
    let differed: FileDifference

    var rightIdenticalURL: URL { URL(fileURLWithPath: identical.rightItemPath) }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

func makeSameSizePairFixture(prefix: String) throws -> SameSizePairFixture {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    let left = base.appendingPathComponent("left")
    let right = base.appendingPathComponent("right")
    try fm.createDirectory(at: left, withIntermediateDirectories: true)
    try fm.createDirectory(at: right, withIntermediateDirectories: true)

    try Data("identical".utf8).write(to: left.appendingPathComponent("same.txt"))
    try Data("identical".utf8).write(to: right.appendingPathComponent("same.txt"))
    try Data("aaaa".utf8).write(to: left.appendingPathComponent("diff.txt"))
    try Data("bbbb".utf8).write(to: right.appendingPathComponent("diff.txt"))

    func dateDiff(_ name: String, size: Int) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: left.appendingPathComponent(name).path,
            rightItemPath: right.appendingPathComponent(name).path,
            type: .differentDates,
            action: .copyToRight,
            description: "Different dates",
            leftFileSize: size,
            rightFileSize: size
        )
    }
    return SameSizePairFixture(base: base, identical: dateDiff("same.txt", size: 9), differed: dateDiff("diff.txt", size: 4))
}

/// Starts `pass` on the main actor, waits for its first checksum stat to park on `gate`, runs
/// `during`, then releases the gate and awaits the pass. Requires that the gate really held it.
@MainActor @discardableResult
func withParkedPass<T, Inner: FileManaging>(_ gate: FirstStatGate<Inner>, pass: @escaping @MainActor () async -> Void,
                       sourceLocation: SourceLocation = #_sourceLocation,
                       during: () async throws -> T) async throws -> T {
    let task = Task { @MainActor in await pass() }
    await awaitSignal(gate.entered, sourceLocation: sourceLocation)
    let result = try await during()
    gate.release.signal()
    await task.value
    try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash",
                 sourceLocation: sourceLocation)
    return result
}

/// Writes `bytes` bytes of `fill` to `url` on the real disk, creating its folder.
func writeBytes(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: fill, count: bytes).write(to: url)
}
