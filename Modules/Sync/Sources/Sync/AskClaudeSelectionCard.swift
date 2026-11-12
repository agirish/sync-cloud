import Foundation

/// What Claude is told about File with Claude's card for a selection (TE342). Claude already has
/// the files' names and handles, from the question's attached section, so each row goes by
/// handle, as where_to_file tells of one file: its folder, unless a word read from page 1 picked
/// it and the file's folder asks first; never a reason, which can name such a word.
public enum AskClaudeSelectionCard {

    /// - `handle`: the handle Claude has for a file's path.
    /// - `namesShared`: Claude has the card's new names (every file's folder shares freely, or
    ///   they clicked Share Names and Folders).
    public static func result(_ plan: AskClaudePlan, handle: (String) -> String, namesShared: Bool) -> String {
        var lines = ["They have a card: \(AskClaudeScreenCard.escape(plan.title)), \(AskClaudeScreenCard.escape(plan.subtitle)). Nothing moves until they click Apply."]
        lines.append("rows: handle|folder|confidence|ticked|note")
        let made = Set(plan.rows.compactMap { row -> String? in
            if case .newFolder = row.change { return row.change.path }
            return nil
        })
        var siblings: [String] = []
        for (group, rows) in plan.groups {
            for row in rows where AskClaudePlan.isFile(row) {
                let folder: String
                switch group {
                case .noFit:
                    folder = "no folder fits; they choose one"
                case .alreadyFiled:
                    folder = row.folderHeld == true ? "already filed in a folder picked by a word read from the file; a Trash row"
                        : "already filed in \(row.folderLabel ?? ""); a Trash row"
                case .needsPick:
                    if row.claudePick == true {
                        folder = "your pick: \(row.folderLabel ?? ""), not decided"
                    } else if row.choices.contains(where: { $0.fromFile == true }) && row.folderHeld == true {
                        folder = "needs their pick between \(row.choices.count) folders, some picked by words read from the file; on their card, not sent to you"
                    } else {
                        folder = "needs their pick: " + row.choices.map(\.label).joined(separator: " or ")
                    }
                case .folder(let label):
                    if row.folderHeld == true {
                        folder = "a folder picked by a word read from the file; on their card, not sent to you"
                    } else if case .move(_, let to) = row.change, made.contains(to) {
                        folder = (row.claudePick == true ? "your new folder: " : "new folder: ") + label
                    } else {
                        folder = (row.claudePick == true ? "your pick: " : "") + label
                    }
                case .emptied:
                    continue
                }
                var notes: [String] = []
                if let name = row.newName {
                    notes.append(namesShared && row.nameHeld != true ? "renamed to \(name)" : "a new name made on their Mac, not sent to you")
                }
                // "Kept as …" spells the name a move lands under, which can be the held one.
                let nameGoes = row.newName == nil || (namesShared && row.nameHeld != true)
                notes += (row.note ?? "").components(separatedBy: " · ").filter { !$0.isEmpty && (nameGoes || !$0.hasPrefix("Kept as ")) }
                if row.claudeAgrees == true { notes.append("Refine kept this folder") }
                if let refusal = row.refusal { notes.append("can’t: " + refusal) }
                lines.append([handle(row.change.path), folder, row.confidence ?? "", row.ticked ? "ticked" : "not ticked",
                              notes.joined(separator: " · ")].map(AskClaudeScreenCard.escape).joined(separator: "|"))
                if let s = row.namedSiblings, row.folderHeld != true, row.claudePick != true {
                    siblings.append("For \(handle(row.change.path)): the folders in \(AskClaudeScreenCard.escape(s.label)) are named \(s.names.map(AskClaudeScreenCard.escape).joined(separator: ", ")).")
                }
            }
        }
        if !siblings.isEmpty {
            lines += siblings
            lines.append("If those are one kind of name (places, people, companies, cars) and the file plainly belongs to a new one of that kind, call where_to_file with new_folders for it: its handle and the name. It goes on this card, first, with the closest folder as the other choice. Otherwise don’t.")
        }
        if let left = plan.leftHere { lines.append(AskClaudeScreenCard.escape(left)) }
        if let remaining = plan.remaining, !remaining.isEmpty {
            lines.append("\(remaining.count) more of the files they selected aren’t on this card; its Next button brings them on a new card.")
        }
        if !plan.refinable.isEmpty {
            lines.append("The card has Refine \(plan.refinable.count) with Claude…, which opens Organize for the rows that aren’t sure and shows the price before anything is sent.")
        }
        lines.append("Say in a line or two how many have a sure home and what needs their pick. Don’t list the files: the card shows them. Don’t guess what isn’t sent.")
        return lines.joined(separator: "\n")
    }
}

extension AskClaudeLooseFiles.File {
    /// A file File with Claude was asked about (TE342), from what the pane knows of it.
    public init(selected path: String, name: String, size: Int?, modified: Date?) {
        self.init(path: path, name: name, size: size, modified: modified, added: nil)
    }
}
