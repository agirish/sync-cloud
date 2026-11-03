import Events
import Foundation

/// What applying a card of changes did (TE262), row by row.
public struct AskClaudePlanOutcome: Sendable, Equatable {
    public enum Row: Sendable, Equatable {
        /// Done, in words: "Moved", "Kept as Ticket 2.pdf".
        case done(String)
        /// Refused before anything ran, or skipped when it came to it, with the reason.
        case refused(String)
        /// Tried, and the disk said no.
        case failed(String)

        public var isDone: Bool { if case .done = self { true } else { false } }
    }

    public var rows: [Int: Row] = [:]
    /// The undo step's name when anything changed; the card's Undo acts only while it tops the
    /// stack.
    public var undoName: String?

    public init(rows: [Int: Row] = [:], undoName: String? = nil) {
        self.rows = rows
        self.undoName = undoName
    }

    public var doneCount: Int { rows.values.filter(\.isDone).count }
}

extension FileSyncManager {

    /// Why no card can apply now (a run going, Verify All), or nil. The button waits; it never
    /// starts on its own.
    public var planApplyBlocker: String? {
        if isVerifyAllRunning { return "Verify All is running" }
        if let run = activeProgress { return run.runLockReason ?? Progress.genericRunLockReason }
        return nil
    }

    /// Why one change can't run, or nil (TE262): checked when Claude proposes it and again at
    /// Apply, so nothing is asked partway through. `creating` are folders the card makes first;
    /// `protected` are the sources' own folders.
    public func planRefusal(_ change: AskClaudePlan.Change, creating: Set<String> = [], isHidden: (String) -> Bool,
                            protected: Set<String>) -> String? {
        let fm = FileManager.default
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }
        func isFolder(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        func isProtected(_ path: String) -> Bool { protected.contains { PathBoundary.resolvesToSameDirectory($0, path, caseSensitive: false) } }
        /// Checks an item the change acts on: there, shown, not a source, not inside a package.
        func checkItem(_ path: String) -> String? {
            if isHidden(path) { return "It’s hidden from Claude" }
            guard exists(path) else { return "It isn’t there any more" }
            if isProtected(path) { return "It’s a source’s own folder" }
            if Self.enclosingPackage(of: URL(fileURLWithPath: parent(path))) != nil { return "It’s inside a document" }
            if let refusal = oneWaySyncRefusal?([path]) { return refusal }
            return nil
        }
        /// Checks a folder something goes into: there (or made by the card), shown, a folder.
        func checkFolder(_ folder: String) -> String? {
            if isHidden(folder) { return "\(name(folder)) is hidden from Claude" }
            if let document = Self.enclosingPackage(of: URL(fileURLWithPath: folder)) {
                return "\(document.lastPathComponent) is a document, not a folder"
            }
            guard creating.contains(folder) || isFolder(folder) else { return "\(name(folder)) isn’t there" }
            if let refusal = oneWaySyncRefusal?([folder]) { return refusal }
            return nil
        }
        // The pane's own rules, the disk's 255-unit limit among them.
        func checkName(_ new: String) -> String? { Self.validateItemName(new) }
        switch change {
        case .move(let from, let toFolder):
            if let why = checkItem(from) ?? checkFolder(toFolder) { return why }
            if PathBoundary.resolvesToSameDirectory(parent(from), toFolder, caseSensitive: false) { return "It’s already there" }
            if toFolder == from || toFolder.hasPrefix(from + "/") { return "A folder can’t go inside itself" }
            if !Self.onSameDisk(from, toFolder) { return "That’s on another disk; only moves on this Mac’s disk can be applied" }
            return checkName(name(from))
        case .rename(let path, let to):
            if let why = checkItem(path) ?? checkName(to) { return why }
            let target = (parent(path) as NSString).appendingPathComponent(to)
            if name(path) == to { return "It already has that name" }
            if name(path).lowercased() != to.lowercased(), exists(target) { return "\(to) is taken there" }
            return nil
        case .newFolder(let folder, let new):
            if let why = checkFolder(folder) ?? checkName(new) { return why }
            if exists((folder as NSString).appendingPathComponent(new)) { return "\(new) is already there" }
            return nil
        case .trash(let path):
            return checkItem(path)
        case .trashIfEmptied(let folders):
            for folder in folders { if let why = checkItem(folder) { return why } }
            return nil
        }
    }

    /// Both paths are on one volume: a move is a rename, quick and fully undone (decision FD).
    /// A path not there yet is judged by the nearest folder above it that is.
    nonisolated static func onSameDisk(_ a: String, _ b: String) -> Bool {
        func volume(_ path: String) -> NSObjectProtocol? {
            var current = URL(fileURLWithPath: path).standardizedFileURL
            while true {
                if let id = (try? current.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier { return id }
                let up = current.deletingLastPathComponent()
                if up.path == current.path { return nil }
                current = up
            }
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va.isEqual(vb)
    }

    /// Applies a card's ticked rows as ONE undo step named `actionName` (TE262): new folders
    /// first, then renames and moves, then the Trash. Each row is checked again here, at the click;
    /// one that fails its check is skipped with the reason, and the rest run. No dialog: a taken
    /// name keeps both (decision GE), and nothing is deleted outright. Every change is a History
    /// record, a new folder included.
    public func applyPlan(_ rows: [(id: Int, change: AskClaudePlan.Change)], actionName: String,
                          isHidden: (String) -> Bool, protected: Set<String>) async -> AskClaudePlanOutcome {
        var outcome = AskClaudePlanOutcome()
        if let blocker = planApplyBlocker {
            for row in rows { outcome.rows[row.id] = .refused("Waiting: \(blocker)") }
            return outcome
        }
        // Folders the card makes are where its moves may go, so they count as there.
        var creating = Set<String>()
        for row in rows { if case .newFolder(let folder, let name) = row.change { creating.insert((folder as NSString).appendingPathComponent(name)) } }
        var runnable: [(id: Int, change: AskClaudePlan.Change)] = []
        for row in rows {
            if let why = planRefusal(row.change, creating: creating, isHidden: isHidden, protected: protected) {
                outcome.rows[row.id] = .refused(why)
            } else {
                runnable.append(row)
            }
        }
        guard !runnable.isEmpty else { return outcome }
        func rank(_ c: AskClaudePlan.Change) -> Int {
            switch c {
            case .newFolder: return 0
            case .rename: return 1
            case .move: return 2
            case .trash: return 3
            case .trashIfEmptied: return 4
            }
        }
        let ordered = runnable.enumerated().sorted { (rank($0.element.change), $0.offset) < (rank($1.element.change), $1.offset) }.map(\.element)
        let fm = fileManager

        struct Done: Sendable {
            var rows: [Int: AskClaudePlanOutcome.Row] = [:]
            var created: [URL] = []
            var moved: [MoveItemState] = []
            /// Files (not folders) moved into a folder: filings, which teach the router (GW).
            var filed: [(from: URL, to: URL)] = []
            /// Trashed items, original and where the Trash put it.
            var trashed: [(original: URL, trashed: URL?)] = []
        }
        let done: Done = await enqueueFileOperation {
            var done = Done()
            for (id, change) in ordered {
                do {
                    switch change {
                    case .newFolder(let folder, let name):
                        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                        guard !fm.fileExists(atPath: url.path) else { done.rows[id] = .refused("\(name) is already there"); continue }
                        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                        done.created.append(url)
                        done.rows[id] = .done("Made")
                    case .rename(let path, let to):
                        let src = URL(fileURLWithPath: path)
                        let dst = src.deletingLastPathComponent().appendingPathComponent(to)
                        let caseOnly = src.lastPathComponent.lowercased() == to.lowercased()
                        guard fm.fileExists(atPath: src.path) else { done.rows[id] = .refused("It isn’t there any more"); continue }
                        guard caseOnly || !fm.fileExists(atPath: dst.path) else { done.rows[id] = .refused("\(to) is taken there"); continue }
                        let overwritten = try Self.safeMoveItem(at: src, to: dst, fileManager: fm,
                                                                caseSensitiveVolume: Self.volumeSupportsCaseSensitiveNames(for: src))
                        done.moved.append((from: src, to: dst, overwritten: overwritten))
                        done.rows[id] = .done("Renamed")
                    case .move(let from, let toFolder):
                        let src = URL(fileURLWithPath: from)
                        guard fm.fileExists(atPath: src.path) else { done.rows[id] = .refused("It isn’t there any more"); continue }
                        var dst = URL(fileURLWithPath: toFolder).appendingPathComponent(src.lastPathComponent)
                        if fm.fileExists(atPath: dst.path) { dst = Self.generateUniqueURL(for: dst, fileManager: fm) }
                        var isFolder: ObjCBool = false
                        let isFile = fm.fileExists(atPath: src.path, isDirectory: &isFolder) && !isFolder.boolValue
                        let overwritten = try Self.safeMoveItem(at: src, to: dst, fileManager: fm,
                                                                caseSensitiveVolume: Self.volumeSupportsCaseSensitiveNames(for: src))
                        done.moved.append((from: src, to: dst, overwritten: overwritten))
                        if isFile { done.filed.append((from: src, to: dst)) }
                        done.rows[id] = .done(dst.lastPathComponent == src.lastPathComponent ? "Moved" : "Moved, as \(dst.lastPathComponent)")
                    case .trash(let path):
                        let url = URL(fileURLWithPath: path)
                        guard fm.fileExists(atPath: url.path) else { done.rows[id] = .refused("It isn’t there any more"); continue }
                        var resulting: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &resulting)
                        done.trashed.append((original: url, trashed: resulting as URL?))
                        done.rows[id] = .done("Moved to Trash")
                    case .trashIfEmptied(let folders):
                        var went = 0
                        for folder in folders {
                            let url = URL(fileURLWithPath: folder)
                            // After the moves: only a folder left holding nothing but OS noise goes.
                            guard fm.fileExists(atPath: url.path), Self.mergeLeftNothing(in: url, fileManager: fm) else { continue }
                            var resulting: NSURL?
                            try fm.trashItem(at: url, resultingItemURL: &resulting)
                            done.trashed.append((original: url, trashed: resulting as URL?))
                            went += 1
                        }
                        done.rows[id] = went == folders.count ? .done("Moved to Trash")
                            : went == 0 ? .refused("Not empty, so left in place")
                            : .done("Moved \(went) of \(folders.count) to Trash; the rest still hold files")
                    }
                } catch {
                    done.rows[id] = .failed(error.localizedDescription)
                }
            }
            return done
        }
        outcome.rows.merge(done.rows) { _, new in new }

        // One undo step, registered in this turn with no await inside the group. Undo runs the
        // registrations last first, which is the apply backwards: out of the Trash, moves back
        // (the latest first), then the folders the card made, each removed only if empty.
        let anything = !done.created.isEmpty || !done.moved.isEmpty || done.trashed.contains { $0.trashed != nil }
        if anything, let undo = undoManager {
            undo.beginUndoGrouping()
            for url in done.created { registerCreateFolderUndo(url: url, fileManager: fm) }
            if !done.moved.isEmpty { _ = registerMoveUndo(items: done.moved.reversed(), actionName: actionName, fileManager: fm) }
            let restorable = done.trashed.filter { $0.trashed != nil }
            if !restorable.isEmpty {
                _ = registerRestoreItems(urls: restorable.map(\.original), trashedItems: restorable.map(\.trashed),
                                         actionName: actionName, fileManager: fm)
            }
            undo.endUndoGrouping()
            undo.setActionName(actionName)
            outcome.undoName = actionName
        }
        // History: folders made, moves and renames as moves, the Trash as a move to the Trash.
        let runId = UUID()
        var records = done.created.map { SyncHistoryRecord(runId: runId, action: .newFolder, sourcePath: $0.path) }
        records += done.moved.map { item in
            SyncHistoryRecord(runId: runId, action: .move, sourcePath: item.from.path, destPath: item.to.path,
                              backupPath: item.overwritten?.path)
        }
        records += done.trashed.map { item in
            SyncHistoryRecord(runId: runId, action: .delete, sourcePath: item.original.path, destPath: item.trashed?.path,
                              reachedTrash: true)
        }
        recordSyncHistory(records, pairedWithUndo: outcome.undoName != nil)
        for url in done.created { noteOwnWrite(atPath: url.path) }
        for item in done.moved { noteOwnWrite(atPath: item.to.path) }
        // A file Claude's card filed teaches the folder as a To File filing does (GW); the router
        // keeps it only for a folder in the tree it ranks, and drops it when Undo moves it back.
        for item in done.filed {
            learnFromFiling(fileName: item.from.lastPathComponent, sourcePath: item.from.path,
                            into: item.to.deletingLastPathComponent().path, filedPath: item.to.path)
        }
        Logger.shared.info("Ask Claude applied “\(actionName)”: \(outcome.doneCount) of \(rows.count) done"
            + (outcome.rows.count > outcome.doneCount ? ", \(outcome.rows.count - outcome.doneCount) skipped or failed" : ""))
        return outcome
    }
}
