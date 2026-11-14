import Foundation
import AppKit
import Sync

/// The bridge between the app's internal file clipboard (`FileSyncManager.clipboardNodes` and
/// `clipboardIsCut`) and the system pasteboard, so ⌘C and ⌘V work between a pane and Finder.
///
/// Deliberately thin: the pasteboard carries file URLs and the existing copy/move path does the
/// work. Nothing here writes to disk. No `NSFilePromiseProvider`: that is for content the receiver's
/// drop makes the sender generate, and every pane node is a real file at a real path (an
/// online-only placeholder is a dataless file the system materialises on read).
public enum SystemClipboard {

    /// Puts these files on the pasteboard for other apps, and returns the `changeCount` that write
    /// produced, the token `ClipboardSource` uses to decide who wrote last.
    ///
    /// A cut writes the same thing a copy does. The pasteboard has no move flag Finder reads
    /// (Finder's paste-as-move is ⌥⌘V, the receiver's choice), so a cut here pasted in Finder
    /// copies, which is the safe way to be wrong. `clipboardIsCut` stays in the in-app clipboard.
    @discardableResult
    public static func write(paths: [String], to pasteboard: NSPasteboard = .general) -> Int {
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.clearContents()
        guard !urls.isEmpty else { return pasteboard.changeCount }
        pasteboard.writeObjects(urls)
        return pasteboard.changeCount
    }

    /// The file URLs currently on the pasteboard, or an empty array when it holds something else.
    /// `urlReadingFileURLsOnly` keeps a copied web address out, or an `https://` URL would reach the
    /// copy engine as a file to copy.
    public static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return objects
    }

    /// Whether the pasteboard holds at least one file URL, memoized on `changeCount`.
    ///
    /// View bodies ask this (the row menu's "Paste here" builds per row), and `readObjects` costs
    /// about 60µs against under 1µs for `changeCount`, so fifty rows would spend milliseconds per
    /// render on one menu item. The memo is exact: AppKit bumps the count on every write by anyone.
    /// It is keyed by the pasteboard's name too, since each pasteboard has its own count and two
    /// could coincide (a test's private pasteboard makes that likely).
    @MainActor
    public static func hasFiles(in pasteboard: NSPasteboard = .general) -> Bool {
        let key = Memo(name: pasteboard.name.rawValue, count: pasteboard.changeCount)
        if key != memoKey {
            memoKey = key
            memoHasFiles = !fileURLs(from: pasteboard).isEmpty
        }
        return memoHasFiles
    }

    private struct Memo: Equatable { var name: String; var count: Int }
    @MainActor private static var memoKey: Memo?
    @MainActor private static var memoHasFiles = false

    /// Those URLs as nodes the existing copy path can take.
    ///
    /// `isDirectory` is read from the disk, not the URL, whose directory hint can be stale or absent,
    /// and the copy engine branches on it. A URL naming something no longer there is dropped, so a
    /// paste never half-fails behind a banner claiming success.
    public static func nodes(from pasteboard: NSPasteboard = .general,
                             fileManager: FileManager = .default) -> [FileNode] {
        fileURLs(from: pasteboard).compactMap { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            return FileNode(id: url.path, name: url.lastPathComponent,
                            isDirectory: isDirectory.boolValue)
        }
    }
}

/// Which clipboard a paste means.
///
/// The system pasteboard is the arbiter, and the in-app list is used only while SyncCloud still
/// owns what is on it. `changeCount` decides that: AppKit bumps it on every write by anyone, so the
/// count recorded at our own ⌘C either still matches or something else is on the pasteboard now.
public enum ClipboardSource: Equatable, Sendable {
    /// SyncCloud's own list: carries `isCut`, so this is the only path that can move.
    case inApp
    /// Whatever another app put there. Always a copy, since the pasteboard carries no cut flag.
    case system
    /// Nothing to paste; the menu item and the row action disable.
    case none

    /// - Parameters:
    ///   - systemChangeCount: `NSPasteboard.general.changeCount` right now.
    ///   - ownChangeCount: what our last ⌘C/⌘X produced, or nil if we have never written.
    ///   - hasInAppItems: `!clipboardNodes.isEmpty`.
    ///   - systemHasFiles: the pasteboard holds at least one file URL.
    ///
    /// Ours only while we still own the pasteboard, so a copy made in Finder after one made here
    /// wins, as a single-clipboard platform promises. When the pasteboard has moved on to something
    /// that isn't files, the answer is `none`, never our stale list: pasting files nobody asked for
    /// would write to disk by surprise.
    public static func resolve(systemChangeCount: Int, ownChangeCount: Int?,
                               hasInAppItems: Bool, systemHasFiles: Bool) -> ClipboardSource {
        if let ownChangeCount, ownChangeCount == systemChangeCount, hasInAppItems { return .inApp }
        if systemHasFiles { return .system }
        return .none
    }

    /// The rule against the live pasteboard, the one place both enablement and the action ask, so
    /// Paste can't be enabled over nothing or greyed over something.
    @MainActor
    public static func current(pasteboard: NSPasteboard = .general,
                               hasInAppItems: Bool, ownChangeCount: Int?) -> ClipboardSource {
        resolve(systemChangeCount: pasteboard.changeCount,
                ownChangeCount: ownChangeCount,
                hasInAppItems: hasInAppItems,
                systemHasFiles: SystemClipboard.hasFiles(in: pasteboard))
    }
}
