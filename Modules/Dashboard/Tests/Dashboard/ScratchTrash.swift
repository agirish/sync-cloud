import Foundation

/// A real `FileManager` whose Trash is a folder the test owns, so a test that trashes never
/// reaches the Trash of whoever runs it — "A privacy prompt nobody answered wedges `sandboxd`, so a
/// move into the real Trash outlasts the wait" in docs/flaky-tests.md.
///
/// A copy of `Modules/Sync/Tests/Sync/ScratchTrash.swift`, whose doc says why each part is there:
/// Dashboard's tests cannot see Sync's test target. Keep the two alike.
final class ScratchTrash: FileManager, @unchecked Sendable {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    /// A Trash inside `base`, so the cleanup that already removes a test's temp root removes it too.
    convenience init(in base: URL) {
        self.init(folder: base.appendingPathComponent("Scratch Trash", isDirectory: true))
    }

    override func trashItem(at url: URL,
                            resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        let slot = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(at: slot, withIntermediateDirectories: true)
        let destination = slot.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: destination)
        resultingItemURL?.pointee = destination as NSURL
    }

    /// The names of everything trashed here, sorted.
    var names: [String] {
        let slots = (try? contentsOfDirectory(atPath: folder.path)) ?? []
        return slots.flatMap {
            (try? contentsOfDirectory(atPath: folder.appendingPathComponent($0).path)) ?? []
        }.sorted()
    }
}
