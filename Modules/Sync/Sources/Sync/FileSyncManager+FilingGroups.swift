import Events
import Foundation

/// Filing a group card, and the two checks that keep a group from filing what is already there.
extension FileSyncManager {

    /// Files a group card's members (``FilingCardGroup/toFile``) to their own homes, or every one of
    /// them into `folder` when the user chose one for the whole group, keeping their names then.
    /// One ⌘Z puts them all back. Members that fail (changed since the scan, gone) stay as cards,
    /// and the banner says how many.
    /// Returns how many moved; the members that couldn't be filed are in ``filingGroupFailures``,
    /// which the lens shows as cards of their own.
    @discardableResult
    public func applyFilingGroup(_ group: FilingCardGroup, into folder: String? = nil,
                                 typed: FilingDestination? = nil, teach: Bool = false,
                                 fileOnce: Bool = false, exceptCopiesTo: Set<String> = []) async -> Int {
        // A folder he chose is checked as a typed one is: never the source, an inbox, or outside
        // the tree.
        if let folder, let first = group.toFile.first,
           case .failure(let refusal) = filingDestination(typed: folder, for: first) {
            banner = .refusal(refusal.sentence, log: .info)
            return 0
        }
        return await fileFilingGroup(group, into: folder, typed: typed, teach: teach, fileOnce: fileOnce,
                                     exceptCopiesTo: exceptCopiesTo)
    }

    /// ``applyFilingGroup(_:into:typed:teach:fileOnce:)``, with an account folder moved out of its
    /// archive just before (`moveOutOfArchiveThenFile`) undone in the same step.
    func fileFilingGroup(_ group: FilingCardGroup, into folder: String? = nil,
                         typed: FilingDestination? = nil, teach: Bool = false, fileOnce: Bool = false,
                         exceptCopiesTo: Set<String> = [],
                         priorFolderMove: PriorFolderMove? = nil) async -> Int {
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before filing", log: .info)
            return 0
        }
        guard !filingBatchInFlight.contains(ObjectIdentifier(self)) else {
            banner = .refusal("Another filing is still running — try again when it finishes", log: .info)
            return 0
        }
        filingBatchInFlight.insert(ObjectIdentifier(self))
        defer { filingBatchInFlight.remove(ObjectIdentifier(self)) }

        var moves: [MoveItemState] = []
        var copied: [CopyItemState] = []
        // The folders filing these makes, copies' included: ⌘Z removes them again.
        let homes = group.toFile.compactMap { s -> FilingDestination? in
            guard let own = s.best else { return nil }
            return typed ?? folder.map { FilingDestination(path: $0, confidence: .high, reasons: [], newSegments: []) } ?? own
        }
        let wouldCreate = missingFolders(for: homes.map(\.path) + (fileOnce ? [] : homes.flatMap { $0.alsoCopiesTo.map(\.path) }))
        var filed: [FilingBatchLog.Filed] = []
        var scored: [FilingScorecard.Record] = []
        var failures = 0, alreadyHome = 0
        for s in group.toFile {
            guard let own = s.best else { continue }
            // A typed path keeps the levels it creates; the first member makes them.
            let dest = typed ?? folder.map {
                FilingDestination(path: $0, confidence: .high, reasons: ["You chose this folder"], newSegments: [])
            } ?? own
            switch await performFiling(s, to: dest) {
            case .moved(let move):
                moves.append(move)
                if !fileOnce {
                    copied += performFilingCopies(of: move.to, copies: dest.alsoCopiesTo.filter { !exceptCopiesTo.contains($0.account.root) })
                }
                if let offer = s.firstOffer {
                    scored.append(FilingScorecard.record(offer, landedFile: move.to.path,
                                                         renamedOffer: Self.isRenamedOffer(dest, of: s)))
                }
                filingScorecard.settle([s.filePath])
                filed.append(FilingBatchLog.Filed(fileName: s.fileName, landedAs: move.to.lastPathComponent,
                                                  folder: move.to.deletingLastPathComponent().path,
                                                  source: FilingBatchLog.source(of: dest)))
            case .noMoveNeeded: alreadyHome += 1
            case .failed:
                failures += 1
                filingGroupFailures.insert(s.id)
            }
        }
        let folderName = ((typed?.path ?? folder ?? group.destination.path) as NSString).lastPathComponent
        guard !moves.isEmpty else {
            if failures > 0 {
                banner = .warning("Couldn’t file \(failures) file\(failures == 1 ? "" : "s") into \(folderName).", log: .warn)
            } else if alreadyHome > 0 {
                banner = .success("Already in \(folderName) — nothing to move.")
            }
            return 0
        }
        filingScorecard.append(scored)
        // What it teaches (decision 8): a group sent somewhere he chose, or a new account made.
        let chosen = typed?.path ?? folder
        // Filed into the new account it proposed (not a folder he chose instead).
        let makesAccount = (typed ?? (folder == nil ? group.destination : nil))?.createsAccountFolder ?? false
        var taught: LearnedAccount?
        if teach || makesAccount, let into = chosen ?? (makesAccount ? group.destination.account?.root : nil) {
            taught = teachAccount(from: group.toFile, landed: moves.map { .init(source: $0.from.path, landed: $0.to.path) },
                                  into: into, by: chosen == nil || (makesAccount && !teach) ? .newAccount : .groupRedirect)
        }
        registerFilingUndo(moves: moves, copies: copied, actionName: "File \(CountedNoun.phrase(moves.count, "Item"))",
                           createdFolders: wouldCreate.filter { fileManager.fileExists(atPath: $0) },
                           priorFolderMove: priorFolderMove, forgetsLesson: taught != nil)
        for line in FilingBatchLog.lines(operation: "Filing group", filed: filed,
                                         summary: FilingBatchLog.recommendedSummary(filed: filed, failures: failures,
                                                                                    alreadyHome: alreadyHome)) {
            Logger.shared.info(line)
        }
        let n = moves.count
        let home = alreadyHome == 0 ? "" : "; \(alreadyHome) \(alreadyHome == 1 ? "was" : "were") already there"
        let text = "Filed \(n) file\(n == 1 ? "" : "s") → \(folderName)" + home + Self.copiedPhrase(copied)
        banner = failures > 0
            ? .warning("\(text); \(failures) couldn’t be filed and stay listed", undoable: true, log: .warn)
            : .success(text, undoable: true)
        return n
    }

    /// Marks, among cards matched to an account, the ones whose document the account already holds
    /// (by page-text fingerprint, so a copy saved under the bank's own name still counts) and the
    /// ones that are an identical copy of another loose file. Reads only the account's own files
    /// from the statement's year and the folder it would land in, never the tree.
    func markingFiledInAccounts(_ suggestions: [FilingSuggestion], scannedFolder: String? = nil) async -> [FilingSuggestion] {
        let matched = suggestions.filter { $0.best?.account != nil && ($0.fileName as NSString).pathExtension.lowercased() == "pdf" }
        guard !matched.isEmpty, filingReadsContents else { return suggestions }
        // The account's files worth comparing: those in the landing folder and in any folder of the
        // same year, bounded per account.
        // Never a loose file itself, nor anything in the folder being filed from: a statement is
        // not "already filed" as itself (an inbox inside an account folder, say).
        let loose = Set(suggestions.map(\.filePath))
        // Every landing folder and year among an account's cards, not the first one's only: a
        // backfilled 2023 statement beside 2026 ones is compared with the account's 2023 files.
        var wanted: [String: (landings: Set<String>, years: Set<Int>)] = [:]
        for s in matched {
            guard let best = s.best, let account = best.account else { continue }
            wanted[account.root, default: ([], [])].landings.insert(best.path)
            if let y = StatementFamily.period(ofName: best.proposedName ?? s.fileName, folder: "")?.year {
                wanted[account.root, default: ([], [])].years.insert(y)
            }
        }
        let filedByAccount = await Task.detached(priority: .userInitiated) { () -> [String: [String]] in
            var out: [String: [String]] = [:]
            for (root, want) in wanted {
                out[root] = Self.comparableFiles(in: root, near: Array(want.landings), years: want.years,
                                                 fileManager: FileManager.default)
                    .filter { path in
                        !loose.contains(path) && !(scannedFolder.map { PathBoundary.contains(path, under: $0) } ?? false)
                    }
            }
            return out
        }.value
        let all = Set(matched.map(\.filePath)).union(filedByAccount.values.joined())
        let fm = fileManager
        let digests = await Self.fingerprintDocuments(Array(all), fileManager: fm, cache: .sharedFingerprints,
                                                      textless: .sharedTextless, extract: PDFTextExtractor.fingerprintReading)
        await ContentHashCache.sharedFingerprints.save()
        await ContentHashCache.sharedTextless.save()
        guard !digests.isEmpty else { return suggestions }
        var firstLoose: [String: String] = [:]
        for s in matched.sorted(by: { $0.filePath < $1.filePath }) {
            if let d = digests[s.filePath], firstLoose[d] == nil { firstLoose[d] = s.filePath }
        }
        return suggestions.map { s in
            guard let best = s.best, let account = best.account, let d = digests[s.filePath] else { return s }
            var out = s
            let holding = (filedByAccount[account.root] ?? []).filter { digests[$0] == d }
            if !holding.isEmpty {
                let folders = Array(Set(holding.map { (($0 as NSString).deletingLastPathComponent) })).sorted()
                    .compactMap { Self.relativePath($0, under: s.providerRoot ?? "") ?? $0 }
                out = out.alreadyFiled(at: folders)
            } else if let first = firstLoose[d], first != s.filePath {
                out.duplicateOf = first
            }
            return out
        }
    }

    /// PDFs in `accountRoot` worth comparing a statement against: the landing folder's, and those of
    /// sibling year folders' namesakes, at most `limit`, newest first.
    nonisolated static func comparableFiles(in accountRoot: String, near landings: [String], years: Set<Int> = [],
                                            fileManager fm: FileManaging, limit: Int = 60) -> [String] {
        var out: [(String, Date)] = []
        func list(_ folder: String, depth: Int) {
            guard depth >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for n in names where !n.hasPrefix(".") {
                let p = folder + "/" + n
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if isDir.boolValue { list(p, depth: depth - 1); continue }
                guard (n as NSString).pathExtension.lowercased() == "pdf", FilingSurvey.isAvailable(p) else { continue }
                let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
                out.append((p, m))
            }
        }
        for landing in landings { list(landing, depth: 0) }
        let inLanding = out.map(\.0)
        out = []
        list(accountRoot, depth: 3)
        // The landing folders' files always, then the statements' years', then the account's newest.
        let sameYear = years.isEmpty ? [] : out.filter {
            StatementFamily.period(ofName: ($0.0 as NSString).lastPathComponent,
                                   folder: ($0.0 as NSString).deletingLastPathComponent).map { years.contains($0.year) } ?? false
        }
        var seen = Set<String>()
        // Each landing and year is always compared; only the account's newest beyond them is capped.
        let sure = (inLanding + sameYear.map(\.0)).filter { seen.insert($0).inserted }
        return sure + out.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(max(0, limit - sure.count))
    }
}
