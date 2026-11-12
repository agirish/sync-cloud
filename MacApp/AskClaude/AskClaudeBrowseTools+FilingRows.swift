import Foundation

import Sync

/// A filing card's rows, one per file, placed by their folder survey as where_to_file places one.
/// Shared by the loose-files card and File with Claude's card for a selection (TE342).
extension AskClaudeBrowseTools {

    struct FilingRows {
        var rows: [AskClaudePlan.Row] = []
        /// Files no folder fits, and files already in their first folder.
        var noHome = 0
        var atHome = 0
        /// The files read in full and left where they are, for Next to skip.
        var leftPaths: [String] = []
        /// Why Apple Intelligence couldn't name files, when it couldn't.
        var namesOff: String?
    }

    /// The rows for `files`, in order: a move or a Trash row per file, the folders the moves need
    /// made, then the emptied-folder row `emptied` names; each checked now, as a proposed card's
    /// are. Nil when stopped.
    /// - `preferring`: the place they named, absolute; it also picks the survey each file is
    ///   answered from.
    /// - `emptied`: the subfolders the rows' files would leave empty, from the paths on the card.
    func filingRows(_ files: [AskClaudeLooseFiles.File], preferring: String?, _ ctx: Context,
                    emptied: (Set<String>) -> [String] = { _ in [] }) async -> FilingRows? {
        var out = FilingRows()
        // TE327: new folders named like their siblings, by path, with what they are named like.
        var newHomes: [String: String] = [:]
        // The names the ticked moves above land under, by folder, in card order.
        var taking: [String: [String]] = [:]
        for file in files {
            // Stopped, or replaced by New Chat: no card.
            if Task.isCancelled { return nil }
            guard let answer = await ctx.whereToFile(file.path, preferring), case .suggested(let list) = answer.outcome,
                  let best = list.first else {
                out.noHome += 1
                out.leftPaths.append(file.path)
                continue
            }
            // Already in its home, under this spelling or another (iCloud's Documents is a link
            // to ~/Documents): nothing to do, and no copy of it to trash.
            if PathBoundary.resolvesToSameDirectory((file.path as NSString).deletingLastPathComponent, best.folder, caseSensitive: false) {
                out.atHome += 1
                out.leftPaths.append(file.path)
                continue
            }
            // The card is on their Mac, so it says which word decided it; what Claude is told
            // carries no reason at all.
            let choices = list.map { s in
                AskClaudePlan.Choice(label: Self.breadcrumb(s.folder, sources: ctx.sources, fallback: s.relativePath),
                                     path: s.folder, confidence: AskClaudeFiling.label(s.confidence), reason: s.reason,
                                     isNew: s.isNew ? true : nil)
            }
            for s in list where s.isNew { newHomes[s.folder] = s.reason }
            let fromLabel = Self.breadcrumb((file.path as NSString).deletingLastPathComponent, sources: ctx.sources,
                                            fallback: ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            let label = choices[0].label
            // The same bytes already in its home is a copy to put in the Trash.
            let isCloudOnly = ctx.isCloudOnly
            if let twin = await Task.detached(priority: .userInitiated, operation: {
                AskClaudeLooseFiles.sameFile(as: file.path, in: best.folder, size: file.size, isCloudOnly: isCloudOnly)
            }).value {
                var row = AskClaudePlan.Row(id: out.rows.count, name: file.name, change: .trash(path: file.path, copyOf: twin), ticked: false,
                                            reason: "The same file is in \(label)", note: (twin as NSString).lastPathComponent == file.name ? nil : "As \((twin as NSString).lastPathComponent)",
                                            folderLabel: label, choices: choices, alreadyFiled: true)
                (row.size, row.modified, row.fromLabel) = (file.size, file.modified, fromLabel)
                out.rows.append(row)
                continue
            }
            // Its landing name (numbered when the name is taken) is noted once the card is built,
            // after the rows above it.
            var row = AskClaudePlan.Row(id: out.rows.count, name: file.name, change: .move(from: file.path, toFolder: best.folder),
                                        ticked: best.confidence == .high, confidence: AskClaudeFiling.label(best.confidence),
                                        reason: choices[0].reason,
                                        note: best.outsidePlace ? preferring.map { "Outside \(($0 as NSString).lastPathComponent)" } : nil,
                                        folderLabel: label, choices: choices)
            (row.size, row.modified, row.fromLabel) = (file.size, file.modified, fromLabel)
            row.offer = FilingScorecard.Offer(list, root: answer.root)
            // TE328: a badly named file is read on this Mac and named for its folder, with the
            // names the ticked rows above land under counted as there.
            if let named = await ctx.nameFile(file.path, choices.map(\.path), taking) {
                let proposal = named.names[best.folder]
                (row.newName, row.nameBasis) = (proposal?.name, proposal?.basis.line)
                // Decision NF: a name copied from a folder that asks first is held.
                if proposal?.basis.copiesFolder == true, !ctx.sharesFreely(best.folder) { row.nameHeld = true }
                (row.nameKept, row.nameFacts) = (named.outcome.keptReason, named.facts)
                out.namesOff = out.namesOff ?? named.unavailable
            }
            if row.ticked { taking[best.folder, default: []].append(row.newName ?? file.name) }
            out.rows.append(row)
        }
        // The last file's read may have been the one stopped.
        if Task.isCancelled { return nil }
        // Subfolders these files would leave empty, as one unticked Trash row.
        let emptiedFolders = emptied(Set(out.rows.map(\.change.path)))
        // A home not made yet (a saved rule's new month folder, "2026 › Oct"): the card makes it,
        // a row per folder, outermost first, ticked while a ticked move goes into it.
        var making: [String] = []
        for row in out.rows {
            guard case .move(_, let to) = row.change else { continue }
            var missing: [String] = []
            var folder = to
            while !folder.isEmpty, folder != "/", !FileManager.default.fileExists(atPath: folder), !making.contains(folder) {
                missing.insert(folder, at: 0)
                folder = (folder as NSString).deletingLastPathComponent
            }
            making += missing
        }
        for path in making {
            let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            var row = AskClaudePlan.Row(id: out.rows.count, name: "New folder “\(name)”", change: .newFolder(in: parent, name: name),
                                        ticked: false, reason: newHomes[path] ?? "For the files filed in it",
                                        folderLabel: Self.breadcrumb(parent, sources: ctx.sources, fallback: (parent as NSString).lastPathComponent))
            row.forMoves = true
            out.rows.append(row)
        }
        if !emptiedFolders.isEmpty {
            let names = emptiedFolders.map { "“\(($0 as NSString).lastPathComponent)”" }
            out.rows.append(AskClaudePlan.Row(id: out.rows.count, name: "Move \(emptiedFolders.count) emptied folder\(emptiedFolders.count == 1 ? "" : "s") to Trash",
                                              change: .trashIfEmptied(folders: emptiedFolders), ticked: false,
                                              reason: ListFormatter.localizedString(byJoining: names) + ", once their files are filed"))
        }
        // Each row checked now, as a proposed card's are, with the folders it makes counted
        // as there: one that can't run says why and has no tick, rather than failing at Apply.
        let creating = Set(making)
        for index in out.rows.indices {
            // A place in a hidden folder is refused before anything is checked on disk, so "already
            // there" can't say what a hidden folder holds.
            if let hidden = Self.places(out.rows[index].change).first(where: ctx.isHidden) {
                out.rows[index].refusal = "\((Self.hiddenEntry(hidden, ctx.hidden) as NSString).lastPathComponent) is hidden from Claude"
                out.rows[index].ticked = false
                continue
            }
            if let why = ctx.planRefusal(out.rows[index].change, creating) {
                out.rows[index].refusal = why
                out.rows[index].ticked = false
            }
        }
        return out
    }
}
