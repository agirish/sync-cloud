import Foundation

/// What a folder gives one slot to — **one month, or one dated document.**
///
/// The distinction is the whole of the `ordinal-day` support. `Work/HPE/Compensation/Salary
/// Statements/2026` is paid twice a month, so `01. Jan 15 2026.pdf` and `02. Jan 31 2026.pdf` are
/// two slots inside January; a planner whose slot is the month sees them as one file's worth of
/// January and a second file colliding with it. Twenty-four folders in the surveyed tree are keyed
/// this way — every `Salary Statements` year, MapR's `Payslips`, and Kaiser's claims and
/// explanations of benefits — and until this existed the rename pass declined all of them.
///
/// ``SlotGranularity/month`` is what every other folder gets, and it is exactly the old behaviour:
/// the day is never parsed into a key, so nothing about the 327 `ordinal-month` folders changes.
public enum SlotGranularity: Sendable, Equatable {
    case month
    case day
}

/// How a folder numbers its slots.
public enum OrdinalScheme: String, Sendable, Equatable {
    /// The ordinal is the file's **position** among its siblings in date order. `HDFC Credit/2010`
    /// runs `01. Apr · 02. Jul · 03. Sep · 04. Oct · 05. Nov · 06. Dec` — Jul is the second file, not
    /// the seventh month.
    case position
    /// The ordinal is the **calendar month number**. `PG&E/2021` runs `03. Mar … 11. Nov`, so March
    /// keeps slot 3 with slots 1 and 2 standing empty.
    case monthNumber
}

/// One rename the pass proposes, inside a folder's plan.
public struct RenameStep: Sendable, Equatable, Identifiable {
    /// What kind of change this is — **carried as a value, never re-derived from `reason`.** The
    /// reason is a sentence shown to the user and is free to be reworded; a count that parsed it
    /// would silently go to zero the day somebody did.
    public enum Kind: String, Sendable, Equatable {
        /// The name was already in the grammar and keeps its slot; only its spelling changes.
        /// `4. Apr 2021.pdf` → `04. Apr 2021.pdf`. Cannot collide, and is the bulk of the backlog.
        case tidied
        /// A raw name taking a slot it did not have. `9829custbill07182023.pdf` → `07. Jul 2023.pdf`.
        case placed
        /// An already-correct name whose **slot moved** to make room for a file inserted before it.
        /// `02. Jul 2010.pdf` → `03. Jul 2010.pdf` when May arrives. Only ever produced under
        /// ``OrdinalScheme/position``, and never alone — see ``RenameStep/cohort``.
        case renumbered
    }

    /// Absolute path of the file as it stands **now**. Doubles as the identity.
    public let id: String
    public var currentPath: String { id }
    public let currentName: String
    public let proposedName: String
    public let kind: Kind
    /// Which **all-or-nothing group** this step belongs to. `0` means the step stands alone.
    ///
    /// A padding fix is independent: `4. Apr` → `04. Apr` is right whether or not its neighbours
    /// move. A renumber is not. Inserting May into `01. Apr · 02. Jul · 03. Sep` shifts Jul and Sep
    /// up by one, and applying *some* of those leaves the folder worse numbered than it started —
    /// two files at slot 3, or a gap where a month used to be. Steps sharing a non-zero cohort are
    /// therefore applied together or not at all, by both the collision guard and the apply path.
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
/// dropped: a silent skip is indistinguishable from a pass that did not look.
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

/// One folder's whole rename plan — **the unit of review and the unit of apply.**
///
/// Not per file. Under ``OrdinalScheme/position`` a file inserted before the end shifts every file
/// after it, so a half-applied plan leaves the folder worse numbered than it started. The steps are
/// and the manager applies a plan whole or not at all.
///
/// No step in a plan can collide with another, so they may be applied in any order: ``RenamePlanner``
/// drops every contended target before the plan is built, and the apply path re-checks each one
/// against the disk and uniquifies rather than overwriting.
public struct RenamePlan: Sendable, Equatable, Identifiable {
    /// Absolute path of the folder — the identity of the finding.
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
    /// Steps that only respell a name already in the grammar — no slot changes hands.
    public var tidied: Int { steps.filter { $0.kind == .tidied }.count }
    /// Steps giving a raw name a slot it did not have.
    public var placed: Int { steps.filter { $0.kind == .placed }.count }
    /// Steps whose slot moved to make room for one of the above.
    public var renumbered: Int { steps.filter { $0.kind == .renumbered }.count }
}

/// One file as the planner sees it. Pure value — no disk handle, so a plan is unit-testable against
/// a list of names.
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
/// Pure and total: same names in, same plan out, no disk and no clock. Everything it needs about the
/// folder — that it numbers its files at all, which year it owns, whether its year is a calendar or
/// a fiscal one — comes from the ``FolderProfileEntry`` the survey mined, with an inference fallback
/// for a folder the profile has not seen.
public enum RenamePlanner {

    /// The plan for one folder, or an empty plan when there is nothing to propose.
    ///
    /// - Parameters:
    ///   - files: every file directly in the folder. Subfolders are not the pass's business.
    ///   - entry: the folder's profile entry, when the survey found one.
    ///   - incoming: a file being filed **into** this folder that is not on disk here yet. Lets the
    ///     Organize queue ask "and what would it be called once it lands?" against the same rules,
    ///     rather than a second implementation that could answer differently.
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

        // Ordinals are assigned PER EXTENSION. `Apple Card/2022` holds a `.csv` and a `.pdf` for
        // every month, each pair sharing one ordinal — twelve "duplicate" ordinals that are entirely
        // correct. A planner that numbered the folder as one list would renumber all twenty-four.
        let groups = Dictionary(grouping: all) { ($0.name as NSString).pathExtension.lowercased() }
        // The SCHEME is read per group too, for the same reason the slots are. Folder-wide, a folder
        // of `.csv`/`.pdf` pairs shows every ordinal twice, which no positional reading can explain,
        // and the inference falls through to `.monthNumber` for a folder that is not numbered that
        // way at all.
        var schemes: [(ext: String, count: Int, scheme: OrdinalScheme)] = []
        for ext in groups.keys.sorted() {
            let group = groups[ext]!
            let groupScheme = inferScheme(files: group, granularity: granularity)
            schemes.append((ext, group.count, groupScheme))
            // A cohort id unique per extension group: two extensions can each need a cascade, and
            // one folder-wide id would tie a `.csv` renumber to a `.pdf` one that has nothing to do
            // with it — a single stale step would then abandon both.
            let result = planGroup(group, scheme: groupScheme, granularity: granularity,
                                   entry: entry, incoming: incoming,
                                   cohortSeed: schemes.count + 1)
            steps.append(contentsOf: result.steps)
            skips.append(contentsOf: result.skips)
        }
        // Reported as the folder's scheme: the one the largest group uses. Display only — every
        // decision above was made with its own group's reading.
        // Largest group wins; ties break on the extension name so the answer is deterministic
        // rather than dictionary-ordered.
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
    /// **This is the trap the pass exists to not fall into.** 682 files in the tree carry a
    /// duplicate marker, and the shape that matters here is the raw original sitting beside the copy
    /// somebody already renamed: `9829custbill07182023.pdf` next to `07. Jul 2023.pdf`, same bill,
    /// same folder. Deciding they are the same document needs a content fingerprint (ROADMAP 18,
    /// unbuilt), so this pass must never *guess* — it detects that two names want one slot and
    /// refuses both, saying so.
    ///
    /// Two ways a target can be occupied, and the per-extension planner can see neither on its own:
    ///
    /// - **Another step wants it.** `4. Apr 2021.pdf` and `04. Apr 2021.pdf` in one folder both
    ///   canonicalise to `04. Apr 2021.pdf`. Only one may proceed, so neither does.
    /// - **A file that is not moving already holds it.** The same pair, where the padded copy is
    ///   already canonical and so has no step of its own to collide with.
    static func withoutCollisions(_ steps: [RenameStep], among all: [FolderFile],
                                  skips: inout [RenameSkip]) -> [RenameStep] {
        // Compared case-INSENSITIVELY throughout. The tree's volume is, so `07. jul 2023.pdf` and
        // `07. Jul 2023.pdf` are one name to it; treating them as two would have the pass propose a
        // rename the filesystem then resolves by overwriting. The conservative direction here only
        // ever costs a skip.
        let moving = Set(steps.map { $0.currentName.lowercased() })
        // Names that stay put: they are still there when the pass finishes, so nothing may land on
        // them. A file being renamed away frees its name and is excluded.
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
            // The step just refused belonged to a renumbering, so the rest of that renumbering must
            // go too. Applying the survivors would leave two files on one slot, or a hole where a
            // month used to be — a folder worse numbered than the one this pass was asked to fix.
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
    /// **An inbox is the one place a correct rename is the wrong thing to do.** The filing engine
    /// routes on the filename, and the house convention throws away exactly the tokens it routes by:
    /// `ATTBill_1897_Feb2022.pdf` carries `attbill`, which is what sends it to `Home/Utilities/AT&T`,
    /// and `02. Feb 2022.pdf` carries `feb`, which sends it nowhere. Measured through
    /// `FilingEngine.salientTokens` — `{attbill, feb2022}` becomes `{feb}`, and
    /// `{9829custbill07182023}` becomes `{jul}`.
    ///
    /// So renaming inside an inbox is not merely premature cosmetics on a file that is about to
    /// move; it destroys the evidence the move depends on, and the destination will decide the name
    /// again anyway. The two features would be working against each other.
    ///
    /// No folder in the surveyed tree is both an inbox and `ordinal-month`, so this changes nothing
    /// there. It is armor for the case ``FolderProfile/isInboxPath(_:)`` was written for: a tree
    /// grows new inboxes, and the profile's own flags lag behind them. Asked through that shared
    /// rule rather than re-implemented, so a fourth place cannot start disagreeing with the three.
    static func isStagingArea(_ relativePath: String, entry: FolderProfileEntry?) -> Bool {
        if entry?.role == .inbox { return true }
        return FolderProfile.isInboxPath(relativePath)
    }

    // MARK: Does this folder number its files at all?

    /// Whether the pass may touch this folder, and what one slot means here. nil to leave it alone.
    ///
    /// The profile's `naming` is the authority — it was mined from the whole folder, and it says
    /// `ordinal-month` for 327 folders, `ordinal-day` for 24 and `descriptive` for 2,158. **A
    /// `descriptive` folder is never touched**, however date-like its files look: `Passport.pdf` and
    /// `Lease Agreement.pdf` have no slot to occupy, and proposing one for them is how a rename pass
    /// gets switched off.
    ///
    /// **`ordinal-day` was written by the survey and read by nothing.** The string appeared nowhere
    /// in the app, so this returned false for all 24 of those folders and the Renames lens was blind
    /// to the entire `Salary Statements` tree — including the one-digit ordinals it fixes everywhere
    /// else. Adding the case is most of what made day-keyed filing work.
    ///
    /// The inference fallback exists only for a folder the profile has not seen — a folder created
    /// since the survey, which the incoming-file path meets often. It demands three conforming files
    /// rather than one so a single stray `1. Something.pdf` cannot recruit a whole folder, and it
    /// answers `.day` only when the conforming files **agree unanimously** that they carry days:
    /// one dated `01. Jan 15 2026.pdf` beside eleven bare months is a folder with a stray in it, not
    /// a day-keyed folder, and reading it as one would renumber the eleven.
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
    /// `.monthNumber` only when **every** dated file already sits in its own month's slot and at
    /// least two do — otherwise `.position`, which is what 118 of the tree's 132 discriminating
    /// folders use against `.monthNumber`'s 14. Requiring unanimity keeps a folder that is merely
    /// contiguous-from-January (where the two schemes agree and cannot be told apart) on the
    /// majority reading.
    ///
    /// **A day-keyed folder is always `.position`.** `.monthNumber` means "the ordinal *is* the
    /// month", which cannot describe a folder holding two files in one month — and the inference
    /// below would answer it anyway for a folder whose only documents happen to be one per month so
    /// far. `Salary Statements/2019` starts in October and runs `01. Oct 15 · 02. Oct 31 · …`; a
    /// January-only stretch would look monthNumber-shaped and renumber the rest of the year on the
    /// next arrival.
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
        /// when the name spells one, which is what keeps a month-keyed folder's behaviour identical.
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
                    // ordinal and its name; treating it as "the whole month" would let it block
                    // every dated file that month legitimately holds.
                    if granularity == .day, p.day == nil {
                        summaries.append((f, p))
                    } else {
                        dated.append((f, p, key(year: y, month: m, day: p.day)))
                    }
                } else {
                    // Parsed, but carries no single month — the summary slot, or a fiscal-span body
                    // this grammar does not model. It holds its ordinal; only its width is fixed.
                    summaries.append((f, p))
                }
            } else {
                unplaced.append(f)
            }
        }

        // 1. Width and body fixes for names whose SLOT does not move. Independent of each other
        //    and of everything else, so they carry no cohort — and they are the safe bulk of the
        //    backlog, 567 one-digit ordinals tree-wide.
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

        // 2. Which raw files are placeable at all — decided BEFORE any ordinal is assigned, because
        //    under `.position` a slot is a rank over the whole group and a rank cannot be computed
        //    one file at a time.
        //
        //    Walked in date order so that a folder the survey found "not renamed at all"
        //    (`PG&E/2022`: eleven raw bills, no conforming sibling) numbers end to end rather than
        //    placing one bill and reporting ten collisions with it.
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
                // Only worth reporting for the file the user is actually asking about. A folder full
                // of `Interest Certificate.pdf` is not a backlog, it is a folder.
                if incoming?.path == f.path {
                    out.skips.append(RenameSkip(path: f.path, fileName: f.name,
                                                reason: "No month and year in the name to rename it by."))
                }
                continue
            }
            // A day-keyed folder needs the day. Placing `Payslip Jun 2026.pdf` among files named
            // `NN. Mon DD YYYY` would have to invent a date, and the honest slot for a document
            // whose day is unknown is no slot at all.
            if granularity == .day, mined.day == nil {
                if incoming?.path == f.path {
                    out.skips.append(RenameSkip(
                        path: f.path, fileName: f.name,
                        reason: "This folder names its files by the day "
                            + "(“01. Jan 15 2026”), and the name gives no day to use."))
                }
                continue
            }
            // **Never rename a file into a year its folder does not own.** A January 2024 bill filed
            // under `2023/` is a MISFILING, and stamping `2023` onto it would bury the evidence
            // under a name that looks right. Reported, not renamed.
            if let owned = entry?.yearKey, !yearFits(mined.year, month: mined.month, ownedBy: owned) {
                out.skips.append(RenameSkip(
                    path: f.path, fileName: f.name,
                    reason: "Names \(OrdinalMonthName.body(month: mined.month, year: mined.year)), "
                        + "but this folder holds \(owned) — it may be filed in the wrong year."))
                continue
            }
            let key = key(year: mined.year, month: mined.month, day: mined.day)
            // A date this group already holds is the duplicate trap: the raw original beside the
            // copy that was already renamed. Proving they are the same document is item 18's job,
            // so this reports the collision and never guesses.
            //
            // **A cascade does not change this.** Renumbering makes room where the CONVENTION needs
            // room; it must never make room for a second copy of a date that is already here.
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

        /// The name a placed file takes at `slot` — day-keyed or not, decided by the key it holds
        /// rather than by the branch this is called from, so the two schemes cannot disagree.
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
            // The slot IS the month, so nothing shifts and there is nothing to cascade. A taken
            // slot here means two files claim one month, which the check above already refused —
            // reaching this is a summary or a stray sitting on a month's number.
            // MUTABLE: a folder with no year of its own (`HDFC Forex 9055`) can take January of
            // two different years in one pass, and both would read slot 01 off an immutable set.
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
            // A cascade is needed only when an EXISTING file's slot moves. Appending a month after
            // everything already there — the ordinary case, and what the incoming-file path almost
            // always does — shifts nothing and takes the next free number.
            //
            // **Gated on there actually being a placement.** Without that gate this fires on any
            // folder whose existing numbering is not already a perfect 1…N — and a great many are
            // not, legitimately: `10. Dec 2021.pdf` sitting beside `1. Mar` and `2. Apr` is a
            // folder somebody numbered by hand, not a folder to renumber behind their back. The
            // cascade exists to make ROOM; with nothing arriving there is no room to make.
            // Rows this grammar can parse but cannot RANK — a fiscal-span body like
            // `1. Apr 2007 to Aug 2007.pdf`, which names two months and so has no single date to
            // sort by. `SBI Savings/2007 - 2008` is three of them at slots 1, 2 and 3.
            //
            // A renumbering cannot reason about those: `positionalOrdinals` ranks only the months it
            // can see, so a shifted file is free to land on a slot one of them is already holding —
            // and `withoutCollisions` does not catch it, because the two NAMES differ even though
            // the slots collide. Measured: a cascade put `03. Mar 2021.pdf` beside
            // `03. Jan 2008 to Mar 2008.pdf`. Slot 0 is exempt; it is the summary slot and sits
            // outside the ranking by design.
            let unrankable = summaries.filter { $0.parsed.ordinal != 0 }
            let shifts = !placements.isEmpty && unrankable.isEmpty && dated.contains {
                ordinals[$0.key] != $0.parsed.ordinal
            }
            // Say so rather than quietly falling back to the append path, which would put the file
            // at the end of a folder whose numbering means something else.
            if !unrankable.isEmpty, !placements.isEmpty,
               dated.contains(where: { ordinals[$0.key] != $0.parsed.ordinal }) {
                // The widenings still stand. Refusing the renumbering is a statement about SLOTS,
                // and padding moves none — withholding it here would punish the folder twice for a
                // shape the pass merely declined to reorder.
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
                    // The rank, unless the folder's own numbering has drifted past it — in which
                    // case the honest slot is the next free one rather than a number already in
                    // use. Reached when `dated` is not a clean 1…N but nothing needs to move.
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
            // A real renumbering. Every file whose name changes goes into ONE cohort, including the
            // padding fixes — half a renumber is worse than none, so they travel together.
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
                // A file whose slot does NOT move is only being widened, which is right whether or
                // not the renumbering around it goes through — so it keeps cohort 0 and survives a
                // cascade that has to stand down.
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

    /// One date a group holds. The unit of a slot — **not** one file.
    ///
    /// `day` is nil under ``SlotGranularity/month``, where it is never read and never written, so a
    /// month-keyed folder's keys are exactly the `(year, month)` pairs they always were.
    struct MonthKey: Hashable, Comparable {
        let year: Int
        let month: Int
        let day: Int?

        init(year: Int, month: Int, day: Int? = nil) {
            self.year = year
            self.month = month
            self.day = day
        }

        /// Ordered by date. A key with no day sorts before any dated key in the same month — which
        /// cannot arise inside one group, since a group's granularity is fixed, but makes the
        /// ordering total rather than leaving it to whichever the sort happens to compare first.
        static func < (a: MonthKey, b: MonthKey) -> Bool {
            (a.year, a.month, a.day ?? 0) < (b.year, b.month, b.day ?? 0)
        }

        /// `Apr 2025`, or `Apr 15 2025` — how this slot is named in a sentence to the user.
        var spelled: String {
            day.map { OrdinalMonthName.body(month: month, day: $0, year: year) }
                ?? OrdinalMonthName.body(month: month, year: year)
        }
    }

    /// The ordinal each month takes under ``OrdinalScheme/position``: its rank in date order.
    ///
    /// **Ranked over distinct MONTHS, not over files**, and that distinction is load-bearing.
    /// `Savings NRI/2014` holds `1. Jun 2014 NRE.pdf` and `1. Jun 2014 NRO.pdf` — two statements
    /// for one month, correctly sharing slot 1 — and the next file is `2. Jul 2014.pdf`, not `3.`.
    /// Counting files instead would renumber that folder `1, 2, 3, …` and shift every month after
    /// June by one, which is a corruption dressed up as a fix.
    static func positionalOrdinals(for months: Set<MonthKey>) -> [MonthKey: Int] {
        var out: [MonthKey: Int] = [:]
        for (i, key) in months.sorted().enumerated() { out[key] = i + 1 }
        return out
    }

    /// Whether a mined year belongs to a folder whose year key is `owned`.
    ///
    /// `2023` owns only 2023. A fiscal key — `2014-2015`, `2009 - 2010` — owns April of the first
    /// year through March of the second, which is the Indian tax year the profile records on the
    /// `fiscalYear` axis. Getting this wrong in the permissive direction would let a January 2015
    /// statement be renamed into a `2014` folder.
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
