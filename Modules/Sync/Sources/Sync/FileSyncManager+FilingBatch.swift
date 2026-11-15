import Events
import Foundation

/// File All: every Matched card the sheet left ticked, filed in one go and undone with one ⌘Z
/// (decision OQ).
extension FileSyncManager {

    /// Files each card's ``FilingCardItem/toFile`` to its own home, copies included, as one ⌘Z.
    ///
    /// `items` are the cards the sheet left ticked, never re-derived from ``filingSuggestions``: the
    /// sheet named exactly these. Each file is checked again (``FilingSuggestion/isMatched``), so a
    /// caller can't make this file a card that needs a look first. Files that fail stay listed as
    /// cards of their own.
    /// - Returns: how many files moved.
    @discardableResult
    public func applyFilingBatch(_ items: [FilingCardItem]) async -> Int {
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before filing", log: .info)
            return 0
        }
        let homes: [(FilingSuggestion, FilingDestination)] = items.flatMap(\.toFile).compactMap { s in
            guard s.isMatched, let best = s.best else { return nil }
            return (s, best)
        }
        guard !homes.isEmpty else { return 0 }
        // The same latch as a group card's File N and the old File All: the sheet's button is one
        // click from a second one while the first batch waits on the file-operation queue.
        guard !isFilingBatchRunning else {
            banner = .refusal("Another filing is still running — try again when it finishes", log: .info)
            return 0
        }
        isFilingBatchRunning = true
        defer { isFilingBatchRunning = false }

        let run = await fileHomes(homes)
        let home = run.alreadyHome == 0 ? ""
            : "; \(run.alreadyHome) \(run.alreadyHome == 1 ? "was" : "were") already in place"
        guard !run.moves.isEmpty else {
            if run.failures > 0 {
                banner = .warning("Couldn’t file \(CountedNoun.phrase(run.failures, "file"))\(home).", log: .warn)
            } else if run.alreadyHome > 0 {
                banner = .success("\(CountedNoun.phrase(run.alreadyHome, "file")) already in place — nothing to move.")
            }
            return 0
        }
        filingScorecard.append(run.scored)
        noteFiledIntoLearnedAccounts(folders: run.moves.map { $0.to.deletingLastPathComponent().path })
        // One ⌘Z for every move, copy and folder the batch made.
        registerFilingUndo(moves: run.moves, copies: run.copied,
                           actionName: "File \(CountedNoun.phrase(run.moves.count, "Item"))",
                           createdFolders: run.createdFolders)
        for line in FilingBatchLog.lines(operation: "Filing batch", filed: run.filed,
                                         summary: FilingBatchLog.recommendedSummary(filed: run.filed, failures: run.failures,
                                                                                    alreadyHome: run.alreadyHome)) {
            Logger.shared.info(line)
        }
        let folders = Set(run.moves.map { $0.to.deletingLastPathComponent().path }).count
        let text = "Filed \(CountedNoun.phrase(run.moves.count, "file")) into \(CountedNoun.phrase(folders, "folder"))"
            + home + Self.copiedPhrase(run.copied)
        banner = run.failures > 0
            ? .warning("\(text); \(run.failures) couldn’t be filed and stay listed", undoable: true, log: .warn)
            : .success(text, undoable: true)
        return run.moves.count
    }
}

extension FilingCardItem {
    /// What filing this card moves: a group's ``FilingCardGroup/toFile``, or the single file unless
    /// it is already filed or a copy of another.
    public var toFile: [FilingSuggestion] {
        switch self {
        case .single(let s): return s.isAlreadyFiled || s.duplicateOf != nil ? [] : [s]
        case .group(let g): return g.toFile
        }
    }
}
