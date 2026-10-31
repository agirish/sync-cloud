//
//  OneWaySyncLister.swift
//  SyncCloud
//

import CryptoKit
import Darwin
import Foundation

/// Something the lister left out on purpose, which Now lists as skipped: a symlink, a live
/// library, or a name Dropbox won't take.
public struct OneWaySyncSkippedItem: Equatable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// One side as the lister read it.
public struct OneWaySyncSideListing: Equatable, Sendable {
    public var listing: OneWaySyncListing
    public var skipped: [OneWaySyncSkippedItem]
    /// Folders directly in the parent that macOS reports as shared: never offered, never synced.
    public var sharedFolders: [String]

    public init(listing: OneWaySyncListing, skipped: [OneWaySyncSkippedItem] = [], sharedFolders: [String] = []) {
        self.listing = listing
        self.skipped = skipped
        self.sharedFolders = sharedFolders
    }
}

/// **Reads one side of RD67's sync from disk** into what the planner diffs: every folder directly
/// in the parent, and everything inside the synced folders, each with the ID the provider keeps on
/// it (DH). It only reads: no file is opened, so an offloaded iCloud file stays offloaded.
///
/// - Every path is read with `lstat`; no symlink is followed or listed. Symlinks are skipped.
/// - A package is one file: its size and date are totals over what is inside it, as
///   `OneWaySyncDisk.state` reports them, so the writer's re-check reads the same numbers.
/// - A folder macOS reports as shared, at any depth, is listed with everything in it excluded:
///   an ID found there means the file was moved into it, which counts as a move out.
/// - A synced folder holding a folder still cloud-only (iCloud hasn't listed it here) is
///   incomplete: nothing in it is decided, and nothing anywhere is called gone.
/// - Finder's and Dropbox's own files, Office lock files and SyncCloud's temporary names are
///   never listed.
public struct OneWaySyncLister: Sendable {
    public let side: OneWaySyncSide
    /// Canonical: the parent's own link already followed.
    public let parent: URL
    /// Whether macOS reports the folder as shared. A test's way in; the real one reads
    /// `ubiquitousItemIsShared`.
    public var isShared: @Sendable (URL) -> Bool = OneWaySyncLister.reportsShared
    public var isCancelled: @Sendable () -> Bool = { false }

    public init(side: OneWaySyncSide, parent: URL) {
        self.side = side
        self.parent = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(parent), isDirectory: true)
    }

    /// Names never listed, anywhere: the system's and Dropbox's own files.
    public static let ignoredNames: Set<String> = [
        ".DS_Store", ".localized", "Thumbs.db", ".Trashes", ".dropbox", ".dropbox.attr", ".dropbox.cache",
        ".TemporaryItems", ".Spotlight-V100", ".fseventsd",
    ]
    /// Names Dropbox won't take: listed as skipped.
    public static let refusedByDropbox: Set<String> = ["Icon\r", "desktop.ini"]
    /// Folders Dropbox makes and manages itself, never offered for sync.
    public static let dropboxManagedNames: Set<String> = [
        "Apps", "Camera Uploads", "Screenshots", "Backup", "Backups", "Vault", "Family Room", OneWaySyncRemovedStore.folderName,
    ]
    /// Packages whose app writes inside them while it runs: a copy would be torn.
    public static let liveLibraryExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "photolibrary"]

    /// Whether a name is one the sync never lists: ignored, temporary, or one of SyncCloud's own.
    public static func isNeverListed(_ name: String) -> Bool {
        ignoredNames.contains(name) || name.hasPrefix(OneWaySyncPlanner.temporaryNamePrefix)
            || name.hasPrefix("~$") || name.hasPrefix(".~lock.") || name == OneWaySyncMarkerFile.fileName
    }

    /// Lists the parent: each folder directly in it, and the contents of `syncedFolders` (names as
    /// they are on this side). `alsoInside` names folders outside the sync whose contents are
    /// listed as excluded, so a file moved there reads as moved out rather than deleted.
    public func list(syncedFolders: Set<String>, alsoInside: Set<String> = []) -> OneWaySyncSideListing {
        var items: [OneWaySyncItem] = []
        var skipped: [OneWaySyncSkippedItem] = []
        var shared: [String] = []
        var incomplete = Set<String>()
        let syncedKeys = Set(syncedFolders.map(side.nameKey))
        let alsoKeys = Set(alsoInside.map(side.nameKey))

        for name in names(in: parent.path) {
            guard !Self.isNeverListed(name) else { continue }
            let url = parent.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, !isPackage(url, name: name) else { continue }
            let isSharedFolder = isShared(url)
            if isSharedFolder { shared.append(name) }
            let managed = side == .dropbox && Self.dropboxManagedNames.contains(name)
            items.append(folderItem(name, info: info, excluded: isSharedFolder || managed))
            let key = side.nameKey(name)
            guard !managed else { continue }
            if MaterializationStatus.isDataless(flags: info.st_flags) {
                if syncedKeys.contains(key) { incomplete.insert(name) }
            } else if syncedKeys.contains(key) {
                if !walk(name, excluded: isSharedFolder, into: &items, skipped: &skipped) { incomplete.insert(name) }
            } else if alsoKeys.contains(key) {
                var ignored: [OneWaySyncSkippedItem] = []
                _ = walk(name, excluded: true, into: &items, skipped: &ignored)
            }
        }
        return OneWaySyncSideListing(
            listing: OneWaySyncListing(items: items, incompleteFolders: incomplete), skipped: skipped, sharedFolders: shared.sorted())
    }

    /// Lists `relative`'s contents into `items`. False when the folder couldn't be read whole: a
    /// read failed, a folder below is still cloud-only, or the pass was cancelled.
    private func walk(_ relative: String, excluded: Bool, into items: inout [OneWaySyncItem],
                      skipped: inout [OneWaySyncSkippedItem]) -> Bool {
        var complete = true
        var pending = [(relative, excluded)]
        while let (folder, folderExcluded) = pending.popLast() {
            if isCancelled() { return false }
            let folderURL = parent.appendingPathComponent(folder)
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else {
                complete = false
                continue
            }
            for name in children.sorted() {
                guard !Self.isNeverListed(name) else { continue }
                let path = folder + "/" + name
                let url = folderURL.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    complete = false
                    continue
                }
                if Self.refusedByDropbox.contains(name) {
                    if !folderExcluded { skipped.append(OneWaySyncSkippedItem(path: path, reason: "Dropbox won’t take it")) }
                    continue
                }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    if !folderExcluded { skipped.append(OneWaySyncSkippedItem(path: path, reason: "a symlink")) }
                case S_IFDIR where isPackage(url, name: name) && MaterializationStatus.isDataless(flags: info.st_flags):
                    // An offloaded package: its size can't be read without reading inside it.
                    if !folderExcluded { complete = false }
                case S_IFDIR where isPackage(url, name: name):
                    if Self.liveLibraryExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        if !folderExcluded { skipped.append(OneWaySyncSkippedItem(path: path, reason: "a live library")) }
                        continue
                    }
                    guard let state = try? OneWaySyncDisk.state(at: url.path) else {
                        complete = false
                        continue
                    }
                    items.append(fileItem(path, url: url, size: state.size, modifiedNanoseconds: state.modified,
                                          flags: info.st_flags, excluded: folderExcluded))
                case S_IFDIR:
                    // A folder iCloud hasn't listed here yet: reading it would download its listing,
                    // and until then what it holds is unknown.
                    // Never read, even outside the sync.
                    if MaterializationStatus.isDataless(flags: info.st_flags) {
                        if !folderExcluded { complete = false }
                        items.append(folderItem(path, info: info, excluded: folderExcluded))
                        continue
                    }
                    let sharedHere = folderExcluded || isShared(url)
                    items.append(folderItem(path, info: info, excluded: sharedHere))
                    pending.append((path, sharedHere))
                case S_IFREG:
                    items.append(fileItem(path, url: url, size: Int64(info.st_size),
                                          modifiedNanoseconds: OneWaySyncDisk.nanoseconds(info.st_mtimespec),
                                          flags: info.st_flags, excluded: folderExcluded))
                default:
                    continue
                }
            }
        }
        return complete
    }

    private func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private func isPackage(_ url: URL, name: String) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private func folderItem(_ path: String, info: stat, excluded: Bool) -> OneWaySyncItem {
        OneWaySyncItem(
            path: path, kind: .folder, folderID: OneWaySyncFolderID(inode: UInt64(info.st_ino)),
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), isExcluded: excluded)
    }

    private func fileItem(_ path: String, url: URL, size: Int64, modifiedNanoseconds: Int64, flags: UInt32,
                          excluded: Bool) -> OneWaySyncItem {
        // A fresh URL each time: a URL caches its resource values.
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.documentIdentifierKey, .tagNamesKey])
        let id = values?.documentIdentifier.flatMap { $0 > 0 ? UInt64($0) : nil }
        let seconds = modifiedNanoseconds >= 0 ? modifiedNanoseconds / 1_000_000_000 : (modifiedNanoseconds - 999_999_999) / 1_000_000_000
        return OneWaySyncItem(
            path: path, kind: .file, documentID: id, size: size,
            modified: Date(timeIntervalSince1970: TimeInterval(seconds)), tags: values?.tagNames ?? [],
            isDownloaded: !MaterializationStatus.isDataless(flags: flags), isExcluded: excluded)
    }

    /// Whether macOS reports the folder as shared: iCloud's sharing, and a File Provider's that
    /// reports it the same way. Dropbox's is not known to be reported (DL asks at setup instead).
    public static let reportsShared: @Sendable (URL) -> Bool = { url in
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.ubiquitousItemIsSharedKey])
        return values?.ubiquitousItemIsShared == true
    }
}

// MARK: - Contents

/// The contents hash the record keeps: SHA-256 of a file's bytes, read 4 MB at a time, or for a
/// package, of each file inside it in path order with its relative path. Nil when it can't be
/// read whole, or an offloaded file would have to download and `download` is false.
public enum OneWaySyncContents {
    public static func hash(at path: String, download: Bool = false, deadline: TimeInterval = 10 * 60,
                            isCancelled: @Sendable () -> Bool = { false }) -> String? {
        guard let kind = OneWaySyncDisk.kind(at: path), kind != .symlink else { return nil }
        let url = URL(fileURLWithPath: path)
        let dataless = MaterializationStatus.isCloudOnly(atPath: path)
        if dataless && !download { return nil }
        func read() -> String? {
            var hasher = SHA256()
            if kind == .file {
                guard add(path, to: &hasher, isCancelled: isCancelled) else { return nil }
            } else {
                var children: [String] = []
                for case let child as String in FileManager.default.enumerator(atPath: path) ?? NSEnumerator() {
                    children.append(child)
                }
                for child in children.sorted() {
                    let full = path + "/" + child
                    guard let childKind = OneWaySyncDisk.kind(at: full), childKind != .symlink else { return nil }
                    hasher.update(data: Data(child.precomposedStringWithCanonicalMapping.utf8))
                    hasher.update(data: Data([0]))
                    if childKind == .file, !add(full, to: &hasher, isCancelled: isCancelled) { return nil }
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard dataless else { return read() }
        // Downloaded inside a coordinated read, only to compare, then offloaded again.
        let result = try? OneWaySyncDisk.coordinatedRead(url, deadline: deadline) { _ in read() }
        try? FileManager.default.evictUbiquitousItem(at: url)
        return result ?? nil
    }

    private static func add(_ path: String, to hasher: inout SHA256, isCancelled: @Sendable () -> Bool) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        while true {
            if isCancelled() { return false }
            // Nil, or empty, at the end of the file.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 4 * 1024 * 1024) } catch { return false }
            guard let chunk, !chunk.isEmpty else { return true }
            hasher.update(data: chunk)
        }
    }
}
