import Foundation

/// A home inside an archive that has a live twin outside it: `Home/Archive/Crescent Village/
/// Utilities/PG&E` (to 2021) and `Home/Utilities/PG&E` (2021 on). A new file goes to the twin.
///
/// Whichever pass picked the archive (the router, an account, Claude), the reason is the same: the
/// archive's files read, and the live folder's may not (a garbled text layer reads as nothing), so
/// every content signal points at the folder that stopped.
extension FileSyncManager {

    /// `suggestions` with each leading home inside an archive replaced by its live twin, the
    /// archived home kept next for Try Another Folder. Untouched: a home his own rule chose, a card
    /// whose twin he already turned down, and a home with no twin or two.
    ///
    /// The twin is the one folder outside every archive and inbox that:
    /// - ends in the same two names as the archived home, the archive's own segments left out
    ///   (`Utilities/PG&E`; `Charles Schwab/Roth IRA` for `Charles Schwab/Archive/Roth IRA`), or in
    ///   its one name when that is all it has, if that name is not a year or a month;
    /// - holds dated files newer than any in the archived home.
    /// Placed inside the twin by its year folders and named like its newest files, as an account is.
    nonisolated static func preferringLiveTwins(
        _ suggestions: [FilingSuggestion], taxonomy: [FileNode], root: String,
        isArchived: (String) -> Bool = { _ in false },
        isInbox: (String) -> Bool = { FolderProfile.isInboxPath($0) },
        facts: [String: DocumentFacts] = [:],
        rejected: [String: Set<String>] = [:]
    ) -> [FilingSuggestion] {
        func inArchive(_ rel: String) -> Int? {
            let segs = rel.split(separator: "/").map(String.init)
            return segs.indices.first { i in
                AccountIndex.isArchiveName(segs[i]) || isArchived(segs[...i].joined(separator: "/"))
            }
        }
        // Only when some card leads into an archive is the tree walked.
        guard suggestions.contains(where: { s in
            guard let best = s.best, !best.remembered, let rel = relativePath(best.path, under: root) else { return false }
            return inArchive(rel) != nil
        }) else { return suggestions }
        var live: [String: [(path: String, node: FileNode)]] = [:]   // by lowercased leaf name
        func visit(_ node: FileNode, _ rel: String) {
            guard node.isDirectory, !AccountIndex.isArchiveName(node.name), !isArchived(rel), !isInbox(rel) else { return }
            live[node.name.lowercased(), default: []].append((rel, node))
            for c in node.children ?? [] where c.isDirectory { visit(c, rel + "/" + c.name) }
        }
        for n in taxonomy { visit(n, n.name) }
        var twins: [String: (path: String, node: FileNode)?] = [:]   // archived home → its twin
        func twin(of home: String) -> (path: String, node: FileNode)? {
            if let known = twins[home] { return known }
            let found = findTwin(of: home)
            twins[home] = .some(found)
            return found
        }
        func findTwin(of home: String) -> (path: String, node: FileNode)? {
            let kept = home.split(separator: "/").map(String.init).enumerated().filter { i, seg in
                !AccountIndex.isArchiveName(seg) && !isArchived(home.split(separator: "/").prefix(i + 1).joined(separator: "/"))
            }.map(\.element)
            guard let leaf = kept.last else { return nil }
            let tail = kept.suffix(2).map { $0.lowercased() }
            if tail.count == 1 {
                guard !FolderProfileEntry.looksLikeYear(leaf), FilingPeriod.monthSlot(ofFolderNamed: leaf) == nil,
                      leaf.contains(where: \.isLetter) else { return nil }
            }
            guard let archivedNode = AccountProposal.node(at: home, in: taxonomy) else { return nil }
            let held = StatementFamily.families(below: archivedNode).values.flatMap { $0 }.map(\.period).max()
            let found = (live[leaf.lowercased()] ?? []).filter { path, node in
                let segs = path.split(separator: "/").map { $0.lowercased() }
                guard segs.count >= tail.count, Array(segs.suffix(tail.count)) == tail,
                      let newest = StatementFamily.families(below: node).values.flatMap({ $0 }).map(\.period).max()
                else { return false }
                return held.map { newest > $0 } ?? true
            }
            return found.count == 1 ? found[0] : nil
        }
        return suggestions.map { s in
            guard let best = s.best, !best.remembered, let rel = relativePath(best.path, under: root),
                  let archiveAt = inArchive(rel) else { return s }
            // The archived home, out of any year or month folder the pick named (`…/PG&E/2021`).
            var segs = rel.split(separator: "/").map(String.init)
            while segs.count > archiveAt + 2, let last = segs.last,
                  FolderProfileEntry.looksLikeYear(last) || FilingPeriod.monthSlot(ofFolderNamed: last) != nil {
                segs.removeLast()
            }
            let home = segs.joined(separator: "/")
            guard segs.count > archiveAt + 1, let (twinPath, twinNode) = twin(of: home) else { return s }
            let f = facts[s.filePath]
            let period = f?.period ?? StatementFamily.period(ofName: s.fileName, folder: "")
            let place = AccountPlacement.place(in: twinNode, period: period, taxForm: f?.kind == .taxForm,
                                               fileName: s.fileName)
            let path = root + "/" + twinPath + (place.folder.isEmpty ? "" : "/" + place.folder)
            if let refused = rejected[s.filePath],
               refused.contains(where: { path == $0 || PathBoundary.contains(path, under: $0) }) { return s }
            let older = segs[archiveAt...].joined(separator: " › ")
            let reason = "Newer \(twinNode.name) files are here; \(older) holds the older ones"
            let name = place.name ?? best.proposedName
            let moved = FilingDestination(path: path, confidence: best.confidence, reasons: [reason] + best.reasons,
                                          newSegments: place.newSegments, fromContent: best.fromContent,
                                          remembered: false, fromAI: best.fromAI, evidenceToken: best.evidenceToken,
                                          neighborMatches: best.neighborMatches, proposedName: name,
                                          fromSurvey: best.fromSurvey, account: nil,
                                          nameOrigin: place.name != nil ? .template : best.nameOrigin)
            let others = s.candidates.dropFirst().filter { $0.path != path }
            return s.replacingCandidates([moved, best] + others)
        }
    }
}
