import Events
import Foundation

/// File All: every Matched card the sheet left ticked, filed in one go and undone with one ⌘Z
/// (decision OQ).
extension FileSyncManager {

    /// Files each card's ``FilingCardItem/toFile`` to its own home, copies included, as one ⌘Z.
    ///
    /// `items` are the cards the sheet left ticked, never re-derived from ``filingSuggestions``: the
    /// sheet named exactly these. Each file is checked again (``FilingSuggestion/isMatched``), so a
    /// caller can't make this file a card that needs a look first, and a file no longer listed
    /// (filed from its own card, set aside, or replaced by a scan while the sheet was open) is
    /// skipped rather than counted as a failure. Files that fail stay listed as cards of their own.
    /// `destinations` overrides a file's home by id: a new folder's name typed on its card.
    /// - Returns: how many files moved.
    @discardableResult
    public func applyFilingBatch(_ items: [FilingCardItem],
                                 destinations: [String: FilingDestination] = [:]) async -> Int {
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before filing", log: .info)
            return 0
        }
        // As the list stands now: a card re-answered while the sheet was open (Refine, Download
        // and Read, a rescan) files only if it is still Matched to the same home the sheet showed.
        let listed = Dictionary(filingSuggestions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let homes: [(FilingSuggestion, FilingDestination)] = items.flatMap(\.toFile).compactMap { shown in
            guard let s = listed[shown.id], s.isMatched, let best = s.best, best.path == shown.best?.path,
                  !s.isAlreadyFiled, s.duplicateOf == nil else { return nil }
            return (s, destinations[s.id] ?? best)
        }
        guard !homes.isEmpty else {
            if !items.isEmpty {
                banner = .success("Nothing left to file — those cards were filed or changed since the list opened.")
            }
            return 0
        }
        // The same latch as a group card's File N and the old File All: the sheet's button is one
        // click from a second one while the first batch waits on the file-operation queue.
        guard !isFilingBatchRunning else {
            banner = .refusal("Another filing is still running — try again when it finishes", log: .info)
            return 0
        }
        isFilingBatchRunning = true
        defer { isFilingBatchRunning = false }

        let positions = filingCardPositions(Set(homes.map(\.0.id)))
        let run = await fileHomes(homes)
        let moved = Set(run.moves.map(\.from.path))
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
        registerFilingUndo(moves: run.undoMoves, copies: run.copied,
                           actionName: "File \(CountedNoun.phrase(run.moves.count, "Item"))",
                           createdFolders: run.createdFolders,
                           restoring: positions.filter { moved.contains($0.suggestion.filePath) })
        for line in FilingBatchLog.lines(operation: "Filing batch", filed: run.filed,
                                         summary: FilingBatchLog.recommendedSummary(filed: run.filed, failures: run.failures,
                                                                                    alreadyHome: run.alreadyHome)) {
            Logger.shared.info(line)
        }
        // Counted as the sheet counts: accounts when every file went to one, else folders.
        let accounts = homes.allSatisfy { $0.1.account != nil }
        let places = Set(homes.map { $0.1.account?.root ?? $0.1.path }).count
        let text = "Filed \(CountedNoun.phrase(run.moves.count, "file")) into "
            + CountedNoun.phrase(places, accounts ? "account" : "folder")
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
