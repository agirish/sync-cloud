import Foundation

/// A card of changes in Ask Claude (the filing card and the plan card): rows the person reviews,
/// ticks and changes. The card is local UI and is saved with the chat; what Claude is told
/// about it is written by the tool that made it.
public struct AskClaudePlan: Codable, Equatable, Sendable {

    /// One change, by absolute path.
    public enum Change: Codable, Equatable, Sendable {
        /// Into `toFolder`, under its own name; the card says `landingName` when that name is
        /// taken there, and the name is found again when it runs.
        case move(from: String, toFolder: String)
        case rename(path: String, to: String)
        case newFolder(in: String, name: String)
        /// `copyOf`, for a file already filed: the other file holding its bytes. It
        /// goes only while that is still another file with the same bytes.
        case trash(path: String, copyOf: String? = nil)
        /// Folders the card's moves leave empty: each goes to the Trash only if,
        /// once the moves have run, it holds no file.
        case trashIfEmptied(folders: [String])

        /// The item the change acts on.
        public var path: String {
            switch self {
            case .move(let from, _): return from
            case .rename(let path, _), .trash(let path, _): return path
            case .newFolder(let parent, let name): return (parent as NSString).appendingPathComponent(name)
            case .trashIfEmptied(let folders): return folders.first ?? ""
            }
        }
    }

    /// A folder a row may go to instead (the runner-up), with its words.
    public struct Choice: Codable, Equatable, Sendable {
        /// "iCloud › Documents › Taxes › 2025".
        public let label: String
        /// Absolute. Never sent to Claude.
        public let path: String
        public let confidence: String?
        public let reason: String?
        /// A new folder the app offered ahead of the router's best (TE327), not made yet.
        public let isNew: Bool?
        /// Picked by a word read from the file's first page (TE342): Claude is told it only where
        /// the file's folder shares without asking. Nil when not.
        public let fromFile: Bool?

        public init(label: String, path: String, confidence: String? = nil, reason: String? = nil, isNew: Bool? = nil,
                    fromFile: Bool? = nil) {
            self.label = label
            self.path = path
            self.confidence = confidence
            self.reason = reason
            self.isNew = isNew
            self.fromFile = fromFile
        }
    }

    /// Where a row is shown on the card.
    public enum Group: Codable, Hashable, Sendable {
        /// Into this folder, by its label.
        case folder(String)
        /// Unsure between folders: picked from its menu.
        case needsPick
        /// The same file is already filed.
        case alreadyFiled
        /// Folders left empty.
        case emptied
        /// A file they selected that no folder fits (TE342, decision NP): theirs to place.
        case noFit
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        /// The item's own name, as the card shows it.
        public var name: String
        public var change: Change
        public var ticked: Bool
        /// "High", "Medium" or "Needs your pick", To File's words; nil for a change no ranking made.
        public var confidence: String?
        public var reason: String?
        /// A line about this row: "Kept as Ticket 2.pdf: the name is taken", "Outside Travel".
        public var note: String?
        /// The folder the move goes to, by label; nil for a row that isn't a move.
        public var folderLabel: String?
        /// The folders its menu offers, the one it goes to first.
        public var choices: [Choice]
        /// Set when they picked a folder from its menu: it then counts as theirs, not unsure.
        public var chosen: Bool
        /// Shown in its own group, for a file already filed.
        public var alreadyFiled: Bool
        /// Why it can't run, found when it was proposed or at Apply; such a row has no tick.
        public var refusal: String?
        /// What Apply did with it: "Moved", "Moved, as Ticket 2.pdf", or why it didn't.
        public var result: String?
        /// Apply did it.
        public var applied: Bool?
        /// The file's size, date and the folder it is in now, by label, for its details.
        public var size: Int?
        public var modified: Date?
        public var fromLabel: String?
        /// A new folder the card makes for its own moves (a saved rule's month folder): ticked
        /// only while a ticked move goes into it.
        public var forMoves: Bool?
        /// Where it was going before their first pick, absolute, and its label (TE331): a row they
        /// sent elsewhere teaches a rule at Apply. Nil until they pick.
        public var pickedFrom: String?
        public var pickedFromLabel: String?
        /// The new folder the app offered it ahead of `pickedFrom` (TE327), absolute: going there
        /// is taking the card's offer, not a pick that teaches.
        public var offeredNew: String?
        /// It needed their pick (no folder was sure) before they chose one.
        public var wasUnsure: Bool?
        /// The name a move lands under instead of its own (TE328), before a taken name is
        /// numbered; nil keeps its name. Made from inside the file, so held like content.
        public var newName: String?
        /// Where the new name's style came from: "Named like 2024 Ally 1099-INT.pdf", "Your name".
        public var nameBasis: String?
        /// The name copies a file in a folder that doesn't share without asking: held until Share
        /// Names and Folders, though the files' folder shares (decision NF). Nil when not.
        public var nameHeld: Bool?
        /// They typed it: a folder change keeps it.
        public var nameTyped: Bool?
        /// Why a file that wanted a name keeps its own: "Locked with a password, so …".
        public var nameKept: String?
        /// What its first page said, so a folder change can name it in that folder's style.
        public var nameFacts: ContentName.Facts?
        /// What the survey offered first for this file, for the filing scorecard (TE341). Set on
        /// filing rows only: a change Claude proposed has no first pick to keep.
        public var offer: FilingScorecard.Offer?
        // TE342. All optional, so a card saved before them still opens.
        /// A file they selected that no folder fits (decision NP): its move goes nowhere yet, so it
        /// has no tick until they choose a folder.
        public var noFit: Bool?
        /// Its folder is Claude's: Refine's pick (decision NS) or a new folder Claude named (NR).
        public var claudePick: Bool?
        /// Refine kept the folder this Mac had.
        public var claudeAgrees: Bool?
        /// The row before Refine changed it, for Undo Refine.
        public var beforeRefine: Before?
        /// Its folder was picked by a word read from page 1 and its file's folder asks first, so
        /// Claude isn't told it.
        public var folderHeld: Bool?
        /// The plain-name folders beside its best folder (TE327), where Claude may name a new one.
        public var namedSiblings: Siblings?

        public init(id: Int, name: String, change: Change, ticked: Bool, confidence: String? = nil, reason: String? = nil,
                    note: String? = nil, folderLabel: String? = nil, choices: [Choice] = [], chosen: Bool = false,
                    alreadyFiled: Bool = false, refusal: String? = nil) {
            self.id = id
            self.name = name
            self.change = change
            self.ticked = ticked
            self.confidence = confidence
            self.reason = reason
            self.note = note
            self.folderLabel = folderLabel
            self.choices = choices
            self.chosen = chosen
            self.alreadyFiled = alreadyFiled
            self.refusal = refusal
            if refusal != nil { self.ticked = false }
        }

        /// A folder they set teaches a rule (TE331, decision JC): any pick for a row that was
        /// unsure, and otherwise a folder other than the one the card had. When the card led with
        /// a new folder of the app's (TE327), the one it had is the router's first existing
        /// folder, and neither is a pick.
        public var teaches: Bool {
            guard case .move(_, let to) = change, noFit != true, claudePick != true else { return false }
            // Ticked as the Mac had it, though it needed their pick: taking its unsure folder.
            guard chosen else { return ticked && wasUnsure == true }
            if wasUnsure == true { return true }
            guard let pickedFrom else { return false }
            let going = (to as NSString).standardizingPath
            if let offeredNew, (offeredNew as NSString).standardizingPath == going { return false }
            return (pickedFrom as NSString).standardizingPath != going
        }

        /// Marks the row as set by them, from where it was going: on the first pick only. Going
        /// to a new folder the app offered, it was going to the router's first existing folder.
        public mutating func notePick() {
            guard !chosen, case .move(_, let to) = change else { return }
            // Nothing was offered, so nothing is corrected (decision NP).
            guard noFit != true else { return }
            pickedFrom = to
            pickedFromLabel = folderLabel
            if let offered = choices.first(where: { $0.isNew == true && $0.path == to }),
               let ranked = choices.first(where: { $0.isNew != true }) {
                offeredNew = offered.path
                pickedFrom = ranked.path
                pickedFromLabel = ranked.label
            }
            wasUnsure = group == .needsPick
        }

        /// Marks a move made by Move Here on filing help's `card` as their pick when it is one
        /// (TE331, decision JC): the runner-up, or any folder of an unsure answer. A new folder
        /// the app leads with (TE327) is no ranking of the router's: the router's best is the
        /// first folder already there, and taking either corrects nothing.
        public mutating func noteMoveHere(_ card: AskClaudeFilingCard) {
            guard case .move(_, let folder) = change, let best = card.folders.first else { return }
            let unsure = best.confidence == AskClaudeFiling.label(.low)
            let ranked = card.folders.first { $0.isNew != true } ?? best
            let offered = card.folders.first { $0.isNew == true }?.path
            guard unsure || (ranked.path != folder && offered != folder) else { return }
            pickedFrom = ranked.path
            pickedFromLabel = ranked.label
            offeredNew = offered
            wasUnsure = unsure
            chosen = true
            reason = "Your pick"
        }

        public var group: Group {
            if noFit == true { return .noFit }
            switch change {
            case .trashIfEmptied: return .emptied
            case .trash where alreadyFiled: return .alreadyFiled
            // Claude's folder (Refine's pick, or one it named) stands like a chosen one: it is in that
            // folder's group, wherever the row's own confidence would have put it (TE342).
            case .move where confidence == AskClaudeFiling.label(.low) && !chosen && claudePick != true: return .needsPick
            default: return .folder(folderLabel ?? "")
            }
        }

        /// Is a move to the Trash: drawn in red, never ticked for them.
        public var isTrash: Bool {
            switch change {
            case .trash, .trashIfEmptied: return true
            default: return false
            }
        }
    }

    /// Where a card is. Optional in the saved chat: an older saved card without it reads as
    /// proposed.
    public enum State: String, Codable, Sendable {
        case proposed, applying, applied, partlyApplied, undone, declined
    }

    /// "File 50 Loose Files".
    public let title: String
    /// "into iCloud › Documents".
    public let subtitle: String
    public var rows: [Row]
    /// "Left here: 4 installers, 2 files no folder fits"; nil when none were.
    public let leftHere: String?
    /// "1–10 of 132 · 122 more"; nil when the card holds them all.
    public let more: String?

    private var savedState: State?
    public var state: State {
        get { savedState ?? .proposed }
        set { savedState = newValue }
    }
    /// The undo step Apply registered; the card's Undo acts only while it tops the stack. Never
    /// saved: the undo history ends with the app, so a restored card offers no Undo.
    public var undoName: String?
    /// Which Apply registered it (`AskClaudePlanOutcome.undoToken`): cards share names ("File 10
    /// Loose Files"), so the name alone can't say the step on top is this card's. Never saved.
    public var undoToken: UUID?
    /// After Apply: "Moved 31 files and made 1 folder."; after Undo, what came back.
    public var summary: String?
    /// What Next asks, the same words they could type: "Show me the next 10 loose files."
    /// Nil when the card holds the last of them.
    public var nextAsk: String?
    /// The Next button's label: "Next 10".
    public var nextLabel: String?
    /// Whether Claude has the card's new names (TE328); nil when the card has none.
    public var names: AskClaudeHeldNames?
    /// Claude wasn't given its rows (a loose-files card from a folder that doesn't share freely,
    /// a move into a folder picked from page 1): what Apply and Undo tell it is counts.
    public var rowsHeld: Bool?
    /// The files a loose-files card read and left where they are (no folder fits, or already in
    /// it), with the place they were filed into: Next skips them for that place, so they never
    /// come back to the front of the next card (TE343). Saved with the chat on this Mac; Claude
    /// is told only how many.
    public var leftPaths: LeftFiles?

    /// Files a card left, and the place it filed into, absolute.
    public struct LeftFiles: Codable, Equatable, Sendable {
        public var place: String
        public var paths: [String]

        public init(place: String, paths: [String]) {
            self.place = place
            self.paths = paths
        }
    }

    /// File with Claude's card for a selection (TE342). All optional, so older cards still open.
    public var selection: Bool?
    /// The files they selected that this card didn't show, for its Next.
    public var remaining: [String]?
    /// The folder Refine N with Claude… scans (decision NQ); nil where Refine can't serve the card.
    public var refineFolder: String?
    /// How old the folder survey is, when it is old enough to miss folders made since.
    public var staleDays: Int?
    /// The card this one updates in the chat, for one tool call: never saved.
    public var replaces: UUID?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, rows, leftHere, more, savedState = "state", summary, nextAsk, nextLabel, names, rowsHeld, leftPaths,
             selection, remaining, refineFolder, staleDays
    }

    public init(title: String, subtitle: String, rows: [Row], leftHere: String? = nil, more: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        self.leftHere = leftHere
        self.more = more
    }

    /// The rows Apply would run: ticked, and not refused.
    public var runnable: [Row] { rows.filter { $0.ticked && $0.refusal == nil } }

    /// Writes what Apply did into the rows and the card.
    public mutating func record(_ outcome: AskClaudePlanOutcome) {
        for index in rows.indices {
            guard let row = outcome.rows[rows[index].id] else { continue }
            switch row {
            case .done(let what):
                rows[index].result = what
                rows[index].applied = true
            case .refused(let why), .failed(let why):
                rows[index].result = why
                rows[index].applied = false
            }
        }
        undoName = outcome.undoName
        undoToken = outcome.undoToken
        let done = outcome.doneCount
        state = done == 0 ? .proposed : (done < outcome.rows.count ? .partlyApplied : .applied)
        summary = Self.summary(rows.filter { $0.applied == true }, failed: outcome.rows.count - done)
    }

    static func summary(_ done: [Row], failed: Int) -> String {
        var moved = 0, renamed = 0, made = 0, trashed = 0, renamedMoves = 0
        for row in done {
            switch row.change {
            case .move:
                moved += 1
                if row.newName != nil { renamedMoves += 1 }
            case .rename: renamed += 1
            case .newFolder: made += 1
            case .trash: trashed += 1
            case .trashIfEmptied(let folders): trashed += folders.count
            }
        }
        var parts: [String] = []
        if made > 0 { parts.append("made \(made) folder\(made == 1 ? "" : "s")") }
        if moved > 0 { parts.append("moved \(moved) file\(moved == 1 ? "" : "s")" + (renamedMoves == 0 ? "" : ", \(renamedMoves) of them renamed")) }
        if renamed > 0 { parts.append("renamed \(renamed)") }
        if trashed > 0 { parts.append("moved \(trashed) to the Trash") }
        var text = parts.isEmpty ? "Nothing changed" : ListFormatter.localizedString(byJoining: parts)
        text = text.prefix(1).uppercased() + text.dropFirst() + "."
        if failed > 0 { text += " \(failed) couldn’t, and stayed where \(failed == 1 ? "it was" : "they were")." }
        return text
    }

    /// The rows by group, in card order: folders the card offered a sure file first (TE343), then
    /// folders with the most rows (then by label), then Needs Your Pick, Already Filed and the
    /// emptied folders. Sure is what was offered when the card was made, so a group never moves
    /// as rows are ticked or sent elsewhere; a card Claude proposed offers nothing and keeps the
    /// plain order.
    public var groups: [(group: Group, rows: [Row])] {
        var order: [Group] = []
        var byGroup: [Group: [Row]] = [:]
        for row in rows {
            if byGroup[row.group] == nil { order.append(row.group) }
            byGroup[row.group, default: []].append(row)
        }
        func rank(_ g: Group) -> Int {
            switch g {
            case .folder: return 0
            case .needsPick: return 1
            case .noFit: return 2
            case .alreadyFiled: return 3
            case .emptied: return 4
            }
        }
        let offeredSure = Set(byGroup.compactMap { group, rows in
            rows.contains { $0.offer?.confidence == .high } ? group : nil
        })
        let sorted = order.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if offeredSure.contains(a) != offeredSure.contains(b) { return offeredSure.contains(a) }
            if case .folder(let la) = a, case .folder(let lb) = b {
                let (ca, cb) = (byGroup[a]?.count ?? 0, byGroup[b]?.count ?? 0)
                return ca != cb ? ca > cb : la.localizedStandardCompare(lb) == .orderedAscending
            }
            return false
        }
        return sorted.map { ($0, byGroup[$0] ?? []) }
    }

    public var tickedCount: Int { rows.filter(\.ticked).count }

    /// The sure rows going into the folder `label` that a tick can change (TE343): a move, High
    /// now, not refused. A heading's tick box covers these alone, so a Medium row stays unticked
    /// until they tick it (decision GC).
    public func sureRows(inFolder label: String) -> [Row] {
        rows.filter { row in
            guard row.group == .folder(label), row.refusal == nil, case .move = row.change else { return false }
            return row.confidence == AskClaudeFiling.label(.high)
        }
    }

    /// Ticks or unticks every sure row going into `label` at once: one change to the card, then
    /// its new folders and landing names are set once.
    public mutating func setSureTicked(_ ticked: Bool, inFolder label: String) {
        let ids = Set(sureRows(inFolder: label).map(\.id))
        guard !ids.isEmpty else { return }
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].ticked = ticked }
        tickNeededFolders()
        noteLandingNames()
    }

    /// A row sent to another folder from its menu: it moves to that folder's group
    /// and is ticked.
    public mutating func choose(_ choice: Choice, forRow id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), case .move(let from, let was) = rows[index].change else { return }
        rows[index].notePick()
        // The name Claude was given went with the folder it was given.
        if rows[index].newName != nil, was != choice.path { namesChanged() }
        rows[index].change = .move(from: from, toFolder: choice.path)
        rows[index].folderLabel = choice.label
        rows[index].confidence = choice.confidence ?? rows[index].confidence
        rows[index].reason = choice.reason ?? "Your pick"
        // A note about the old folder says nothing about the new one; the name is found again.
        rows[index].note = nil
        rows[index].chosen = true
        rows[index].ticked = true
        (rows[index].noFit, rows[index].claudePick, rows[index].claudeAgrees) = (nil, nil, nil)
        tickNeededFolders()
        noteLandingNames()
    }

    public mutating func setTicked(_ ticked: Bool, row id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].noFit != true else { return }
        rows[index].ticked = ticked
        guard case .move = rows[index].change else { return }
        // Ticking a row that needs their pick takes the Mac's folder for it (decision JC).
        if !rows[index].chosen, rows[index].claudePick != true, rows[index].group == .needsPick {
            rows[index].wasUnsure = ticked ? true : nil
        }
        tickNeededFolders()
        noteLandingNames()
    }

    /// "Kept as Ticket 2.pdf: the name is taken".
    public static func landingNote(_ landing: String) -> String { "Kept as \(landing): the name is taken" }

    /// The names Apply gives, by row: each ticked move with a new name (TE328).
    public var newNames: [Int: String] {
        Dictionary(uniqueKeysWithValues: runnable.compactMap { row in row.newName.map { (row.id, $0) } })
    }

    /// The rows with a new name made from inside the file, or typed for one.
    public var namedRows: [Row] { rows.filter { $0.newName != nil } }

    /// Sets the name row `id` lands under: their typed `name`, or nil to keep its own. Returns why
    /// it can't be that name, or nil. The extension stays the file's own.
    @discardableResult
    public mutating func setName(_ name: String?, row id: Int) -> String? {
        guard state == .proposed, let index = rows.firstIndex(where: { $0.id == id }),
              case .move(let from, _) = rows[index].change else { return "That row moves no file." }
        let before = rows[index].newName
        defer { if rows[index].newName != before { namesChanged() } }
        guard let name else {
            rows[index].newName = nil
            rows[index].nameBasis = nil
            rows[index].nameTyped = nil
            noteLandingNames()
            return nil
        }
        let ext = (from as NSString).pathExtension
        let stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = ContentName.stemProblem(stem) { return problem }
        let full = ext.isEmpty ? stem : stem + "." + ext
        rows[index].newName = full == (from as NSString).lastPathComponent ? nil : full
        rows[index].nameBasis = rows[index].newName == nil ? nil : ContentName.typedBasis
        rows[index].nameTyped = rows[index].newName == nil ? nil : true
        noteLandingNames()
        return nil
    }

    /// A row's name made again for the folder it now goes to, unless they typed it. `named` gives
    /// the proposal from the facts, the file, its folder and the names the ticked rows above take
    /// in that folder: names are made in card order, so two scans filed together into a numbered
    /// folder take two numbers, not the same one.
    public mutating func renameForFolders(_ named: (ContentName.Facts, String, String, [String]) -> ContentName.Proposal?) {
        var taking: [String: [String]] = [:]
        var changed = false
        for index in rows.indices {
            guard case .move(let from, let to) = rows[index].change else { continue }
            let folder = (to as NSString).standardizingPath
            if rows[index].nameTyped != true, let facts = rows[index].nameFacts {
                let proposal = named(facts, from, to, taking[folder] ?? [])
                changed = changed || rows[index].newName != proposal?.name
                rows[index].newName = proposal?.name
                rows[index].nameBasis = proposal?.basis.line
            }
            if rows[index].ticked, rows[index].refusal == nil {
                taking[folder, default: []].append(rows[index].newName ?? (from as NSString).lastPathComponent)
            }
        }
        if changed { namesChanged() }
        noteLandingNames()
    }

    /// A new name Claude never saw: the card holds its names again, unless the files' folder
    /// shares without asking.
    mutating func namesChanged() {
        guard names?.shared == true, names?.sharedBy == nil else { return }
        names?.shared = false
    }

    /// Each move's landing name noted on its row, in the order Apply runs them: a
    /// name taken in its folder, on the disk or by a ticked move above it, lands numbered.
    public mutating func noteLandingNames(fileManager fm: FileManager = .default) {
        // Paths by the folder each resolves to, so two spellings of one folder share their names.
        var reserved = Set<String>()
        for index in rows.indices {
            guard case .move(let from, let toFolder) = rows[index].change, rows[index].noFit != true else { continue }
            let name = rows[index].newName ?? (from as NSString).lastPathComponent
            let folder = URL(fileURLWithPath: toFolder).resolvingSymlinksInPath()
            let caseSensitive = FileSyncManager.volumeSupportsCaseSensitiveNamesForNewItem(at: folder)
            // Apply's own naming, with the names the rows above take counted as taken.
            let landing = FileSyncManager.generateUniqueURL(for: folder.appendingPathComponent(name), fileManager: fm,
                                                            reserved: reserved, caseSensitiveVolume: caseSensitive)
            if rows[index].ticked { reserved.insert(landing.path) }
            let landingName = landing.lastPathComponent
            var notes = (rows[index].note ?? "").components(separatedBy: " · ")
                .filter { !$0.isEmpty && !($0.hasPrefix("Kept as ") && $0.hasSuffix(": the name is taken")) }
            if landingName != name { notes.insert(Self.landingNote(landingName), at: 0) }
            rows[index].note = notes.isEmpty ? nil : notes.joined(separator: " · ")
        }
    }

    /// Why `name` can't name a new folder, or nil (TE327).
    public static func folderNameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A folder needs a name." }
        if trimmed.contains("/") || trimmed.contains(":") { return "A folder name can’t contain “:” or “/”." }
        if trimmed.hasPrefix(".") { return "A name starting with “.” would hide the folder." }
        if trimmed.utf8.count > 255 { return "That name is too long for a folder." }
        return nil
    }

    /// Renames the new folder row `id` makes (TE327). Moves into it, folders made inside it and
    /// its rows' choices follow. When a folder of that name is already there, found by `existing`,
    /// the moves go into that one and this row makes nothing. Returns why it couldn't, or nil.
    @discardableResult
    public mutating func renameNewFolder(_ id: Int, to name: String, existing: (String) -> String?) -> String? {
        guard state == .proposed, let index = rows.firstIndex(where: { $0.id == id }),
              case .newFolder(let parent, let old) = rows[index].change else { return "That row makes no folder." }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.folderNameProblem(name) { return problem }
        guard name != old else { return nil }
        let oldPath = (parent as NSString).appendingPathComponent(old)
        let parentLabel = rows[index].folderLabel ?? ""
        let oldLabel = parentLabel.isEmpty ? old : parentLabel + " › " + old
        let taken = existing((parent as NSString).appendingPathComponent(name))
        let newPath = taken ?? (parent as NSString).appendingPathComponent(name)
        let newName = (newPath as NSString).lastPathComponent
        let newLabel = parentLabel.isEmpty ? newName : parentLabel + " › " + newName
        func moved(_ path: String) -> String? {
            if path == oldPath { return newPath }
            return path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : nil
        }
        func relabeled(_ label: String) -> String {
            if label == oldLabel { return newLabel }
            return label.hasPrefix(oldLabel + " › ") ? newLabel + label.dropFirst(oldLabel.count) : label
        }
        rows[index].change = .newFolder(in: parent, name: newName)
        rows[index].name = "New folder “\(newName)”"
        if taken != nil {
            rows[index].refusal = Self.alreadyThere(newName)
            rows[index].ticked = false
        } else if rows[index].refusal?.hasSuffix(Self.alreadyThere("")) == true {
            // Named back from a folder already there: it makes this one again, ticked below
            // while a ticked move goes into it.
            rows[index].refusal = nil
        }
        for i in rows.indices where i != index {
            switch rows[i].change {
            case .move(let from, let to):
                if let to = moved(to) { rows[i].change = .move(from: from, toFolder: to) }
            case .newFolder(let inside, let made):
                if let inside = moved(inside) { rows[i].change = .newFolder(in: inside, name: made) }
            default: break
            }
            rows[i].folderLabel = rows[i].folderLabel.map(relabeled)
            rows[i].offeredNew = rows[i].offeredNew.map { moved($0) ?? $0 }
            rows[i].choices = rows[i].choices.map { choice in
                guard let path = moved(choice.path) else { return choice }
                return Choice(label: relabeled(choice.label), path: path, confidence: choice.confidence, reason: choice.reason,
                              isNew: choice.isNew)
            }
        }
        tickNeededFolders()
        noteLandingNames()
        return nil
    }

    /// A new folder's refusal when its name is taken: "India is already there; the files go into it".
    static func alreadyThere(_ name: String) -> String { "\(name) is already there; the files go into it" }

    /// The folder already at `path` in any case, as it is spelled on disk, or nil: a file of that
    /// name is no folder the files could go into.
    public static func existingFolder(_ path: String, fileManager fm: FileManager = .default) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let wanted = (path as NSString).lastPathComponent
        let names = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
        for name in names where name.caseInsensitiveCompare(wanted) == .orderedSame {
            let found = (parent as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: found, isDirectory: &isDirectory), isDirectory.boolValue { return found }
        }
        return nil
    }

    /// A new folder made for the card's moves is ticked while a ticked move goes into it, and
    /// unticked once none does, so Apply never makes an empty one.
    public mutating func tickNeededFolders() {
        for index in rows.indices where rows[index].forMoves == true && rows[index].refusal == nil {
            let folder = rows[index].change.path
            rows[index].ticked = rows.contains { row in
                guard row.ticked, case .move(_, let to) = row.change else { return false }
                return to == folder || to.hasPrefix(folder + "/")
            }
        }
    }

    /// What Undo did, once it ran: rows `notBack` are those it didn't put back as they were.
    public mutating func recordUndo(notBack: [Int]) {
        state = .undone
        undoName = nil
        undoToken = nil
        let missed = rows.filter { notBack.contains($0.id) }.map(\.name)
        summary = missed.isEmpty ? "Undone: everything is back where it was."
            : "Undone, except \(missed.count): " + ListFormatter.localizedString(byJoining: missed.prefix(5).map { $0 })
                + (missed.count > 5 ? " and \(missed.count - 5) more" : "") + " didn’t go back."
    }

    // MARK: What Claude is told

    /// What Claude is told once Apply has run: the summary, and the rows that didn't run. A card
    /// whose rows Claude never had gives a count, not the files or why.
    public var applyReport: String {
        var line = "They applied your card “\(title)”: \(summary ?? "applied.")"
        let missed = rows.filter { $0.applied == false }
        guard !missed.isEmpty else { return line }
        if rowsHeld == true { return line + " \(missed.count) didn’t run; their card says why." }
        line += " Didn’t run: " + missed.prefix(10).map { "\($0.name) (\(Self.toldWhy($0, namesHeld: names?.shared == false)))" }
            .joined(separator: "; ")
        if missed.count > 10 { line += "; and \(missed.count - 10) more" }
        return line + "."
    }

    /// What Claude is told once Undo has run, with rows `notBack` those it didn't put back.
    public func undoReport(notBack: [Int]) -> String {
        let missed = rows.filter { notBack.contains($0.id) }.map(\.name)
        if missed.isEmpty { return "They undid your card “\(title)”: everything it did is back where it was." }
        if rowsHeld == true { return "They undid your card “\(title)”, but \(missed.count) didn’t go back." }
        return "They undid your card “\(title)”, but \(missed.count) didn’t go back: \(missed.prefix(10).joined(separator: "; "))."
    }

    /// Why a row didn't run, as Claude hears it: never a hidden folder's name, nor a reason that
    /// may carry a new name Claude hasn't been given.
    static func toldWhy(_ row: Row, namesHeld: Bool) -> String {
        guard let why = row.result else { return "skipped" }
        if why.hasSuffix(" is hidden from Claude") { return "its folder is hidden from Claude" }
        if why == "It’s hidden from Claude" { return why }
        if row.newName != nil, namesHeld { return "it couldn’t be moved; their card says why" }
        return why
    }
}
