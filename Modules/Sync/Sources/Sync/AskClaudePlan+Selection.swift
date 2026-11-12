import Foundation

// MARK: - File with Claude's card for a selection (TE342)

extension AskClaudePlan {

    /// The parent of a row's best folder and its plain-name folders (TE327), so Claude can name a
    /// new one of the same kind there.
    public struct Siblings: Codable, Equatable, Sendable {
        /// "Home › Documents › Travel › Trips".
        public let label: String
        /// Absolute. Never sent to Claude.
        public let path: String
        public let names: [String]

        public init(label: String, path: String, names: [String]) {
            self.label = label
            self.path = path
            self.names = names
        }
    }

    /// A row as it was before Refine changed it, so Undo Refine can put it back.
    public struct Before: Codable, Equatable, Sendable {
        public let change: Change
        public let folderLabel: String?
        public let choices: [Choice]
        public let confidence: String?
        public let reason: String?
        public let offer: FilingScorecard.Offer?

        init(_ row: Row) {
            (change, folderLabel, choices, confidence, reason, offer) =
                (row.change, row.folderLabel, row.choices, row.confidence, row.reason, row.offer)
        }
    }

    /// What Refine made of one row's file.
    public enum RefinePick: Equatable, Sendable {
        /// Claude picked another folder: as its best, or next under Try Another Folder.
        case folder(path: String, label: String, reason: String?)
        /// Claude kept the folder this Mac had.
        case agrees
    }

    /// Why a row stands where it is, for its details: Refine's or Claude's.
    public static let claudesPick = "Claude’s pick"

    /// A No Folder Fits row's reason (decision NP).
    public static let noFitReason = "No folder in your folder survey fits it"

    /// The rows Refine N with Claude… covers (decision NQ): moves still waiting, not sure (High),
    /// not chosen by them and not already Claude's. Nil for a card Refine can't serve.
    public var refinable: [Row] {
        guard state == .proposed, refineFolder != nil else { return [] }
        return rows.filter { row in
            guard case .move = row.change, row.noFit != true, row.refusal == nil, !row.chosen, row.claudePick != true,
                  row.applied == nil else { return false }
            return row.confidence != AskClaudeFiling.label(.high)
        }
    }

    /// Carries what they did on `old`, an earlier card for the same files, onto this one: a folder
    /// they chose, a name they typed, and ticks on rows still going where they went. A row whose
    /// folder changed stays unticked: they approved the other one.
    public mutating func carryPicks(from old: AskClaudePlan) {
        for index in rows.indices {
            let path = rows[index].change.path
            guard let was = old.rows.first(where: { $0.change.path == path && Self.isFile($0) }) else { continue }
            if was.chosen, case .move = was.change {
                rows[index].change = was.change
                rows[index].folderLabel = was.folderLabel
                rows[index].choices = was.choices
                rows[index].confidence = was.confidence
                rows[index].reason = was.reason
                rows[index].chosen = true
                rows[index].ticked = was.ticked
                rows[index].noFit = nil
                rows[index].claudePick = nil
                (rows[index].pickedFrom, rows[index].pickedFromLabel) = (was.pickedFrom, was.pickedFromLabel)
                (rows[index].offeredNew, rows[index].wasUnsure) = (was.offeredNew, was.wasUnsure)
            } else if was.change == rows[index].change, rows[index].refusal == nil {
                rows[index].ticked = was.ticked
                rows[index].wasUnsure = was.wasUnsure
            }
            if was.nameTyped == true {
                (rows[index].newName, rows[index].nameBasis, rows[index].nameTyped) = (was.newName, was.nameBasis, true)
            }
        }
        tickNeededFolders()
        noteLandingNames()
    }

    /// A file's row, not one for a folder the card makes or empties.
    public static func isFile(_ row: Row) -> Bool {
        switch row.change {
        case .move: return true
        case .trash: return row.alreadyFiled
        default: return false
        }
    }

    /// Claude's folder leads the row for `file` (decision NR): a new folder named like its
    /// siblings, or one they asked for. The card makes it, ticked once the row is. Returns why it
    /// can't, or nil. A folder they chose for the row is never changed.
    @discardableResult
    public mutating func claudeFolder(forFile file: String, folder: String, label: String, reason: String) -> String? {
        guard state == .proposed else { return "The card was already applied or put away." }
        guard let index = rows.firstIndex(where: { $0.change.path == file && Self.isFile($0) }) else {
            return "That file isn’t on the card."
        }
        guard !rows[index].chosen else { return "They chose a folder for it themselves." }
        guard case .move(let from, _) = rows[index].change else { return "That file isn’t moved by the card." }
        let choice = Choice(label: label, path: folder, reason: reason, isNew: true)
        rows[index].choices = [choice] + rows[index].choices.filter { $0.path != folder }
        rows[index].change = .move(from: from, toFolder: folder)
        rows[index].folderLabel = label
        rows[index].reason = reason
        rows[index].note = nil
        rows[index].ticked = false
        rows[index].noFit = nil
        rows[index].claudePick = true
        rows[index].claudeAgrees = nil
        rows[index].offer = Self.claudesOffer(rows[index].offer, folder: folder, isNew: true)
        addFolderRow(for: folder)
        tickNeededFolders()
        noteLandingNames()
        return nil
    }

    /// Refine's answers for the card's rows (decision NS): each row it moved goes to Claude's
    /// folder, unticked, with this Mac's folders as its other choices; a row it kept says so.
    /// Rows they chose a folder for, or that were applied, stay as they are.
    public mutating func refined(_ picks: [String: RefinePick]) {
        guard state == .proposed else { return }
        for index in rows.indices {
            guard case .move(let from, let was) = rows[index].change, !rows[index].chosen,
                  rows[index].applied == nil, let pick = picks[from] else { continue }
            switch pick {
            case .agrees:
                rows[index].claudeAgrees = true
            case .folder(let path, let label, let reason):
                guard (path as NSString).standardizingPath != (was as NSString).standardizingPath else {
                    rows[index].claudeAgrees = true
                    continue
                }
                if rows[index].beforeRefine == nil { rows[index].beforeRefine = Before(rows[index]) }
                let choice = Choice(label: label, path: path, reason: reason.map { Self.claudesPick + ": " + $0 } ?? Self.claudesPick)
                rows[index].choices = [choice] + rows[index].choices.filter { $0.path != path }
                rows[index].change = .move(from: from, toFolder: path)
                rows[index].folderLabel = label
                rows[index].reason = choice.reason
                rows[index].note = nil
                rows[index].ticked = false
                rows[index].claudePick = true
                rows[index].claudeAgrees = nil
                rows[index].offer = Self.claudesOffer(rows[index].offer, folder: path, isNew: false)
                addFolderRow(for: path)
            }
        }
        tickNeededFolders()
        noteLandingNames()
    }

    /// Undo Refine: each row Refine moved and they haven't touched since goes back to this Mac's
    /// folder.
    public mutating func refineUndone() {
        guard state == .proposed else { return }
        for index in rows.indices {
            rows[index].claudeAgrees = nil
            guard rows[index].claudePick == true, let before = rows[index].beforeRefine,
                  !rows[index].chosen, !rows[index].ticked else { continue }
            rows[index].change = before.change
            rows[index].folderLabel = before.folderLabel
            rows[index].choices = before.choices
            rows[index].confidence = before.confidence
            rows[index].reason = before.reason
            rows[index].offer = before.offer
            rows[index].claudePick = nil
            rows[index].beforeRefine = nil
        }
        tickNeededFolders()
        noteLandingNames()
    }

    /// What Claude offered, for the scorecard: counted under Claude, with this Mac's first folder
    /// as the runner-up. A new folder Claude named is the card's own offer, never "their new folder".
    static func claudesOffer(_ mac: FilingScorecard.Offer?, folder: String, isNew: Bool) -> FilingScorecard.Offer {
        FilingScorecard.Offer(path: folder, confidence: mac?.confidence ?? .low, evidence: mac?.evidence ?? .name,
                              picker: .claude, runnerUp: mac?.path, offeredNew: isNew ? [folder] : [], root: mac?.root)
    }

    /// A row that makes `folder` and the folders above it not there yet, unless one already does.
    mutating func addFolderRow(for folder: String, fileManager fm: FileManager = .default) {
        var missing: [String] = []
        var path = folder
        let made = Set(rows.compactMap { row -> String? in
            if case .newFolder = row.change { return row.change.path }
            return nil
        })
        while !path.isEmpty, path != "/", !fm.fileExists(atPath: path), !made.contains(path) {
            missing.insert(path, at: 0)
            path = (path as NSString).deletingLastPathComponent
        }
        for path in missing {
            let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            let parentLabel = rows.compactMap { $0.folderLabel }.first { $0.hasSuffix(" › " + name) }
                .map { String($0.dropLast(name.count + 3)) } ?? (parent as NSString).lastPathComponent
            var row = Row(id: (rows.map(\.id).max() ?? -1) + 1, name: "New folder “\(name)”", change: .newFolder(in: parent, name: name),
                          ticked: false, reason: "For the files filed in it", folderLabel: parentLabel)
            row.forMoves = true
            rows.append(row)
        }
    }
}
