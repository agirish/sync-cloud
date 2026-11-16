import Foundation

/// The rename pass for the folders ``StatementOrdinals`` governs: every statement numbered by its
/// position by date, `1.` … `11.` below twelve and `01.` … `12.` from twelve on.
///
/// Unlike the other folders' plans this one is always the whole folder: a statement arriving in
/// the middle renumbers every one after it, and the twelfth respells all eleven before it. So every
/// step shares one cohort, applied together or not at all, and a folder that breaks the rule with
/// nothing arriving (two `10.`s, a `July` the rename missed) is proposed whole too.
extension RenamePlanner {

    static func planStatements(folderPath: String, relativePath: String, files: [FolderFile],
                               entry: FolderProfileEntry?, incoming: FolderFile?) -> RenamePlan {
        let none = RenamePlan(folderPath: folderPath, relativePath: relativePath, scheme: .position,
                              steps: [], skips: [])
        let all = files + (incoming.map { [$0] } ?? [])
        // The arriving file is told apart by flag, not path: its path is only the folder and its
        // own name, which a file already here can share.
        struct Item { let file: FolderFile; let arriving: Bool
            var id: String { arriving ? "\u{1}" + file.path : file.path } }
        let items = files.map { Item(file: $0, arriving: false) } + (incoming.map { [Item(file: $0, arriving: true)] } ?? [])
        var statements: [Item] = []
        var raw: [Item] = []
        for item in items {
            guard let p = OrdinalMonthName.parse(item.file.name) else { raw.append(item); continue }
            if p.isSummarySlot { continue }
            // A numbered file that isn't a statement name: this folder's numbers mean something
            // else (`01. Equifax - Aug 2019.pdf`), so none of them is the rule's to move.
            guard StatementOrdinals.date(ofBody: p.body) != nil else { return none }
            statements.append(item)
        }
        let here = statements.filter { !$0.arriving }
        // A folder that numbers nothing yet is a statement folder only on the profile's word, or
        // because what arrives is a statement name (an account's own, from its newest statements).
        let profileNumbers = entry?.naming == "ordinal-month" || entry?.naming == "ordinal-day"
        guard !here.isEmpty || profileNumbers || statements.contains(where: \.arriving) else { return none }

        var skips: [RenameSkip] = []
        let dated = Dictionary(statements.compactMap { item -> (String, StatementOrdinals.Dated)? in
            guard let p = OrdinalMonthName.parse(item.file.name), let d = StatementOrdinals.date(ofBody: p.body) else { return nil }
            return (item.id, d)
        }, uniquingKeysWith: { a, _ in a })
        // A folder whose statements all carry a day (`2. Feb 28 2019.pdf`) gives a file a slot only
        // with its day.
        let byDay = entry?.naming == "ordinal-day"
            || (!here.isEmpty && here.allSatisfy { dated[$0.id]?.day != nil })
        func slot(_ d: StatementOrdinals.Dated) -> MonthKey {
            MonthKey(year: d.year, month: d.month, day: byDay ? d.day : nil)
        }
        // Which statement of each type holds each date. By type, because a CSV export is the twin
        // of the PDF of its month, never its duplicate.
        var claimedBy: [MonthKey: [String: String]] = [:]
        for item in here {
            if let d = dated[item.id] {
                claimedBy[slot(d), default: [:]][(item.file.name as NSString).pathExtension.lowercased()] = item.file.name
            }
        }
        // A year folder owns its year: `Statements/2020` takes no January 2021 bill.
        let leaf = (relativePath as NSString).lastPathComponent
        let owned = entry?.yearKey ?? (FolderProfileEntry.looksLikeYear(leaf) ? leaf : nil)

        // Only the arriving file is given a number, never a raw name already here. A date in a
        // name doesn't make a statement: `Renewal Notice - Jun 2024.pdf`, `Online Access Sign-up -
        // Jan 2018.pdf` and the `Apple Card Transactions - May 2023.csv` exports sit in his
        // statement folders unnumbered, and counting one would renumber the folder around it. His
        // raw bank names (`eStmt_2023-01-15.pdf`) wait for him to read and rename them. A file
        // being filed is different: its card is reviewed, and the account it matched read it as a
        // statement.
        var placed: [String: (name: String, evidence: String)] = [:]
        if let item = raw.first(where: \.arriving) {
            let f = item.file
            // Each refusal says why: this is the file the user is asking about.
            func refuse(_ reason: String) { skips.append(RenameSkip(path: f.path, fileName: f.name, reason: reason)) }
            if let date = FileNameDate.mine(f.name) {
                let key = MonthKey(year: date.year, month: date.month, day: byDay ? date.day : nil)
                if byDay, date.day == nil {
                    refuse("This folder names its files by the day (“1. Jan 15 2026”), and the name gives no day to use.")
                } else if let owned, !yearFits(date.year, month: date.month, ownedBy: owned) {
                    refuse("Names \(OrdinalMonthName.body(month: date.month, year: date.year)), "
                           + "but this folder holds \(owned) — it may be filed in the wrong year.")
                } else if let holder = claimedBy[key]?[(f.name as NSString).pathExtension.lowercased()] {
                    // The duplicate trap: the raw original of a statement already here.
                    refuse("“\(holder)” already holds \(key.spelled) here.")
                } else {
                    let ext = (f.name as NSString).pathExtension
                    let name = key.day.map { OrdinalMonthName.render(ordinal: 1, month: key.month, day: $0, year: key.year, ext: ext, padded: false) }
                        ?? OrdinalMonthName.render(ordinal: 1, month: key.month, year: key.year, ext: ext, padded: false)
                    placed[item.id] = (name, date.evidence)
                }
            } else {
                refuse(undatedReason(f.name))
            }
        }

        var entries: [StatementOrdinals.Entry] = statements.map {
            .init(id: $0.id, name: $0.file.name, arriving: $0.arriving)
        }
        for item in raw { if let p = placed[item.id] { entries.append(.init(id: item.id, name: p.name, arriving: true)) } }
        guard let numbering = StatementOrdinals.number(entries) else { return none }

        var steps: [RenameStep] = []
        for item in statements + raw {
            let f = item.file
            guard let target = numbering.names[item.id], target != f.name else { continue }
            let to = OrdinalMonthName.parse(target)?.ordinal ?? 0
            let reason: String
            let kind: RenameStep.Kind
            if let p = placed[item.id] {
                kind = .placed
                reason = "Named from \(p.evidence), statement \(to) of \(numbering.count) here by date."
            } else if item.arriving {
                kind = .placed
                reason = "Statement \(to) of \(numbering.count) here by date."
            } else if let from = OrdinalMonthName.parse(f.name), from.ordinal != to {
                kind = .renumbered
                reason = "Statement \(to) of \(numbering.count) here by date, not \(from.ordinal)."
            } else {
                kind = .tidied
                let widthOnly = OrdinalMonthName.parse(f.name).map {
                    $0.canonicalName(ordinal: to, padded: $0.ordinalDigits >= 2) != target
                } ?? false
                reason = !widthOnly ? "Respelled as the folder writes its statements."
                    : numbering.count >= 12 ? "Two digits: this folder holds \(numbering.count) statements."
                    : "One digit: this folder holds \(numbering.count) statements, fewer than 12."
            }
            steps.append(RenameStep(currentPath: f.path, currentName: f.name, proposedName: target,
                                    kind: kind, cohort: 1, reason: reason))
        }
        let guarded = withoutCollisions(sequenced(steps), among: all, skips: &skips)
        return RenamePlan(folderPath: folderPath, relativePath: relativePath, scheme: .position,
                          steps: guarded, skips: skips)
    }

    /// `steps` in an order that never lands a file on a name another step has yet to vacate.
    ///
    /// Two statements dated alike share a body, so a renumbering can chain through names:
    /// `1. Jul 2016.pdf` → `2. Jul 2016.pdf` beside `2. Jul 2016.pdf` → `3. Jul 2016.pdf`. Run first
    /// to last, the first would find its target taken and land as `2. Jul 2016 2.pdf`. The rule's
    /// ordering keeps the relative order of same-named statements, so the chain never closes into a
    /// cycle; were one to appear, the rest keep their order and the apply path's never-overwrite
    /// guard still holds.
    public static func sequenced(_ steps: [RenameStep]) -> [RenameStep] {
        var pending = steps
        var out: [RenameStep] = []
        while !pending.isEmpty {
            let ready = pending.firstIndex { s in
                let target = s.proposedName.lowercased()
                return !pending.contains { $0.id != s.id && $0.currentName.lowercased() == target }
            }
            guard let i = ready else { out.append(contentsOf: pending); break }
            out.append(pending.remove(at: i))
        }
        return out
    }
}
