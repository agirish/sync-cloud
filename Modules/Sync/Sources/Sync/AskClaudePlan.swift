import Foundation

/// A card of changes in Ask Claude (TE285's filing card; TE262's plan card): rows the person
/// reviews, ticks and changes. The card is local UI and is saved with the chat; what Claude is told
/// about it is written by the tool that made it.
public struct AskClaudePlan: Codable, Equatable, Sendable {

    /// One change, by absolute path.
    public enum Change: Codable, Equatable, Sendable {
        /// Into `toFolder`, under its own name; the card says `landingName` when that name is
        /// taken there (decision GE), and the name is found again when it runs.
        case move(from: String, toFolder: String)
        case rename(path: String, to: String)
        case newFolder(in: String, name: String)
        case trash(path: String)
        /// Folders the card's moves leave empty (decision GA): each goes to the Trash only if,
        /// once the moves have run, it holds nothing else.
        case trashIfEmptied(folders: [String])

        /// The item the change acts on.
        public var path: String {
            switch self {
            case .move(let from, _): return from
            case .rename(let path, _), .trash(let path): return path
            case .newFolder(let parent, let name): return (parent as NSString).appendingPathComponent(name)
            case .trashIfEmptied(let folders): return folders.first ?? ""
            }
        }
    }

    /// A folder a row may go to instead (decision GC: the runner-up), with its words.
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
        /// The same file is already filed (decision GF).
        case alreadyFiled
        /// Folders left empty (decision GA).
        case emptied
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        /// The item's own name, as the card shows it.
        public let name: String
        public var change: Change
        public var ticked: Bool
        /// "High", "Medium" or "Needs your pick", To File's words; nil for a change no ranking made.
        public var confidence: String?
        public var reason: String?
        /// A line about this row: "Kept as Ticket 2.pdf: the name is taken", "Outside Travel".
        public var note: String?
        /// The folder the move goes to, by label; nil for a row that isn't a move.
        public var folderLabel: String?
        /// The folders its menu offers, the one it goes to first (decision GD).
        public var choices: [Choice]
        /// Set when they picked a folder from its menu: it then counts as theirs, not unsure.
        public var chosen: Bool
        /// Shown in its own group, for a file already filed (decision GF).
        public var alreadyFiled: Bool
        /// Why it can't run, found when it was proposed or at Apply (TE262); such a row has no tick.
        public var refusal: String?
        /// What Apply did with it: "Moved", "Moved, as Ticket 2.pdf", or why it didn't.
        public var result: String?
        /// Apply did it.
        public var applied: Bool?
        /// The file's size, date and the folder it is in now, by label, for its details.
        public var size: Int?
        public var modified: Date?
        public var fromLabel: String?

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

    /// Where a card is (TE262). Optional in the saved chat: a card saved before Apply existed
    /// reads as proposed.
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
    /// "50 of 132 · 82 more: ask for the next 50"; nil when the card holds them all.
    public let more: String?

    private var savedState: State?
    public var state: State {
        get { savedState ?? .proposed }
        set { savedState = newValue }
    }
    /// The undo step Apply registered; the card's Undo acts only while it tops the stack. Never
    /// saved: the undo history ends with the app, so a restored card offers no Undo.
    public var undoName: String?
    /// After Apply: "Moved 31 files and made 1 folder."
    public var summary: String?
    /// What Next asks, the same words they could type: "Show me the next 10 loose files."
    /// Nil when the card holds the last of them (decision GG).
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

    /// A row sent to another folder from its menu (decision GD): it moves to that folder's group
    /// and is ticked.
    public mutating func choose(_ choice: Choice, forRow id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), case .move(let from, _) = rows[index].change else { return }
        rows[index].change = .move(from: from, toFolder: choice.path)
        rows[index].folderLabel = choice.label
        rows[index].confidence = choice.confidence ?? rows[index].confidence
        rows[index].reason = choice.reason ?? "Your pick"
        // A note about the name in the old folder says nothing about the new one.
        rows[index].note = nil
        rows[index].chosen = true
        rows[index].ticked = true
    }

    public mutating func setTicked(_ ticked: Bool, row id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].ticked = ticked
    }
}
