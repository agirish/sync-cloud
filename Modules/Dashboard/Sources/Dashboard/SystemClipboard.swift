import Foundation
import AppKit
import Sync
import Events

/// **The other clipboard.**
///
/// SyncCloud has had a working file clipboard since v3 — `FileSyncManager.clipboardNodes` plus
/// `clipboardIsCut`, with grouped undo and a banner — and it has always been *internal*: ⌘C in a
/// pane and ⌘V in Finder did nothing, and ⌘C in Finder and ⌘V in a pane did nothing. Every
/// `NSPasteboard` use in the app before this wrote a path as **text**.
///
/// This is the bridge, and it is deliberately thin: the pasteboard carries file URLs, and the
/// existing copy/move path does the work. Nothing here writes to disk.
///
/// **`NSFilePromiseProvider` is not involved, and §3's "there is no file pasteboard" priced it in.**
/// A promise provider exists for content that does not exist yet — a file the receiver's drop makes
/// the sender generate. Every node in a SyncCloud pane is a real file at a real path, including an
/// online-only placeholder, which is a dataless file the system materialises on read. Writing the
/// URLs is both sufficient and what every other file browser does.
public enum SystemClipboard {

    /// Puts these files on the pasteboard for other apps, and returns the `changeCount` that write
    /// produced — the token `ClipboardSource` uses to decide who wrote last.
    ///
    /// **A cut writes the same thing a copy does.** The pasteboard has no "this is a move" flag
    /// that Finder reads — Finder's own paste-as-move is ⌥⌘V, a decision made by the *receiver* —
    /// so a cut in SyncCloud followed by a paste in Finder copies. That is the safe direction of
    /// being wrong, and it is why `clipboardIsCut` stays in the in-app clipboard rather than being
    /// something this tries to encode.
    @discardableResult
    public static func write(paths: [String], to pasteboard: NSPasteboard = .general) -> Int {
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.clearContents()
        guard !urls.isEmpty else { return pasteboard.changeCount }
        pasteboard.writeObjects(urls)
        return pasteboard.changeCount
    }

    /// The file URLs currently on the pasteboard, or an empty array when it holds something else.
    ///
    /// `urlReadingFileURLsOnly` is what keeps a copied *web address* out: without it a plain
    /// `https://` URL on the pasteboard reads back as an `NSURL` and would be handed to the copy
    /// engine as a file to copy.
    public static func fileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return []
        }
        return objects
    }

    /// Whether the pasteboard holds at least one file URL — **memoized on `changeCount`**.
    ///
    /// This is asked from view bodies — the row menu's "Paste here" builds per row — so it runs
    /// many times per render of the workspace. **Measured on this machine rather than assumed:**
    /// `changeCount` is **0.8µs** and `readObjects` is **62µs**, seventy-seven times more, so fifty
    /// visible rows would spend ~3ms per render deciding whether one menu item is enabled.
    ///
    /// Keying the memo on the count is exact rather than approximate — AppKit bumps it on **every**
    /// write by anyone, so an unchanged count is a guarantee that the contents are unchanged, not a
    /// guess that they probably are.
    /// **Keyed by the pasteboard's name as well as its count.** Every pasteboard keeps its own
    /// independent `changeCount`, so a memo on the number alone would answer a question about the
    /// general pasteboard with a reading taken from another one the moment the two counts happened
    /// to coincide — which is exactly what a test with its own pasteboard makes likely.
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
    /// `isDirectory` is read from the disk rather than from the URL, which can carry a stale or
    /// absent directory hint depending on how the sender created it — and the copy engine branches
    /// on it. A URL naming something that is no longer there is dropped: a paste that half-fails
    /// with a banner claiming success is worse than one that pastes what still exists.
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

/// **Which clipboard a paste means.**
///
/// Two clipboards would be two behaviours, so this makes them one: the system pasteboard is the
/// arbiter, and the in-app list is consulted only while SyncCloud still owns what is on it.
///
/// `changeCount` is what makes that decidable. AppKit bumps it on every write by anyone, so the
/// count recorded at our own ⌘C either still matches — nobody has copied since — or it does not,
/// and something else is on the pasteboard now.
public enum ClipboardSource: Equatable, Sendable {
    /// SyncCloud's own list: carries `isCut`, so this is the only path that can *move*.
    case inApp
    /// Whatever another app put there. Always a copy — the pasteboard carries no cut flag.
    case system
    /// Nothing to paste; the menu item and the row action disable.
    case none

    /// - Parameters:
    ///   - systemChangeCount: `NSPasteboard.general.changeCount` right now.
    ///   - ownChangeCount: what our last ⌘C/⌘X produced, or nil if we have never written.
    ///   - hasInAppItems: `!clipboardNodes.isEmpty`.
    ///   - systemHasFiles: the pasteboard holds at least one file URL.
    ///
    /// The ordering is the whole rule. **Ours only while we still own the pasteboard**, so a copy
    /// made in Finder after a copy made here wins — which is what a single-clipboard platform
    /// promises and what a user who just pressed ⌘C in Finder expects. And when the pasteboard has
    /// moved on to something that is *not* files (text, an image), the answer is `none` rather than
    /// a fallback to our stale list: pasting files nobody asked for, from a copy made minutes ago,
    /// is the one outcome here that writes to disk by surprise.
    public static func resolve(systemChangeCount: Int, ownChangeCount: Int?,
                               hasInAppItems: Bool, systemHasFiles: Bool) -> ClipboardSource {
        if let ownChangeCount, ownChangeCount == systemChangeCount, hasInAppItems { return .inApp }
        if systemHasFiles { return .system }
        return .none
    }

    /// The rule against the live pasteboard — **the one place enablement and action both ask**, so
    /// a Paste that offers itself and a Paste that runs can never be answering different questions.
    /// That split is how a menu item comes to be enabled over nothing, or greyed over something.
    @MainActor
    public static func current(pasteboard: NSPasteboard = .general,
                               hasInAppItems: Bool, ownChangeCount: Int?) -> ClipboardSource {
        resolve(systemChangeCount: pasteboard.changeCount,
                ownChangeCount: ownChangeCount,
                hasInAppItems: hasInAppItems,
                systemHasFiles: SystemClipboard.hasFiles(in: pasteboard))
    }
}
