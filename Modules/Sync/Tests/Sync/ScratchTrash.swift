import Foundation

/// A real `FileManager` whose Trash is a folder the test owns, so a test that trashes never
/// reaches the Trash of whoever runs it.
///
/// Everything but `trashItem` is the real disk. The real Trash is the one part a test cannot
/// control: each move into it waits on a privacy check the system can hold for as long as an
/// unanswered dialog is up — "A privacy prompt nobody answered wedges `sandboxd`, so a move into
/// the real Trash outlasts the wait" in docs/flaky-tests.md — and every package run left its
/// fixtures behind. This Mac's Trash held about 545 each of `Payment`, `Emptied`, `Reports` and
/// `bystander.txt` by 2026-10-16.
///
/// **Reports where the item went, as the real Trash does.** `deleteItems` counts an item with no
/// resulting URL as out of ⌘Z's reach, and an undo restores a replaced file from that URL, so
/// leaving it out would quietly test another branch.
///
/// Each item gets a folder of its own, so two trashes of one name both keep it, as the real Trash
/// renames rather than collides.
///
/// **A double that overrides `trashItem` forwards to one of these instead of calling `super`** —
/// `super` is the real Trash. It cannot subclass this: a `FileManager` here is `Sendable` through
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

    /// The names of everything trashed here, sorted — what a test checks to know its trash
    /// landed in this folder and not somewhere else.
    var names: [String] {
        let slots = (try? contentsOfDirectory(atPath: folder.path)) ?? []
        return slots.flatMap {
            (try? contentsOfDirectory(atPath: folder.appendingPathComponent($0).path)) ?? []
        }.sorted()
    }
}
