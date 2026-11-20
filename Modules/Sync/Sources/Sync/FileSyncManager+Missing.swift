import Events
import Foundation

/// The Missing lens's scan: one names-only walk, then ``MissingStatements`` over what it listed.
/// It opens no file and never moves, renames or fetches one.
extension FileSyncManager {

    public var isFindingMissingStatements: Bool { missingLifecycle.isRunning }

    /// The root the report on screen was walked from.
    public var missingRoot: URL? { missingLifecycle.root }

    /// Starts a cancellable walk of `root`, replacing any in flight.
    public func startFindingMissingStatements(root: URL, choices: MissingStatements.Choices,
                                              now: Date = Date(), calendar: Calendar = .current) {
        missingTask = restartedScanTask(replacing: missingTask) { [weak self] in
            await self?.findMissingStatements(root: root, choices: choices, now: now, calendar: calendar)
        }
    }

    public func cancelFindingMissingStatements() {
        missingTask?.cancel()
    }

    /// Clears the report, so one source's accounts are never shown under another.
    public func clearMissingStatements() {
        missingTask?.cancel()
        missingReport = nil
        missingWalk = nil
        missingLifecycle.root = nil
        missingLifecycle.completedAt = nil
        missingLifecycle.hasCompleted = false
    }

    /// The same walk under new choices: no disk is read. Nothing happens before a first walk.
    public func applyMissingChoices(_ choices: MissingStatements.Choices, now: Date = Date(),
                                    calendar: Calendar = .current) {
        guard let walk = missingWalk else { return }
        missingReport = MissingStatements.find(paths: walk.paths, notChecked: walk.notChecked, now: now,
                                               calendar: calendar, choices: choices)
    }

    /// Every file under `tree` by its path relative to the walked root, and the folders the walk
    /// could not list. A folder that was not listed is unknown, never empty.
    nonisolated static func missingStatementPaths(in tree: [FileNode]) -> (paths: [String], notChecked: [String]) {
        var paths: [String] = []
        var notChecked: [String] = []
        func visit(_ node: FileNode, _ prefix: String) {
            let path = prefix.isEmpty ? node.name : prefix + "/" + node.name
            guard node.isDirectory else {
                paths.append(path)
                return
            }
            if node.isUnexplored == true {
                notChecked.append(path)
                return
            }
            for child in node.children ?? [] { visit(child, path) }
        }
        for node in tree { visit(node, "") }
        return (paths, notChecked)
    }

    func findMissingStatements(root: URL, choices: MissingStatements.Choices, now: Date, calendar: Calendar) async {
        guard !isFindingMissingStatements else { return }
        beginScan(\.missingLifecycle, status: "Reading names in \(root.lastPathComponent)…")
        defer { endScan(\.missingLifecycle) }

        let tree: [FileNode]
        switch await walkWholeTree(root, pass: .missingStatements, fileManager: fileManager) {
        case .walked(let walked): tree = walked
        case .cancelled: return
        case .declined(let preflight):
            Logger.shared.info("Missing: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not checked")
            return
        }
        let report = await Task.detached(priority: .userInitiated) {
            let walk = Self.missingStatementPaths(in: tree)
            return (walk, MissingStatements.find(paths: walk.paths, notChecked: walk.notChecked, now: now,
                                                 calendar: calendar, choices: choices))
        }.value
        if Task.isCancelled { return }

        missingWalk = report.0
        missingReport = report.1
        completeScan(\.missingLifecycle, root: root)
        noteFirstMissingCheck(now: now, calendar: calendar)
        Logger.shared.info("Missing: read \(report.0.paths.count) name(s) under \(root.lastPathComponent) — "
            + "\(report.1.counted) statement(s) missing from \(report.1.countedAccounts) of \(report.1.accounts.count) account(s)"
            + (report.0.notChecked.isEmpty ? "" : ", \(report.0.notChecked.count) folder(s) not checked"))
    }
}

// MARK: - What the user decided

@MainActor
extension FileSyncManager {

    /// Whether choices made about the report on screen are kept: there is a ledger, it can be
    /// written, and the survey it belongs to is of the folder that was walked. The choices are
    /// keyed by paths inside that folder, so under any other root they would name other accounts.
    public var missingChoicesAreKept: Bool {
        guard let store = restructureStore, !store.isUnreadable, let root = missingRoot,
              let profile = filingFolderProfile else { return false }
        let surveyed = URL(fileURLWithPath: (profile.root as NSString).expandingTildeInPath)
        return surveyed.standardizedFileURL.path == root.standardizedFileURL.path
    }

    /// The choices that apply to a walk of `root`: the ledger's when its survey is of that folder,
    /// none otherwise.
    public func missingChoices(for root: URL) -> MissingStatements.Choices {
        guard let store = restructureStore, let profile = filingFolderProfile else { return .init() }
        let surveyed = URL(fileURLWithPath: (profile.root as NSString).expandingTildeInPath)
        return surveyed.standardizedFileURL.path == root.standardizedFileURL.path ? store.missing : .init()
    }

    /// One decision in the Missing lens (hide an account, stop tracking it, take a gap off the
    /// count): saved to the ledger, applied to the report with no new walk, and undoable.
    ///
    /// `actionName` is the menu's "Undo …" and `message` the banner's sentence. Does nothing when
    /// choices are not kept here, or when `change` changes nothing.
    public func changeMissingChoices(actionName: String, message: String,
                                     _ change: (inout MissingStatements.Choices) -> Void) {
        guard missingChoicesAreKept, let store = restructureStore else { return }
        let before = store.missing
        guard store.updateMissing(actionName, change) else { return }
        applyMissingChoices(store.missing)
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreMissingChoices(before, in: store, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        banner = .success(message, undoable: undoManager != nil)
    }

    /// ⌘Z, and ⌘⇧Z after it: puts the ledger's choices back as they were. Only in the ledger the
    /// decision was made in, and only while the app still reads it: after a source switch the
    /// current ledger is another folder's, where the same paths name other accounts.
    func restoreMissingChoices(_ choices: MissingStatements.Choices, in store: RestructureStore, actionName: String) {
        guard restructureStore === store else {
            Logger.shared.info("Missing: not undoing “\(actionName)” — the folder it was decided in is no longer on screen")
            return
        }
        let before = store.missing
        guard store.updateMissing("undo of \(actionName)", { $0 = choices }) else { return }
        applyMissingChoices(store.missing)
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreMissingChoices(before, in: store, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Records when this folder was first checked, once. Accounts already silent then are the
    /// quiet ones; every other account is tracked from then on and never goes quiet by itself.
    func noteFirstMissingCheck(now: Date, calendar: Calendar) {
        guard missingChoicesAreKept, let store = restructureStore, store.missing.firstChecked == nil else { return }
        let parts = calendar.dateComponents([.year, .month], from: now)
        guard let year = parts.year, let month = parts.month else { return }
        store.updateMissing("first checked in \(year)-\(month)") {
            $0.firstChecked = MissingStatements.Month(year: year, month: month)
        }
    }
}
