import AppKit
import Events
import Foundation
import Sync

/// Now's buttons, each answered here: the sheets they open, and the one-step answers that run at
/// once and then sync.
extension OneWaySyncController {

    /// Where Now's rows show their result when an answer can't go through.
    public func perform(_ button: OneWaySyncNoticeButton, row: OneWaySyncNoticeRow, from host: OneWaySyncSheetHost = .main) {
        sheetHost = host
        let notice = row.members.first
        switch button {
        case .openDropbox:
            CloudAppMonitor.shared.open(.dropbox)
        case .openICloudSettings:
            CloudAppMonitor.shared.openICloudSettings()
        case .retry, .syncNow:
            syncNow()
        case .showThem:
            show(row)
        case .grantAccess:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                NSWorkspace.shared.open(url)
            }
        case .chooseItemsToEmpty:
            sheet = .chooseItemsToEmpty
        case .review:
            if row.id.hasPrefix("group:") {
                sheet = .group(String(row.id.dropFirst("group:".count)))
            } else if case .folder(let folder) = notice?.scope {
                sheet = .review(folder: folder)
            } else {
                sheet = .review(folder: nil)
            }
        case .findFolder:
            findFolder()
        case .turnOff:
            confirmTurnOff()
        case .reviewFirstRun:
            sheet = .setup(replacing: true)
        case .syncFromThisMacInstead:
            confirmSyncFromThisMacInstead(from: host)
        case .renameDropboxsToo, .moveToSyncCloudRemoved, .stopSyncing, .downloadFolderList, .createInDropboxAndSync:
            guard case .folder(let folder) = notice?.scope else { return }
            Task { await answerFolder(button, folder: folder) }
        case .matchICloud:
            if case .folder(let folder) = notice?.scope {
                Task { await answerFolder(button, folder: folder) }
            } else if let path = filePath(of: notice) {
                Task { await answerFile(button, path: path) }
            }
        case .chooseAVersion, .stopSyncingThisFile, .showBoth, .renameIClouds:
            guard let path = filePath(of: notice) else { return }
            Task { await answerFile(button, path: path) }
        }
    }

    func filePath(of notice: OneWaySyncNotice?) -> String? {
        if case .file(_, let path) = notice?.scope { return path }
        return nil
    }

    /// The wait a file row is about, in a fresh look.
    func subject(forFile path: String, in look: OneWaySyncLook) -> OneWaySyncWait.Subject? {
        look.plan.waits.first { wait in
            guard case .file(let i, let d) = wait.subject else { return false }
            return i == path || d == path
        }?.subject
    }

    // MARK: Files

    func answerFile(_ button: OneWaySyncNoticeButton, path: String) async {
        guard let look = await freshLook(), let subject = subject(forFile: path, in: look),
              let versions = OneWaySyncAnswers.versions(for: subject, in: look) else {
            // The cause cleared since: the next pass clears the row.
            syncNow()
            return
        }
        switch button {
        case .chooseAVersion:
            sheet = .chooseVersion(subject)
        case .renameIClouds:
            sheet = .renameICloud(subject)
        case .showBoth:
            guard let record else { return }
            let places = places(for: record)
            var urls: [URL] = []
            if let i = versions.iCloud { urls.append(places.iCloudParent.appendingPathComponent(i.path)) }
            if let d = versions.dropbox { urls.append(places.dropboxParent.appendingPathComponent(d.path)) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .matchICloud:
            _ = await answer("put \(OneWaySyncPath.name(versions.iCloudPath)) back as it is in iCloud") { writer in
                try OneWaySyncAnswers.matchICloud(versions, writer: writer)
            }
        case .stopSyncingThisFile:
            stopSyncingFile(versions)
        default:
            break
        }
    }

    public func stopSyncingFile(_ versions: OneWaySyncVersions) {
        guard let record else { return }
        let (newRecord, newExclusions) = OneWaySyncAnswers.stopSyncingFile(versions, record: record, exclusions: exclusions, now: Date())
        do {
            try save(newExclusions)
            try save(newRecord)
        } catch {
            Logger.shared.error("One-way sync: couldn’t stop syncing \(versions.iCloudPath): \(error.localizedDescription)")
            return
        }
        Logger.shared.info("One-way sync: stopped syncing \(versions.iCloudPath)")
        syncNow()
    }

    /// *Sync Again…* for a file you stopped syncing.
    public func syncAgain(_ exclusion: OneWaySyncExclusion) {
        do { try save(OneWaySyncAnswers.syncAgain(exclusion, exclusions: exclusions)) } catch { return }
        Logger.shared.info("One-way sync: syncing \(exclusion.iCloudPath) again")
        syncNow()
    }

    /// *Use iCloud’s* in *Choose a Version…*.
    public func useICloudsVersion(_ versions: OneWaySyncVersions) async -> String? {
        await answer("used iCloud’s \(OneWaySyncPath.name(versions.iCloudPath))") { writer in
            try OneWaySyncAnswers.useICloudsVersion(versions, writer: writer)
        }
    }

    /// *Copy Dropbox’s into iCloud* in *Choose a Version…*.
    public func copyDropboxsIntoICloud(_ versions: OneWaySyncVersions) async -> String? {
        await answer("copied Dropbox’s \(OneWaySyncPath.name(versions.dropboxPath)) into iCloud") { writer in
            try OneWaySyncAnswers.copyDropboxsIntoICloud(versions, writer: writer)
        }
    }

    /// *Rename iCloud’s…*.
    public func renameICloud(_ versions: OneWaySyncVersions, to name: String) async -> String? {
        guard let record else { return nil }
        let places = places(for: record)
        let path = versions.iCloudPath
        return await answer("renamed \(OneWaySyncPath.name(path)) to \(name) in iCloud") { _ in
            try OneWaySyncAnswers.renameICloudFile(path, to: name, places: places)
        }
    }

    // MARK: Folders

    func answerFolder(_ button: OneWaySyncNoticeButton, folder: String) async {
        guard let record, !isRunning, !isAnswering else { return }
        switch button {
        case .stopSyncing:
            stopSyncingFolder(folder)
        case .createInDropboxAndSync:
            let places = places(for: record)
            if let failure = await answer("made \(folder) in Dropbox", then: false, { _ in
                try OneWaySyncAnswers.createInDropbox(folder, places: places)
            }) {
                Logger.shared.info("One-way sync: \(folder) couldn’t be made in Dropbox: \(failure)")
                return
            }
            let draft = await draft(iCloudParent: places.iCloudParent, dropboxParent: places.dropboxParent)
            // The record as it is now, not as it was before the awaits.
            guard let current = self.record,
                  let added = OneWaySyncSetup.adding(folder, to: current, iCloud: draft.iCloud, dropbox: draft.dropbox) else { return }
            try? save(added)
            center.clearOneWaySync(["ows:info:new-folder:\(folder)"])
            syncNow()
        case .downloadFolderList:
            let base = places(for: record).iCloudParent.appendingPathComponent(folder)
            await Task.detached(priority: .utility) { Self.readListings(below: base) }.value
            Logger.shared.info("One-way sync: asked iCloud for \(folder)’s full listing")
            syncNow()
        case .renameDropboxsToo:
            guard let look = await freshLook() else { return }
            nonisolated(unsafe) var renamed: OneWaySyncRecord?
            let failure = await answer("renamed \(folder) in Dropbox too", then: false) { writer in
                renamed = try OneWaySyncAnswers.renameDropboxFolderToo(folder, look: look, writer: writer)
            }
            if failure == nil, let renamed {
                try? save(renamed)
                clearRows(ofFolder: folder)
                watchDropboxAgain()
                syncNow()
            }
        case .moveToSyncCloudRemoved:
            guard let look = await freshLook() else { return }
            nonisolated(unsafe) var result: (OneWaySyncRecord, failed: [String])?
            _ = await answer("moved \(folder)’s synced files to SyncCloud Removed", then: false) { writer in
                result = OneWaySyncAnswers.moveFolderToRemoved(folder, look: look, writer: writer)
            }
            guard let result else { return }
            try? save(result.0)
            if result.failed.isEmpty { clearRows(ofFolder: folder) }
            syncNow()
        case .matchICloud:
            guard let look = await freshLook() else { return }
            _ = await answer("put \(folder) back as it is in iCloud") { writer in
                try OneWaySyncAnswers.matchICloudFolder(folder, look: look, writer: writer)
            }
        default:
            break
        }
    }

    /// *Stop Syncing* a folder: its record goes; Dropbox's copy stays as it is.
    public func stopSyncingFolder(_ folder: String) {
        guard let record else { return }
        do { try save(OneWaySyncSetup.removing(folder, from: record)) } catch { return }
        clearRows(ofFolder: folder)
        saveState { $0.knownUnsyncedFolders = Array(Set($0.knownUnsyncedFolders).union([folder])).sorted() }
        watchDropboxAgain()
        Logger.shared.info("One-way sync: stopped syncing \(folder)")
    }

    func watchDropboxAgain() { start() }

    /// Reads every folder below `base`, which asks iCloud for the listings it hasn't brought here.
    nonisolated static func readListings(below base: URL) {
        var pending = [base]
        while let folder = pending.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let url = folder.appendingPathComponent(name)
                if OneWaySyncDisk.kind(at: url.path) == .folder { pending.append(url) }
            }
        }
    }

    // MARK: The removal limit

    /// *Apply* in *Review…*: the ticked go ahead (and don't count toward the limit); the unticked
    /// stay in Dropbox.
    public func applyReview(go: [OneWaySyncPendingRemoval], keep: [OneWaySyncPendingRemoval], look: OneWaySyncLook) {
        guard let record else { return }
        if !keep.isEmpty {
            let (newRecord, newExclusions) = OneWaySyncAnswers.keepInDropbox(keep, look: look, record: record, exclusions: exclusions, now: Date())
            try? save(newExclusions)
            try? save(newRecord)
        }
        if !go.isEmpty { saveState { $0.confirmed = Array(Set($0.confirmed).union(go.map(\.record))).sorted() } }
        Logger.shared.info("One-way sync: \(go.count) removals confirmed, \(keep.count) kept in Dropbox")
        syncNow()
    }

    // MARK: Reverse in iCloud

    /// The History entry, when it may be reversed at all.
    public func reversible(_ entry: OneWaySyncHistoryEntry) -> Bool {
        guard let firstRun else { return false }
        return OneWaySyncHistoryStore.canReverse(entry, firstRun: firstRun, now: Date())
    }

    public func reverse(_ chosen: [OneWaySyncReversal]) async -> [String] {
        guard let record else { return [] }
        let places = places(for: record)
        let failed: [String] = await Task.detached(priority: .userInitiated) {
            guard let writer = try? OneWaySyncWriter(places: places) else { return ["SyncCloud’s staging folder isn’t usable"] }
            return OneWaySyncAnswers.reverse(chosen, writer: writer).map { "\($0.0.item): \($0.1)" }
        }.value
        Logger.shared.info("One-way sync: reversed \(chosen.count - failed.count) changes in iCloud"
                           + (failed.isEmpty ? "" : "; not: " + failed.joined(separator: "; ")))
        syncNow()
        return failed
    }

    // MARK: Show

    func show(_ row: OneWaySyncNoticeRow) {
        guard let record else { return }
        let places = places(for: record)
        let paths: [String]
        switch row.id {
        case "ows:info:dropbox-only":
            paths = (lastLook?.plan.dropboxOnly ?? []).map { places.dropboxParent.appendingPathComponent($0).path }
        case OneWaySyncRows.stopPrefix + "online-only":
            paths = (lastLook?.dropboxNotHere ?? []).map { places.dropboxParent.appendingPathComponent($0).path }
        case "ows:info:skipped":
            paths = (lastLook?.iCloud.skipped ?? []).map { places.iCloudParent.appendingPathComponent($0.path).path }
        default:
            paths = []
        }
        guard !paths.isEmpty else {
            // Not in the last look (a relaunch since): look once, then show what there is.
            Task {
                guard let look = await freshLook() else { return }
                let paths: [String]
                switch row.id {
                case "ows:info:dropbox-only": paths = look.plan.dropboxOnly.map { places.dropboxParent.appendingPathComponent($0).path }
                case "ows:info:skipped": paths = look.iCloud.skipped.map { places.iCloudParent.appendingPathComponent($0.path).path }
                default: paths = look.dropboxNotHere.map { places.dropboxParent.appendingPathComponent($0).path }
                }
                if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths.prefix(200).map { URL(fileURLWithPath: $0) }) }
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(paths.prefix(200).map { URL(fileURLWithPath: $0) })
    }

    // MARK: Confirmations

    func confirmTurnOff() {
        let alert = NSAlert()
        alert.messageText = "Turn off one-way sync?"
        alert.informativeText = "SyncCloud stops syncing and forgets which files it synced. Dropbox’s copies stay as they are, "
            + "and so does Dropbox ▸ SyncCloud Removed. Turning it on again is a new first run."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { turnOff() }
    }

    func confirmSyncFromThisMacInstead(from host: OneWaySyncSheetHost = .main) {
        let alert = NSAlert()
        alert.messageText = "Sync from this Mac instead?"
        if let other = otherMac {
            let last = other.lastSyncAt.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .shortened) }
            alert.informativeText = "\(other.macName) syncs now" + (last.map { ", last on \($0)" } ?? "")
                + ". This Mac takes over with a new first run, and that Mac stops."
        } else {
            alert.informativeText = "This Mac takes the sync over with a new first run; any other Mac stops."
        }
        alert.addButton(withTitle: "Review First Run…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { syncFromThisMacInstead(from: host) }
    }

    /// Changing *If a Dropbox file is edited* to *Use iCloud’s* asks once.
    public func confirmUseICloudsOnEdit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace Dropbox edits with iCloud’s version?"
        alert.informativeText = "From now on, a synced file edited directly in Dropbox is replaced by iCloud’s, without asking. "
            + "Dropbox’s edit is kept in Dropbox ▸ SyncCloud Removed."
        alert.addButton(withTitle: "Use iCloud’s")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// *Find Folder…*: the parent that moved, found again. Only a folder whose synced folders carry
    /// the recorded IDs is taken; to choose a different parent, turn off and set up again.
    func findFolder() {
        guard var record else { return }
        let iCloudMoved = OneWaySyncSetup.parentProblem(record.iCloudParent) != nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = iCloudMoved ? "Find the iCloud folder one-way sync copies from" : "Find the Dropbox folder one-way sync copies to"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lister = OneWaySyncLister(side: iCloudMoved ? .iCloud : .dropbox, parent: url).list(syncedFolders: [])
        let inodes = Set(lister.listing.items.compactMap { $0.folderID?.inode })
        let recorded = record.syncedFolders.compactMap { (iCloudMoved ? $0.iCloudID : $0.dropboxID)?.inode }
        guard !recorded.isEmpty, recorded.allSatisfy(inodes.contains) else {
            let alert = NSAlert()
            alert.messageText = "That isn’t the same folder"
            alert.informativeText = "Its folders aren’t the ones one-way sync recorded. To sync a different folder, turn one-way sync off and set it up again."
            alert.runModal()
            return
        }
        if iCloudMoved { record.iCloudParent = OneWaySyncSetup.parentRecord(url) } else { record.dropboxParent = OneWaySyncSetup.parentRecord(url) }
        try? save(record)
        stop = nil
        center.clearOneWaySync([OneWaySyncRows.stopPrefix + "parent"])
        syncNow()
    }
}
