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

        public init(label: String, path: String, confidence: String? = nil, reason: String? = nil) {
            self.label = label
            self.path = path
            self.confidence = confidence
            self.reason = reason
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
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
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
        /// It needed their pick (no folder was sure) before they chose one.
        public var wasUnsure: Bool?

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
        /// unsure, and otherwise a folder other than the one the card had.
        public var teaches: Bool {
            guard chosen, case .move(_, let to) = change else { return false }
            if wasUnsure == true { return true }
            guard let pickedFrom else { return false }
            return (pickedFrom as NSString).standardizingPath != (to as NSString).standardizingPath
        }

        /// Marks the row as set by them, from where it was going: on the first pick only.
        public mutating func notePick() {
            guard !chosen, case .move(_, let to) = change else { return }
            pickedFrom = to
            pickedFromLabel = folderLabel
            wasUnsure = group == .needsPick
        }

        public var group: Group {
            switch change {
            case .trashIfEmptied: return .emptied
            case .trash where alreadyFiled: return .alreadyFiled
            case .move where confidence == AskClaudeFiling.label(.low) && !chosen: return .needsPick
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

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, rows, leftHere, more, savedState = "state", summary, nextAsk, nextLabel
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
        var moved = 0, renamed = 0, made = 0, trashed = 0
        for row in done {
            switch row.change {
            case .move: moved += 1
            case .rename: renamed += 1
            case .newFolder: made += 1
            case .trash: trashed += 1
            case .trashIfEmptied(let folders): trashed += folders.count
            }
        }
        var parts: [String] = []
        if made > 0 { parts.append("made \(made) folder\(made == 1 ? "" : "s")") }
        if moved > 0 { parts.append("moved \(moved) file\(moved == 1 ? "" : "s")") }
        if renamed > 0 { parts.append("renamed \(renamed)") }
        if trashed > 0 { parts.append("moved \(trashed) to the Trash") }
        var text = parts.isEmpty ? "Nothing changed" : ListFormatter.localizedString(byJoining: parts)
        text = text.prefix(1).uppercased() + text.dropFirst() + "."
        if failed > 0 { text += " \(failed) couldn’t, and stayed where \(failed == 1 ? "it was" : "they were")." }
        return text
    }

    /// The rows by group, in card order: folders with the most rows first (then by label), then
    /// Needs Your Pick, Already Filed and the emptied folders.
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
            case .alreadyFiled: return 2
            case .emptied: return 3
            }
        }
        let sorted = order.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if case .folder(let la) = a, case .folder(let lb) = b {
                let (ca, cb) = (byGroup[a]?.count ?? 0, byGroup[b]?.count ?? 0)
                return ca != cb ? ca > cb : la.localizedStandardCompare(lb) == .orderedAscending
            }
            return false
        }
        return sorted.map { ($0, byGroup[$0] ?? []) }
    }

    public var tickedCount: Int { rows.filter(\.ticked).count }

    /// A row sent to another folder from its menu: it moves to that folder's group
    /// and is ticked.
    public mutating func choose(_ choice: Choice, forRow id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), case .move(let from, _) = rows[index].change else { return }
        rows[index].notePick()
        rows[index].change = .move(from: from, toFolder: choice.path)
        rows[index].folderLabel = choice.label
        rows[index].confidence = choice.confidence ?? rows[index].confidence
        rows[index].reason = choice.reason ?? "Your pick"
        // A note about the old folder says nothing about the new one; the name is found again.
        rows[index].note = nil
        rows[index].chosen = true
        rows[index].ticked = true
        tickNeededFolders()
        noteLandingNames()
    }

    public mutating func setTicked(_ ticked: Bool, row id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].ticked = ticked
        guard case .move = rows[index].change else { return }
        tickNeededFolders()
        noteLandingNames()
    }

    /// "Kept as Ticket 2.pdf: the name is taken".
    public static func landingNote(_ landing: String) -> String { "Kept as \(landing): the name is taken" }

    /// Each move's landing name noted on its row, in the order Apply runs them: a
    /// name taken in its folder, on the disk or by a ticked move above it, lands numbered.
    public mutating func noteLandingNames(fileManager fm: FileManager = .default) {
        // Paths by the folder each resolves to, so two spellings of one folder share their names.
        var reserved = Set<String>()
        for index in rows.indices {
            guard case .move(let from, let toFolder) = rows[index].change else { continue }
            let name = (from as NSString).lastPathComponent
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
            rows[index].refusal = "\(newName) is already there; the files go into it"
            rows[index].ticked = false
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
            rows[i].choices = rows[i].choices.map { choice in
                guard let path = moved(choice.path) else { return choice }
                return Choice(label: relabeled(choice.label), path: path, confidence: choice.confidence, reason: choice.reason)
            }
        }
        tickNeededFolders()
        noteLandingNames()
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
}
