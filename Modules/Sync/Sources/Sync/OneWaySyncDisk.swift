//
//  OneWaySyncDisk.swift
//  SyncCloud
//

import Darwin
import Foundation

/// What a write of RD67's one-way sync can fail with. Each leaves both sides as they were, apart
/// from what the case says; nothing in Dropbox is ever half-written.
public enum OneWaySyncWriteError: Error, Equatable, Sendable {
    /// A symlink where a file or folder was expected. No symlink is followed or copied.
    case symlink(String)
    case missing(String)
    /// Dropbox's copy on this Mac isn't the one the plan was made from. The file waits.
    case changedSinceDiff(String)
    /// The size, date or change time moved while the file was being copied.
    case changedDuringCopy(String)
    /// Another process held the file past the deadline (file coordination), or iCloud didn't
    /// download it in time.
    case coordinationTimedOut(String)
    /// The name is taken. Nothing was overwritten.
    case nameTaken(String)
    /// A file where Dropbox has a package (a folder), or the other way round: no rename can put
    /// one in the other's place and keep the Dropbox item.
    case kindChanged(String)
    /// The staging folder isn't on the same volume as Dropbox, so moving a staged file in would
    /// copy it, or is inside one of the synced sides.
    case stagingUnusable(String)
    /// A relative path that would leave its folder ("..", an empty component).
    case badPath(String)
    case failed(String, errno: Int32)
}

/// A file's state as the disk reports it, never through a symlink. A package (or any folder
/// copied as one file) reports totals over everything inside it, so a change anywhere in it moves
/// at least one field.
public struct OneWaySyncFileState: Equatable, Sendable {
    public var size: Int64
    /// Modification and change times, in nanoseconds since 1970.
    public var modified: Int64
    public var changed: Int64
    public var inode: UInt64
    public var isFolder: Bool
    /// Items inside a folder; 0 for a file.
    public var count: Int

    /// The modification date to the second, the precision the diff compares.
    public var modifiedSecond: Int64 { modified >= 0 ? modified / 1_000_000_000 : (modified - 999_999_999) / 1_000_000_000 }
}

/// What the plan saw of a Dropbox file, re-checked just before SyncCloud writes over it, moves it
/// or keeps it: "Dropbox's copy on this Mac changed since the diff" waits.
public struct OneWaySyncExpectedState: Equatable, Sendable {
    public var size: Int64
    /// To the second.
    public var modified: Int64
    /// Checked only when the diff saw one.
    public var documentID: UInt64?

    public init(size: Int64, modified: Int64, documentID: UInt64? = nil) {
        self.size = size
        self.modified = modified
        self.documentID = documentID
    }

    /// What the lister saw of `item`.
    public init(_ item: OneWaySyncItem) {
        self.init(size: item.size, modified: item.second, documentID: item.documentID)
    }

    func matches(_ state: OneWaySyncFileState, documentID current: UInt64?) -> Bool {
        guard state.size == size, state.modifiedSecond == modified else { return false }
        if let documentID, documentID != 0 { return current == documentID }
        return true
    }
}

/// The disk calls one-way sync is built from. Every path is read with `lstat`, so no symlink is
/// followed; every move into a name that may be taken is `RENAME_EXCL`, so nothing is overwritten
/// by accident.
public enum OneWaySyncDisk {

    /// Dropbox's own attributes start with this. A copy, clone or restore never carries them, or
    /// Dropbox could read the new item as the one it came from.
    public static let dropboxAttributePrefix = "com.dropbox."

    // MARK: Paths

    /// `relative` below `base`, refusing any component that would leave it, and any folder on the
    /// way that is a symlink. `base` is taken as it is: callers pass it canonical.
    ///
    /// The check is a moment's; every move and clone also passes `NOFOLLOW_ANY`, so a folder that
    /// becomes a symlink after it fails rather than being followed.
    ///
    /// The path keeps `relative`'s bytes (``child(_:of:)``), so every name the sync writes lands in
    /// the Unicode form it was listed or typed in.
    public static func url(_ relative: String, in base: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw OneWaySyncWriteError.badPath(relative)
        }
        var url = base
        for (index, part) in parts.enumerated() {
            url = child(part, of: url)
            if index < parts.count - 1, kind(at: url.path) == .symlink { throw OneWaySyncWriteError.symlink(url.path) }
        }
        return url
    }

    /// `name` in `folder`, through a path that keeps `name`'s bytes.
    ///
    /// `appendingPathComponent` decomposes a name (an NFC `é` becomes `e` plus an accent), and APFS
    /// stores a name in the form it is sent, so an iCloud name copied through it reached Dropbox
    /// as other bytes than iCloud's — the same name to the Mac, another spelling to Dropbox's
    /// servers and every device it syncs to. And APFS's 255-unit limit counts the form sent, so a
    /// long name could fit iCloud and not Dropbox. `NSString` joins without normalizing, and a
    /// URL made from the joined bytes keeps them in its `path` (measured 2026-10-31).
    public static func child(_ name: String, of folder: URL) -> URL {
        let path = (folder.path as NSString).appendingPathComponent(name)
        return URL(fileURLWithFileSystemRepresentation: path, isDirectory: kind(at: path) == .folder, relativeTo: nil)
    }

    /// Creates the folders of `relative` below `base` that are missing and returns the deepest.
    /// Never through a symlink: one found on the way is refused, and so is a file in a folder's place.
    @discardableResult
    public static func makeFolders(_ relative: String, in base: URL) throws -> URL {
        guard !relative.isEmpty else { return base }
        _ = try url(relative, in: base)
        var folder = base
        for part in relative.split(separator: "/") {
            folder = child(String(part), of: folder)
            switch kind(at: folder.path) {
            case .folder: continue
            case .symlink: throw OneWaySyncWriteError.symlink(folder.path)
            case .file: throw OneWaySyncWriteError.nameTaken(folder.path)
            case .none:
                if mkdir(folder.path, 0o755) != 0 {
                    let code = errno
                    if code == EEXIST, kind(at: folder.path) == .folder { continue }
                    throw OneWaySyncWriteError.failed(folder.path, errno: code)
                }
            }
        }
        return folder
    }

    /// `url`'s path with every symlink resolved (`/var` is `/private/var`), for telling whether one
    /// folder is inside another. A part that doesn't exist yet is kept as written below the
    /// deepest part that does.
    public static func canonicalPath(_ url: URL) -> String {
        // Not `standardizedFileURL`: it drops `..` before the symlinks are resolved, which can
        // name another folder. `realpath` resolves them in order.
        var existing = url.absoluteURL
        var rest: [String] = []
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed()).joined(separator: "/")
            }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return "/" + rest.reversed().joined(separator: "/")
    }

    /// The first component of `path`, from the root down, that is a symlink.
    static func firstSymlink(on path: String) -> String? {
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix += "/" + part
            if kind(at: prefix) == .symlink { return prefix }
        }
        return nil
    }

    /// Whether `path` is `folder` or inside it, both canonical.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    public enum Kind: Equatable, Sendable {
        case file
        case folder
        case symlink
    }

    /// What is at `path`, not following a symlink; nil when nothing is.
    public static func kind(at path: String) -> Kind? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .folder
        default: return .file
        }
    }

    // MARK: State

    /// The item's state; refuses a symlink and a missing item.
    public static func state(at path: String) throws -> OneWaySyncFileState {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            throw code == ENOENT ? OneWaySyncWriteError.missing(path) : OneWaySyncWriteError.failed(path, errno: code)
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw OneWaySyncWriteError.symlink(path) }
        var state = OneWaySyncFileState(
            size: Int64(info.st_size), modified: nanoseconds(info.st_mtimespec), changed: nanoseconds(info.st_ctimespec),
            inode: UInt64(info.st_ino), isFolder: type == S_IFDIR, count: 0)
        guard state.isFolder else { return state }
        state.size = 0
        // `enumerator(atPath:)` lists symlinks without descending into them.
        for case let child as String in FileManager.default.enumerator(atPath: path) ?? NSEnumerator() {
            var inner = stat()
            guard lstat(path + "/" + child, &inner) == 0 else { continue }
            state.count += 1
            if inner.st_mode & S_IFMT == S_IFREG { state.size += Int64(inner.st_size) }
            state.modified = max(state.modified, nanoseconds(inner.st_mtimespec))
            state.changed = max(state.changed, nanoseconds(inner.st_ctimespec))
        }
        return state
    }

    static func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }

    /// The document ID the file system gives a tracked file (iCloud and Dropbox track every
    /// file); nil when it has none. Read fresh each time: a URL caches its resource values.
    public static func documentID(at path: String) -> UInt64? {
        guard kind(at: path) != .symlink,
              let id = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.documentIdentifierKey]).documentIdentifier,
              id > 0 else { return nil }
        return UInt64(id)
    }

    /// Whether the Finder lock (`uchg`, `uappnd`) is on the item, which stops any rename over it.
    static func isLocked(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0
    }

    static func device(of path: String) -> Int32? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    // MARK: Moves

    /// Moves `source` to `destination` only if nothing is there. A change of letter case alone,
    /// on a volume that ignores case, is the same item and goes ahead.
    public static func moveExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0 else {
            let code = errno
            if code == EEXIST { throw OneWaySyncWriteError.nameTaken(destination.path) }
            throw failure(code, source: source, destination: destination)
        }
    }

    /// What a failed rename or clone from `source` to `destination` means.
    static func failure(_ code: Int32, source: URL, destination: URL) -> OneWaySyncWriteError {
        switch code {
        // `NOFOLLOW_ANY` met a symlink somewhere on one of the paths.
        case ELOOP: return .symlink(firstSymlink(on: source.path) ?? firstSymlink(on: destination.path) ?? destination.path)
        case ENOENT where kind(at: source.path) == nil: return .missing(source.path)
        default: return .failed(destination.path, errno: code)
        }
    }

    /// Puts `source` in `destination`'s place, so the item there keeps its document ID, and with
    /// it Dropbox's item, links and history. A file is renamed over the old one: measured with
    /// Dropbox, that keeps its document ID, item ID and server file ID. A folder (a package) can't
    /// be renamed over, so the two are swapped (measured here: the package keeps its own document
    /// ID; the files inside it are new; Dropbox's server side not measured), and the old one, now
    /// at `source`, is deleted there, outside Dropbox. Both must be of one kind.
    static func moveOver(_ source: URL, onto destination: URL) throws {
        let folder = kind(at: source.path) == .folder
        let flags = folder ? RENAME_SWAP | RENAME_NOFOLLOW_ANY : RENAME_NOFOLLOW_ANY
        guard renamex_np(source.path, destination.path, UInt32(flags)) == 0 else {
            throw failure(errno, source: source, destination: destination)
        }
        if folder { removeStaged(source) }
    }

    // MARK: Copies

    /// A copy of `source` at `destination` (which must not exist), cloned when the volume allows.
    /// No symlink is followed or copied: a symlink source is refused, and so is a package holding
    /// one. The copy carries no document ID (measured) and none of Dropbox's attributes, and loses
    /// the Finder lock (`uchg`, `uappnd`), which would stop it ever being moved into place.
    static func copy(_ source: URL, to destination: URL) throws {
        switch kind(at: source.path) {
        case .symlink: throw OneWaySyncWriteError.symlink(source.path)
        case .none: throw OneWaySyncWriteError.missing(source.path)
        case .folder:
            for case let child as String in FileManager.default.enumerator(atPath: source.path) ?? NSEnumerator()
            where kind(at: source.path + "/" + child) == .symlink {
                throw OneWaySyncWriteError.symlink(source.path + "/" + child)
            }
        case .file: break
        }
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW | CLONE_NOFOLLOW_ANY)) != 0 {
            let code = errno
            guard code == ENOTSUP || code == EXDEV else { throw failure(code, source: source, destination: destination) }
            let flags = COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | (kind(at: source.path) == .folder ? COPYFILE_RECURSIVE : 0)
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(flags)) == 0 else {
                let failure = errno
                removeStaged(destination)
                throw OneWaySyncWriteError.failed(destination.path, errno: failure)
            }
        }
        forEachItem(destination.path) { path in
            // The lock first: a locked item refuses to have its attributes removed.
            unlock(path)
            stripDropboxAttributes(at: path)
        }
    }

    /// Takes the Finder lock (`uchg`, `uappnd`) off the item itself.
    static func unlock(_ path: String) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
            lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
        }
    }

    /// Deletes something SyncCloud made in its staging folder, locked files inside a package
    /// included, which `removeItem` alone can't.
    static func removeStaged(_ url: URL) {
        guard kind(at: url.path) != nil else { return }
        forEachItem(url.path) { unlock($0) }
        try? FileManager.default.removeItem(at: url)
    }

    /// `path`, and everything inside it when it is a folder.
    static func forEachItem(_ path: String, _ body: (String) -> Void) {
        body(path)
        guard kind(at: path) == .folder else { return }
        for case let child as String in FileManager.default.enumerator(atPath: path) ?? NSEnumerator() {
            body(path + "/" + child)
        }
    }

    // MARK: Attributes

    static func attributeNames(at path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer[..<read].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    /// Removes Dropbox's attributes from the item itself (not from what is inside a folder).
    public static func stripDropboxAttributes(at path: String) {
        for name in attributeNames(at: path) where name.hasPrefix(dropboxAttributePrefix) {
            removexattr(path, name, XATTR_NOFOLLOW)
        }
    }

    static func attribute(_ name: String, at path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }

    static func setAttribute(_ name: String, _ value: Data, at path: String) throws {
        let result = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw OneWaySyncWriteError.failed(path, errno: errno) }
    }

    // MARK: File coordination

    /// Runs `body` inside a coordinated read of `url`, giving up once `deadline` passes before the
    /// read is granted: another process writing it, or iCloud still downloading it. A read
    /// without options asks other writers to save first, and downloads an offloaded iCloud file.
    public static func coordinatedRead<T>(_ url: URL, deadline: TimeInterval, _ body: (URL) throws -> T) throws -> T {
        let session = Coordination(deadline: deadline)
        defer { session.end() }
        var result: Result<T, Error>?
        var error: NSError?
        session.coordinator.coordinate(readingItemAt: url, options: [], error: &error) { granted in
            if session.enter() { result = Result { try body(granted) } }
        }
        return try session.finish(result, error, url.path)
    }

    /// Runs `body` inside a coordinated write of `url`, as `coordinatedRead` does.
    public static func coordinatedWrite<T>(_ url: URL, deadline: TimeInterval, _ body: (URL) throws -> T) throws -> T {
        let session = Coordination(deadline: deadline)
        defer { session.end() }
        var result: Result<T, Error>?
        var error: NSError?
        session.coordinator.coordinate(writingItemAt: url, options: [], error: &error) { granted in
            if session.enter() { result = Result { try body(granted) } }
        }
        return try session.finish(result, error, url.path)
    }

    /// One coordinated access with a deadline. The coordinator is cancelled if the deadline passes
    /// before access is granted; once granted, the body runs to the end, since cancelling then
    /// would cut nothing short.
    private final class Coordination: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        private let lock = NSLock()
        private var entered = false
        private var cancelled = false
        private var timer: DispatchWorkItem?

        init(deadline: TimeInterval) {
            // Weak: a cancelled work item keeps its block until its time comes, which for a
            // download is minutes.
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                lock.lock(); defer { lock.unlock() }
                guard !entered else { return }
                cancelled = true
                coordinator.cancel()
            }
            self.timer = timer
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline, execute: timer)
        }

        /// Whether the body may run: false once the deadline has cancelled the access.
        func enter() -> Bool {
            lock.lock(); defer { lock.unlock() }
            entered = true
            return !cancelled
        }

        func end() { timer?.cancel(); timer = nil }

        func finish<T>(_ result: Result<T, Error>?, _ error: NSError?, _ path: String) throws -> T {
            if let result { return try result.get() }
            lock.lock(); let timedOut = cancelled; lock.unlock()
            // A real error is reported as itself, even if the deadline passed as it arrived.
            if let error, !(error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError) {
                let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                throw OneWaySyncWriteError.failed(path, errno: underlying.flatMap { Int32(exactly: $0) } ?? EIO)
            }
            if timedOut || error != nil { throw OneWaySyncWriteError.coordinationTimedOut(path) }
            throw OneWaySyncWriteError.failed(path, errno: EIO)
        }
    }
}
