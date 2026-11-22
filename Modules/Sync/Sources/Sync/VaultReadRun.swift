import Foundation

/// One Read Documents pass over its planned files (VT7): how far it is, when an account's older
/// years need no reading, and what it found. ``VaultModel/readDocuments(with:again:scope:)``
/// holds one for the length of a read; it reads nothing itself, so its rules are tested alone.
struct VaultReadRun {
    /// What is being read: said with every step of progress.
    let scope: VaultReadScope
    /// The files planned to be looked at.
    let total: Int
    var tally = VaultReadTally()

    /// The numbers each account's newest year read so far gave, by account.
    private var lastNumbers: [String: Set<String>] = [:]
    /// How many of each account's years gave no number, newest first.
    private var emptyYears: [String: Int] = [:]
    /// Each unlabelled number an account's papers print, and the first file that printed it.
    private var bareSeen: [String: [String: String]] = [:]
    /// Accounts read far enough: their older years would only say the same again.
    private var settled = Set<String>()

    init(scope: VaultReadScope, total: Int, documents: Int) {
        self.scope = scope
        self.total = total
        tally.documents = documents
    }

    /// The progress once `done` of the planned files are looked at.
    func progress(done: Int) -> VaultModel.ReadingProgress {
        VaultModel.ReadingProgress(done: done, total: total, scope: scope)
    }

    /// Passed over without opening: an older year of an account already read far enough. A
    /// refresh opens every document it was asked to.
    func passesOver(_ step: VaultReadPlan.Step) -> Bool {
        guard !scope.isRefresh, let account = step.account else { return false }
        return settled.contains(account)
    }

    /// An account is read newest year first, and no further once two of its years agree on its
    /// numbers, or its three newest give none: papers of that kind carry no number the readers
    /// know. Three, not two: a phone bill that stopped labelling its number in 2025 still did in
    /// 2024. `numbers` are what `step`'s file gave the account.
    mutating func settle(_ step: VaultReadPlan.Step, numbers: Set<String>) {
        guard let account = step.account else { return }
        if numbers.isEmpty {
            if lastNumbers[account] == nil, emptyYears[account, default: 0] + 1 >= 3 { settled.insert(account) }
            emptyYears[account, default: 0] += 1
            return
        }
        if lastNumbers[account] == numbers { settled.insert(account) }
        lastNumbers[account] = numbers
    }

    /// Whether an account has given no labelled number yet: only then are its papers' unlabelled
    /// numbers weighed.
    func hasNoNumbers(_ account: String) -> Bool { lastNumbers[account] == nil }

    /// The one unlabelled number `path` and an earlier year of `account` both print, with that
    /// year's file: the account's number, and it is read far enough. Two or more (a customer
    /// service line taken for a number, say) leave it unread rather than guessed at, and this
    /// year's are remembered for the next.
    mutating func repeatedBareNumber(_ bare: Set<String>, for account: String, in path: String)
        -> (value: String, earlier: String)? {
        let repeated = bare.filter { bareSeen[account]?[$0] != nil }
        if repeated.count == 1, let value = repeated.first, let earlier = bareSeen[account]?[value] {
            settled.insert(account)
            return (value, earlier)
        }
        for value in bare where bareSeen[account]?[value] == nil { bareSeen[account, default: [:]][value] = path }
        return nil
    }

    /// The log line for a read stopped with `index` of the planned files looked at. Counts only:
    /// a file's name can hold the very number it carries.
    func stoppedLine(at index: Int) -> String {
        "Vault: read stopped at \(index) of \(total) document(s), \(tally.opened) opened; "
            + "the Vault closed or locked, and what was read is kept"
    }
}
