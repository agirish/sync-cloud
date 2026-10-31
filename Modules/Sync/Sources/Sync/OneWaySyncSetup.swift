//
//  OneWaySyncSetup.swift
//  SyncCloud
//

import Foundation

/// A folder directly in both parents, as setup offers it.
public struct OneWaySyncFolderChoice: Equatable, Sendable, Identifiable {
    public enum Where: Equatable, Sendable {
        case inBoth
        case onlyInICloud
        case onlyInDropbox
    }

    public var name: String
    public var place: Where
    /// Why it isn't offered: shared, or one Dropbox manages. Nil when it can be ticked.
    public var notOffered: String?

    public var id: String { name }
    public var canTick: Bool { place == .inBoth && notOffered == nil }
}

/// **Setting one-way sync up**: where the parents are, which folders it can offer, and the record
/// a first run starts from. Reads only folder names and IDs; writes nothing.
public enum OneWaySyncSetup {

    /// iCloud Drive ▸ Documents. With Desktop & Documents on, a link to the Mac's own Documents.
    public static func defaultICloudParent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents", isDirectory: true)
    }

    /// Dropbox's account folder in `~/Library/CloudStorage`: "Dropbox", or the first "Dropbox-…".
    public static func dropboxAccountFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []).sorted()
        let name = names.first { $0 == "Dropbox" } ?? names.first { $0.hasPrefix("Dropbox-") }
        return name.map { storage.appendingPathComponent($0, isDirectory: true) }
    }

    /// Dropbox ▸ Documents.
    public static func defaultDropboxParent(account: URL) -> URL {
        account.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The account folder a Dropbox parent is in: the folder directly in `…/Library/CloudStorage`
    /// on its canonical path. Nil for a folder outside every provider.
    public static func accountFolder(containing url: URL) -> URL? {
        let parts = OneWaySyncPath.components(OneWaySyncDisk.canonicalPath(url))
        for index in stride(from: parts.count - 3, through: 0, by: -1)
        where parts[index] == "Library" && parts[index + 1] == "CloudStorage" {
            return URL(fileURLWithPath: "/" + parts[0...(index + 2)].joined(separator: "/"), isDirectory: true)
        }
        return nil
    }

    /// The parent as recorded: the path chosen, and the link it is when it is one, with its target.
    public static func parentRecord(_ url: URL) -> OneWaySyncParentRecord {
        let path = url.path
        if OneWaySyncDisk.kind(at: path) == .symlink {
            return OneWaySyncParentRecord(path: path, link: path, linkTarget: OneWaySyncDisk.canonicalPath(url))
        }
        return OneWaySyncParentRecord(path: path)
    }

    /// Why a recorded parent can't be used now, or nil: missing, no longer a folder, or its link
    /// now leads somewhere else (Desktop & Documents turned off moves iCloud's Documents).
    public static func parentProblem(_ parent: OneWaySyncParentRecord) -> String? {
        let url = URL(fileURLWithPath: parent.path)
        if let link = parent.link, let target = parent.linkTarget {
            guard OneWaySyncDisk.kind(at: link) == .symlink else { return "\(url.lastPathComponent) is no longer where it was" }
            guard OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: link)) == target else {
                return "\(url.lastPathComponent) now leads to another folder"
            }
        } else if OneWaySyncDisk.kind(at: parent.path) == .symlink {
            return "\(url.lastPathComponent) became a link"
        }
        guard OneWaySyncDisk.kind(at: OneWaySyncDisk.canonicalPath(url)) == .folder else {
            return "\(url.lastPathComponent) is missing or moved"
        }
        return nil
    }

    /// The folders directly in either parent, with which can be ticked. Shared folders, and the
    /// ones Dropbox manages, are listed and not offered.
    public static func choices(iCloud: OneWaySyncSideListing, dropbox: OneWaySyncSideListing) -> [OneWaySyncFolderChoice] {
        let key = OneWaySyncSide.dropbox.nameKey
        func tops(_ listing: OneWaySyncSideListing) -> [String: OneWaySyncItem] {
            var tops: [String: OneWaySyncItem] = [:]
            for item in listing.listing.items where item.kind == .folder && OneWaySyncPath.depth(item.path) == 1 { tops[key(item.path)] = item }
            return tops
        }
        let iTops = tops(iCloud), dTops = tops(dropbox)
        let iShared = Set(iCloud.sharedFolders.map(key)), dShared = Set(dropbox.sharedFolders.map(key))
        var choices: [OneWaySyncFolderChoice] = []
        for (folderKey, item) in iTops {
            let name = item.path
            var why: String?
            if iShared.contains(folderKey) || dShared.contains(folderKey) { why = "shared" }
            if let d = dTops[folderKey], d.isExcluded, why == nil { why = "managed by Dropbox" }
            choices.append(OneWaySyncFolderChoice(name: name, place: dTops[folderKey] == nil ? .onlyInICloud : .inBoth, notOffered: why))
        }
        for (folderKey, item) in dTops where iTops[folderKey] == nil {
            choices.append(OneWaySyncFolderChoice(name: item.path, place: .onlyInDropbox,
                                                  notOffered: item.isExcluded ? (dShared.contains(folderKey) ? "shared" : "managed by Dropbox") : nil))
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The record a first run starts from: the chosen folders, each with both sides' IDs and its
    /// first run still to do, and no files yet.
    public static func record(
        binding: OneWaySyncBinding, iCloudParent: OneWaySyncParentRecord, dropboxParent: OneWaySyncParentRecord,
        folders: [String], iCloud: OneWaySyncSideListing, dropbox: OneWaySyncSideListing,
        keeping old: OneWaySyncRecord? = nil
    ) -> OneWaySyncRecord {
        let key = OneWaySyncSide.dropbox.nameKey
        var record = OneWaySyncRecord(binding: binding, iCloudParent: iCloudParent, dropboxParent: dropboxParent,
                                      nextKey: max(1, old?.nextKey ?? 1))
        for name in folders.sorted() {
            let i = iCloud.listing.items.first { $0.kind == .folder && OneWaySyncPath.depth($0.path) == 1 && key($0.path) == key(name) }
            let d = dropbox.listing.items.first { $0.kind == .folder && OneWaySyncPath.depth($0.path) == 1 && key($0.path) == key(name) }
            guard let i, let d else { continue }
            record.syncedFolders.append(OneWaySyncFolderRecord(
                key: record.nextKey, iCloudPath: i.path, dropboxPath: d.path, iCloudID: i.folderID, dropboxID: d.folderID,
                firstRunCompleted: false))
            record.nextKey += 1
        }
        return record
    }

    /// Adds a folder to a running sync, for its own first run: *Create in Dropbox & Sync*, or
    /// *Choose Folders…* ticking one more. Nil when it isn't directly in both parents.
    public static func adding(_ name: String, to record: OneWaySyncRecord, iCloud: OneWaySyncSideListing,
                              dropbox: OneWaySyncSideListing) -> OneWaySyncRecord? {
        let key = OneWaySyncSide.dropbox.nameKey
        guard !record.syncedFolders.contains(where: { key($0.iCloudPath) == key(name) }),
              let i = iCloud.listing.items.first(where: { $0.kind == .folder && OneWaySyncPath.depth($0.path) == 1 && key($0.path) == key(name) }),
              let d = dropbox.listing.items.first(where: { $0.kind == .folder && OneWaySyncPath.depth($0.path) == 1 && key($0.path) == key(name) })
        else { return nil }
        var record = record
        record.syncedFolders.append(OneWaySyncFolderRecord(
            key: record.nextKey, iCloudPath: i.path, dropboxPath: d.path, iCloudID: i.folderID, dropboxID: d.folderID,
            firstRunCompleted: false))
        record.nextKey += 1
        return record
    }

    /// *Stop Syncing* a folder: its record goes, with every file and folder recorded below it.
    /// Dropbox's copy stays as it is; syncing it again is a first run.
    public static func removing(_ name: String, from record: OneWaySyncRecord) -> OneWaySyncRecord {
        let key = OneWaySyncSide.dropbox.nameKey
        let target = key(name)
        var record = record
        let dropped = record.syncedFolders.filter { key($0.iCloudPath) == target || key($0.dropboxPath) == target }
        let tops = Set(dropped.flatMap { [key($0.iCloudPath), key($0.dropboxPath)] })
        func below(_ path: String) -> Bool { tops.contains(key(OneWaySyncPath.top(path))) }
        record.syncedFolders.removeAll { tops.contains(key($0.iCloudPath)) }
        record.subfolders.removeAll { below($0.iCloudPath) || below($0.dropboxPath) }
        record.files.removeAll { below($0.iCloudPath) || below($0.dropboxPath) }
        return record
    }
}
