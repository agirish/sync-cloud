import Foundation

/// A home inside an archive that has a live twin outside it: `Home/Archive/Meadow Village/
/// Utilities/PG&E` (to 2021) and `Home/Utilities/PG&E` (2021 on). A new file goes to the twin.
///
/// Whichever pass picked the archive (the router, Claude), the reason is the same: the archive's
/// files read, and the live folder's may not (a garbled text layer reads as nothing), so every
/// content signal points at the folder that stopped.
///
/// Found by one walk of the tree, on first need; each archived home is looked up once. Not
/// thread-safe: make one per pass, inside the task that runs it.
final class LiveTwinFinder {
    private let taxonomy: [FileNode]
    private let isArchived: (String) -> Bool
    private let isInbox: (String) -> Bool
    private var found: [String: (path: String, node: FileNode)?] = [:]
    /// Each candidate's newest statement, by path and `ownOnly`: shared by the homes that name it.
    private var newest: [String: DocumentFacts.Period?] = [:]
    /// Every folder outside the archives and inboxes, by lowercased name.
    private lazy var live: [String: [(path: String, node: FileNode)]] = {
        var out: [String: [(path: String, node: FileNode)]] = [:]
        func visit(_ node: FileNode, _ rel: String) {
            guard node.isDirectory, !AccountIndex.isArchiveName(node.name), !isArchived(rel), !isInbox(rel) else { return }
            out[node.name.lowercased(), default: []].append((rel, node))
            for c in node.children ?? [] where c.isDirectory { visit(c, rel + "/" + c.name) }
        }
        for n in taxonomy { visit(n, n.name) }
        return out
    }()

    init(taxonomy: [FileNode], isArchived: @escaping (String) -> Bool,
         isInbox: @escaping (String) -> Bool = { FolderProfile.isInboxPath($0) }) {
        self.taxonomy = taxonomy
        self.isArchived = isArchived
        self.isInbox = isInbox
    }

    static func isPeriodName(_ name: String) -> Bool {
        FolderProfileEntry.looksLikeYear(name) || FilingPeriod.monthSlot(ofFolderNamed: name) != nil
    }

    /// Where the archive begins in `rel`: the first folder named so or marked so by the survey.
    func archiveIndex(of rel: String) -> Int? {
        let segs = rel.split(separator: "/").map(String.init)
        return segs.indices.first { i in
            AccountIndex.isArchiveName(segs[i]) || isArchived(segs[...i].joined(separator: "/"))
        }
    }

    /// The archived folder a pick of `rel` stands for: out of any year or month folders it named,
    /// down to the archive itself (`…/PG&E/2021` → `…/PG&E`; `PG&E/Archive/2019` → `PG&E/Archive`).
    func archivedHome(of rel: String) -> (home: String, archiveAt: Int)? {
        guard let at = archiveIndex(of: rel) else { return nil }
        var segs = rel.split(separator: "/").map(String.init)
        while segs.count > at + 1, let last = segs.last, Self.isPeriodName(last) { segs.removeLast() }
        return (segs.joined(separator: "/"), at)
    }

    /// The one live folder `home` carries on in, or nil when there is none or more than one.
    ///
    /// - Where `home` is the archive itself (`PG&E/Archive`, or `PG&E/Archive/2019` once out of its
    ///   year), the folder it sits in, `PG&E`, and only that; and only if it keeps statements of
    ///   its own, in itself or its year folders. Otherwise every folder with an archive inside
    ///   (`Work`, `Finance/US`) would be one.
    /// - Otherwise a folder ending in the same two names, the archive and year folders left out
    ///   (`Utilities/PG&E` for `Home/Archive/Old House/Utilities/PG&E`; `Charles Schwab/Roth IRA`
    ///   for `Charles Schwab/Archive/Roth IRA`), or its one name when that is all it has.
    ///
    /// Either way the twin keeps a regular run of statements (``StatementFamily/isRegular(_:)``),
    /// the newest newer than anything in `home`.
    func twin(of home: String) -> (path: String, node: FileNode)? {
        if let known = found[home] { return known }
        let result = find(home)
        found[home] = .some(result)
        return result
    }

    private func find(_ home: String) -> (path: String, node: FileNode)? {
        guard let at = archiveIndex(of: home) else { return nil }
        let segs = home.split(separator: "/").map(String.init)
        // Out: the archive's own folder, marked by name or as the survey's topmost archived folder
        // (it marks every folder below as well, and those still name what they hold), and years.
        let keptAt = segs.indices.filter { i in
            let marked = isArchived(segs[...i].joined(separator: "/"))
                && (i == 0 || !isArchived(segs[..<i].joined(separator: "/")))
            return !AccountIndex.isArchiveName(segs[i]) && !marked && !Self.isPeriodName(segs[i])
        }
        // By name first, so a home with no namesake costs nothing more.
        let candidates: [(path: String, node: FileNode)]
        let ownOnly: Bool
        if keptAt.allSatisfy({ $0 < at }) {
            guard at > 0 else { return nil }
            let parent = segs[..<at].joined(separator: "/")
            guard !isArchived(parent), !isInbox(parent), let node = AccountProposal.node(at: parent, in: taxonomy)
            else { return nil }
            candidates = [(parent, node)]
            ownOnly = true
        } else {
            let kept = keptAt.map { segs[$0] }
            guard let leaf = kept.last, leaf.contains(where: \.isLetter) else { return nil }
            let tail = kept.suffix(2).map { $0.lowercased() }
            candidates = (live[leaf.lowercased()] ?? []).filter { path, _ in
                let names = path.split(separator: "/").map { $0.lowercased() }
                return names.count >= tail.count && Array(names.suffix(tail.count)) == tail
            }
            ownOnly = false
        }
        let dated = candidates.compactMap { path, node -> (path: String, node: FileNode, latest: DocumentFacts.Period)? in
            let key = (ownOnly ? "own\u{0}" : "\u{0}") + path
            let latest = newest[key] ?? Self.newestRegularStatement(in: node, ownOnly: ownOnly)
            newest[key] = .some(latest)
            return latest.map { (path, node, $0) }
        }
        // The archive's own files are read only for a folder still in the running.
        guard !dated.isEmpty, let archivedNode = AccountProposal.node(at: home, in: taxonomy) else { return nil }
        let held = StatementFamily.families(below: archivedNode).values.flatMap { $0 }.map(\.period).max()
        let newer = dated.filter { d in held.map { d.latest > $0 } ?? true }
        return newer.count == 1 ? (newer[0].path, newer[0].node) : nil
    }

    /// The newest statement of a regular run below `node`; with `ownOnly`, of one in it or its
    /// year and month folders, not in another folder below it (an archive, another account).
    static func newestRegularStatement(in node: FileNode, ownOnly: Bool) -> DocumentFacts.Period? {
        // Pruned to its year and month folders before any file is read: a folder holding an
        // archive can hold a whole tree besides (`Home`, `Work`).
        func own(_ n: FileNode) -> FileNode {
            FileNode(id: n.id, name: n.name, isDirectory: true, children: (n.children ?? []).compactMap { c in
                c.isDirectory ? (isPeriodName(c.name) ? own(c) : nil) : c
            })
        }
        return StatementFamily.families(below: ownOnly ? own(node) : node).values
            .filter(StatementFamily.isRegular)
            .flatMap { $0 }.map(\.period).max()
    }

    /// Each archived folder in the tree that has a live twin, mapped to the twin. Relative paths.
    func allTwins() -> [String: String] {
        var out: [String: String] = [:]
        // Asked only inside an archive, found on the way down: a tree is mostly live folders.
        func visit(_ node: FileNode, _ rel: String, inArchive: Bool) {
            guard node.isDirectory else { return }
            let inside = inArchive || AccountIndex.isArchiveName(node.name) || isArchived(rel)
            if inside, let (home, _) = archivedHome(of: rel), let t = twin(of: home) { out[rel] = t.path }
            for c in node.children ?? [] where c.isDirectory { visit(c, rel + "/" + c.name, inArchive: inside) }
        }
        for n in taxonomy { visit(n, n.name, inArchive: false) }
        return out
    }
}

extension FileSyncManager {

    /// `suggestions` with each leading home inside an archive replaced by its live twin
    /// (``LiveTwinFinder``), the archived home kept next for Try Another Folder.
    ///
    /// Untouched: a home his own rule chose; a home an account's number chose, which decides
    /// archived accounts by its own rule (``archiveOffer(for:)``) and may be another account than
    /// the live folder of the same name; a card whose twin he already turned down; a home with no
    /// twin or two. The twin is placed inside by its year folders and named like its newest files,
    /// as an account is, and is High only when that placement is sure. `facts` are the statements
    /// the account pass read; `pages`, page 1 of the others.
    nonisolated static func preferringLiveTwins(
        _ suggestions: [FilingSuggestion], taxonomy: [FileNode], root: String,
        isArchived: @escaping (String) -> Bool = { _ in false },
        isInbox: @escaping (String) -> Bool = { FolderProfile.isInboxPath($0) },
        facts: [String: DocumentFacts] = [:], pages: [String: String] = [:],
        rejected: [String: Set<String>] = [:]
    ) -> [FilingSuggestion] {
        let twins = LiveTwinFinder(taxonomy: taxonomy, isArchived: isArchived, isInbox: isInbox)
        func archivedLead(_ s: FilingSuggestion) -> (best: FilingDestination, rel: String)? {
            guard let best = s.best, !best.remembered, best.account == nil,
                  let rel = relativePath(best.path, under: root), twins.archiveIndex(of: rel) != nil
            else { return nil }
            return (best, rel)
        }
        // Only when some card leads into an archive is the tree walked.
        guard suggestions.contains(where: { archivedLead($0) != nil }) else { return suggestions }
        return suggestions.map { s in
            guard let (best, rel) = archivedLead(s), let (home, archiveAt) = twins.archivedHome(of: rel),
                  let (twinPath, twinNode) = twins.twin(of: home) else { return s }
            // Read for an account where the tree has some; otherwise from the page in hand.
            let f = facts[s.filePath] ?? pages[s.filePath].map { DocumentFacts(page: $0) }
            let taxForm = f?.kind == .taxForm
            // A tax form's year is the one it prints; a file name's date is when it was fetched.
            let period = f?.period ?? (taxForm ? nil : StatementFamily.period(ofName: s.fileName, folder: ""))
            let place = AccountPlacement.place(in: twinNode, period: period, taxForm: taxForm, fileName: s.fileName)
            let twinRoot = root + "/" + twinPath
            let path = place.folder.isEmpty ? twinRoot : twinRoot + "/" + place.folder
            if let refused = rejected[s.filePath],
               refused.contains(where: { path == $0 || PathBoundary.contains(path, under: $0) }) { return s }
            let older = home.split(separator: "/").dropFirst(archiveAt).joined(separator: " › ")
            let reason = "Newer \(twinNode.name) files are here; \(older) holds the older ones"
            // Sure of the folder only when the statement's year chose it, as for an account.
            let confidence = period != nil && !place.yearUnknown ? best.confidence : min(best.confidence, .medium)
            // The archive's evidence (its similar files, a matched word) is about the archive: not
            // carried over to a folder it says nothing about.
            let moved = FilingDestination(path: path, confidence: confidence, reasons: [reason] + best.reasons,
                                          newSegments: place.newSegments, fromContent: best.fromContent,
                                          remembered: false, fromAI: best.fromAI,
                                          proposedName: place.name ?? best.proposedName,
                                          fromSurvey: best.fromSurvey, account: nil,
                                          nameOrigin: place.name != nil ? .template : best.nameOrigin)
            // The twin's own folder is the same offer as its year folder; not offered twice.
            let others = s.candidates.dropFirst().filter { $0.path != path && $0.path != twinRoot }
            let kept = max(s.candidates.count, FilingOptions().maxCandidates)
            return s.replacingCandidates(Array(([moved, best] + others).prefix(kept)))
        }
    }

    /// `folders` with the live twin of each archived folder put just before it (`twins` from
    /// ``LiveTwinFinder/allTwins()``): a model told to keep new files out of archives is shown
    /// where the folder carries on, which a shortlist ranked on the archive's readable files can
    /// leave out.
    nonisolated static func withLiveTwins(_ folders: [String], twins: [String: String]) -> [String] {
        guard !twins.isEmpty, folders.contains(where: { twins[$0] != nil }) else { return folders }
        var out: [String] = []
        var seen = Set<String>()
        for f in folders {
            if let t = twins[f], seen.insert(t).inserted { out.append(t) }
            if seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    /// Inboxes by name, and the ones the survey marks as such.
    nonisolated static func inboxPredicate(profile: FolderProfile?) -> @Sendable (String) -> Bool {
        let marked = Set((profile?.folders ?? [:]).filter { $0.value.role == .inbox }.keys)
        return { FolderProfile.isInboxPath($0) || marked.contains($0) }
    }
}
