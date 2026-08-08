import Foundation

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
    }

    /// Absolute path of the file as it stands **now**. Doubles as the identity.
    public let id: String
    public var currentPath: String { id }
    public let currentName: String
    public let proposedName: String
    public let kind: Kind
    /// Why, for the row subtitle.
    public let reason: String

    public init(currentPath: String, currentName: String, proposedName: String,
                kind: Kind, reason: String) {
        self.id = currentPath
        self.currentName = currentName
        self.proposedName = proposedName
        self.kind = kind
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
        guard usesOrdinalConvention(files: files, entry: entry) else {
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
            let groupScheme = inferScheme(files: group)
            schemes.append((ext, group.count, groupScheme))
            let result = planGroup(group, scheme: groupScheme, entry: entry, incoming: incoming)
            steps.append(contentsOf: result.steps)
            skips.append(contentsOf: result.skips)
        }
        // Reported as the folder's scheme: the one the largest group uses. Display only — every
        // decision above was made with its own group's reading.
        let scheme = schemes.max { ($0.count, $1.ext) < ($1.count, $0.ext) }?.scheme ?? .position
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
            }
        }
        return kept
    }

    // MARK: Does this folder number its files at all?

    /// Whether the pass may touch this folder.
    ///
    /// The profile's `naming` is the authority — it was mined from the whole folder, and it says
    /// `ordinal-month` for 327 folders and `descriptive` for 2,158. **A `descriptive` folder is
    /// never touched**, however date-like its files look: `Passport.pdf` and `Lease Agreement.pdf`
    /// have no slot to occupy, and proposing one for them is how a rename pass gets switched off.
    ///
    /// The inference fallback exists only for a folder the profile has not seen — a folder created
    /// since the survey, which the incoming-file path meets often. It demands three conforming files
    /// rather than one so a single stray `1. Something.pdf` cannot recruit a whole folder.
    static func usesOrdinalConvention(files: [FolderFile], entry: FolderProfileEntry?) -> Bool {
        if let naming = entry?.naming { return naming == "ordinal-month" }
        let conforming = files.filter { OrdinalMonthName.parse($0.name)?.month != nil }
        return conforming.count >= 3
    }

    /// Which scheme the folder's existing names vouch for.
    ///
    /// `.monthNumber` only when **every** dated file already sits in its own month's slot and at
    /// least two do — otherwise `.position`, which is what 118 of the tree's 132 discriminating
    /// folders use against `.monthNumber`'s 14. Requiring unanimity keeps a folder that is merely
    /// contiguous-from-January (where the two schemes agree and cannot be told apart) on the
    /// majority reading.
    static func inferScheme(files: [FolderFile]) -> OrdinalScheme {
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
        _ files: [FolderFile], scheme: OrdinalScheme,
        entry: FolderProfileEntry?, incoming: FolderFile?
    ) -> GroupResult {
        var out = GroupResult()

        /// (file, parsed) for names already in the grammar; the rest are candidates for placement.
        var dated: [(file: FolderFile, parsed: OrdinalMonthName.Parsed, month: Int, year: Int)] = []
        var summaries: [(file: FolderFile, parsed: OrdinalMonthName.Parsed)] = []
        var unplaced: [FolderFile] = []

        for f in files {
            if let p = OrdinalMonthName.parse(f.name) {
                if let m = p.month, let y = p.year {
                    dated.append((f, p, m, y))
                } else {
                    // Parsed, but carries no single month — the summary slot, or a fiscal-span body
                    // this grammar does not model. It holds its ordinal; only its width is fixed.
                    summaries.append((f, p))
                }
            } else {
                unplaced.append(f)
            }
        }

        // Slots already spoken for, so a placement never lands on one.
        var taken = Set(dated.map(\.parsed.ordinal)).union(summaries.map(\.parsed.ordinal))
        // The months this group holds, GROWING as placements are decided. Both the duplicate check
        // and the positional rank read it, so a second raw bill for a month a first raw bill just
        // claimed is caught by the same rule that catches one clashing with a renamed sibling.
        var claimed: [(month: Int, year: Int, by: String)] =
            dated.map { (month: $0.month, year: $0.year, by: $0.file.name) }

        // 1. Width and body fixes. The ordinal does not move, so these can never collide with
        //    anything and are the safe bulk of the backlog — 567 one-digit ordinals tree-wide.
        for d in dated where !d.parsed.isCanonical {
            out.steps.append(RenameStep(
                currentPath: d.file.path, currentName: d.file.name,
                proposedName: d.parsed.canonicalName,
                kind: .tidied,
                reason: d.parsed.ordinalDigits == 1
                    ? "Padded to two digits — a one-digit ordinal sorts after “10.”"
                    : "Tidied to the folder’s “NN. Mon YYYY” form"))
        }
        for s in summaries where !s.parsed.isCanonical {
            out.steps.append(RenameStep(
                currentPath: s.file.path, currentName: s.file.name,
                proposedName: s.parsed.canonicalName,
                kind: .tidied,
                reason: "Padded to two digits — a one-digit ordinal sorts after “10.”"))
        }

        // 2. Placements: a raw name that already carries its own date.
        //
        // Mined FIRST and then walked in date order, because under `.position` a slot is a rank and
        // a rank is only meaningful against everything already placed. A folder the survey found
        // "not renamed at all" — `PG&E/2022`, eleven raw bills and no conforming sibling — is the
        // case that makes this necessary: ranked against the *original* file list alone, all eleven
        // compute slot 1, ten of them collide with the first, and the pass places one bill and
        // reports ten failures for a folder it should have numbered end to end.
        let minedUnplaced = unplaced
            .map { (file: $0, mined: FileNameDate.mine($0.name)) }
            .sorted { a, b in
                switch (a.mined, b.mined) {
                case let (x?, y?): return (x.year, x.month) < (y.year, y.month)
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
            // A slot already holding this exact month is the duplicate trap: the raw original beside
            // the copy that was already renamed. Proving they are the same document is item 18's
            // job, so this reports the collision and never guesses.
            if let clash = claimed.first(where: { $0.month == mined.month && $0.year == mined.year }) {
                out.skips.append(RenameSkip(
                    path: f.path, fileName: f.name,
                    reason: "“\(clash.by)” already holds "
                        + "\(OrdinalMonthName.body(month: mined.month, year: mined.year)) here."))
                continue
            }
            let slot = self.slot(forMonth: mined.month, year: mined.year, scheme: scheme,
                                 among: claimed)
            guard !taken.contains(slot) else {
                out.skips.append(RenameSkip(
                    path: f.path, fileName: f.name,
                    reason: "Slot \(String(format: "%02d", slot)) is taken — this folder needs "
                        + "renumbering before \(OrdinalMonthName.body(month: mined.month, year: mined.year))"
                        + " can be placed."))
                continue
            }
            taken.insert(slot)
            claimed.append((month: mined.month, year: mined.year, by: f.name))
            out.steps.append(RenameStep(
                currentPath: f.path, currentName: f.name,
                proposedName: OrdinalMonthName.render(ordinal: slot, month: mined.month,
                                                      year: mined.year,
                                                      ext: (f.name as NSString).pathExtension),
                kind: .placed,
                reason: "Renamed to the folder’s convention from \(mined.evidence)."))
        }
        return out
    }

    /// The ordinal a new month takes.
    ///
    /// Under `.monthNumber` it is the month. Under `.position` it is the file's rank in date order
    /// among the folder's dated files — which for the ordinary case, a new month arriving after
    /// every month already there, is simply the next free number.
    static func slot(forMonth month: Int, year: Int, scheme: OrdinalScheme,
                     among claimed: [(month: Int, year: Int, by: String)]) -> Int {
        switch scheme {
        case .monthNumber:
            return month
        case .position:
            return claimed.filter { ($0.year, $0.month) < (year, month) }.count + 1
        }
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
