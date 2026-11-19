import Events
import Foundation

/// The balance chain: a statement whose page 1 names no account folder's number opens at the
/// balance its account's last statement closed at (`Previous Balance` = last month's `New Balance`).
/// That places an Apple Card statement, which prints no number, and a card reissued under a new
/// number, whose folder still carries the old one.
///
/// Measured on his filed bank and card statements before it was written: on 457 pairs of
/// consecutive months where both balances read, the opening matched the month before's closing on
/// 450. Replayed with each statement arriving after the one filed before it, 184 of 1,173 matched
/// no account's number, and the chain placed 117 of those in their own account and none in another.
/// One small subscription billed to several cards can leave them at the same balance, always beside
/// the true account in that replay: so only the bank's own accounts are compared, and two matches
/// place nothing.
enum BalanceChain {

    /// The balances page 1 prints, in cents: what the statement opened and closed at. A zero
    /// balance is left out: a card paid in full opens at zero every month, which names no account.
    /// Sign is dropped too (`-$12.00` and `$12.00 CR` are one credit balance).
    struct Balances: Sendable, Equatable {
        var opening: Set<Int> = []
        var closing: Set<Int> = []
    }

    /// An account's newest filed statement: the month its name gives and what it closed at.
    struct Link: Sendable, Equatable {
        let period: DocumentFacts.Period
        let closing: Set<Int>
    }

    // `Previous Balance`, `Prior Monthly Balance`, `Beginning balance on March 1, 2025`; never a
    // points or rewards balance (`Beginning Points Balance`), which names no word here.
    private static let openingLabel = try! NSRegularExpression(pattern:
        #"\b(?:previous|prior|beginning|opening|starting)(?:\s+(?:monthly|total|statement|account))?\s+balance\b"#,
        options: [.caseInsensitive])
    // `New Balance`, `Ending balance`, `Closing Balance`, Apple Card's `Total Balance`; the opening
    // labels that end the same way (`Previous Total Balance`) are dropped below.
    private static let closingLabel = try! NSRegularExpression(pattern:
        #"\b(?:new|ending|closing|total)\s+balance(?:\s+total)?\b"#, options: [.caseInsensitive])
    private static let openingBefore = try! NSRegularExpression(pattern:
        #"\b(?:previous|prior|beginning|opening|starting)\s+(?:monthly\s+|statement\s+)?$"#, options: [.caseInsensitive])
    /// The amount after a label on its line: past a date (`as of 01/27/26:`, `on March 1, 2025`) to a
    /// dollar sign, or straight after the label's own punctuation and dot leaders.
    private static let amountAfter = try! NSRegularExpression(pattern:
        #"^(?:[^\n$]{0,40}?\$\s*-?\s*|[\s:.…_]*-?\s*)(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})\b"#)
    /// A line that is only an amount: the value of a label that ended the line before.
    private static let amountLine = try! NSRegularExpression(pattern:
        #"^\s*\(?-?\s*\$?\s*-?\s*(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})\)?(?:\s*cr)?\s*$"#, options: [.caseInsensitive])

    static func balances(in page: String) -> Balances {
        var out = Balances()
        let lines = page.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            for (label, isOpening) in [(openingLabel, true), (closingLabel, false)] {
                for m in label.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    if !isOpening {
                        let before = ns.substring(to: m.range.location)
                        if openingBefore.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
                    }
                    let rest = ns.substring(from: m.range.location + m.range.length)
                    var cents = amount(amountAfter, in: rest)
                    // The label ends its line: the value is the next line holding anything, when that
                    // line is only an amount (a two-column summary extracted label, then value).
                    if cents == nil, rest.trimmingCharacters(in: .whitespaces).isEmpty,
                       let next = lines[(i + 1)...].prefix(2).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        cents = amount(amountLine, in: next)
                    }
                    guard let cents, cents != 0 else { continue }
                    if isOpening { out.opening.insert(cents) } else { out.closing.insert(cents) }
                }
            }
        }
        return out
    }

    private static func amount(_ re: NSRegularExpression, in s: String) -> Int? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let dollars = Int(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")),
              let cents = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return dollars * 100 + cents
    }

    /// The account's newest statement, relative to its root, and the month its name gives: the
    /// newest member of its regular statement families, PDFs only, outside a tax folder (as
    /// ``AccountPlacement`` reads the same folder).
    static func newestStatement(in node: FileNode) -> (file: String, period: DocumentFacts.Period)? {
        let members = StatementFamily.families(below: node)
            .mapValues { $0.filter { !AccountPlacement.isTaxFolder($0.folder) && ($0.name as NSString).pathExtension.lowercased() == "pdf" } }
            .filter { StatementFamily.isRegular($0.value) }
            .values.flatMap { $0 }
        guard let newest = members.max(by: { $0.period < $1.period }) else { return nil }
        return (newest.folder.isEmpty ? newest.name : newest.folder + "/" + newest.name, newest.period)
    }

    /// The one account among `accounts` whose newest statement closed at a balance this statement
    /// opens at, and closed before it: nil for none, or for two (`adjacent` when it closed the month
    /// before).
    static func account(for f: DocumentFacts, among accounts: [AccountIndex.Account],
                        links: [String: Link]) -> (account: AccountIndex.Account, link: Link, adjacent: Bool)? {
        guard f.kind == .statement else { return nil }
        let opening = balances(in: f.text).opening
        guard !opening.isEmpty else { return nil }
        let hits = accounts.compactMap { a -> (AccountIndex.Account, Link)? in
            guard !a.archived, let link = links[a.root], !link.closing.isDisjoint(with: opening) else { return nil }
            if let p = f.period, link.period.monthIndex >= p.monthIndex { return nil }
            return (a, link)
        }
        guard hits.count == 1, let (account, link) = hits.first else { return nil }
        let adjacent = f.period.map { p in
            p.monthIndex - link.period.monthIndex == 1
                || (f.periodStart.map { $0.monthIndex - link.period.monthIndex == 1 } ?? false)
        } ?? false
        return (account, link, adjacent)
    }

    /// The accounts a loose statement could chain to: the ones its number ends like, else every
    /// account at the bank its header (or the folder it came from) names.
    static func candidates(for f: DocumentFacts, match: AccountIndex.Match, index: AccountIndex,
                           hint: String) -> [AccountIndex.Account] {
        switch match {
        case .ambiguous(let accounts):
            return accounts
        case .none:
            guard let bank = index.headerInstitution(f) ?? index.institution(namedIn: hint.lowercased()) else { return [] }
            return index.accounts.filter { $0.institution == bank }
        default:
            return []
        }
    }
}

extension FileSyncManager {

    /// The newest statement's closing balance of every account a loose statement could chain to
    /// (``BalanceChain``), by account root. Read only for statements that print an opening balance
    /// and no account's number; through the scan's reader and the session's page cache, as
    /// ``addingUnnamedAccounts(to:taxonomy:root:isArchived:)`` reads, so a cloud-only file is never
    /// opened and a rescan reads only what changed.
    func balanceLinks(for snippets: [String: String], index: AccountIndex, taxonomy: [FileNode],
                      root: String, scannedFolder: String?) async -> [String: BalanceChain.Link] {
        guard let extractor = filingSnippetExtractor, !index.isEmpty else { return [:] }
        let (wanted, nodes): ([String], [String: FileNode]) = await Task.detached(priority: .userInitiated) {
            var roots = Set<String>()
            for (path, page) in snippets {
                let f = DocumentFacts(page: page)
                guard f.kind == .statement, !BalanceChain.balances(in: f.text).opening.isEmpty else { continue }
                let hint = Self.sourceHint(forFile: path, scannedFolder: scannedFolder)
                for a in BalanceChain.candidates(for: f, match: index.match(f), index: index, hint: hint) where !a.archived {
                    roots.insert(a.root)
                }
            }
            let nodes = Self.accountNodes(AccountIndex(accounts: index.accounts.filter { roots.contains($0.root) },
                                                      institutionTokens: [:]), in: taxonomy)
            return (roots.sorted(), nodes)
        }.value
        guard !wanted.isEmpty else { return [:] }
        var newest: [String: (path: String, period: DocumentFacts.Period)] = [:]
        for account in wanted {
            guard let node = nodes[account], let n = BalanceChain.newestStatement(in: node) else { continue }
            newest[account] = (root + "/" + account + "/" + n.file, n.period)
        }
        var toRead: [String] = []
        var modifiedAt: [String: Date?] = [:]
        for (_, n) in newest {
            let modified = (try? fileManager.attributesOfItem(atPath: n.path))?[.modificationDate] as? Date
            modifiedAt[n.path] = modified
            if let cached = filingAccountPageCache[n.path], cached.modified == modified { continue }
            toRead.append(n.path)
        }
        let pages = await Self.extractSnippets(for: toRead, using: extractor)
        if Task.isCancelled { return [:] }
        for path in toRead {
            filingAccountPageCache[path] = (modifiedAt[path] ?? nil, pages[path].map { DocumentFacts(page: $0) })
        }
        var links: [String: BalanceChain.Link] = [:]
        for (account, n) in newest {
            guard let facts = filingAccountPageCache[n.path]?.facts else { continue }
            let closing = BalanceChain.balances(in: facts.text).closing
            if !closing.isEmpty { links[account] = BalanceChain.Link(period: n.period, closing: closing) }
        }
        Logger.shared.info("Filing: read the newest statement of \(newest.count) account(s) for the balance chain "
            + "(\(toRead.count) fresh); \(links.count) print a closing balance")
        return links
    }
}
