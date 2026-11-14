import Foundation
import Events

/// An account he taught by filing its statements somewhere To File didn't offer (decision 8): the
/// number the statements print for themselves, their bank, and the folder he chose. The next scan
/// matches it like an account whose folder name carries the number.
///
/// Stored in plain text: the last four digits, the same digits his folder names already show.
/// Hashing four digits protects nothing on the Mac that holds them.
public struct LearnedAccount: Codable, Equatable, Identifiable, Sendable {
    public enum TaughtBy: String, Codable, Sendable { case groupRedirect, singleRedirect, newAccount }

    /// One file of the filing that taught it: Undo puts it back at `source` and takes it from
    /// `landed`, which is how the entry knows to forget itself.
    public struct Teaching: Codable, Equatable, Sendable {
        public let source: String
        public let landed: String
        public init(source: String, landed: String) { self.source = source; self.landed = landed }
    }

    public var id: UUID
    /// The bank's normalized name (`charles schwab`), as the account index keys it.
    public var institution: String
    /// The bank's folder name, for display (`Charles Schwab`).
    public var institutionName: String
    /// The last four digits the statements print.
    public var ending: String
    /// The account folder, relative to `surveyRoot`.
    public var folder: String
    public var surveyRoot: String
    public var taughtAt: Date
    public var taughtBy: TaughtBy
    /// Statements filed into it since, its teaching included.
    public var filedCount: Int
    public var teaching: [Teaching]

    public var absoluteFolder: String { surveyRoot + "/" + folder }
}

extension FileSyncManager {

    public nonisolated static let learnedAccountsDefaultsKey = "filingLearnedAccounts"

    /// Every account taught, newest last. Lives beside the rules (`filingRuleDefaults`), apart
    /// from the survey: a survey rebuilt leaves it as it was.
    public var filingLearnedAccounts: [LearnedAccount] {
        get {
            FileSyncManager.decodePersistedStore([LearnedAccount].self, from: filingRuleDefaults,
                                                 key: Self.learnedAccountsDefaultsKey,
                                                 describing: "learned accounts") ?? []
        }
        set {
            objectWillChange.send()
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.learnedAccountsDefaultsKey,
                                                describing: "learned accounts")
        }
    }

    /// The number a filing of `members` would teach: the ending most of them print for themselves.
    /// nil when none prints one: "Nothing to remember: no account number on page 1".
    public func rememberableEnding(for members: [FilingSuggestion]) -> String? {
        rememberableEnding(for: members, facts: filingDocumentFacts)
    }

    func rememberableEnding(for members: [FilingSuggestion], facts: [String: DocumentFacts]) -> String? {
        var counts: [String: Int] = [:]
        for m in members {
            // Statements only: a 1099 sent to Income Tax says nothing about where statements go.
            guard let f = facts[m.filePath], f.kind == .statement else { continue }
            for e in Set(f.matchingNumbers.map(\.ending)) { counts[e, default: 0] += 1 }
        }
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        // A tie names no one account.
        return counts.filter { $0.value == top.value }.count == 1 ? top.key : nil
    }

    /// Records what filing `members` into `folder` taught: their number, their bank and the
    /// account folder holding `folder` (its year and month levels set aside). Nothing when they
    /// print no number, when `folder` is outside the tree the scan walked, or when no bank is
    /// known for them. Returns the entry taught.
    @discardableResult
    public func teachAccount(from members: [FilingSuggestion], landed: [LearnedAccount.Teaching],
                             into folder: String, by taughtBy: LearnedAccount.TaughtBy,
                             now: Date = Date()) -> LearnedAccount? {
        teachingAccount(from: members, landed: landed, into: folder, by: taughtBy, now: now)?.taught
    }

    /// ``teachAccount(from:landed:into:by:now:)``, with the entry as it was before (nil when the
    /// lesson is new): what ⌘Z of this filing restores.
    /// `facts`: the page facts as they were when filing began; a scan finishing meanwhile replaces
    /// the manager's.
    func teachingAccount(from members: [FilingSuggestion], landed: [LearnedAccount.Teaching],
                         into folder: String, by taughtBy: LearnedAccount.TaughtBy,
                         facts snapshot: [String: DocumentFacts]? = nil,
                         now: Date = Date()) -> (taught: LearnedAccount, previous: LearnedAccount?)? {
        let pageFacts = snapshot ?? filingDocumentFacts
        guard !landed.isEmpty, let ending = rememberableEnding(for: members, facts: pageFacts),
              let root = members.first?.providerRoot ?? filingLastProviderRoot,
              var relative = Self.relativePath(folder, under: root), !relative.isEmpty else { return nil }
        relative = Self.accountFolder(of: relative)
        guard !relative.isEmpty else { return nil }
        let index = filingAccountIndex
        let facts = members.compactMap { pageFacts[$0.filePath] }
        // The bank the pages name, else the bank folder he chose.
        let named = facts.compactMap { index?.headerInstitution($0) }
        let byPage = Dictionary(grouping: named, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        // Else a folder above the one chosen that the tree already knows as a bank: never a guess
        // from a folder that only sits above it (`…/Checking/Statements` is not a bank "checking").
        let known = Set(index?.institutionTokens.keys.map { $0 } ?? [])
        let folderBank = relative.split(separator: "/").map(String.init).reversed()
            .first { known.contains($0.lowercased()) }
        let institution = byPage ?? folderBank.map { $0.lowercased() }
        guard let institution else {
            Logger.shared.info("Filing: nothing learned for ••\(ending): no bank named on the page or above “\(relative)”")
            return nil
        }
        // A folder whose name carries this number at this bank outranks any lesson
        // (`AccountIndex.adding(learned:)`): one taught here would be listed and never used.
        if let named = index?.accounts.first(where: { a in
            a.institution == institution && a.root != relative
                && AccountIndex.accountDigits(inFolderNamed: (a.root as NSString).lastPathComponent)
                    .contains { $0.hasSuffix(ending) }
        }) {
            Logger.shared.info("Filing: nothing learned for ••\(ending): \(named.root) carries that number")
            return nil
        }
        let displayName = relative.split(separator: "/").map(String.init).last { $0.lowercased() == institution }
            ?? index?.accounts.first { $0.institution == institution }?.institutionName
            ?? folderBank ?? institution
        var all = filingLearnedAccounts
        let entry: LearnedAccount
        var previous: LearnedAccount?
        if let i = all.firstIndex(where: { $0.institution == institution && $0.ending == ending
                                           && $0.folder == relative && $0.surveyRoot == root }) {
            // Counted already as the files landed (`noteFiledIntoLearnedAccounts`).
            previous = all[i]
            all[i].teaching = Array((all[i].teaching + landed).suffix(200))
            all[i].taughtAt = now
            entry = all[i]
        } else {
            // The same number at the same bank somewhere else stays too: two accounts can share an
            // ending, and the cards then say so rather than pick one.
            entry = LearnedAccount(id: UUID(), institution: institution, institutionName: displayName,
                                   ending: ending, folder: relative, surveyRoot: root, taughtAt: now,
                                   taughtBy: taughtBy, filedCount: landed.count, teaching: landed)
            all.append(entry)
        }
        filingLearnedAccounts = all
        Logger.shared.info("Filing: learned \(displayName) ••\(ending) → \(relative)")
        return (entry, previous)
    }

    /// What the ⌘Z of a filing that taught a lesson does to it: once the files are back (each at
    /// its source, none where it landed), the lesson is as it was before, or gone if the filing
    /// made it. ⇧⌘Z, once they've landed again, teaches it again. Nothing else forgets a lesson:
    /// a file later renamed or moved in Finder says nothing about where statements go.
    func registerLessonUndo(taught: LearnedAccount, previous: LearnedAccount?, batch: [LearnedAccount.Teaching]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerLessonRedo(taught: taught, previous: previous, batch: batch)
            Task { @MainActor in
                let slot = target.claimFileOperationSlot()
                let undone = await target.enqueueFileOperation(slot: slot) {
                    batch.allSatisfy { !FileManager.default.fileExists(atPath: $0.landed) && FileManager.default.fileExists(atPath: $0.source) }
                }
                guard undone else { return }
                var all = target.filingLearnedAccounts
                if let previous, let i = all.firstIndex(where: { $0.id == taught.id }) { all[i] = previous }
                else if previous == nil { all.removeAll { $0.id == taught.id } }
                target.filingLearnedAccounts = all
                Logger.shared.info("Filing: forgot what an undone filing taught (\(taught.institutionName) ••\(taught.ending))")
            }
        }
    }

    private func registerLessonRedo(taught: LearnedAccount, previous: LearnedAccount?, batch: [LearnedAccount.Teaching]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerLessonUndo(taught: taught, previous: previous, batch: batch)
            Task { @MainActor in
                let slot = target.claimFileOperationSlot()
                let redone = await target.enqueueFileOperation(slot: slot) {
                    batch.allSatisfy { FileManager.default.fileExists(atPath: $0.landed) }
                }
                guard redone else { return }
                var all = target.filingLearnedAccounts
                if let i = all.firstIndex(where: { $0.id == taught.id }) { all[i] = taught } else { all.append(taught) }
                target.filingLearnedAccounts = all
            }
        }
    }

    /// `relative` without the year and month levels at its end: the account, not its 2026.
    nonisolated static func accountFolder(of relative: String) -> String {
        var parts = relative.split(separator: "/").map(String.init)
        while let last = parts.last, parts.count > 1,
              FolderProfileEntry.looksLikeYear(last) || FilingPeriod.monthSlot(ofFolderNamed: last) != nil {
            parts.removeLast()
        }
        return parts.joined(separator: "/")
    }

    /// Why a lesson isn't in use, for its row: taught for another tree than the one the last scan
    /// walked, or outranked by a folder whose name carries the number. nil when it is used.
    public func learnedAccountNote(_ account: LearnedAccount) -> String? {
        if let root = filingLastProviderRoot, root != account.surveyRoot {
            return "not used: taught for “\((account.surveyRoot as NSString).lastPathComponent)”, not the folders scanned last"
        }
        let number = DocumentFacts.OwnNumber(digits: account.ending, masked: false)
        if let index = filingAccountIndex, let named = index.accounts.first(where: { a in
            a.institution == account.institution && a.root != account.folder
                && AccountIndex.namedByFolder(a, ending: account.ending) && a.identities.contains { index.ends(number, identity: $0) }
        }) {
            return "not used: “\((named.root as NSString).lastPathComponent)” carries ••\(account.ending)"
        }
        return nil
    }

    public func removeLearnedAccount(id: UUID) {
        filingLearnedAccounts.removeAll { $0.id == id }
    }

    /// Whether the folder an entry points at is still there; a missing one is listed, not used.
    public func learnedAccountFolderExists(_ account: LearnedAccount) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: account.absoluteFolder, isDirectory: &isDir) && isDir.boolValue
    }

    /// Counts filings into learned accounts' folders, for the "N filed" on their rows: one write
    /// for a whole filing, not one per file.
    func noteFiledIntoLearnedAccounts(folders: [String]) {
        var all = filingLearnedAccounts
        guard !all.isEmpty else { return }
        var changed = false
        for folder in folders {
            guard let i = all.firstIndex(where: { PathBoundary.contains(folder, under: $0.absoluteFolder) }) else { continue }
            all[i].filedCount += 1
            changed = true
        }
        if changed { filingLearnedAccounts = all }
    }
}

extension AccountIndex {

    /// The index with the accounts he taught for this tree. A learned number loses to a folder
    /// whose own name carries it at the same bank: what the tree says outranks a past correction.
    /// A learned folder no longer in the tree is not used.
    public func adding(learned: [LearnedAccount], root: String, tree: [FileNode],
                       isArchived: (String) -> Bool = { _ in false }) -> AccountIndex {
        var accounts = self.accounts
        var tokens = institutionTokens
        for l in learned where l.surveyRoot == root {
            guard AccountProposal.node(at: l.folder, in: tree) != nil else { continue }
            let number = DocumentFacts.OwnNumber(digits: l.ending, masked: false)
            // Against the tree's own accounts only: a second lesson for the same number is not
            // outranked by the first; both stay and the card asks. Only a folder whose own name
            // carries the number outranks a lesson; one learned from reading its statements gives
            // the number up to it.
            func carries(_ a: Account) -> Bool {
                a.institution == l.institution && a.root != l.folder
                    && a.identities.contains { ends(number, identity: $0) }
            }
            if self.accounts.contains(where: { carries($0) && Self.namedByFolder($0, ending: l.ending) }) { continue }
            let treeRoots = Set(self.accounts.map(\.root))
            for (i, a) in accounts.enumerated().reversed()
            where treeRoots.contains(a.root) && carries(a) && !Self.namedByFolder(a, ending: l.ending) {
                let left = a.identities.filter { !ends(number, identity: $0) }
                if left.isEmpty { accounts.remove(at: i); continue }
                var trimmed = Account(root: a.root, identities: left, institution: a.institution, archived: a.archived)
                trimmed.institutionName = a.institutionName
                accounts[i] = trimmed
            }
            if let i = accounts.firstIndex(where: { $0.root == l.folder }) {
                let a = accounts[i]
                guard !a.identities.contains(l.ending) else { continue }
                var merged = Account(root: a.root, identities: a.identities + [l.ending],
                                     institution: a.institution, archived: a.archived)
                merged.institutionName = a.institutionName
                accounts[i] = merged
                continue
            }
            let archived = l.folder.split(separator: "/").contains { Self.isArchiveName(String($0)) }
                || isArchived(l.folder)
            var a = Account(root: l.folder, identities: [l.ending], institution: l.institution, archived: archived)
            a.institutionName = l.institutionName
            accounts.append(a)
            if tokens[l.institution] == nil {
                tokens[l.institution] = Self.words(l.institution).filter {
                    $0.count >= 3 && !Self.stopWords.contains($0) && !genericWords.contains($0)
                }
            }
        }
        return AccountIndex(accounts: accounts, institutionTokens: tokens, genericWords: genericWords)
    }

    /// The account folder's own name carries `ending`.
    static func namedByFolder(_ a: Account, ending: String) -> Bool {
        accountDigits(inFolderNamed: (a.root as NSString).lastPathComponent).contains { $0.hasSuffix(ending) }
    }
}
