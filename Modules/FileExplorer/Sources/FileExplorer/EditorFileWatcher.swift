import Foundation
import Sync

/// **The kernel's word that something happened to the open document's file, or to the folder it
/// is in** (TE59) — a pair of `kqueue` vnode sources, and nothing else.
///
/// **Why `kqueue`, and not `NSFilePresenter`.** A presenter is told only about what goes through
/// `NSFileCoordinator`, plus whatever `filecoordinationd` chooses to relay of the rest, on its own
/// schedule; a shell's `mv`, `vim`'s save, a script, `git checkout` and most sync clients coordinate
/// nothing. A vnode source hears every one of them, at once, because it is the file system itself
/// reporting — iCloud Drive's daemon included, which installs a newer version by writing or
/// renaming inside the same APFS folder like anybody else. And it can be driven from a test with
/// `Data.write` and `rename(2)`, which is what lets the rules above it be proven rather than hoped.
///
/// **It decides nothing.** An event only says "look again"; ``EditorDiskWatch`` then reads the
/// stamp at the document's path and compares it with what the document knows, so a burst of
/// events, a missed one, or one caused by the editor's own save all come to the same answer. Two
/// things only the open descriptor can tell, it does tell:
///
/// - **Where the file went.** `F_GETPATH` on the descriptor follows the inode, not the name, so a
///   file renamed in Finder or filed by Organize is found at its new path.
/// - **Whether its last link is gone** (`st_nlink == 0`) — deleted, not moved.
///
/// **The folder is watched as well as the file**, and three cases need it: an atomic save replaces
/// the inode the file source holds (the folder sees the new entry); a file deleted and created
/// again — another device's rename can arrive that way — leaves no file to watch until it is back;
/// and the folder itself being renamed changes the file's path without touching the file.
///
/// **`O_EVTONLY`**, so the descriptor never keeps a volume from unmounting, and **no descriptor at
/// all on a cloud-only file**: opening a dataless file can ask its provider for the bytes, and a
/// provider that is not running can make that wait forever (the OneDrive `.Trash` hang, 2026-10-02).
/// The folder alone is watched until the file is downloaded.
final class EditorFileWatcher: @unchecked Sendable {

    /// Every watcher's handlers, on one serial queue: they only signal, so one is plenty.
    private static let queue = DispatchQueue(label: "SyncCloud.EditorFileWatcher", qos: .utility)

    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    /// The file's descriptor while it is open, `-1` once cancelled — set to `-1` BEFORE the source
    /// is cancelled, because the cancel handler closes it later on the queue and a descriptor
    /// number read after that could name somebody else's file.
    private var fileDescriptor: Int32 = -1

    /// The inode the file source is on — `0` when no file is watched. The watch re-arms when the
    /// file at the path is a different one (an atomic save installed a new inode).
    let fileID: Int
    /// The path this watcher was armed for.
    let path: String
    /// The folder watched: the file's own, or the nearest one above it while that is gone — `nil`
    /// when not even `/` could be opened.
    let watchedFolder: String?

    /// Whether the watch is on a folder above the file's own while a nearer one now exists — the
    /// file's folder came back, and the watch should move down to hear the file arriving in it.
    var watchesAboveAFolderThatIsBack: Bool {
        let own = (path as NSString).deletingLastPathComponent
        guard let watchedFolder, watchedFolder != own else { return false }
        var isFolder: ObjCBool = false
        var nearer = own
        while nearer != watchedFolder, !nearer.isEmpty {
            if FileManager.default.fileExists(atPath: nearer, isDirectory: &isFolder), isFolder.boolValue { return true }
            let above = (nearer as NSString).deletingLastPathComponent
            if above == nearer { break }
            nearer = above
        }
        return false
    }

    init(path: String, isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
         onEvent: @escaping @Sendable () -> Void) {
        self.path = path
        var armed: [DispatchSourceFileSystemObject] = []
        var fileID = 0
        var descriptor: Int32 = -1
        if !isCloudOnly(path), let fd = Self.arm(path, mask: [.write, .extend, .attrib, .delete, .rename,
                                                               .link, .revoke],
                                                 onEvent: onEvent, into: &armed) {
            descriptor = fd
            var info = stat()
            if fstat(fd, &info) == 0 { fileID = Int(truncatingIfNeeded: info.st_ino) }
        }
        // **The folder — or, while that is gone too, the nearest one above it that is there.** With
        // neither the file nor its folder to open, nothing would be heard when they came back (a
        // restore, another device), and the deleted banner would stand over a file that is there.
        // An entry made in the ancestor is an event; the look after it re-arms one level nearer.
        var folder = (path as NSString).deletingLastPathComponent
        var watchedFolder: String?
        while !folder.isEmpty {
            if Self.arm(folder, mask: [.write, .delete, .rename, .revoke], onEvent: onEvent, into: &armed) != nil {
                watchedFolder = folder
                break
            }
            let above = (folder as NSString).deletingLastPathComponent
            if above == folder { break }
            folder = above
        }
        self.watchedFolder = watchedFolder
        self.fileID = fileID
        self.fileDescriptor = descriptor
        self.sources = armed
    }

    deinit { cancel() }

    /// Opens `path` for events only and puts a source on it. `nil` when it cannot be opened — the
    /// file is not there, which the caller answers by watching the folder alone.
    private static func arm(_ path: String, mask: DispatchSource.FileSystemEvent,
                            onEvent: @escaping @Sendable () -> Void,
                            into sources: inout [DispatchSourceFileSystemObject]) -> Int32? {
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { onEvent() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        sources.append(source)
        return fd
    }

    /// Where the watched file is now — **`nil` when no file is watched, or its last link is gone**.
    var trackedPath: String? {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, info.st_nlink > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Stops both sources; their descriptors close on the queue.
    func cancel() {
        lock.lock()
        let cancelled = sources
        sources = []
        fileDescriptor = -1
        lock.unlock()
        for source in cancelled { source.cancel() }
    }
}
