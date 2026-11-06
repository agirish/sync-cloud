import Foundation

/// What a folder gives one slot to: one month, or one dated document.
///
/// A folder paid twice a month (`Salary Statements/2026`) holds `01. Jan 15 2026.pdf` and
/// `02. Jan 31 2026.pdf` as two slots inside January; read by month, the second would collide with
/// the first. ``SlotGranularity/month`` is what every other folder gets: the day is never parsed
/// into a key.
public enum SlotGranularity: Sendable, Equatable {
    case month
    case day
}

/// How a folder numbers its slots.
public enum OrdinalScheme: String, Sendable, Equatable {
    /// The ordinal is the file's position among its siblings in date order. `HDFC Credit/2010` runs
    /// `01. Apr · 02. Jul · 03. Sep · …`: Jul is the second file, not the seventh month.
    case position
    /// The ordinal is the calendar month number. `PG&E/2021` runs `03. Mar … 11. Nov`, so March
    /// keeps slot 3 with slots 1 and 2 standing empty.
    case monthNumber
}

/// One rename the pass proposes, inside a folder's plan.
public struct RenameStep: Sendable, Equatable, Identifiable {
    /// What kind of change this is, carried as a value and never re-derived from `reason`: the
    /// reason is a user-facing sentence free to be reworded, and a count that parsed it would
    /// silently go to zero.
    public enum Kind: String, Sendable, Equatable {
        /// The name was already in the grammar and keeps its slot; only its spelling changes.
        /// `4. Apr 2021.pdf` → `04. Apr 2021.pdf`. Cannot collide, and is the bulk of the backlog.
        case tidied
        /// A raw name taking a slot it didn't have. `9829custbill07182023.pdf` →
        /// `07. Jul 2023.pdf`.
        case placed
        /// An already-correct name whose slot moved to make room for a file inserted before it.
        /// `02. Jul 2010.pdf` → `03. Jul 2010.pdf` when May arrives. Only under
        /// ``OrdinalScheme/position``, and never alone: see ``RenameStep/cohort``.
        case renumbered
    }

    /// Absolute path of the file as it stands now. Doubles as the identity.
    public let id: String
    public var currentPath: String { id }
    public let currentName: String
    public let proposedName: String
    public let kind: Kind
    /// Which all-or-nothing group this step belongs to; `0` means it stands alone.
    ///
    /// A padding fix is independent: `4. Apr` → `04. Apr` is right whatever its neighbours do. A
    /// renumber is not: inserting May into `01. Apr · 02. Jul · 03. Sep` shifts Jul and Sep up, and
    /// applying only some of those leaves two files on one slot or a gap. Steps sharing a non-zero
    /// cohort are applied together or not at all, by both the collision guard and the apply path.
    public let cohort: Int
    /// Why, for the row subtitle.
    public let reason: String

    public init(currentPath: String, currentName: String, proposedName: String,
                kind: Kind, cohort: Int = 0, reason: String) {
        self.id = currentPath
        self.currentName = currentName
        self.proposedName = proposedName
        self.kind = kind
        self.cohort = cohort
        self.reason = reason
    }
}

/// A file the pass deliberately declined to rename, and what stopped it. Reported rather than
/// dropped: a silent skip looks the same as a pass that didn't look.
public struct RenameSkip: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let reason: String

    public init(path: String, fileName: String, reason: String) {
        self.id = path
        self.fileName = fileName
        self.reason = reason
    }
}

/// One folder's whole rename plan: the unit of review and the unit of apply.
///
/// Not per file. Under ``OrdinalScheme/position`` a file inserted before the end shifts every file
/// after it, so a half-applied plan leaves the folder worse numbered than it started; the manager
/// applies a plan whole or not at all.
///
/// No step in a plan can collide with another, so they may be applied in any order:
/// ``RenamePlanner`` drops every contended target before the plan is built, and the apply path
/// re-checks each one against the disk and uniquifies rather than overwriting.
public struct RenamePlan: Sendable, Equatable, Identifiable {
    /// Absolute path of the folder: the identity of the finding.
    public let id: String
    public var folderPath: String { id }
    /// Provider-relative path, for the row's "where is it" label.
    public let relativePath: String
    public let scheme: OrdinalScheme
    public let steps: [RenameStep]
    public let skips: [RenameSkip]

    public init(folderPath: String, relativePath: String, scheme: OrdinalScheme,
                steps: [RenameStep], skips: [RenameSkip]) {
        self.id = folderPath
        self.relativePath = relativePath
        self.scheme = scheme
        self.steps = steps
        self.skips = skips
    }

    public var isEmpty: Bool { steps.isEmpty }
    /// Steps that only respell a name already in the grammar; no slot changes hands.
    public var tidied: Int { steps.filter { $0.kind == .tidied }.count }
    /// Steps giving a raw name a slot it didn't have.
    public var placed: Int { steps.filter { $0.kind == .placed }.count }
    /// Steps whose slot moved to make room for one of the above.
    public var renumbered: Int { steps.filter { $0.kind == .renumbered }.count }
}

/// One file as the planner sees it. A pure value with no disk handle, so a plan is unit-testable
/// against a list of names.
public struct FolderFile: Sendable, Equatable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Turns a folder's file list into the renames that would bring it to its own convention.
///
/// Pure and total: same names in, same plan out, no disk and no clock. What it needs about the
/// folder (that it numbers its files at all, which year it owns, calendar or fiscal year) comes
/// from the ``FolderProfileEntry`` the survey mined, with an inference fallback for a folder the
/// profile hasn't seen.
public enum RenamePlanner {

    /// Why a file the miner found no date in is not renamed. A stamp both conventions could have
    /// written is not "no date": the name plainly carries one, and the reader can settle in a
    /// second what the pass can't, so both readings are given, in the folder's own form.
    static func undatedReason(_ fileName: String) -> String {
        guard let ambiguous = FileNameDate.ambiguity(fileName) else {
            return "No month and year in the name to rename it by."
        }
        func said(_ date: FileNameDate.Mined) -> String {
            OrdinalMonthName.body(month: date.month, day: date.day ?? 1, year: date.year)
        }
        return "The date \(ambiguous.evidence) in the name could be \(said(ambiguous.monthFirst)) "
            + "(month first) or \(said(ambiguous.dayFirst)) (day first), so it isn’t renamed by it."
    }

    /// The plan for one folder, or an empty plan when there is nothing to propose.
    ///
    /// - Parameters:
    ///   - files: every file directly in the folder. Subfolders are not the pass's business.
    ///   - entry: the folder's profile entry, when the survey found one.
    ///   - incoming: a file being filed into this folder that isn't on disk here yet, so the
    ///     Organize queue can ask what it would be called once it lands against the same rules.
    public static func plan(
        folderPath: String,
        relativePath: String,
        files: [FolderFile],
        entry: FolderProfileEntry?,
        incoming: FolderFile? = nil
    ) -> RenamePlan {
        let all = files + (incoming.map { [$0] } ?? [])
        guard !isStagingArea(relativePath, entry: entry),
              let granularity = slotGranularity(files: files, entry: entry) else {
            return RenamePlan(folderPath: folderPath, relativePath: relativePath,
                              scheme: .position, steps: [], skips: [])
        }
        var steps: [RenameStep] = []
        var skips: [RenameSkip] = []

        // Ordinals are assigned per extension: `Apple Card/2022` holds a `.csv` and a `.pdf` for
        // every month, each pair sharing one ordinal. Numbered as one list, all would be
        // renumbered.
        let groups = Dictionary(grouping: all) { ($0.name as NSString).pathExtension.lowercased() }
        // The scheme is read per group too: folder-wide, every ordinal shows twice, no positional
        // reading explains it, and the inference would fall through to `.monthNumber`.
        var schemes: [(ext: String, count: Int, scheme: OrdinalScheme)] = []
        for ext in groups.keys.sorted() {
            let group = groups[ext]!
            let groupScheme = inferScheme(files: group, granularity: granularity)
            schemes.append((ext, group.count, groupScheme))
            // A cohort id unique per extension group: one folder-wide id would tie a `.csv`
            // renumber to an unrelated `.pdf` one, and a single stale step would abandon both.
            let result = planGroup(group, scheme: groupScheme, granularity: granularity,
                                   entry: entry, incoming: incoming,
                                   cohortSeed: schemes.count + 1)
            steps.append(contentsOf: result.steps)
            skips.append(contentsOf: result.skips)
        }
        // Reported as the folder's scheme: the largest group's, ties broken by extension name so it
        // is deterministic. Display only; every decision above used its own group's reading.
        let scheme = schemes.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.ext < $1.ext
        }.first?.scheme ?? .position
        let guarded = withoutCollisions(steps, among: all, skips: &skips)
        return RenamePlan(folderPath: folderPath, relativePath: relativePath, scheme: scheme,
                          steps: guarded, skips: skips)
    }

    // MARK: The collision guard

    /// Drops every step whose target is not free, folder-wide, and reports why.
    ///
    /// The trap this pass must not fall into: a raw original beside a copy somebody already renamed
    /// (`9829custbill07182023.pdf` next to `07. Jul 2023.pdf`, same bill, same folder). Deciding
    /// they are the same document needs a content fingerprint, so the pass never guesses: when two
    /// names want one slot it refuses both and says so.
    ///
    /// Two ways a target can be occupied, neither visible to the per-extension planner alone:
    ///
    /// - Another step wants it. `4. Apr 2021.pdf` and `04. Apr 2021.pdf` both canonicalise to
    ///   `04. Apr 2021.pdf`. Only one may proceed, so neither does.
    /// - A file that isn't moving already holds it: the same pair, where the padded copy is already
    ///   canonical and so has no step of its own.
    static func withoutCollisions(_ steps: [RenameStep], among all: [FolderFile],
                                  skips: inout [RenameSkip]) -> [RenameStep] {
        // Compared case-insensitively throughout: on the tree's volume `07. jul 2023.pdf` and
        // `07. Jul 2023.pdf` are one name, and treating them as two would propose a rename the
        // filesystem resolves by overwriting. The conservative direction only costs a skip.
        let moving = Set(steps.map { $0.currentName.lowercased() })
        // Names that stay put are still there when the pass finishes, so nothing may land on them.
        // A file being renamed away frees its name and is excluded.
        let staying = Set(all.map { $0.name.lowercased() }).subtracting(moving)

        var wanted: [String: Int] = [:]
        for s in steps { wanted[s.proposedName.lowercased(), default: 0] += 1 }

        var kept: [RenameStep] = []
        var doomedCohorts: Set<Int> = []
        for s in steps {
            if staying.contains(s.proposedName.lowercased()) {
                skips.append(RenameSkip(path: s.currentPath, fileName: s.currentName,
                                        reason: "“\(s.proposedName)” is already there — renaming "
                                            + "this would collide with it."))
            } else if wanted[s.proposedName.lowercased(), default: 0] > 1 {
                skips.append(RenameSkip(path: s.currentPath, fileName: s.currentName,
                                        reason: "Another file here wants the same name "
                                            + "(“\(s.proposedName)”); both were left alone."))
            } else {
                kept.append(s)
                continue
            }
            // The refused step belonged to a renumbering, so the rest of it must go too: the
            // survivors alone would leave two files on one slot, or a hole where a month was.
            if s.cohort != 0 { doomedCohorts.insert(s.cohort) }
        }
        guard !doomedCohorts.isEmpty else { return kept }
        for s in kept where doomedCohorts.contains(s.cohort) {
            skips.append(RenameSkip(path: s.currentPath, fileName: s.currentName,
                                    reason: "Part of a renumbering this folder cannot complete — "
                                        + "another file here already holds a name it needs."))
        }
        return kept.filter { !doomedCohorts.contains($0.cohort) }
    }

    /// Whether this folder is a staging area, where a file's own name is still doing work.
    ///
    /// An inbox is the one place a correct rename is wrong. The filing engine routes on the
    /// filename, and the house convention drops exactly those tokens: `ATTBill_1897_Feb2022.pdf`
    /// carries `attbill`, which sends it to `Home/Utilities/AT&T`, while `02. Feb 2022.pdf` carries
    /// only `feb`. Renaming there destroys the evidence the move depends on, and the destination
    /// names it again anyway.
    ///
    /// Asked through ``FolderProfile/isInboxPath(_:)`` too, not just the entry's role, because a
    /// tree grows new inboxes faster than the profile's flags; shared, not re-implemented, so the
    /// callers can't drift apart.
    static func isStagingArea(_ relativePath: String, entry: FolderProfileEntry?) -> Bool {
        if entry?.role == .inbox { return true }
        return FolderProfile.isInboxPath(relativePath)
    }

    // MARK: Does this folder number its files at all?

    /// Whether the pass may touch this folder, and what one slot means here. nil to leave it alone.
    ///
    /// The profile's `naming` is the authority, mined from the whole folder: `ordinal-month`,
    /// `ordinal-day`, or `descriptive`. A `descriptive` folder is never touched, however date-like
    /// its files look: `Passport.pdf` and `Lease Agreement.pdf` have no slot, and proposing one is
    /// how a rename pass gets switched off.
    ///
    /// The inference fallback is only for a folder the profile hasn't seen, such as one created
    /// since the survey, which the incoming-file path meets often. It needs three conforming files,
    /// so one stray `1. Something.pdf` can't recruit a folder, and answers `.day` only when they
    /// all carry days: one `01. Jan 15 2026.pdf` beside eleven bare months is a stray, and reading
    /// it as day-keyed would renumber the eleven.
    static func slotGranularity(files: [FolderFile], entry: FolderProfileEntry?) -> SlotGranularity? {
        if let naming = entry?.naming {
            switch naming {
            case "ordinal-month": return .month
            case "ordinal-day": return .day
            default: return nil
            }
        }
        let conforming = files.compactMap { OrdinalMonthName.parse($0.name) }
            .filter { $0.month != nil }
        guard conforming.count >= 3 else { return nil }
        return conforming.allSatisfy { $0.day != nil } ? .day : .month
    }

    /// Which scheme the folder's existing names vouch for.
    ///
    /// `.monthNumber` only when every dated file already sits in its own month's slot and at least
    /// two do; otherwise `.position`, which most folders use. Unanimity keeps a folder merely
    /// contiguous from January (where the two schemes agree) on the majority reading.
    ///
    /// A day-keyed folder is always `.position`. `.monthNumber` means "the ordinal is the month",
    /// which can't describe two files in one month, yet a folder with one document per month so far
    /// would look monthNumber-shaped and be renumbered on the next arrival.
    static func inferScheme(files: [FolderFile], granularity: SlotGranularity) -> OrdinalScheme {
        guard granularity == .month else { return .position }
        let dated = files.compactMap { f -> OrdinalMonthName.Parsed? in
            guard let p = OrdinalMonthName.parse(f.name), p.month != nil else { return nil }
            return p
        }
        guard dated.count >= 2 else { return .position }
        let everyFileInItsMonthSlot = dated.allSatisfy { $0.ordinal == $0.month }
        let positionWouldAlsoFit = dated.count == Set(dated.map(\.month)).count
            && dated.sorted { ($0.year ?? 0, $0.month ?? 0) < ($1.year ?? 0, $1.month ?? 0) }
                   .enumerated().allSatisfy { $0.element.ordinal == $0.offset + 1 }
        return (everyFileInItsMonthSlot && !positionWouldAlsoFit) ? .monthNumber : .position
    }

    // MARK: One extension's worth of files

    private struct GroupResult {
        var steps: [RenameStep] = []
        var skips: [RenameSkip] = []
    }

    private static func planGroup(
        _ files: [FolderFile], scheme: OrdinalScheme, granularity: SlotGranularity,
        entry: FolderProfileEntry?, incoming: FolderFile?, cohortSeed: Int
    ) -> GroupResult {
        var out = GroupResult()

        /// The slot a parsed name occupies. Under ``SlotGranularity/month`` the day is dropped even
        /// when the name spells one.
        func key(year: Int, month: Int, day: Int?) -> MonthKey {
            MonthKey(year: year, month: month, day: granularity == .day ? day : nil)
        }

        /// (file, parsed) for names already in the grammar; the rest are candidates for placement.
        var dated: [(file: FolderFile, parsed: OrdinalMonthName.Parsed, key: MonthKey)] = []
        var summaries: [(file: FolderFile, parsed: OrdinalMonthName.Parsed)] = []
        var unplaced: [FolderFile] = []

        for f in files {
            if let p = OrdinalMonthName.parse(f.name) {
                if let m = p.month, let y = p.year {
                    // A day-keyed folder's file that names no day has no slot here. It keeps its
                    // ordinal and name; treated as "the whole month" it would block every dated
                    // file that month holds.
                    if granularity == .day, p.day == nil {
                        summaries.append((f, p))
                    } else {
                        dated.append((f, p, key(year: y, month: m, day: p.day)))
                    }
                } else {
                    // Parsed, but no single month: the summary slot, or a fiscal-span body this
                    // grammar doesn't model. It keeps its ordinal; only its width is fixed.
                    summaries.append((f, p))
                }
            } else {
                unplaced.append(f)
            }
        }

        // 1. Width and body fixes for names whose slot doesn't move. Independent of each other and
        //    of everything else, so they carry no cohort, and they are the safe bulk of the
        //    backlog.
        //
        //    Emitted below only when no cascade runs: a cascade re-renders every dated file itself,
        //    and two steps for one file is not a plan.
        func paddingSteps() -> [RenameStep] {
            dated.filter { !$0.parsed.isCanonical }.map { d in
                RenameStep(currentPath: d.file.path, currentName: d.file.name,
                           proposedName: d.parsed.canonicalName, kind: .tidied,
                           reason: d.parsed.ordinalDigits == 1
                               ? "Padded to two digits — a one-digit ordinal sorts after “10.”"
                               : "Tidied to the folder’s “NN. Mon YYYY” form")
            }
        }
        for sum in summaries where !sum.parsed.isCanonical {
            out.steps.append(RenameStep(
                currentPath: sum.file.path, currentName: sum.file.name,
                proposedName: sum.parsed.canonicalName, kind: .tidied,
                reason: "Padded to two digits — a one-digit ordinal sorts after “10.”"))
        }

        // 2. Which raw files are placeable at all, decided before any ordinal is assigned, because
        //    under `.position` a slot is a rank over the whole group, not computable file by file.
        //
        //    Walked in date order, so a folder of raw bills with no conforming sibling numbers end
        //    to end rather than placing one bill and reporting the rest as collisions with it.
        var claimed: Set<MonthKey> = Set(dated.map(\.key))
        var claimedBy: [MonthKey: String] = [:]
        for d in dated { claimedBy[d.key] = d.file.name }
        var placements: [(file: FolderFile, key: MonthKey, evidence: String)] = []

        let minedUnplaced = unplaced
            .map { (file: $0, mined: FileNameDate.mine($0.name)) }
            .sorted { a, b in
                switch (a.mined, b.mined) {
                case let (x?, y?):
                    return (x.year, x.month, x.day ?? 0) < (y.year, y.month, y.day ?? 0)
                case (nil, _?): return false          // undatable names last; they take no slot
                case (_?, nil): return true
                case (nil, nil): return a.file.name < b.file.name
                }
            }
        for (f, minedDate) in minedUnplaced {
            guard let mined = minedDate else {
                // Reported only for the file the user is asking about. A folder full of
                // `Interest Certificate.pdf` is not a backlog, it is a folder.
                if incoming?.path == f.path {
                    out.skips.append(RenameSkip(path: f.path, fileName: f.name,
                                                reason: Self.undatedReason(f.name)))
                }
                continue
            }
            // A day-keyed folder needs the day. Placing `Payslip Jun 2026.pdf` among
            // `NN. Mon DD YYYY` names would mean inventing a date, so a document with no known day
            // gets no slot.
            if granularity == .day, mined.day == nil {
                if incoming?.path == f.path {
                    out.skips.append(RenameSkip(
                        path: f.path, fileName: f.name,
                        reason: "This folder names its files by the day "
                            + "(“01. Jan 15 2026”), and the name gives no day to use."))
                }
                continue
            }
            // Never rename a file into a year its folder doesn't own. A January 2024 bill under
            // `2023/` is a misfiling, and stamping `2023` on it would bury the evidence under a
            // name that looks right. Reported, not renamed.
            if let owned = entry?.yearKey, !yearFits(mined.year, month: mined.month, ownedBy: owned) {
                out.skips.append(RenameSkip(
                    path: f.path, fileName: f.name,
                    reason: "Names \(OrdinalMonthName.body(month: mined.month, year: mined.year)), "
                        + "but this folder holds \(owned) — it may be filed in the wrong year."))
                continue
            }
            let key = key(year: mined.year, month: mined.month, day: mined.day)
            // A date this group already holds is the duplicate trap: the raw original beside the
            // copy already renamed. Proving they are one document needs content, so this reports
            // the collision and never guesses. A cascade doesn't change this: renumbering makes
            // room for the convention, never for a second copy of a date already here.
            if claimed.contains(key) {
                out.skips.append(RenameSkip(
                    path: f.path, fileName: f.name,
                    reason: "“\(claimedBy[key] ?? "another file")” already holds "
                        + "\(key.spelled) here."))
                continue
            }
            claimed.insert(key)
            claimedBy[key] = f.name
            placements.append((f, key, mined.evidence))
        }

        /// The name a placed file takes at `slot`, day-keyed or not by the key it holds rather than
        /// by the calling branch, so the two schemes can't disagree.
        func placedName(_ p: (file: FolderFile, key: MonthKey, evidence: String),
                        slot: Int) -> String {
            let ext = (p.file.name as NSString).pathExtension
            guard let day = p.key.day else {
                return OrdinalMonthName.render(ordinal: slot, month: p.key.month,
                                               year: p.key.year, ext: ext)
            }
            return OrdinalMonthName.render(ordinal: slot, month: p.key.month, day: day,
                                           year: p.key.year, ext: ext)
        }

        // 3. Ordinals.
        switch scheme {
        case .monthNumber:
            // The slot is the month, so nothing shifts and there is nothing to cascade. A taken
            // slot means a summary or a stray sits on a month's number (two files claiming one
            // month were refused above). Mutable: a folder with no year of its own can take January
            // of two years in one pass, and both would read slot 01 off an immutable set.
            var taken = Set(dated.map(\.parsed.ordinal)).union(summaries.map(\.parsed.ordinal))
            out.steps.append(contentsOf: paddingSteps())
            for p in placements.sorted(by: { $0.key < $1.key }) {
                guard !taken.contains(p.key.month) else {
                    out.skips.append(RenameSkip(
                        path: p.file.path, fileName: p.file.name,
                        reason: "Slot \(String(format: "%02d", p.key.month)) is already in use here."))
                    continue
                }
                taken.insert(p.key.month)
                out.steps.append(RenameStep(
                    currentPath: p.file.path, currentName: p.file.name,
                    proposedName: placedName(p, slot: p.key.month),
                    kind: .placed,
                    reason: "Renamed to the folder’s convention from \(p.evidence)."))
            }

        case .position:
            // The rank of every month the group will hold once the placements land.
            let ordinals = positionalOrdinals(for: claimed)
            // A cascade is needed only when an existing file's slot moves. Appending after
            // everything already there (the usual case, and nearly always the incoming-file path)
            // shifts nothing and takes the next free number.
            //
            // Gated on there being a placement. Many folders legitimately aren't a perfect 1…N
            // (`10. Dec 2021.pdf` beside `1. Mar` and `2. Apr` was numbered by hand), and with
            // nothing arriving there is no room to make, so they are not renumbered behind the
            // user's back.
            //
            // Rows this grammar parses but can't rank, such as a fiscal-span body
            // (`1. Apr 2007 to Aug 2007.pdf`) naming two months, block a renumbering:
            // `positionalOrdinals` ranks only the months it sees, so a shifted file could land on
            // such a row's slot, and `withoutCollisions` wouldn't catch it because the names
            // differ. Slot 0 is exempt: the summary slot sits outside the ranking by design.
            let unrankable = summaries.filter { $0.parsed.ordinal != 0 }
            let shifts = !placements.isEmpty && unrankable.isEmpty && dated.contains {
                ordinals[$0.key] != $0.parsed.ordinal
            }
            // Say so rather than falling back to the append path, which would put the file at the
            // end of a folder whose numbering means something else.
            if !unrankable.isEmpty, !placements.isEmpty,
               dated.contains(where: { ordinals[$0.key] != $0.parsed.ordinal }) {
                // The widenings still stand: refusing the renumbering is about slots, and padding
                // moves none.
                out.steps.append(contentsOf: paddingSteps())
                for p in placements {
                    out.skips.append(RenameSkip(
                        path: p.file.path, fileName: p.file.name,
                        reason: "Placing \(p.key.spelled) "
                            + "here needs a renumbering, and “\(unrankable[0].file.name)” holds a slot "
                            + "this pass cannot rank."))
                }
                break
            }
            if !shifts {
                out.steps.append(contentsOf: paddingSteps())
                var taken = Set(dated.map(\.parsed.ordinal)).union(summaries.map(\.parsed.ordinal))
                for p in placements.sorted(by: { $0.key < $1.key }) {
                    // The rank, unless the folder's own numbering has drifted past it; then the
                    // next free slot rather than a number in use. Reached when `dated` isn't a
                    // clean 1…N but nothing needs to move.
                    var slot = ordinals[p.key] ?? p.key.month
                    while taken.contains(slot) { slot += 1 }
                    taken.insert(slot)
                    out.steps.append(RenameStep(
                        currentPath: p.file.path, currentName: p.file.name,
                        proposedName: placedName(p, slot: slot),
                        kind: .placed,
                        reason: "Renamed to the folder’s convention from \(p.evidence)."))
                }
                break
            }
            // A real renumbering. Every file whose slot moves, and every placement, share one
            // cohort: half a renumber is worse than none.
            let cohort = cohortSeed
            let moved = dated.filter {
                ordinals[$0.key] != $0.parsed.ordinal
            }.count
            let arriving = placements
                .map { OrdinalMonthName.body(month: $0.key.month, year: $0.key.year) }
                .joined(separator: ", ")
            for d in dated {
                let target = ordinals[d.key] ?? d.parsed.ordinal
                let name = d.parsed.canonicalName(ordinal: target)
                guard name != d.file.name else { continue }
                // A file whose slot doesn't move is only being widened, which is right either way,
                // so it keeps cohort 0 and survives a cascade that has to stand down.
                out.steps.append(RenameStep(
                    currentPath: d.file.path, currentName: d.file.name, proposedName: name,
                    kind: target == d.parsed.ordinal ? .tidied : .renumbered,
                    cohort: target == d.parsed.ordinal ? 0 : cohort,
                    reason: target == d.parsed.ordinal
                        ? "Padded to two digits — a one-digit ordinal sorts after “10.”"
                        : "Moved to slot \(String(format: "%02d", target)) to make room for "
                            + "\(arriving)."))
            }
            for p in placements {
                out.steps.append(RenameStep(
                    currentPath: p.file.path, currentName: p.file.name,
                    proposedName: placedName(p, slot: ordinals[p.key] ?? p.key.month),
                    kind: .placed, cohort: cohort,
                    reason: "Renamed to the folder’s convention from \(p.evidence)"
                        + " — \(moved) later file\(moved == 1 ? "" : "s") renumbered to make room."))
            }
        }
        return out
    }

    /// One date a group holds: the unit of a slot, not one file. `day` is nil under
    /// ``SlotGranularity/month``, where it is never read or written.
    struct MonthKey: Hashable, Comparable {
        let year: Int
        let month: Int
        let day: Int?

        init(year: Int, month: Int, day: Int? = nil) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// Ordered by date. A key with no day sorts before any dated key in the same month; that
        /// can't arise inside one group, whose granularity is fixed, but it makes the ordering
        /// total.
        static func < (a: MonthKey, b: MonthKey) -> Bool {
            (a.year, a.month, a.day ?? 0) < (b.year, b.month, b.day ?? 0)
        }

        /// `Apr 2025`, or `Apr 15 2025`: how this slot is named in a sentence to the user.
        var spelled: String {
            day.map { OrdinalMonthName.body(month: month, day: $0, year: year) }
                ?? OrdinalMonthName.body(month: month, year: year)
        }
    }

    /// The ordinal each month takes under ``OrdinalScheme/position``: its rank in date order.
    ///
    /// Ranked over distinct months, not files. `Savings NRI/2014` holds `1. Jun 2014 NRE.pdf` and
    /// `1. Jun 2014 NRO.pdf`, two statements correctly sharing slot 1, and the next file is
    /// `2. Jul 2014.pdf`. Counting files would renumber it `1, 2, 3, …` and shift every later
    /// month.
    static func positionalOrdinals(for months: Set<MonthKey>) -> [MonthKey: Int] {
        var out: [MonthKey: Int] = [:]
        for (i, key) in months.sorted().enumerated() { out[key] = i + 1 }
        return out
    }

    /// Whether a mined year belongs to a folder whose year key is `owned`. `2023` owns only 2023. A
    /// fiscal key (`2014-2015`, `2009 - 2010`) owns April of the first year through March of the
    /// second, the Indian tax year the profile records on the `fiscalYear` axis. Erring permissive
    /// would let a January 2015 statement be renamed into a `2014` folder.
    static func yearFits(_ year: Int, month: Int, ownedBy owned: String) -> Bool {
        let parts = owned.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
            if year == a { return month >= 4 }
            if year == b { return month <= 3 }
            return false
        }
        return Int(owned) == year
    }
}
