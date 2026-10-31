//
//  OneWaySyncRows.swift
//  SyncCloud
//

import Foundation

/// What stops the whole sync before or instead of a pass. Each is one row under *Needs you*.
public enum OneWaySyncStopReason: Equatable, Sendable {
    case dropboxNotRunning
    case dropboxNeverQuiet
    /// A parent can't be read, or written: no access, or an access prompt unanswered.
    case noAccess(folder: String)
    /// A parent moved, was renamed, or its link now leads elsewhere.
    case parentMoved(String)
    case iCloudSignedOut
    case needsNewFirstRun(OneWaySyncNewFirstRunReason)
    case twoMacsClaim
    case markerUnavailable
    case overRemovalLimitAcrossFolders(count: Int)
    case lowDiskSpace(needed: Int64, free: Int64)
    /// Dropbox files in the synced folders not on this Mac (online-only): unsupported.
    case dropboxFilesNotHere(count: Int)
    /// Anything else that stopped a pass, in words: a save that failed, say.
    case failed(String)
}

/// **Activity ▸ Now's rows for one-way sync**, from what a pass found: the page's *What waits*
/// table, row by row, with its buttons. Pure; the app raises them and clears what no longer holds.
///
/// Every id starts with `prefix`. A whole-sync stop is `ows:stop:…`; a folder's row
/// `ows:folder:<name>:…`; a file's `ows:file:<path>`; an information row `ows:info:…`.
public enum OneWaySyncRows {
    public static let prefix = "ows:"
    public static let stopPrefix = "ows:stop:"

    // MARK: Stops

    public static func stop(_ reason: OneWaySyncStopReason, at now: Date) -> OneWaySyncNotice {
        func row(_ id: String, _ title: String, _ detail: String?, _ buttons: [OneWaySyncNoticeButton]) -> OneWaySyncNotice {
            OneWaySyncNotice(id: stopPrefix + id, kind: .needsYou, scope: .wholeSync, title: title, detail: detail,
                             buttons: buttons, raisedAt: now)
        }
        switch reason {
        case .dropboxNotRunning:
            return row("dropbox", "Sync stopped: the Dropbox app isn’t running",
                       "SyncCloud syncs only while Dropbox runs, so Dropbox’s copies here are current.", [.openDropbox, .retry])
        case .dropboxNeverQuiet:
            return row("busy", "Sync stopped: Dropbox hasn’t been quiet for 30 minutes",
                       "Changes keep arriving in the synced folders, so SyncCloud waits rather than write over them.", [.retry])
        case .noAccess(let folder):
            return row("access", "Sync stopped: no access to \(folder)",
                       "macOS hasn’t given SyncCloud access to the folder, or a prompt asking is still open.", [.grantAccess, .retry])
        case .parentMoved(let why):
            return row("parent", "Sync stopped: \(why)", "Nothing is re-created; find the folder, or turn one-way sync off.",
                       [.findFolder, .turnOff])
        case .iCloudSignedOut:
            return row("icloud", "Sync stopped: iCloud is signed out, or iCloud Drive is off",
                       "Nothing syncs until iCloud Drive is back.", [.openICloudSettings, .retry])
        case .needsNewFirstRun(let why):
            return row("first-run", "Needs a new first run", firstRunReason(why), [.reviewFirstRun])
        case .twoMacsClaim:
            return row("two-macs", "Two Macs both claim this sync",
                       "Dropbox holds a conflicted copy of the sync’s marker. Every Mac stops until one takes the sync over.",
                       [.syncFromThisMacInstead])
        case .markerUnavailable:
            return row("marker", "Sync stopped: Dropbox’s marker for this sync couldn’t be read",
                       "It says which Mac syncs. SyncCloud tries again at the next sync.", [.retry])
        case .overRemovalLimitAcrossFolders(let count):
            return row("limit", "\(count) removals wait for you, across folders",
                       "Over the removal limit across all folders: nothing syncs until you review them.", [.review])
        case .lowDiskSpace(let needed, let free):
            return row("disk", "Sync stopped: this Mac is low on space",
                       "This sync needs \(bytes(needed)); \(bytes(free)) is free.", [.retry])
        case .dropboxFilesNotHere(let count):
            return row("online-only", count == 1 ? "Sync stopped: a Dropbox file isn’t on this Mac" : "Sync stopped: \(count) Dropbox files aren’t on this Mac",
                       "One-way sync works from the files on this Mac. Make the synced folders available offline in Dropbox.",
                       [.showThem, .retry])
        case .failed(let why):
            return row("failed", "Sync stopped: \(why)", nil, [.retry])
        }
    }

    static func firstRunReason(_ reason: OneWaySyncNewFirstRunReason) -> String {
        switch reason {
        case .noRecord, .unreadable: return "The sync’s saved data is missing or unreadable."
        case .unsupportedVersion: return "The sync was saved by a newer SyncCloud."
        case .otherMac: return "The sync was set up on another Mac."
        case .otherICloudAccount: return "iCloud is signed in to a different account."
        case .otherDropboxAccount: return "Dropbox is signed in to a different account."
        case .otherDisk: return "The sync was set up on a different disk."
        case .noMarker: return "Dropbox no longer says which Mac syncs: it was turned off on another Mac, or the marker was lost."
        }
    }

    // MARK: A pass

    /// The rows a look raises: what waits, folder by folder and file by file, and what is only
    /// for your information. `knownUnsynced` are iCloud folders already announced or declined.
    public static func rows(for look: OneWaySyncLook, knownUnsynced: Set<String>, at now: Date) -> [OneWaySyncNotice] {
        var rows: [OneWaySyncNotice] = []
        let plan = look.plan
        if case .overRemovalLimitAcrossFolders(let count) = plan.stop {
            rows.append(stop(.overRemovalLimitAcrossFolders(count: count), at: now))
        }

        // Over the limit in one folder: one row per folder, its removals listed in Review.
        var overLimit: [String: (removals: Int, replacements: Int)] = [:]
        for wait in plan.waits where wait.reason == .overRemovalLimit {
            guard case .file(let iCloudPath, let dropboxPath) = wait.subject else { continue }
            let folder = OneWaySyncPath.top(iCloudPath ?? dropboxPath ?? "")
            let replacement = iCloudPath.flatMap(look.iCloudItem) != nil
            var count = overLimit[folder] ?? (0, 0)
            if replacement { count.replacements += 1 } else { count.removals += 1 }
            overLimit[folder] = count
        }
        for (folder, count) in overLimit.sorted(by: { $0.key < $1.key }) {
            let total = count.removals + count.replacements
            let what = count.replacements == 0 ? (total == 1 ? "removal" : "removals")
                : count.removals == 0 ? (total == 1 ? "replacement" : "replacements") : "removals and replacements"
            rows.append(OneWaySyncNotice(
                id: "ows:folder:\(folder):limit", kind: .needsYou, scope: .folder(folder),
                title: "\(folder): \(total) \(what) wait for you",
                detail: "Over the removal limit for \(folder) in 24 hours. Everything else keeps syncing.",
                buttons: [.review], raisedAt: now))
        }

        for wait in plan.waits where wait.reason.needsYou && wait.reason != .overRemovalLimit && wait.reason != .overRemovalLimitAcrossFolders {
            switch wait.subject {
            case .folder(let name):
                rows.append(folderRow(name, wait.reason, at: now))
            case .file(let iCloudPath, let dropboxPath):
                rows.append(fileRow(iCloudPath: iCloudPath, dropboxPath: dropboxPath, wait.reason, at: now))
            }
        }

        for folder in plan.notFullyListed {
            rows.append(OneWaySyncNotice(
                id: "ows:folder:\(folder):listing", kind: .needsYou, scope: .folder(folder),
                title: "iCloud hasn’t listed \(folder) fully on this Mac",
                detail: "Nothing in it syncs, and nothing anywhere is removed, until it has.",
                buttons: [.downloadFolderList], raisedAt: now))
        }

        // For your information.
        if !plan.dropboxOnly.isEmpty {
            let count = plan.dropboxOnly.count
            rows.append(OneWaySyncNotice(
                id: "ows:info:dropbox-only", kind: .information, scope: .wholeSync,
                title: count == 1 ? "1 file is only in Dropbox" : "\(count) files are only in Dropbox",
                detail: "Inside synced folders · left alone", buttons: [.showThem], raisedAt: now))
        }
        let dropboxTops = Set(look.pass.dropbox.items.filter { $0.kind == .folder && OneWaySyncPath.depth($0.path) == 1 }
            .map { OneWaySyncSide.dropbox.nameKey($0.path) })
        let known = Set(knownUnsynced.map(OneWaySyncSide.iCloud.nameKey))
        let shared = Set(look.iCloud.sharedFolders.map(OneWaySyncSide.iCloud.nameKey))
        for folder in plan.unsyncedICloudFolders where !known.contains(OneWaySyncSide.iCloud.nameKey(folder))
            && !shared.contains(OneWaySyncSide.iCloud.nameKey(folder)) {
            let inDropbox = dropboxTops.contains(OneWaySyncSide.dropbox.nameKey(folder))
            rows.append(OneWaySyncNotice(
                id: "ows:info:new-folder:\(folder)", kind: .information, scope: .folder(folder),
                title: "\(folder) is new in iCloud",
                detail: inDropbox ? "Not synced. Dropbox has a \(folder) folder too." : "Not synced. Dropbox has no \(folder) folder.",
                buttons: [.createInDropboxAndSync], raisedAt: now))
        }
        let skipped = look.iCloud.skipped
        if !skipped.isEmpty {
            rows.append(OneWaySyncNotice(
                id: "ows:info:skipped", kind: .information, scope: .wholeSync,
                title: skipped.count == 1 ? "1 item skipped" : "\(skipped.count) items skipped",
                detail: skippedDetail(skipped), buttons: [.showThem], raisedAt: now))
        }
        return rows
    }

    /// "Icon file and desktop.ini (Dropbox won’t take them), 1 symlink · nothing else waits".
    static func skippedDetail(_ skipped: [OneWaySyncSkippedItem]) -> String {
        var parts: [String] = []
        let refused = skipped.filter { $0.reason == "Dropbox won’t take it" }
        if !refused.isEmpty {
            let names = Array(Set(refused.map { OneWaySyncPath.name($0.path) == "Icon\r" ? "Icon file" : OneWaySyncPath.name($0.path) })).sorted()
            parts.append(names.joined(separator: " and ") + (refused.count == 1 ? " (Dropbox won’t take it)" : " (Dropbox won’t take them)"))
        }
        let links = skipped.filter { $0.reason == "a symlink" }.count
        if links > 0 { parts.append(links == 1 ? "1 symlink" : "\(links) symlinks") }
        let libraries = skipped.filter { $0.reason == "a live library" }.count
        if libraries > 0 { parts.append(libraries == 1 ? "1 live library" : "\(libraries) live libraries") }
        let others = skipped.count - refused.count - links - libraries
        if others > 0 { parts.append("\(others) more") }
        return parts.joined(separator: ", ") + " · nothing else waits"
    }

    static func folderRow(_ name: String, _ reason: OneWaySyncWaitReason, at now: Date) -> OneWaySyncNotice {
        let id = "ows:folder:\(name):\(reasonKey(reason))"
        switch reason {
        case .syncedFolderRenamedInICloud(let to):
            return OneWaySyncNotice(id: id, kind: .needsYou, scope: .folder(name), title: "\(name) was renamed to \(to) in iCloud",
                                    detail: "\(name) waits. Nothing copied or removed meanwhile.",
                                    buttons: [.renameDropboxsToo, .stopSyncing], raisedAt: now)
        case .syncedFolderMovedOrDeletedInICloud:
            return OneWaySyncNotice(id: id, kind: .needsYou, scope: .folder(name), title: "\(name) was moved or deleted in iCloud",
                                    detail: "\(name) waits. Removing it moves only synced files; it stays while it holds files only in Dropbox.",
                                    buttons: [.moveToSyncCloudRemoved, .stopSyncing], raisedAt: now)
        default:
            return OneWaySyncNotice(id: id, kind: .needsYou, scope: .folder(name),
                                    title: "\(name) was renamed, moved or deleted in Dropbox",
                                    detail: "\(name) waits. Match iCloud puts it back as it is in iCloud.",
                                    buttons: [.matchICloud, .stopSyncing], raisedAt: now)
        }
    }

    static func fileRow(iCloudPath: String?, dropboxPath: String?, _ reason: OneWaySyncWaitReason, at now: Date) -> OneWaySyncNotice {
        let path = iCloudPath ?? dropboxPath ?? ""
        let name = OneWaySyncPath.name(path)
        let folder = OneWaySyncPath.top(path)
        let scope = OneWaySyncNotice.Scope.file(folder: folder, path: path)
        let rest = "\(folder) · this file waits; the rest keeps syncing"
        func row(_ title: String, _ detail: String, _ buttons: [OneWaySyncNoticeButton]) -> OneWaySyncNotice {
            OneWaySyncNotice(id: "ows:file:\(path)", kind: .needsYou, scope: scope, title: title, detail: detail,
                             buttons: buttons, raisedAt: now)
        }
        switch reason {
        case .editedInDropbox:
            return row("\(name) was edited in Dropbox", rest, [.chooseAVersion])
        case .editedOnBothSides:
            return row("\(name) was edited in iCloud and in Dropbox", rest, [.chooseAVersion])
        case .deletedInICloudEditedInDropbox:
            return row("\(name) was deleted in iCloud but edited in Dropbox", rest, [.chooseAVersion])
        case .conflictedCopy:
            return row("Dropbox made a conflicted copy of \(name)", rest, [.chooseAVersion])
        case .dropboxNewerOnFirstRun:
            return row("\(name) is newer in Dropbox", "\(folder) · first run · this file waits", [.chooseAVersion])
        case .sameDateOnFirstRun, .futureDateOnFirstRun:
            return row("\(name) differs, and which is newer is unclear", "\(folder) · first run · this file waits", [.chooseAVersion])
        case .deletedOrMovedInDropbox:
            return row("\(name) was deleted, renamed or moved in Dropbox", rest, [.matchICloud, .stopSyncingThisFile])
        case .changedInDropboxAgainToday:
            return row("\(name) was changed in Dropbox again today", "\(folder) · SyncCloud put it back once already; this file waits",
                       [.matchICloud, .stopSyncingThisFile])
        case .changedOnBothSides:
            return row("\(name) was changed in iCloud and in Dropbox", rest, [.matchICloud, .stopSyncingThisFile])
        case .nameTakenByDropboxOnlyFile(let other), .nameTaken(let other):
            return row("\(name)’s name is taken in Dropbox", "\(folder) · \(OneWaySyncPath.name(other)) is there with other contents · this file waits",
                       [.showBoth, .renameIClouds])
        default:
            return row("\(name) waits", rest, [.syncNow])
        }
    }

    static func reasonKey(_ reason: OneWaySyncWaitReason) -> String {
        switch reason {
        case .syncedFolderRenamedInICloud: return "renamed"
        case .syncedFolderMovedOrDeletedInICloud: return "gone"
        case .syncedFolderChangedInDropbox: return "dropbox"
        default: return "waits"
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
