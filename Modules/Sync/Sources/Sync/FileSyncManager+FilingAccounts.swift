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
        taxonomy: [FileNode], root: String, scannedFolder: String?,
        sharedStatementFolders shared: Set<String>? = nil,
        isArchived: @escaping (String) -> Bool = { _ in false },
        preferences: [FilingPreference] = []
    ) -> (suggestions: [FilingSuggestion], facts: [String: DocumentFacts]) {
        var facts: [String: DocumentFacts] = [:]
        let nodes = accountNodes(index, in: taxonomy)
        // Folders where a bank's statements are kept together with no account of their own
        // (`Fidelity/Statements`): a bank that has one gets no new account folders proposed.
        let sharedStatementFolders = shared ?? Set(index.unnamedSamples(tree: taxonomy).map(\.candidate))
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
            case .several(let accounts, let numbers):
                let pairs = Array(zip(accounts, numbers))
                // Filed into the account whose number comes first, copied into the others he
                // hasn't asked to file once (decision 11).
                var placed: [(AccountIndex.Account, DocumentFacts.OwnNumber, AccountPlacement.Placement)] = []
                for (account, number) in pairs {
                    guard let node = nodes[account.root] else { continue }
                    placed.append((account, number, AccountPlacement.place(in: node, period: period, taxForm: false,
                                                                           fileName: s.fileName)))
                }
                guard let (account, number, place) = placed.first else { return s }
                let sure = placed.allSatisfy { !$0.2.yearUnknown }
                var dest = destination(for: account, number: number, place: place, kind: f.kind,
                                       confidence: sure ? .high : .medium, root: root, match: .high(account, number: number))
                let copies = placed.dropFirst().map { a, n, p -> FilingCopy in
                    let accountPath = root + "/" + a.root
                    var fa = FilingAccount(root: accountPath, ending: n.ending, institution: a.institution,
                                           archived: a.archived, kind: f.kind)
                    fa.institutionName = a.institutionName
                    return FilingCopy(path: p.folder.isEmpty ? accountPath : accountPath + "/" + p.folder,
                                      proposedName: p.name, account: fa)
                }
                let kept = copies.filter { FilingPreference.copies(into: $0.account, kind: f.kind, preferences: preferences) }
                let named = copies.map { "••" + $0.account.ending }.joined(separator: ", ")
                var reasons = dest.reasons
                reasons.append(kept.isEmpty
                    ? "Also names \(named) · filed once, as you asked"
                    : "Also names " + kept.map { "••\($0.account.ending)" }.joined(separator: ", ") + " · a copy goes to each")
                dest = FilingDestination(path: dest.path, confidence: dest.confidence, reasons: reasons,
                                         newSegments: dest.newSegments, fromContent: true, evidenceToken: dest.evidenceToken,
                                         proposedName: dest.proposedName, account: dest.account, nameOrigin: dest.nameOrigin)
                dest.alsoCopiesTo = kept
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
                return proposingAccount(for: s, facts: f, period: period, hint: hint, index: index,
                                        taxonomy: taxonomy, root: root, sharedStatementFolders: sharedStatementFolders,
                                        isArchived: isArchived)
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

    /// A new account folder for a statement from a known bank that no account matches
    /// (``AccountProposal``), unless the bank keeps such statements together in one folder
    /// (`Fidelity/Statements`), or a home in an account of this type is already offered. When the
    /// folder the statement came from names an account the tree already has, that account is the
    /// home instead.
    nonisolated static func proposingAccount(for s: FilingSuggestion, facts f: DocumentFacts,
                                             period: DocumentFacts.Period?, hint: String, index: AccountIndex,
                                             taxonomy: [FileNode], root: String,
                                             sharedStatementFolders: Set<String> = [],
                                             isArchived: (String) -> Bool = { _ in false }) -> FilingSuggestion {
        guard f.kind != .taxForm, let institution = index.headerInstitution(f) else { return s }
        let hinted = AccountProposal.typeAndDigits(inHint: hint)
        // A page not read as a statement (a lease bill, a page whose words OCR split apart) still
        // gets one when the number it prints for itself is the one its inbox folder names.
        guard f.kind == .statement
              || (hinted.map { h in f.matchingNumbers.contains { $0.ending == h.digits } } ?? false) else { return s }
        let ending = f.matchingNumbers.first?.ending ?? hinted?.digits
        // An account this bank already has, named by the inbox folder's number (a statement that
        // prints none, after the first ones made its folder): that account, at Medium.
        if let digits = hinted?.digits, f.matchingNumbers.isEmpty,
           let account = { () -> AccountIndex.Account? in
               let named = index.accounts.filter { a in
                   a.institution == institution && a.identities.contains { $0.hasSuffix(digits) || digits.hasSuffix($0) }
               }
               // A live account over a closed one of the same number; a closed one is still its home.
               return named.first { !$0.archived } ?? named.first
           }(),
           let node = accountNodes(AccountIndex(accounts: [account], institutionTokens: [:]), in: taxonomy)[account.root] {
            let place = AccountPlacement.place(in: node, period: period, taxForm: false, fileName: s.fileName)
            var dest = destination(for: account, number: DocumentFacts.OwnNumber(digits: digits, masked: false),
                                   place: place, kind: .statement, confidence: .medium, root: root,
                                   match: .medium(account, number: DocumentFacts.OwnNumber(digits: digits, masked: false), why: .institutionSilent))
            dest = FilingDestination(path: dest.path, confidence: .medium,
                                     reasons: ["The folder it came from names ••\(digits) at \(account.institutionName.isEmpty ? institution : account.institutionName); page 1 prints no number"],
                                     newSegments: dest.newSegments, fromContent: true, evidenceToken: dest.evidenceToken,
                                     proposedName: dest.proposedName, account: dest.account, nameOrigin: dest.nameOrigin)
            return s.replacingCandidates(inserting(dest, into: s.candidates))
        }
        guard let type = hinted?.type,
              let p = AccountProposal.propose(institution: institution, type: type, ending: ending,
                                              // The folder's own spelling, when it is this account's.
                                              name: hinted.flatMap { h in ending == nil || h.digits == ending ? h.name : nil },
                                              index: index, tree: taxonomy, period: period, fileName: s.fileName,
                                              isArchived: isArchived) else { return s }
        // The bank keeps statements of this category together in one folder: no account folders.
        let parent = (p.accountRoot as NSString).deletingLastPathComponent
        if sharedStatementFolders.contains(where: { $0 == parent || $0.hasPrefix(parent + "/") }) { return s }
        // A Medium home already offered inside an account of this type (or this number) is the home.
        if let best = s.best, best.confidence >= .medium,
           let rel = relativePath(best.path, under: root),
           let holder = index.accounts.first(where: { rel == $0.root || rel.hasPrefix($0.root + "/") }) {
            let n = (holder.root as NSString).lastPathComponent.lowercased()
            if n.hasPrefix(type.lowercased()) || (ending.map { e in holder.identities.contains { $0.hasSuffix(e) || e.hasSuffix($0) } } ?? false) {
                return s
            }
        }
        let bank = AccountProposal.displayName(institution, from: AccountProposal.folders(namedFor: institution, in: taxonomy))
        var reason = "No folder holds this \(bank) account"
        if let e = ending.map({ "••" + $0 }) { reason = "No folder holds \(bank) \(e)" }
        if let like = p.namedLike { reason += " · named like \((like as NSString).lastPathComponent)" }
        if f.matchingNumbers.isEmpty, hinted != nil { reason += " · the number is from the folder it came from" }
        var account = FilingAccount(root: root + "/" + p.accountRoot, ending: ending ?? "", institution: institution,
                                    archived: false, kind: .statement)
        account.institutionName = bank
        let dest = FilingDestination(
            path: root + "/" + p.folder, confidence: .medium, reasons: [reason], newSegments: p.newSegments,
            fromContent: true, evidenceToken: ending.map { "••" + $0 }, account: account)
        return s.replacingCandidates(inserting(dest, into: s.candidates))
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
        let (placed, facts) = Self.applyingAccounts([suggestion], index: index, snippets: [suggestion.filePath: page],
                                                    taxonomy: filingAccountTaxonomy, root: root,
                                                    scannedFolder: filingScanFolder,
                                                    sharedStatementFolders: filingSharedStatementFolders,
                                                    isArchived: { [archived = filingArchivedFolders] in archived.contains($0) },
                                                    preferences: filingPreferences)
        if let f = facts[suggestion.filePath] { filingDocumentFacts[suggestion.filePath] = f }
        return placed.first ?? suggestion
    }

    /// The folders the survey marks as archives, by path relative to its root.
    nonisolated static func archivedFolders(in profile: FolderProfile?) -> Set<String> {
        Set((profile?.folders ?? [:]).filter { $0.value.role == .archive || $0.value.axes["lifecycle"] == "archive" }.keys)
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
