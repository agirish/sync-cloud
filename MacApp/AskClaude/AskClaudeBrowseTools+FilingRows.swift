import Events
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
        /// The oldest survey's age in days, when one is old enough to miss folders made since.
        var staleDays: Int?
    }

    /// The rows for `files`, in order: a move or a Trash row per file, the folders the moves need
    /// made, then the emptied-folder row `emptied` names; each checked now, as a proposed card's
    /// are. Nil when stopped.
    /// - `preferring`: the place they named, absolute; it also picks the survey each file is
    ///   answered from.
    /// - `emptied`: the subfolders the rows' files would leave empty, from the paths on the card.
    /// - `selection`: File with Claude's card (TE342): a file no folder fits gets a row of its own
    ///   (decision NP), and each row keeps what Claude may be told of its folder and the
    ///   plain-name folders beside it.
    func filingRows(_ files: [AskClaudeLooseFiles.File], preferring: String?, _ ctx: Context, selection: Bool = false,
                    emptied: (Set<String>) -> [String] = { _ in [] }) async -> FilingRows? {
        var out = FilingRows()
        // TE327: new folders named like their siblings, by path, with what they are named like.
        var newHomes: [String: String] = [:]
        // The names the ticked moves above land under, by folder, in card order.
        var taking: [String: [String]] = [:]
        for file in files {
            // Stopped, or replaced by New Chat: no card.
            if Task.isCancelled { return nil }
            let answer = await ctx.whereToFile(file.path, preferring)
            if selection, let answer, answer.isStale(now: ctx.now()) {
                out.staleDays = max(out.staleDays ?? 0, answer.surveyAgeDays(now: ctx.now()) ?? 0)
            }
            guard let answer, case .suggested(let list) = answer.outcome, let best = list.first else {
                out.noHome += 1
                if selection {
                    let own = (file.path as NSString).deletingLastPathComponent
                    var row = AskClaudePlan.Row(id: out.rows.count, name: file.name, change: .move(from: file.path, toFolder: own),
                                                ticked: false, reason: AskClaudePlan.noFitReason)
                    row.noFit = true
                    (row.size, row.modified) = (file.size, file.modified)
                    row.fromLabel = Self.breadcrumb(own, sources: ctx.sources, fallback: (own as NSString).lastPathComponent)
                    out.rows.append(row)
                } else {
                    out.leftPaths.append(file.path)
                }
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
                                     isNew: s.isNew ? true : nil,
                                     fromFile: selection && s.evidenceToken != nil ? true : nil)
            }
            for s in list where s.isNew { newHomes[s.folder] = s.reason }
            let fromLabel = Self.breadcrumb((file.path as NSString).deletingLastPathComponent, sources: ctx.sources,
                                            fallback: ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            let label = choices[0].label
            // As where_to_file tells of one file: a folder a word on page 1 picked stays on their
            // card unless the file's folder shares without asking. Any of the row's folders: a
            // runner-up is named to Claude too (TE342).
            let held = selection && choices.contains { $0.fromFile == true } && !ctx.sharesFreely(file.path)
            // The plain-name folders beside its home, unless a folder page 1 picked is among them,
            // which their names would point at.
            let siblings: AskClaudePlan.Siblings? = selection ? answer.namedSiblings.flatMap { named in
                let pointsAtPage = choices.contains { $0.fromFile == true && ($0.path as NSString).deletingLastPathComponent == named.parent }
                guard !(pointsAtPage && !ctx.sharesFreely(file.path)) else { return nil }
                return AskClaudePlan.Siblings(label: Self.breadcrumb(named.parent, sources: ctx.sources, fallback: (named.parent as NSString).lastPathComponent),
                                              path: named.parent, names: named.names)
            } : nil
            // The same bytes already in its home is a copy to put in the Trash.
            let isCloudOnly = ctx.isCloudOnly
            if let twin = await Task.detached(priority: .userInitiated, operation: {
                AskClaudeLooseFiles.sameFile(as: file.path, in: best.folder, size: file.size, isCloudOnly: isCloudOnly)
            }).value {
                var row = AskClaudePlan.Row(id: out.rows.count, name: file.name, change: .trash(path: file.path, copyOf: twin), ticked: false,
                                            reason: "The same file is in \(label)", note: (twin as NSString).lastPathComponent == file.name ? nil : "As \((twin as NSString).lastPathComponent)",
                                            folderLabel: label, choices: choices, alreadyFiled: true)
                (row.size, row.modified, row.fromLabel) = (file.size, file.modified, fromLabel)
                if held { row.folderHeld = true }
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
            if held { row.folderHeld = true }
            row.namedSiblings = siblings
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
        Self.check(&out.rows, creating: Set(making), ctx)
        return out
    }

    /// Each row checked now, as a proposed card's are, with the folders `creating` counted as
    /// there: one that can't run says why and has no tick. A No Folder Fits row has nothing to check.
    static func check(_ rows: inout [AskClaudePlan.Row], creating: Set<String>, _ ctx: Context) {
        for index in rows.indices where rows[index].noFit != true {
            // A place in a hidden folder is refused before anything is checked on disk, so "already
            // there" can't say what a hidden folder holds.
            if let hidden = places(rows[index].change).first(where: ctx.isHidden) {
                rows[index].refusal = "\((hiddenEntry(hidden, ctx.hidden) as NSString).lastPathComponent) is hidden from Claude"
                rows[index].ticked = false
                continue
            }
            if let why = ctx.planRefusal(rows[index].change, creating) {
                rows[index].refusal = why
                rows[index].ticked = false
            }
        }
    }

    // MARK: File with Claude's card for a selection (TE342)

    /// where_to_file with handles: every file they selected on one card, grouped by the folder each
    /// goes to, with one Apply and one Undo. A card already waiting for these same files is
    /// updated in place, keeping what they did on it.
    func fileSelection(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        if let entries = call.input["new_folders"]?.arrayValue, !entries.isEmpty {
            return claudeFolders(entries, into: call.string("into"), ctx, handles)
        }
        let asked = call.strings("handles") ?? []
        let paths = asked.compactMap { handles.path(for: $0) }
        return await fileSelection(paths, unknown: asked.count - paths.count, into: call.string("into"), ctx, handles)
    }

    /// The card for `paths`, the files they selected, in order: also where where_to_file's one
    /// handle goes when the question is File with Claude's (decision OB).
    func fileSelection(_ paths: [String], unknown: Int, into: String?, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        // Each file once, in the order given; what can't be filed is counted, never a reason to
        // refuse the rest.
        var files: [AskClaudeLooseFiles.File] = []
        var hidden = 0, folders = 0, gone = 0
        let notesFile = AskClaudeNotes.defaultFileURL().path
        for path in paths {
            guard !files.contains(where: { $0.path == path }) else { continue }
            if ctx.isHidden(path) || path == notesFile { hidden += 1; continue }
            // A selection is files on disk, as a folder's loose files are: read there when the pane
            // hasn't loaded them.
            guard let node = ctx.node(path) ?? statDisk(path) ?? AskClaudeDisk.node(atPath: path) else { gone += 1; continue }
            if node.isDirectory { folders += 1; continue }
            files.append(AskClaudeLooseFiles.File(selected: path, name: node.name, size: node.fileSize, modified: node.modificationDate))
        }
        // What the card says it left out, and what Claude is told besides.
        var leftOut: [String] = []
        if hidden > 0 { leftOut.append("\(hidden) hidden from Claude") }
        if folders > 0 { leftOut.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if gone > 0 { leftOut.append("\(gone) no longer there") }
        var toClaude: [String] = []
        if folders > 0 { toClaude.append("Folders aren’t filed here: file_loose_files files a folder’s loose files.") }
        if unknown > 0 { toClaude.append("\(unknown) handle\(unknown == 1 ? "" : "s") this chat never gave \(unknown == 1 ? "was" : "were") left out.") }
        guard !files.isEmpty else {
            return AskClaudeToolOutcome(result: (["No file to file" + (leftOut.isEmpty ? "." : ": " + leftOut.joined(separator: ", ") + ".")] + toClaude)
                                            .joined(separator: "\n"),
                                        isError: true, step: "No file to file")
        }
        // A place they named: as where_to_file takes one.
        var place: String?
        if let into = into?.trimmingCharacters(in: .whitespaces).nonEmptyText {
            guard let resolved = Self.place(into, ctx) else {
                return AskClaudeToolOutcome(result: "There’s no folder called \(into) in their folder survey or their sources. Ask where they mean.",
                                            isError: true, step: "No place called \(into)", logStep: "No place called that (no match, \(into.count) characters)")
            }
            if ctx.isHidden(resolved) { return hiddenFolder() }
            place = resolved
            // A place the survey doesn't cover is said once, for the whole card.
            if let survey = ctx.survey(for: resolved), !FileSyncManager.isAtOrUnderSurvey(resolved, root: survey) {
                let surveyLabel = Self.breadcrumb(survey, sources: ctx.sources, fallback: (survey as NSString).lastPathComponent)
                let placeLabel = Self.breadcrumb(resolved, sources: ctx.sources, fallback: (resolved as NSString).lastPathComponent)
                let card = AskClaudeFilingCard(fileName: "\(files.count) file\(files.count == 1 ? "" : "s")", filePath: files[0].path,
                                               kind: .outside(surveyed: surveyLabel), place: placeLabel)
                let survey = AskClaudeScreenCard.escape(surveyLabel), place = AskClaudeScreenCard.escape(placeLabel)
                return AskClaudeToolOutcome(result: "Their folder survey covers \(survey) only, and \(place) isn’t in it, so there are no conventions of theirs to sort by there. Say so, and offer to file them into \(survey) by how they file instead (call where_to_file again with their handles and no into), or to move them all into one folder of \(place) they name, with propose_changes. Don’t guess a folder.",
                                            step: "\(placeLabel) is outside the folder survey", filing: card)
            }
        }
        guard files.contains(where: { ctx.survey(for: $0.path) != nil }) || place.flatMap(ctx.survey) != nil else {
            let card = AskClaudeFilingCard(fileName: files[0].name, filePath: files[0].path, kind: .noProfile)
            return AskClaudeToolOutcome(result: AskClaudeFiling.result(card, sharesFreely: false), step: "No folder survey to go by", filing: card)
        }
        // More than a card holds: the sure ones first, as the loose-files card takes them (TE343).
        var page = files
        var remaining: [String] = []
        if files.count > Self.looseFilesPerCard {
            var ahead: [String: AskClaudeLooseFiles.Ahead] = [:]
            let rank = ctx.rankAhead ?? ctx.whereToFile
            for file in files.prefix(AskClaudeLooseFiles.lookAhead) {
                if Task.isCancelled { return Self.stoppedSelection() }
                ahead[file.path] = Self.ahead(await rank(file.path, place), of: file.path)
            }
            let ordered = AskClaudeLooseFiles.sureFirst(files, path: \.path, ahead: ahead)
            page = Array(ordered.prefix(Self.looseFilesPerCard))
            remaining = ordered.dropFirst(Self.looseFilesPerCard).map(\.path)
        }
        guard let built = await filingRows(page, preferring: place, ctx, selection: true) else { return Self.stoppedSelection() }
        let folderLabels = Set(page.map { Self.folderLabel(of: $0.path, ctx) })
        let selectedIn = folderLabels.count == 1 ? "selected in \(folderLabels.first ?? "")" : "selected in \(folderLabels.count) folders"
        let subtitle = selectedIn + (place.map { " · into " + Self.breadcrumb($0, sources: ctx.sources, fallback: ($0 as NSString).lastPathComponent) } ?? "")
        var left = leftOut
        if built.atHome > 0 { left.insert("\(built.atHome) already in \(built.atHome == 1 ? "its" : "their") folder", at: 0) }
        let count = built.rows.filter(AskClaudePlan.isFile).count
        var plan = AskClaudePlan(title: count == 1 ? "File This File" : "File \(count) Files", subtitle: subtitle, rows: built.rows,
                                 leftHere: left.isEmpty ? nil : "Left here: " + left.joined(separator: ", "),
                                 more: remaining.isEmpty ? nil : "\(remaining.count) more selected")
        plan.selection = true
        if !remaining.isEmpty {
            plan.remaining = remaining
            plan.nextLabel = "Next \(min(remaining.count, Self.looseFilesPerCard))"
            plan.nextAsk = "File these"
        }
        plan.staleDays = built.staleDays
        // Refine N with Claude… (decision NQ): only where Organize would answer these rows from
        // the survey the card used, and for one folder, which is what one Organize scan covers.
        let unsureFolders = Set(plan.rows.filter { row in
            guard case .move = row.change, row.noFit != true else { return false }
            return row.confidence != AskClaudeFiling.label(.high)
        }.map { (($0.change.path as NSString).deletingLastPathComponent) })
        if ctx.canRefineFiling, place == nil, unsureFolders.count == 1, let folder = unsureFolders.first,
           let survey = ctx.survey(for: folder), let organizes = ctx.organizeInto(folder),
           FilingScorecard.canonical(survey) == FilingScorecard.canonical(organizes) {
            plan.refineFolder = folder
        }
        plan.tickNeededFolders()
        plan.noteLandingNames()
        // Names go to Claude only where every file's folder shares freely (decision NF).
        let allShare = page.allSatisfy { ctx.sharesFreely($0.path) }
        if !plan.namedRows.isEmpty || built.namesOff != nil {
            let shares = allShare && !plan.rows.contains { $0.nameHeld == true }
            plan.names = AskClaudeHeldNames(shared: shares, sharedBy: shares && folderLabels.count == 1 ? folderLabels.first : nil,
                                            unavailable: built.namesOff)
        }
        // Apply and Undo tell Claude counts when it wasn't given every row's folder.
        if plan.rows.contains(where: { $0.folderHeld == true }) || plan.names?.shared == false { plan.rowsHeld = true }
        // A card still waiting for these same files takes this one's place, with what they did on it.
        var replacing: UUID?
        // By the files on the card: one already in its folder has no row on either.
        let onCard = Set(plan.rows.filter(AskClaudePlan.isFile).map(\.change.path))
        if !onCard.isEmpty, let open = ctx.openSelectionCard(onCard), Set(open.plan.rows.filter(AskClaudePlan.isFile).map(\.change.path)) == onCard {
            plan.carryPicks(from: open.plan)
            // A carried folder was checked for the other card: checked again here.
            for index in plan.rows.indices { plan.rows[index].refusal = nil }
            let creating = Set(plan.rows.compactMap { row -> String? in
                if case .newFolder = row.change { return row.change.path }
                return nil
            })
            Self.check(&plan.rows, creating: creating, ctx)
            plan.tickNeededFolders()
            replacing = open.id
        }
        let sure = plan.rows.filter { $0.ticked && AskClaudePlan.isFile($0) }.count
        Logger.shared.info("Ask Claude filing card: \(page.count) selected file\(page.count == 1 ? "" : "s"), \(sure) ticked, \(remaining.count) for Next"
                           + (replacing == nil ? "" : "; updated the card waiting for them"))
        plan.replaces = replacing
        let told = AskClaudeSelectionCard.result(plan, handle: { handles.existingHandle(for: $0) ?? "?" },
                                                 namesShared: plan.names?.shared ?? allShare)
        return AskClaudeToolOutcome(result: ([told] + toClaude).joined(separator: "\n"),
                                           step: "Found homes for \(plan.rows.filter { AskClaudePlan.isFile($0) && $0.noFit != true }.count) of \(page.count) files · \(sure) sure",
                                           plan: plan)
    }

    /// where_to_file's new_folders (decision NR): Claude's folder leads a row of the card waiting
    /// for that file. Its parent is the one the file's own siblings are in, or `in` (where they
    /// asked for it); the name is checked here, and a folder hidden from Claude is refused before
    /// anything on disk is looked at, so the answer can't say what one holds.
    func claudeFolders(_ entries: [JSONFragment], into: String?, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome {
        var lines: [String] = []
        var card: (id: UUID, plan: AskClaudePlan)?
        var made = 0
        for entry in entries {
            let handle = entry["handle"]?.stringValue ?? ""
            let name = (entry["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let file = handles.path(for: handle) else { lines.append("\(handle): no such handle in this chat."); continue }
            if let problem = AskClaudePlan.folderNameProblem(name) { lines.append("\(handle): \(problem)"); continue }
            // The card already updated above, or the newest one waiting for this file.
            let target = card.flatMap { $0.plan.rows.contains { $0.change.path == file } ? $0 : nil } ?? ctx.openSelectionCard([file])
            guard var open = target else {
                lines.append("\(handle): it isn’t on a card waiting for Apply. For one file, offer the new folder and the move with propose_changes.")
                continue
            }
            if let other = card, other.id != open.id {
                lines.append("\(handle): it’s on another card; give its new folder in a call of its own.")
                continue
            }
            guard let row = open.plan.rows.first(where: { $0.change.path == file && AskClaudePlan.isFile($0) }) else { continue }
            let named = (entry["in"]?.stringValue ?? into)?.trimmingCharacters(in: .whitespaces).nonEmptyText
            let parent: String
            if let named {
                guard let resolved = Self.place(named, ctx) else {
                    lines.append("\(handle): there’s no folder called \(named) in their folder survey or their sources.")
                    continue
                }
                parent = resolved
            } else if let siblings = row.namedSiblings, row.folderHeld != true {
                parent = siblings.path
            } else {
                lines.append("\(handle): its folders aren’t named one kind of name, so give in: where they asked for it.")
                continue
            }
            let folder = (parent as NSString).appendingPathComponent(name)
            // Hidden first, with the same words as any refused name.
            guard !ctx.isHidden(parent), !ctx.isHidden(folder) else {
                lines.append("\(handle): a folder can’t be made there.")
                continue
            }
            let existing = AskClaudePlan.existingFolder(folder)
            let path = existing ?? folder
            let label = Self.breadcrumb(path, sources: ctx.sources, fallback: (path as NSString).lastPathComponent)
            let reason = existing != nil ? "Claude’s pick" : row.namedSiblings.map { "A new folder named like \($0.names.prefix(3).joined(separator: ", "))" } ?? "A new folder you asked for"
            if let refusal = open.plan.claudeFolder(forFile: file, folder: path, label: label, reason: reason) {
                lines.append("\(handle): \(refusal)")
                continue
            }
            made += 1
            lines.append("\(handle): \(existing != nil ? "now goes to \(label), already there" : "now goes to a new folder, \(label), first on its row; the closest folder is its other choice"). Unticked until they tick it.")
            card = open
        }
        guard var updated = card else {
            return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), isError: true, step: "No new folder added",
                                        logStep: "No new folder added (\(entries.count) asked)")
        }
        // Each folder the card now makes, checked as the card's own rows are.
        let creating = Set(updated.plan.rows.compactMap { row -> String? in
            if case .newFolder = row.change { return row.change.path }
            return nil
        })
        for index in updated.plan.rows.indices where updated.plan.rows[index].forMoves == true && updated.plan.rows[index].refusal == nil {
            if let why = ctx.planRefusal(updated.plan.rows[index].change, creating) {
                updated.plan.rows[index].refusal = why
                updated.plan.rows[index].ticked = false
            }
        }
        updated.plan.replaces = updated.id
        lines.append("Say in a line what changed on their card. Nothing is made until they Apply.")
        // The step names no folder: the name is Claude's words, or theirs.
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: "Put \(made) new folder\(made == 1 ? "" : "s") on the card",
                                    plan: updated.plan)
    }

    private static func stoppedSelection() -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "No card: they stopped the question.", isError: true, step: "Stopped filing")
    }
}

private extension String {
    var nonEmptyText: String? { isEmpty ? nil : self }
}
