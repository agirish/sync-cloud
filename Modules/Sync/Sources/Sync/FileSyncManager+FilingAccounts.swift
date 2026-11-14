import Events
import Foundation

/// The scan's account phase (design §3–§4): match each loose file's page 1 to an account folder by
/// the number it prints for itself, then place and name it like that account's newest statements.
extension FileSyncManager {

    /// `suggestions` with an account home leading where page 1 identifies one, and the facts read
    /// from every page. A rule the user wrote still leads; a High account match leads everything
    /// else, a Medium one leads only homes no surer than it.
    nonisolated static func applyingAccounts(
        _ suggestions: [FilingSuggestion], index: AccountIndex, snippets: [String: String],
        taxonomy: [FileNode], root: String, scannedFolder: String?
    ) -> (suggestions: [FilingSuggestion], facts: [String: DocumentFacts]) {
        var facts: [String: DocumentFacts] = [:]
        let nodes = accountNodes(index, in: taxonomy)
        let out = suggestions.map { s -> FilingSuggestion in
            guard let page = snippets[s.filePath] else { return s }
            let f = DocumentFacts(page: page)
            facts[s.filePath] = f
            let match = index.match(f)
            let hint = sourceHint(forFile: s.filePath, scannedFolder: scannedFolder)
            // A tax form's year is the one it prints; a file name's date is when it was fetched.
            let period = f.period ?? (f.kind == .taxForm ? nil : StatementFamily.period(ofName: s.fileName, folder: hint))
            switch match {
            case .high(let account, let number), .medium(let account, let number, _):
                guard let node = nodes[account.root] else { return s }
                let place = AccountPlacement.place(in: node, period: period, taxForm: f.kind == .taxForm,
                                                   fileName: s.fileName)
                // High only when the folder inside the account is sure too.
                let confidence: FilingConfidence
                if case .high = match, !place.yearUnknown { confidence = .high } else { confidence = .medium }
                let dest = destination(for: account, number: number, place: place, kind: f.kind,
                                       confidence: confidence, root: root, match: match)
                // A Medium match on a page that isn't a statement (a tax return naming its refund
                // account, a credit report) is one more option, behind the homes found for it.
                if case .medium(_, _, .notAStatement) = match {
                    return s.replacingCandidates(appending(dest, to: s.candidates))
                }
                return s.replacingCandidates(inserting(dest, into: s.candidates))
            case .ambiguous(let accounts):
                // Which of them can't be told from the page: each is offered, none leads a surer home.
                let offers = accounts.prefix(3).map { account in
                    FilingDestination(path: root + "/" + account.root, base: .medium, evidence: .measuredContent,
                                      reasons: ["Page 1’s account number also ends like another account’s"],
                                      newSegments: [])
                }
                var candidates = s.candidates
                for o in offers { candidates = appending(o, to: candidates) }
                return s.replacingCandidates(candidates)
            case .none:
                return s
            }
        }
        return (out, facts)
    }

    /// Names copied from an account's statements, made unique per folder: two statements with one
    /// date (`Statement12302025.pdf` twice), or a name a different file there already has, get
    /// " 2" here, on the card, rather than silently at filing time.
    nonisolated static func reservingLandingNames(_ suggestions: [FilingSuggestion]) -> [FilingSuggestion] {
        var taken: [String: Set<String>] = [:]
        func existing(_ folder: String) -> Set<String> {
            if let t = taken[folder] { return t }
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { $0.lowercased() })
            taken[folder] = names
            return names
        }
        return suggestions.map { s in
            guard let best = s.best, best.nameOrigin == .template, let name = best.proposedName,
                  !s.isAlreadyFiled else { return s }
            var used = existing(best.path)
            var chosen = name
            var n = 2
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            while used.contains(chosen.lowercased()) {
                chosen = stem + " \(n)" + (ext.isEmpty ? "" : "." + ext)
                n += 1
            }
            used.insert(chosen.lowercased())
            taken[best.path] = used
            guard chosen != name else { return s }
            let renamed = FilingDestination(path: best.path, confidence: best.confidence,
                                            reasons: best.reasons + ["Kept as “\(chosen)”: “\(name)” is taken there"],
                                            newSegments: best.newSegments, fromContent: best.fromContent,
                                            remembered: best.remembered, fromAI: best.fromAI,
                                            evidenceToken: best.evidenceToken, neighborMatches: best.neighborMatches,
                                            proposedName: chosen, fromSurvey: best.fromSurvey,
                                            account: best.account, nameOrigin: .template)
            return s.replacingCandidates([renamed] + s.candidates.dropFirst())
        }
    }

    /// The walked node for each account root.
    nonisolated static func accountNodes(_ index: AccountIndex, in taxonomy: [FileNode]) -> [String: FileNode] {
        var wanted = Set(index.accounts.map(\.root))
        var out: [String: FileNode] = [:]
        func visit(_ nodes: [FileNode], _ prefix: String) {
            for n in nodes where n.isDirectory && !wanted.isEmpty {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if wanted.contains(rel) { out[rel] = n; wanted.remove(rel) }
                if wanted.contains(where: { $0.hasPrefix(rel + "/") }) { visit(n.children ?? [], rel) }
            }
        }
        visit(taxonomy, "")
        return out
    }

    nonisolated static func destination(for account: AccountIndex.Account, number: DocumentFacts.OwnNumber,
                                        place: AccountPlacement.Placement, kind: DocumentFacts.Kind,
                                        confidence: FilingConfidence, root: String,
                                        match: AccountIndex.Match) -> FilingDestination {
        let accountPath = root + "/" + account.root
        let path = place.folder.isEmpty ? accountPath : accountPath + "/" + place.folder
        let bank = account.institutionName.isEmpty
            ? account.institution.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            : account.institutionName
        let what: String
        switch kind {
        case .statement: what = "\(bank) statement"
        case .taxForm: what = "\(bank) tax form"
        case .other: what = "\(bank) document"
        }
        var reason = "Account ••\(number.ending) on page 1 · \(what)"
        if case .medium(_, _, let why) = match {
            reason += why == .institutionSilent ? " · the page doesn’t name the bank" : " · not a statement, so check it"
        }
        var filing = FilingAccount(root: accountPath, ending: number.ending, institution: account.institution,
                                   archived: account.archived, kind: kind)
        filing.institutionName = account.institutionName
        return FilingDestination(
            path: path, confidence: confidence, reasons: [reason], newSegments: place.newSegments,
            fromContent: true, remembered: false, fromAI: false, evidenceToken: "••" + number.ending,
            proposedName: place.name, fromSurvey: false, account: filing,
            nameOrigin: place.name == nil ? .planner : .template)
    }

    /// `dest` placed among `candidates`: after the user's own rules; ahead of every other home no
    /// surer than it, and behind surer ones. The same folder offered twice keeps the account's claim.
    nonisolated static func inserting(_ dest: FilingDestination, into candidates: [FilingDestination]) -> [FilingDestination] {
        // His own rule naming this folder already says it, and keeps saying it as his.
        if candidates.contains(where: { $0.remembered && $0.path == dest.path }) { return candidates }
        let others = candidates.filter { $0.path != dest.path }
        let ruled = others.prefix { $0.remembered }
        let rest = others.dropFirst(ruled.count)
        let surer = rest.prefix { $0.confidence > dest.confidence }
        return Array(ruled) + Array(surer) + [dest] + Array(rest.dropFirst(surer.count))
    }

    /// `dest` after every home already offered, unless one of them is the same folder.
    nonisolated static func appending(_ dest: FilingDestination, to candidates: [FilingDestination]) -> [FilingDestination] {
        candidates.contains { $0.path == dest.path } ? candidates : candidates + [dest]
    }

    /// The account phase for one card a re-ask (Read Scan, Download and Read) just re-placed, with
    /// the last scan's index and tree, so a statement whose page arrived late is placed like the
    /// rest.
    func applyingAccounts(to suggestion: FilingSuggestion, page: String) -> FilingSuggestion {
        guard let index = filingAccountIndex, !index.isEmpty, let root = filingLastProviderRoot else { return suggestion }
        return Self.applyingAccounts([suggestion], index: index, snippets: [suggestion.filePath: page],
                                     taxonomy: filingAccountTaxonomy, root: root,
                                     scannedFolder: filingScanFolder).suggestions.first ?? suggestion
    }

    /// `index` with the accounts the tree names without digits, learned from page 1 of a few
    /// statements filed in each (``AccountIndex/unnamedSamples(tree:isInbox:perFolder:limit:)``).
    /// Pages are read through the scan's own reader, so a cloud-only file is never opened, and kept
    /// for the session by path and modification date: a rescan reads only what changed.
    func addingUnnamedAccounts(to index: AccountIndex, taxonomy: [FileNode], root: String,
                               isArchived: @escaping @Sendable (String) -> Bool) async -> AccountIndex {
        guard let extractor = filingSnippetExtractor else { return index }
        let samples = await Task.detached(priority: .userInitiated) {
            index.unnamedSamples(tree: taxonomy)
        }.value
        let pdfs = samples.filter { ($0.file as NSString).pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return index }
        var read: [(sample: AccountIndex.Sample, facts: DocumentFacts)] = []
        var toRead: [String] = []
        var modifiedAt: [String: Date?] = [:]
        for sample in pdfs {
            let path = root + "/" + sample.file
            let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            modifiedAt[path] = modified
            if let cached = filingAccountPageCache[path], cached.modified == modified { continue }
            toRead.append(path)
        }
        // A few at a time, through the scan's reader (which never opens a cloud-only file).
        let pages = await Self.extractSnippets(for: toRead, using: extractor)
        if Task.isCancelled { return index }
        for path in toRead {
            filingAccountPageCache[path] = (modifiedAt[path] ?? nil, pages[path].map { DocumentFacts(page: $0) })
        }
        for sample in pdfs {
            if let facts = filingAccountPageCache[root + "/" + sample.file]?.facts { read.append((sample, facts)) }
        }
        let fresh = toRead.count
        let before = index.accounts.count
        let grown = await Task.detached(priority: .userInitiated) {
            index.adding(read: read, isArchived: isArchived)
        }.value
        Logger.shared.info("Filing: read \(fresh) filed statement(s) (\(pdfs.count - fresh) remembered) "
            + "for accounts named without digits; found \(grown.accounts.count - before)")
        return grown
    }
}
