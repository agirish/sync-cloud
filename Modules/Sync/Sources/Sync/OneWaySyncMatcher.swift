//
//  OneWaySyncMatcher.swift
//  SyncCloud
//

import Foundation

/// Where one record's item is on one side this pass.
public enum OneWaySyncMatch: Equatable, Sendable {
    public enum Basis: Sendable {
        /// Its recorded ID, possibly under a new name: a rename or move.
        case id
        /// Its recorded name, possibly with a new ID: an app saved it as a new file.
        case name
    }

    case found(OneWaySyncItem, by: Basis)
    /// Its ID is outside the synced folders, or inside a skipped one.
    case movedOut(OneWaySyncItem)
    case gone

    public var item: OneWaySyncItem? {
        switch self {
        case .found(let item, _), .movedOut(let item): return item
        case .gone: return nil
        }
    }
}

/// One side's matches, keyed by record `key`.
public struct OneWaySyncSideMatches: Equatable, Sendable {
    public var folders: [UInt64: OneWaySyncMatch]
    public var files: [UInt64: OneWaySyncMatch]
    /// Files inside the synced folders that no record claimed, by path.
    public var unclaimed: [OneWaySyncItem]
    /// IDs seen at more than one path (hard links). Never matched by and never recorded.
    public var sharedIDs: Set<UInt64>
    /// Each recorded folder found this pass, from its recorded path's name key to where it is now.
    var folderPaths: [String: String] = [:]
    var side: OneWaySyncSide = .iCloud

    /// Where a recorded path is now if only the folders above it moved: the path its file would
    /// have had it stayed put inside its folder.
    func followingFolders(_ path: String) -> String {
        let parts = OneWaySyncPath.components(path)
        guard parts.count > 1 else { return path }
        for length in stride(from: parts.count - 1, through: 1, by: -1) {
            let prefix = parts[0..<length].joined(separator: "/")
            if let now = folderPaths[side.nameKey(prefix)] {
                return now + "/" + parts[length...].joined(separator: "/")
            }
        }
        return path
    }

    /// The ID to record for `item`: nil when it has none, or shares it with another path.
    public func recordableID(of item: OneWaySyncItem) -> UInt64? {
        guard let id = item.documentID, id != 0, !sharedIDs.contains(id) else { return nil }
        return id
    }
}

/// An iCloud file and a Dropbox file no record holds, found to be the same file.
public struct OneWaySyncPair: Equatable, Sendable {
    public enum Basis: Sendable {
        /// The same name, compared as Dropbox compares names.
        case name
        /// Identical contents of a unique size and type, over 1 KB, onto a free name: on a first
        /// run only.
        case contents
    }

    public var iCloud: OneWaySyncItem
    public var dropbox: OneWaySyncItem
    public var basis: Basis
}

/// An iCloud file whose ID belongs to a file SyncCloud removed from Dropbox.
public struct OneWaySyncReappearance: Equatable, Sendable {
    public var item: OneWaySyncItem
    public var removed: OneWaySyncRemovedFile
}

public struct OneWaySyncMatches: Equatable, Sendable {
    public var iCloud: OneWaySyncSideMatches
    public var dropbox: OneWaySyncSideMatches
    public var pairs: [OneWaySyncPair]
    public var reappeared: [OneWaySyncReappearance]
}

/// RD67's matching order: which item on disk each record now is, on each side separately.
///
/// Each record and each item on disk is claimed at most once. Synced folders are matched first,
/// then the folders below them, then files; within each tier, step 1 (by ID) finishes before
/// step 2 (by name), so a rename followed by a new file at the old name reads as both, while an
/// app's save that made a new file at the same name reads as an edit.
public enum OneWaySyncMatcher {

    /// Files at or below this size are never paired by contents: small files collide too easily.
    public static let contentsPairingMinimumSize: Int64 = 1024

    public static func match(
        record: OneWaySyncRecord, iCloud: OneWaySyncListing, dropbox: OneWaySyncListing
    ) -> OneWaySyncMatches {
        var iCloudMatches = matchSide(.iCloud, record: record, listing: iCloud)
        var dropboxMatches = matchSide(.dropbox, record: record, listing: dropbox)

        // A removed file's ID turning up again in iCloud moves it back.
        var removedByID: [UInt64: OneWaySyncRemovedFile] = [:]
        for removed in record.removed {
            if let id = removed.file.iCloudID { removedByID[id] = removed }
        }
        var reappeared: [OneWaySyncReappearance] = []
        let sharedIDs = iCloudMatches.sharedIDs
        iCloudMatches.unclaimed.removeAll { item in
            guard let id = item.documentID, !sharedIDs.contains(id), let removed = removedByID.removeValue(forKey: id) else {
                return false
            }
            reappeared.append(OneWaySyncReappearance(item: item, removed: removed))
            return true
        }

        let pairs = pair(
            record: record, iCloud: &iCloudMatches.unclaimed, dropbox: &dropboxMatches.unclaimed,
            dropboxListing: dropbox
        )
        return OneWaySyncMatches(iCloud: iCloudMatches, dropbox: dropboxMatches, pairs: pairs, reappeared: reappeared)
    }

    // MARK: - One side against the record

    static func matchSide(_ side: OneWaySyncSide, record: OneWaySyncRecord, listing: OneWaySyncListing) -> OneWaySyncSideMatches {
        let items = listing.items
        var claimed = Array(repeating: false, count: items.count)

        // An ID seen at more than one path is never used: the paths are hard links of one file.
        var pathsByID: [UInt64: Set<String>] = [:]
        for item in items where item.kind == .file {
            if let id = item.documentID, id != 0 { pathsByID[id, default: []].insert(side.nameKey(item.path)) }
        }
        let sharedIDs = Set(pathsByID.filter { $0.value.count > 1 }.keys)
        func usable(_ id: UInt64?) -> UInt64? {
            guard let id, id != 0, !sharedIDs.contains(id) else { return nil }
            return id
        }

        var fileByID: [UInt64: Int] = [:]
        var fileByName: [String: Int] = [:]
        var folderByID: [String: [Int]] = [:]
        var folderByName: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            let name = side.nameKey(item.path)
            switch item.kind {
            case .file:
                if let id = usable(item.documentID) { fileByID[id] = index }
                if fileByName[name] == nil { fileByName[name] = index }
            case .folder:
                for key in item.folderID?.allKeys ?? [] { folderByID[key, default: []].append(index) }
                if folderByName[name] == nil { folderByName[name] = index }
            }
        }

        var folderMatches: [UInt64: OneWaySyncMatch] = [:]
        // Recorded folder path (name key) → where that folder is now, to find a recorded name
        // below a renamed folder.
        var folderNow: [String: String] = [:]

        func translate(_ path: String) -> String {
            var lookup = OneWaySyncSideMatches(folders: [:], files: [:], unclaimed: [], sharedIDs: [])
            lookup.folderPaths = folderNow
            lookup.side = side
            return lookup.followingFolders(path)
        }

        let recordFolderIDs = Set((record.syncedFolders + record.subfolders).compactMap { $0.id(on: side)?.lookupKey })

        func matchFolders(_ folders: [OneWaySyncFolderRecord], inScope: (OneWaySyncItem) -> Bool) {
            let ordered = folders.sorted { (OneWaySyncPath.depth($0.path(on: side)), $0.key) < (OneWaySyncPath.depth($1.path(on: side)), $1.key) }
            // Step 1: by ID.
            for folder in ordered {
                guard let key = folder.id(on: side)?.lookupKey, let hits = folderByID[key], hits.count == 1,
                      !claimed[hits[0]] else { continue }
                let item = items[hits[0]]
                claimed[hits[0]] = true
                if inScope(item) {
                    folderMatches[folder.key] = .found(item, by: .id)
                    folderNow[side.nameKey(folder.path(on: side))] = item.path
                } else {
                    folderMatches[folder.key] = .movedOut(item)
                }
            }
            // Step 2: by name, shallowest first so a parent's new name is already known.
            for folder in ordered where folderMatches[folder.key] == nil {
                let path = translate(folder.path(on: side))
                guard let index = folderByName[side.nameKey(path)], !claimed[index], inScope(items[index]) else {
                    folderMatches[folder.key] = .gone
                    continue
                }
                let item = items[index]
                let oldKey = folder.id(on: side)?.lookupKey
                let sameID = oldKey != nil && (item.folderID?.allKeys ?? []).contains(oldKey!)
                if !sameID {
                    let oldElsewhere = oldKey.map { (folderByID[$0] ?? []).contains { $0 != index } } ?? false
                    let newHeld = (item.folderID?.allKeys ?? []).contains { recordFolderIDs.contains($0) }
                    if oldElsewhere || newHeld {
                        folderMatches[folder.key] = .gone
                        continue
                    }
                }
                claimed[index] = true
                folderMatches[folder.key] = .found(item, by: .name)
                folderNow[side.nameKey(folder.path(on: side))] = item.path
            }
        }

        // Synced folders sit directly in the parent; anywhere else, they have been moved away.
        matchFolders(record.syncedFolders) { !$0.isExcluded && OneWaySyncPath.depth($0.path) == 1 }

        // In scope: below a synced folder, under its recorded name or the name it has now. A
        // renamed synced folder waits as a whole, so its files must not read as moved out.
        var scope = Set(record.syncedFolders.map { side.nameKey($0.path(on: side)) })
        for folder in record.syncedFolders {
            if case .found(let item, _) = folderMatches[folder.key] { scope.insert(side.nameKey(item.path)) }
        }
        func inScope(_ item: OneWaySyncItem) -> Bool {
            !item.isExcluded && OneWaySyncPath.depth(item.path) >= 2 && scope.contains(side.nameKey(OneWaySyncPath.top(item.path)))
        }

        matchFolders(record.subfolders, inScope: inScope)

        // Files, step 1: a recorded ID found under any name.
        var fileMatches: [UInt64: OneWaySyncMatch] = [:]
        let files = record.files.sorted { $0.key < $1.key }
        for file in files {
            guard let id = usable(file.id(on: side)), let index = fileByID[id], !claimed[index] else { continue }
            claimed[index] = true
            fileMatches[file.key] = inScope(items[index]) ? .found(items[index], by: .id) : .movedOut(items[index])
        }

        // Files, step 2: a recorded name still present is the same file. It takes on a new ID only
        // if its old ID is nowhere else in the listing and no record holds the new one.
        var recordIDs = Set(record.files.compactMap { $0.id(on: side) })
        if side == .iCloud { recordIDs.formUnion(record.removed.compactMap { $0.file.iCloudID }) }
        for file in files where fileMatches[file.key] == nil {
            let path = translate(file.path(on: side))
            let name = side.nameKey(path)
            guard let index = fileByName[name], !claimed[index], inScope(items[index]) else {
                fileMatches[file.key] = .gone
                continue
            }
            let item = items[index]
            let oldID = file.id(on: side)
            if oldID == nil || item.documentID != oldID {
                let oldElsewhere = oldID.map { (pathsByID[$0] ?? []).contains { $0 != name } } ?? false
                let newHeld = usable(item.documentID).map { recordIDs.contains($0) } ?? false
                if oldElsewhere || newHeld {
                    fileMatches[file.key] = .gone
                    continue
                }
            }
            claimed[index] = true
            fileMatches[file.key] = .found(item, by: .name)
        }

        let unclaimed = items.indices
            .filter { !claimed[$0] && items[$0].kind == .file && inScope(items[$0]) }
            .map { items[$0] }
            .sorted { $0.path < $1.path }

        var result = OneWaySyncSideMatches(folders: folderMatches, files: fileMatches, unclaimed: unclaimed, sharedIDs: sharedIDs)
        result.folderPaths = folderNow
        result.side = side
        return result
    }

    // MARK: - Unrecorded files, across the sides

    /// Pairs unrecorded iCloud files with unrecorded Dropbox files. By name everywhere (the planner
    /// decides what a same-name pair means); by contents only within folders on their first run.
    /// Paired items leave the unclaimed lists.
    static func pair(
        record: OneWaySyncRecord,
        iCloud: inout [OneWaySyncItem], dropbox: inout [OneWaySyncItem],
        dropboxListing: OneWaySyncListing
    ) -> [OneWaySyncPair] {
        let key = OneWaySyncSide.dropbox.nameKey
        var pairs: [OneWaySyncPair] = []

        var dropboxByName: [String: Int] = [:]
        for (index, item) in dropbox.enumerated() where dropboxByName[key(item.path)] == nil {
            dropboxByName[key(item.path)] = index
        }
        var takenDropbox = Set<Int>()
        var takenICloud = Set<Int>()
        for (index, item) in iCloud.enumerated() {
            guard let match = dropboxByName[key(item.path)], !takenDropbox.contains(match) else { continue }
            takenDropbox.insert(match)
            takenICloud.insert(index)
            pairs.append(OneWaySyncPair(iCloud: item, dropbox: dropbox[match], basis: .name))
        }

        // By contents: on a first run only, and only where nothing else could be the match.
        let firstRun = Set(record.syncedFolders.filter { !$0.firstRunCompleted }.flatMap { [key($0.iCloudPath), key($0.dropboxPath)] })
        if !firstRun.isEmpty {
            struct Shape: Hashable { var size: Int64; var type: String }
            func shape(_ item: OneWaySyncItem) -> Shape {
                Shape(size: item.size, type: (item.path as NSString).pathExtension.lowercased())
            }
            func candidate(_ item: OneWaySyncItem) -> Bool {
                firstRun.contains(key(OneWaySyncPath.top(item.path))) && item.size > contentsPairingMinimumSize
            }
            var iCloudByShape: [Shape: [Int]] = [:]
            for (index, item) in iCloud.enumerated() where !takenICloud.contains(index) && candidate(item) {
                iCloudByShape[shape(item), default: []].append(index)
            }
            var dropboxByShape: [Shape: [Int]] = [:]
            for (index, item) in dropbox.enumerated() where !takenDropbox.contains(index) && candidate(item) {
                dropboxByShape[shape(item), default: []].append(index)
            }
            let occupied = Set(dropboxListing.items.map { key($0.path) })
            for (shape, iCloudIndices) in iCloudByShape.sorted(by: { iCloud[$0.value[0]].path < iCloud[$1.value[0]].path }) {
                guard iCloudIndices.count == 1, let dropboxIndices = dropboxByShape[shape], dropboxIndices.count == 1 else { continue }
                let i = iCloud[iCloudIndices[0]], d = dropbox[dropboxIndices[0]]
                guard let hash = i.contentHash, hash == d.contentHash, !occupied.contains(key(i.path)) else { continue }
                takenICloud.insert(iCloudIndices[0])
                takenDropbox.insert(dropboxIndices[0])
                pairs.append(OneWaySyncPair(iCloud: i, dropbox: d, basis: .contents))
            }
        }

        iCloud = iCloud.indices.filter { !takenICloud.contains($0) }.map { iCloud[$0] }
        dropbox = dropbox.indices.filter { !takenDropbox.contains($0) }.map { dropbox[$0] }
        return pairs
    }
}
