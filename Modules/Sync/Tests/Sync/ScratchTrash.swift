import Foundation

/// A real `FileManager` whose Trash is a folder the test owns, so a test that trashes never
/// reaches the Trash of whoever runs it. Everything but `trashItem` is the real disk. The real
/// Trash can't be controlled: each move into it waits on a privacy check the system can hold while
/// a dialog goes unanswered (`docs/flaky-tests.md`, "A privacy prompt nobody answered wedges
/// `sandboxd`, so a move into the real Trash outlasts the wait"), and it collects every run's
/// fixtures.
///
/// Reports where the item went, as the real Trash does: `deleteItems` treats an item with no
/// resulting URL as out of ⌘Z's reach, and an undo restores a replaced file from that URL, so
/// leaving it out would test another branch. Each item gets its own folder, so two trashes of one
/// name both keep it, as the real Trash renames rather than collides.
///
/// **A double that overrides `trashItem` must forward to one of these, never call `super`**, which
/// is the real Trash. It can't subclass this: a `FileManager` here is `Sendable` through
/// `FileManaging`, so every subclass must be final.
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

    /// The names of everything trashed here, sorted, so a test can check its trash landed here.
    var names: [String] {
        let slots = (try? contentsOfDirectory(atPath: folder.path)) ?? []
        return slots.flatMap {
            (try? contentsOfDirectory(atPath: folder.appendingPathComponent($0).path)) ?? []
        }.sorted()
    }
}
