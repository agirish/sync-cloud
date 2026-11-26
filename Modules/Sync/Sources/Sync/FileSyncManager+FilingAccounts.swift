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
        preferences: [FilingPreference] = [],
        rejected: [String: Set<String>] = [:],
        registry: PersonRegistry? = nil,
        balanceLinks: [String: BalanceChain.Link] = [:]
    ) -> (suggestions: [FilingSuggestion], facts: [String: DocumentFacts]) {
        var facts: [String: DocumentFacts] = [:]
        let nodes = accountNodes(index, in: taxonomy)
        // Folders where a bank's statements are kept together with no account of their own
        // (`Fidelity/Statements`): a bank that has one gets no new account folders proposed.
        let sharedStatementFolders = shared ?? Set(index.unnamedSamples(tree: taxonomy).map(\.candidate))
        let out = suggestions.map { s -> FilingSuggestion in
            let placed = placingByAccount(s)
            // Try Another said "not there": an account home is never re-suggested either.
            guard let refused = rejected[s.filePath], let best = placed.best, best.account != nil || best.isNew,
                  refused.contains(where: { best.path == $0 || PathBoundary.contains(best.path, under: $0) }) else { return placed }
            return s
        }
        func placingByAccount(_ s: FilingSuggestion) -> FilingSuggestion {
            guard let page = snippets[s.filePath] else { return s }
            let f = DocumentFacts(page: page)
            facts[s.filePath] = f
            let match = index.match(f)
            let hint = sourceHint(forFile: s.filePath, scannedFolder: scannedFolder)
            // A tax form's year is the one it prints; a file name's date is when it was fetched.
            let period = f.period ?? (f.kind == .taxForm ? nil : StatementFamily.period(ofName: s.fileName, folder: hint))
            // A file name's date is usually when it was fetched, which runs a month or so past the
            // period it holds (`eStmt_2025-03-27` for a February statement). It can place a file,
            // never surely: Medium, saying where the month came from.
            let monthFromName = f.period == nil && period != nil
            switch match {
            case .high(let account, let number), .medium(let account, let number, _):
                guard let node = nodes[account.root] else { return s }
                let place = Self.placement(in: node, facts: f, period: period, monthFromName: monthFromName,
                                           fileName: s.fileName, bank: bankNode(of: account.root, in: taxonomy))
                // High only when the folder inside the account is sure too.
                let confidence: FilingConfidence
                if case .high = match, !place.yearUnknown, !monthFromName { confidence = .high } else { confidence = .medium }
                let dest = destination(for: account, number: number, place: place, kind: f.kind,
                                       confidence: confidence, root: root, match: match,
                                       monthFromName: monthFromName)
                // A tax form printing its account's own number, from the bank the page names, leads:
                // its account is certain, whatever a word match says (Medium, as tax forms are).
                if case .medium(_, _, .notAStatement) = match, f.kind == .taxForm {
                    return s.replacingCandidates(leading(dest, in: s.candidates))
                }
                // A Medium match on another page that isn't a statement (a tax return naming its
                // refund account, a credit report) is one more option, behind the homes found for it.
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
                                                                           fileName: s.fileName,
                                                                           bank: bankNode(of: account.root, in: taxonomy),
                                                                           periodStart: monthFromName ? nil : f.periodStart)))
                }
                guard let (account, number, place) = placed.first else { return s }
                let sure = placed.allSatisfy { !$0.2.yearUnknown } && !monthFromName
                var dest = destination(for: account, number: number, place: place, kind: f.kind,
                                       confidence: sure ? .high : .medium, root: root, match: .high(account, number: number),
                                       monthFromName: monthFromName)
                let copies = placed.dropFirst().map { a, n, p -> FilingCopy in
                    let accountPath = root + "/" + a.root
                    var fa = FilingAccount(root: accountPath, ending: n.ending, institution: a.institution,
                                           archived: a.archived, kind: f.kind)
                    fa.institutionName = a.institutionName
                    return FilingCopy(path: p.folder.isEmpty ? accountPath : accountPath + "/" + p.folder,
                                      proposedName: p.name, account: fa)
                }
                // Every account it names; which get a copy is decided at filing and on screen by the
                // preferences then (``FileSyncManager/copiesToMake(_:)``), so one set or removed
                // later applies to the cards already open.
                var reasons = dest.reasons
                reasons.append("Also names " + copies.map { "••" + $0.account.ending }.joined(separator: ", "))
                dest = FilingDestination(path: dest.path, confidence: dest.confidence, reasons: reasons,
                                         newSegments: dest.newSegments, fromContent: true, evidenceToken: dest.evidenceToken,
                                         proposedName: dest.proposedName, account: dest.account, nameOrigin: dest.nameOrigin)
                dest.alsoCopiesTo = copies
                return s.replacingCandidates(inserting(dest, into: s.candidates))
            case .ambiguous(let accounts):
                // The one whose last statement closed at the balance this one opens at.
                if let chained = chainedHome(s, facts: f, period: period, monthFromName: monthFromName, match: match,
                                             index: index, nodes: nodes, taxonomy: taxonomy, root: root, hint: hint,
                                             links: balanceLinks) { return chained }
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
                if let chained = chainedHome(s, facts: f, period: period, monthFromName: monthFromName, match: match,
                                             index: index, nodes: nodes, taxonomy: taxonomy, root: root, hint: hint,
                                             links: balanceLinks) { return chained }
                return proposingAccount(for: s, facts: f, period: period, hint: hint, index: index,
                                        taxonomy: taxonomy, root: root, sharedStatementFolders: sharedStatementFolders,
                                        isArchived: isArchived, registry: registry)
            }
        }
        _ = isArchived
        return (out, facts)
    }

    /// A statement no account's number places, in the one account at its bank whose newest
    /// statement closed at the balance it opens at (``BalanceChain``). High when that statement is
    /// the month before, page 1 dates this one and prints no other number; Medium otherwise.
    nonisolated static func chainedHome(_ s: FilingSuggestion, facts f: DocumentFacts, period: DocumentFacts.Period?,
                                        monthFromName: Bool, match: AccountIndex.Match, index: AccountIndex,
                                        nodes: [String: FileNode], taxonomy: [FileNode], root: String, hint: String,
                                        links: [String: BalanceChain.Link]) -> FilingSuggestion? {
        guard !links.isEmpty else { return nil }
        let among = BalanceChain.candidates(for: f, match: match, index: index, hint: hint)
        guard let (account, link, adjacent) = BalanceChain.account(for: f, among: among, links: links),
              let node = nodes[account.root] else { return nil }
        let place = placement(in: node, facts: f, period: period, monthFromName: monthFromName,
                              fileName: s.fileName, bank: bankNode(of: account.root, in: taxonomy))
        let own = account.identities.first.map { String($0.suffix(4)) } ?? ""
        let printed = f.matchingNumbers.first?.ending
        let ending = printed ?? own
        let sure = adjacent && !monthFromName && !place.yearUnknown && printed == nil
        let number = DocumentFacts.OwnNumber(digits: ending, masked: false)
        let dest = destination(for: account, number: number, place: place, kind: f.kind,
                               confidence: sure ? .high : .medium, root: root, match: .high(account, number: number),
                               monthFromName: monthFromName)
        let month = AccountPlacement.Template.monthNames[link.period.month - 1] + " \(link.period.year)"
        var reason = "Opens at the balance " + (own.isEmpty ? "this account’s" : "••\(own)’s")
            + " \(month) statement closed at"
        if let printed, printed != own { reason += " · page 1 prints ••\(printed), a number no folder has" }
        if case .ambiguous = match { reason += " · its number ends like another account’s" }
        if monthFromName { reason += " · month from the file name" }
        var chained = FilingDestination(path: dest.path, confidence: dest.confidence, reasons: [reason],
                                        newSegments: dest.newSegments, fromContent: true, evidenceToken: dest.evidenceToken,
                                        proposedName: dest.proposedName, account: dest.account, nameOrigin: dest.nameOrigin)
        chained.alsoCopiesTo = dest.alsoCopiesTo
        return s.replacingCandidates(inserting(chained, into: s.candidates))
    }

    /// Where a paper goes inside its account. A year-end summary is `0. Summary YYYY` in that
    /// year's folder, and a trade confirmation `Trade Confirms/<year>/DD Mon YYYY` where the account
    /// keeps that folder (``StatementForms``); anything else as the month's statement.
    nonisolated static func placement(in node: FileNode, facts f: DocumentFacts, period: DocumentFacts.Period?,
                                      monthFromName: Bool, fileName: String, bank: FileNode?) -> AccountPlacement.Placement {
        if f.kind != .taxForm, !monthFromName, let form = StatementForms.form(of: f) {
            switch form {
            case .yearEndSummary(let year), .spendReport(let year):
                let p = AccountPlacement.place(in: node, period: .init(year: year, month: 12, day: 31), taxForm: false,
                                               fileName: fileName, bank: bank)
                guard !p.yearUnknown else { return p }
                let ext = (p.name.map { ($0 as NSString).pathExtension } ?? (fileName as NSString).pathExtension)
                let name = if case .spendReport = form { StatementForms.spendName(year: year, ext: ext) }
                           else { StatementForms.summaryName(year: year, ext: ext) }
                return AccountPlacement.Placement(folder: p.folder, newSegments: p.newSegments, name: name)
            case .tradeConfirm(let date):
                if let p = StatementForms.confirmPlacement(date, in: node, fileName: fileName) { return p }
            }
        }
        return AccountPlacement.place(in: node, period: period, taxForm: f.kind == .taxForm, fileName: fileName,
                                      bank: bank, periodStart: monthFromName ? nil : f.periodStart)
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
            var renamed = FilingDestination(path: best.path, confidence: best.confidence,
                                            reasons: best.reasons + ["Kept as “\(chosen)”: “\(name)” is taken there"],
                                            newSegments: best.newSegments, fromContent: best.fromContent,
                                            remembered: best.remembered, fromAI: best.fromAI,
                                            evidenceToken: best.evidenceToken, neighborMatches: best.neighborMatches,
                                            proposedName: chosen, fromSurvey: best.fromSurvey,
                                            account: best.account, nameOrigin: .template)
            renamed.alsoCopiesTo = best.alsoCopiesTo
            return s.replacingCandidates([renamed] + s.candidates.dropFirst())
        }
    }

    /// A new account folder for a statement from a known bank that no account matches
    /// (``AccountProposal``), unless the bank keeps such statements together in one folder and no
    /// account in a folder of its own (`Citi/Statements`), or a home in an account of this type is
    /// already offered. When the
    /// folder the statement came from names an account the tree already has, that account is the
    /// home instead.
    nonisolated static func proposingAccount(for s: FilingSuggestion, facts f: DocumentFacts,
                                             period: DocumentFacts.Period?, hint: String, index: AccountIndex,
                                             taxonomy: [FileNode], root: String,
                                             sharedStatementFolders: Set<String> = [],
                                             isArchived: (String) -> Bool = { _ in false },
                                             registry: PersonRegistry? = nil) -> FilingSuggestion {
        guard f.kind != .taxForm else { return s }
        // The bank: the one page 1's header names; else the one the folder it came from names (his
        // own words, `ScholarShare 529/529 6797-02`). Not the rest of the page, where a GEICO
        // letter names the card it is paid with.
        guard let institution = index.headerInstitution(f) ?? index.institution(namedIn: hint.lowercased()) else {
            return companyHome(for: s, facts: f, hint: hint, index: index, taxonomy: taxonomy, root: root,
                               period: period)
        }
        // The inbox folder names another company the page names too (`GEICO`, on a declarations
        // page whose header mentions American Express): his folder says whose it is.
        let company = companyWords(hint: hint, facts: f, index: index, taxonomy: taxonomy)
        if !company.isEmpty, company.isDisjoint(with: index.institutionTokens[institution] ?? []) {
            return companyHome(for: s, facts: f, hint: hint, index: index, taxonomy: taxonomy, root: root,
                               period: period)
        }
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
            let place = AccountPlacement.place(in: node, period: period, taxForm: false, fileName: s.fileName,
                                               bank: bankNode(of: account.root, in: taxonomy))
            var dest = destination(for: account, number: DocumentFacts.OwnNumber(digits: digits, masked: false),
                                   place: place, kind: .statement, confidence: .medium, root: root,
                                   match: .medium(account, number: DocumentFacts.OwnNumber(digits: digits, masked: false), why: .institutionSilent))
            dest = FilingDestination(path: dest.path, confidence: .medium,
                                     reasons: ["The folder it came from names ••\(digits) at \(account.institutionName.isEmpty ? institution : account.institutionName); page 1 prints no number"],
                                     newSegments: dest.newSegments, fromContent: true, evidenceToken: dest.evidenceToken,
                                     proposedName: dest.proposedName, account: dest.account, nameOrigin: dest.nameOrigin)
            return s.replacingCandidates(inserting(dest, into: s.candidates))
        }
        guard let type = hinted?.type else {
            return f.kind == .statement
                ? homeAtInstitution(for: s, facts: f, period: period, institution: institution, index: index,
                                    taxonomy: taxonomy, root: root, isArchived: isArchived, registry: registry)
                : s
        }
        // The folder's own spelling, when it is this account's; with the holder after the number
        // when page 1 names only someone whose accounts carry their name (`Credit 8436 (Mother)`).
        let ownName = hinted.flatMap { h in ending == nil || h.digits == ending ? h.name : nil }
        let holder = ownName?.contains("(") == true ? nil
            : AccountProposal.holderSuffix(page: f.text, tree: taxonomy, registry: registry)
        let accountName = holder.map { h in (ownName ?? [type, ending].compactMap { $0 }.joined(separator: " ")) + " (\(h))" }
            ?? ownName
        guard let p = AccountProposal.propose(institution: institution, type: type, ending: ending,
                                              name: accountName,
                                              index: index, tree: taxonomy, period: period, fileName: s.fileName,
                                              isArchived: isArchived) else { return s }
        // The bank keeps statements of this category together in one folder (`Citi/Statements`): no
        // account folders. Unless it keeps a live account in a folder of its own there too
        // (`Fidelity/Roth IRA 4657` beside `Fidelity/Statements`): then each account gets one.
        let parent = (p.accountRoot as NSString).deletingLastPathComponent
        let ownFolders = index.accounts.contains { a in
            !a.archived && a.institution == institution && (a.root as NSString).deletingLastPathComponent == parent
                && !sharedStatementFolders.contains(a.root)
        }
        if !ownFolders, sharedStatementFolders.contains(where: { $0 == parent || $0.hasPrefix(parent + "/") }) { return s }
        // A Medium home already offered inside an account of this type (or this number) is the home.
        if let best = s.best, best.confidence >= .medium,
           let rel = relativePath(best.path, under: root),
           let holder = index.accounts.first(where: { $0.institution == institution && (rel == $0.root || rel.hasPrefix($0.root + "/")) }) {
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
        if let holder { reason += " · page 1 names only \(holder)" }
        var account = FilingAccount(root: root + "/" + p.accountRoot, ending: ending ?? "", institution: institution,
                                    archived: false, kind: .statement)
        account.institutionName = bank
        let dest = FilingDestination(
            path: root + "/" + p.folder, confidence: .medium, reasons: [reason], newSegments: p.newSegments,
            fromContent: true, evidenceToken: ending.map { "••" + $0 }, account: account)
        return s.replacingCandidates(inserting(dest, into: s.candidates))
    }

    /// A statement from a known bank that no account matches and whose folder names no account type
    /// to call a new one by (`529 6797-02`, or loose): the bank's own folder, when the tree has just
    /// one. Inside it, the folder of the one person page 1 names that holds no other account
    /// (`ScholarShare/Son` for Son's 529, beside Daughter's account `ScholarShare/Daughter`), laid out
    /// like the bank's live account there. Medium either way: no number placed it.
    nonisolated static func homeAtInstitution(for s: FilingSuggestion, facts f: DocumentFacts,
                                              period: DocumentFacts.Period?, institution: String,
                                              index: AccountIndex, taxonomy: [FileNode], root: String,
                                              isArchived: (String) -> Bool,
                                              registry: PersonRegistry?) -> FilingSuggestion {
        let folders = AccountProposal.folders(namedFor: institution, in: taxonomy, isArchived: isArchived)
        guard folders.count == 1, let bankFolder = folders.first,
              let bankNode = AccountProposal.node(at: bankFolder, in: taxonomy) else { return s }
        let bank = AccountProposal.displayName(institution, from: folders)
        let ending = f.matchingNumbers.first?.ending
        let accountsHere = index.accounts.filter { $0.root.hasPrefix(bankFolder + "/") }
        var reason = "No \(bank) folder holds " + (ending.map { "••" + $0 } ?? "this account")
        // The person's folder: named on the page, resolved by the registry so `Son Father` is
        // Son, and not another account's (Daughter's statements print her own number).
        if let registry, let person = { () -> FileNode? in
            let named = registry.detect(in: f.text)
            let people = (bankNode.children ?? []).filter { c in
                let path = bankFolder + "/" + c.name
                return c.isDirectory && !AccountIndex.isArchiveName(c.name) && !isArchived(path)
                    && !accountsHere.contains { $0.root == path || $0.root.hasPrefix(path + "/") }
                    && registry.person(forAxisValue: c.name).map(named.contains) == true
            }
            return people.count == 1 ? people[0] : nil
        }() {
            let home = bankFolder + "/" + person.name
            // Laid out like the bank's live account: its year folder and its newest name.
            var path = home
            var name: String?
            if let model = accountsHere.first(where: { !$0.archived }),
               let modelNode = AccountProposal.node(at: model.root, in: taxonomy) {
                let place = AccountPlacement.place(in: modelNode, period: period, taxForm: false, fileName: s.fileName,
                                                   bank: bankNode)
                if !place.yearUnknown, !place.folder.isEmpty { path = home + "/" + place.folder }
                if !place.yearUnknown { name = place.name }
            }
            reason += " · page 1 names \(person.name)"
            var account = FilingAccount(root: root + "/" + home, ending: ending ?? "", institution: institution,
                                        archived: false, kind: .statement)
            account.institutionName = bank
            let dest = FilingDestination(
                path: root + "/" + path, confidence: .medium, reasons: [reason],
                newSegments: AccountProposal.missing(path, in: taxonomy), fromContent: true,
                evidenceToken: ending.map { "••" + $0 }, proposedName: name, account: account,
                nameOrigin: name == nil ? .planner : .template)
            return s.replacingCandidates(inserting(dest, into: s.candidates))
        }
        // The bank's folder itself, unless a home in it is already offered.
        if let best = s.best, best.confidence >= .medium,
           PathBoundary.contains(best.path, under: root + "/" + bankFolder) { return s }
        let dest = FilingDestination(path: root + "/" + bankFolder, confidence: .medium, reasons: [reason],
                                     newSegments: [], fromContent: true, evidenceToken: ending.map { "••" + $0 })
        return s.replacingCandidates(inserting(dest, into: s.candidates))
    }

    /// A page from a company no account folder names (an insurer: `TODO/Finance/GEICO/Auto 0652`),
    /// whose folder in the inbox names it and whose page 1 names it too: the one folder holding the
    /// most files named for it (`Vehicles/Honda/Insurance`, eight `GEICO …` files). When the page
    /// prints the number that folder names (policy ••0652), that is its account. Medium: a name, not
    /// a number, chose the folder.
    nonisolated static func companyHome(for s: FilingSuggestion, facts f: DocumentFacts, hint: String,
                                        index: AccountIndex, taxonomy: [FileNode], root: String,
                                        period: DocumentFacts.Period? = nil) -> FilingSuggestion {
        let words = companyWords(hint: hint, facts: f, index: index, taxonomy: taxonomy)
        guard !words.isEmpty else { return s }
        // The folder being sorted, which `hint` is relative to: nothing in it is a home.
        let parent = (s.filePath as NSString).deletingLastPathComponent
        let sorted = hint.isEmpty || !parent.hasSuffix("/" + hint) ? parent : String(parent.dropLast(hint.count + 1))
        var counts: [String: Int] = [:]
        func visit(_ nodes: [FileNode], _ prefix: String) {
            for n in nodes where n.isDirectory {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                // Never an archive or an inbox, nor the folder being sorted.
                if AccountIndex.isArchiveName(n.name) || FolderProfile.isInboxPath(rel)
                    || PathBoundary.contains(root + "/" + rel, under: sorted) { continue }
                let named = (n.children ?? []).filter { c in
                    !c.isDirectory && !words.isDisjoint(with: AccountIndex.words(c.name))
                }.count
                if named > 0 { counts[rel] = named }
                visit(n.children ?? [], rel)
            }
        }
        visit(taxonomy, "")
        guard let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              counts.values.filter({ $0 == top.value }).count == 1 else { return s }
        let company = (hint.split(separator: "/").map(String.init).first { seg in
            !words.isDisjoint(with: AccountIndex.words(seg))
        }) ?? words.sorted()[0]
        var reason = "\(top.value) file\(top.value == 1 ? "" : "s") here \(top.value == 1 ? "is" : "are") named for \(company), as the folder it came from is"
        var account: FilingAccount?
        if let hinted = AccountProposal.typeAndDigits(inHint: hint),
           f.matchingNumbers.contains(where: { $0.ending == hinted.digits }) {
            reason += " · ••\(hinted.digits) on page 1"
            var a = FilingAccount(root: root + "/" + top.key, ending: hinted.digits, institution: company.lowercased(),
                                  archived: false, kind: f.kind)
            a.institutionName = company
            account = a
        }
        // Inside it, the year's folder when the folder keeps its newest files by year
        // (`Home/Insurance/2025` holds 2025's renewal, so 2026's goes to `2026`).
        var path = top.key
        var newSegments: [String] = []
        if let year = period?.year, let node = AccountProposal.node(at: top.key, in: taxonomy),
           let folder = yearFolder(in: node, for: year) {
            path += "/" + folder.name
            if folder.isNew { newSegments = [folder.name] }
        }
        let dest = FilingDestination(path: root + "/" + path, confidence: .medium, reasons: [reason],
                                     newSegments: newSegments, fromContent: true,
                                     evidenceToken: account.map { "••" + $0.ending }, account: account)
        return s.replacingCandidates(inserting(dest, into: s.candidates))
    }

    /// The folder for `year` inside `node`, when `node` files by year: it has year folders, and no
    /// file loose in it is dated later than the newest of them (`Vehicles/Honda/Insurance` has
    /// folders up to 2021 but keeps 2024–2026 loose, so it doesn't).
    nonisolated static func yearFolder(in node: FileNode, for year: Int) -> (name: String, isNew: Bool)? {
        let kids = node.children ?? []
        let years = kids.filter { $0.isDirectory && $0.name.count == 4 && FolderProfileEntry.looksLikeYear($0.name) }
            .compactMap { Int($0.name) }
        guard let newestFolder = years.max() else { return nil }
        let newestLoose = kids.filter { !$0.isDirectory }
            .compactMap { StatementFamily.period(ofName: $0.name, folder: "")?.year }.max()
        if let newestLoose, newestLoose > newestFolder { return nil }
        return (String(year), !years.contains(year))
    }

    /// The company the inbox folder names, as words page 1 names too: the folders' own words, less
    /// a category (`Finance`), a year, the account folder (`Auto 0652`) and words common to many
    /// folder names. `TODO/Finance/GEICO/Auto 0652/2026` gives `geico`.
    nonisolated static func companyWords(hint: String, facts f: DocumentFacts, index: AccountIndex,
                                         taxonomy: [FileNode]) -> Set<String> {
        let categories = Set(taxonomy.filter(\.isDirectory).map { $0.name.lowercased() })
        return Set(hint.split(separator: "/").map(String.init).filter { seg in
            !categories.contains(seg.lowercased()) && !FolderProfileEntry.looksLikeYear(seg)
                && AccountIndex.accountDigits(inFolderNamed: seg).isEmpty
        }.flatMap(AccountIndex.words).filter { w in
            w.count >= 4 && !index.genericWords.contains(w) && !AccountIndex.stopWords.contains(w)
                && !FilingPeriod.isMonthWord(w) && AccountIndex.wordCount(w, in: f.text) > 0
        })
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

    /// The bank's folder above an account (`Investments/Fidelity` for `…/Fidelity/Roth IRA 4657`).
    nonisolated static func bankNode(of accountRoot: String, in taxonomy: [FileNode]) -> FileNode? {
        AccountIndex.institutionFolder(of: accountRoot, isArchived: { _ in false })
            .flatMap { AccountProposal.node(at: $0.0, in: taxonomy) }
    }

    nonisolated static func destination(for account: AccountIndex.Account, number: DocumentFacts.OwnNumber,
                                        place: AccountPlacement.Placement, kind: DocumentFacts.Kind,
                                        confidence: FilingConfidence, root: String,
                                        match: AccountIndex.Match, monthFromName: Bool = false) -> FilingDestination {
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
        if monthFromName { reason += " · month from the file name" }
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

    /// `dest` first, after only the user's own rules.
    nonisolated static func leading(_ dest: FilingDestination, in candidates: [FilingDestination]) -> [FilingDestination] {
        if candidates.contains(where: { $0.remembered && $0.path == dest.path }) { return candidates }
        let others = candidates.filter { $0.path != dest.path }
        let ruled = others.prefix { $0.remembered }
        return Array(ruled) + [dest] + Array(others.dropFirst(ruled.count))
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
                                                    preferences: filingPreferences,
                                                    rejected: [suggestion.filePath: rejectedFolders(fileName: suggestion.fileName, filePath: suggestion.filePath,
                                                                                                    in: filingRejections(under: URL(fileURLWithPath: root)))],
                                                    registry: filingPersonRegistry, balanceLinks: filingBalanceLinks)
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
