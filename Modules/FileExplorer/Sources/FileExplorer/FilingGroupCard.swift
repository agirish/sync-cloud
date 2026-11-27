import SwiftUI
import Sync
import Design

/// Every statement going to one account folder, as one card: "Charles Schwab ••9312 · 10
/// statements", filed with one click (design §5.1, cards mockup v6). What File N does is always on
/// the card: From where, Moves to where, the folders it makes, the dates and the evidence, and what
/// it leaves (copies already filed, duplicates in the inbox). Its files are rows to look at.
struct FilingGroupCard: View {
    let group: FilingCardGroup
    let densityMetrics: ListDensityMetrics
    let onFile: () -> Void
    /// Its File N is running: the button says "Filing…" and the card's buttons wait.
    var isFiling = false
    let onChooseFolder: () -> Void
    let onTrashCopies: ([FilingSuggestion]) -> Void
    /// Type the whole group's home in full, offered when its home creates folders.
    var pathEditor: FilingPathEditorHooks? = nil
    @State private var editingPath = false
    /// What Choose a Folder… would teach.
    var rememberAccount: FilingRememberAccount? = nil
    /// The account sits in an archive and these are newer than anything in it: File N files into
    /// the archive, and this moves the account out first. nil hides it.
    var onMoveOutOfArchive: (() -> Void)? = nil
    /// The archive's own name, for "File N in Archive".
    var archiveName: String = "Archive"
    /// File Once Here, when the statements name other accounts too.
    var onFileOnce: ((FilingPreference.Scope?) -> Void)? = nil
    /// What File N copies into now, under the preferences as they stand.
    var copies: [FilingCopy] = []
    /// The folder the scan walked, which "From" is relative to.
    var scannedRoot: String? = nil
    /// What the file rows show and do.
    var rowHooks = FilingFileRowsHooks()

    /// The list's own answer to "too narrow for the label column"; nil measures the card itself.
    var isNarrow: Bool? = nil
    @State private var expanded: Bool? = nil
    /// The clicked row: the line's Quick Look and Trash act on that one file.
    @State private var selectedRow: String?
    @State private var measuredNarrow = false
    private var narrow: Bool { isNarrow ?? measuredNarrow }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appFontScale) private var scale
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    /// Shown open when it is short enough to read at a glance.
    private var isExpanded: Bool { expanded ?? (group.members.count <= 3) }

    /// Below this a card's route labels sit above their paths and the new names under the files'.
    static let narrowWidth: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FilingGroupText.titleText(group, scale: scale)
                        .scaledFont(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    FilingRouteGrid(lines: FilingRouteText.lines(members: group.members, destination: group.destination,
                                                                 scannedRoot: scannedRoot, copies: copies),
                                    narrow: narrow, accent: hueAccent)
                    if densityMetrics.showsSecondaryDetail || group.destination.confidence != .high {
                        Text(FilingGroupText.why(group))
                            .scaledFont(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Claude's group: the same pill its files had as cards of their own.
                    if group.account == nil {
                        Pill(.mini, tint: hueAccent, systemImage: "sparkles", text: "AI suggestion")
                    }
                    // With the rows folded away, the names File N gives still show, at every density.
                    if !isExpanded, let renaming = FilingGroupText.renaming(group) {
                        Text(renaming)
                            .scaledFont(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !group.alreadyFiled.isEmpty || !group.copies.isEmpty { leftBehindRow }
                }
                Spacer(minLength: 0)
            }
            if isExpanded {
                Divider()
                FilingFileRows(members: group.members, inGroup: true, narrow: narrow, accent: hueAccent, hooks: rowHooks,
                               selected: $selectedRow)
            }
            if group.toFile.isEmpty {
                // Every member is already filed or a copy: nothing for File N to move.
                nothingToFileRow
            } else {
                // One line at every width: the right half folds into ⋯ first, then the left half's
                // lesser buttons, so the line never outgrows the column beside Ask Claude.
                ViewThatFits(in: .horizontal) {
                    actionLine(level: 0)
                    actionLine(level: 1)
                    actionLine(level: 2)
                    actionLine(level: 3)
                }
            }
            if let rememberAccount { FilingRememberAccountRow(remember: rememberAccount) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, max(densityMetrics.cardHeaderVerticalPadding, 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowWidth } action: { measuredNarrow = $0 }
        .lensCard()
        // While its File runs: dimmed, and its buttons wait, so a second click can't land.
        .opacity(isFiling ? 0.72 : 1)
        .disabled(isFiling)
        .designAnimation(.easeOut(duration: 0.2), value: isFiling)
        .popover(isPresented: $editingPath, arrowEdge: .bottom) {
            if let pathEditor {
                FilingPathEditor(hooks: pathEditor) { editingPath = false }
                    .presentedNativeControlAccent()
            }
        }
    }

    /// The action line (cards mockup v8). Left: File N, Choose a Folder…, Edit Path…, the archive
    /// offer, File Once Here and Show Files. Right: ``FilingCardFileActions``, acting on the selected
    /// row, or with none selected offering Open Folder. Level 1 folds the left half's lesser buttons
    /// into ⋯, so Quick Look stays in sight; level 2 drops the right half's words; level 3 folds it
    /// in too.
    private func actionLine(level: Int) -> some View {
        HStack(spacing: 9) {
            Button(action: onFile) {
                if isFiling {
                    FilingBusyLabel()
                } else {
                    Label(FilingGroupText.fileButton(group) + (onMoveOutOfArchive == nil ? "" : " in \(archiveName)"),
                          systemImage: "arrow.right.circle")
                }
            }
            .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
            .chromeHover().lockedDuringRun()
            Button(action: onChooseFolder) { Label("Choose a Folder…", systemImage: "folder") }
                .controlSize(.small).lockedDuringRun()
            if level == 0 {
                if pathEditor != nil {
                    Button("Edit Path…") { editingPath = true }
                        .controlSize(.small)
                        .help("Type where these go, anywhere in your folders; missing folders are made when you file")
                }
                if let onMoveOutOfArchive {
                    Button(action: onMoveOutOfArchive) { Label("Move Out of \(archiveName), Then File", systemImage: "archivebox") }
                        .controlSize(.small).lockedDuringRun()
                        .help("These are newer than anything in the account, so it looks live again: move its folder beside the archive, then file them. ⌘Z undoes both.")
                }
                showFilesButton
            }
            if let onFileOnce, !copies.isEmpty { FilingFileOnceMenu(copies: copies, onFileOnce: onFileOnce) }
            Spacer(minLength: 8)
            FilingCardFileActions(target: selectedMember,
                                  folder: FilingRouteText.commonFolder(group.members.map { ($0.filePath as NSString).deletingLastPathComponent }),
                                  destinationFolder: FilingRouteText.deepestExisting(group.destination.path),
                                  hooks: rowHooks, folded: level == 3, labeled: level < 2,
                                  foldedItems: level >= 1 ? foldedLesser : [])
        }
    }

    /// The row the card's line acts on, while it is still one of the card's.
    private var selectedMember: FilingSuggestion? {
        Self.target(members: group.members, selected: selectedRow, expanded: isExpanded)
    }

    /// The file a group card's Quick Look and Trash act on: the selected row, only while it is still
    /// a member and the rows are showing. nil offers Open Folder alone.
    nonisolated static func target(members: [FilingSuggestion], selected: String?, expanded: Bool) -> FilingSuggestion? {
        expanded ? members.first { $0.id == selected } : nil
    }

    /// The left half's lesser buttons, as ⋯ items on the narrowest line.
    private var foldedLesser: [FilingFoldedItem] {
        var out: [FilingFoldedItem] = []
        if pathEditor != nil { out.append(FilingFoldedItem(title: "Edit Path…", systemImage: "pencil") { editingPath = true }) }
        if let onMoveOutOfArchive {
            out.append(FilingFoldedItem(title: "Move Out of \(archiveName), Then File", systemImage: "archivebox",
                                        action: onMoveOutOfArchive))
        }
        out.append(FilingFoldedItem(title: isExpanded ? "Hide Files" : "Show \(group.members.count) Files",
                                    systemImage: "list.bullet") { toggleExpanded() })
        return out
    }

    private var showFilesButton: some View {
        Button { toggleExpanded() } label: {
            Text(isExpanded ? "Hide Files" : "Show \(group.members.count) Files")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .accessibilityLabel(isExpanded ? "Hide the \(group.members.count) files" : "Show the \(group.members.count) files")
    }

    private func toggleExpanded() {
        withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) { expanded = !isExpanded }
    }

    /// Nothing left to move: what is in the folders already, and the proven copies to the Trash.
    private var nothingToFileRow: some View {
        HStack(spacing: 9) {
            let copies = FilingGroupText.removable(group)
            if !copies.isEmpty {
                Button("Move \(copies.count) to Trash") { onTrashCopies(copies) }
                    .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                    .lockedDuringRun()
                    .help(FilingGroupText.trashHelp(group))
            }
            showFilesButton
            Spacer(minLength: 8)
            // The same look as every card: to see the copies before they go.
            FilingCardFileActions(target: selectedMember,
                                  folder: FilingRouteText.commonFolder(group.members.map { ($0.filePath as NSString).deletingLastPathComponent }),
                                  destinationFolder: FilingRouteText.deepestExisting(group.destination.path),
                                  hooks: rowHooks)
        }
    }

    private var leftBehindRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.on.doc.fill").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.caution)
            Text(FilingGroupText.leftBehind(group))
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            let copies = FilingGroupText.removable(group)
            if !group.toFile.isEmpty, !copies.isEmpty {
            Button("Move \(copies.count) to Trash") { onTrashCopies(copies) }
                .buttonStyle(.hoverAffordance(.inline))
                .scaledFont(.system(size: 11))
                .lockedDuringRun()
                .help(FilingGroupText.trashHelp(group))
            }
        }
    }
}

/// The group card's words, apart so they can be tested.
enum FilingGroupText {
    /// The bank's name; for Claude's group, the reason its members share ("Fidelity statement").
    static func bank(_ g: FilingCardGroup) -> String {
        guard let account = g.account else { return g.reason ?? "Suggested by Claude" }
        return account.institutionName.isEmpty ? titleCased(account.institution) : account.institutionName
    }

    /// `charles schwab` as `Charles Schwab`.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func noun(_ g: FilingCardGroup) -> String {
        // Claude's group: its reason already says what they are ("AT&T bill · 4 files").
        guard let account = g.account else { return "file" }
        switch account.kind {
        case .statement: return "statement"
        case .taxForm: return "tax form"
        case .other: return "document"
        }
    }

    /// "American Express ••5652 · 2 statements"; for Claude's group, "Fidelity statement · 6 files".
    static func title(_ g: FilingCardGroup) -> String {
        let n = g.members.count
        let ending = g.account.map { " ••" + $0.ending } ?? ""
        return "\(bank(g))\(ending) · \(n) \(noun(g))\(n == 1 ? "" : "s")"
    }

    /// ``title(_:)`` with the ending set in the muted monospaced face, at the app's text `scale`:
    /// the run's own font overrides the title's `scaledFont`.
    static func titleText(_ g: FilingCardGroup, scale: CGFloat) -> Text {
        let n = g.members.count
        guard let account = g.account else { return Text(title(g)) }
        return Text(bank(g) + " ")
            + Text("••" + account.ending).scaledFont(.system(size: 12.5, weight: .medium, design: .monospaced), scale: scale).foregroundStyle(.secondary)
            + Text(" · \(n) \(noun(g))\(n == 1 ? "" : "s")")
    }

    static func why(_ g: FilingCardGroup) -> String {
        let n = g.members.count
        // Claude's group: no number on the page backs it, so it says whose suggestion it is.
        if g.account == nil {
            let evidence = "Claude suggested this folder for " + (n == 2 ? "both" : "all \(n)")
            var s = g.dateRange.map { dates($0.first, $0.last, count: n) + " · " + evidence } ?? evidence
            if g.destination.confidence != .high { s += " · check before filing" }
            return s
        }
        // A new account: say so, and where its name came from.
        if g.destination.createsAccountFolder, let reason = g.destination.reasons.first {
            var s = reason
            if let r = g.dateRange { s += " · " + range(r.first, r.last) }
            return s + " · check before filing"
        }
        // The dates covered, then the evidence: "Jan and Oct 2026 · account number on page 1 of both".
        let evidence = "account number on page 1 of " + (n == 2 ? "both" : "all \(n)")
        var s = g.dateRange.map { dates($0.first, $0.last, count: n) + " · " + evidence } ?? evidence.prefix(1).uppercased() + evidence.dropFirst()
        if g.destination.confidence != .high { s += " · check before filing" }
        return s
    }

    /// Two statements' months as "Jan and Oct 2026"; more as a range.
    static func dates(_ a: DocumentFacts.Period, _ b: DocumentFacts.Period, count: Int) -> String {
        let m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard count == 2, a.year == b.year, a.month != b.month else { return range(a, b) }
        return "\(m[a.month - 1]) and \(m[b.month - 1]) \(a.year)"
    }

    static func range(_ a: DocumentFacts.Period, _ b: DocumentFacts.Period) -> String {
        let m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if a == b || (a.year == b.year && a.month == b.month) { return "\(m[a.month - 1]) \(a.year)" }
        if a.year == b.year { return "\(m[a.month - 1])–\(m[b.month - 1]) \(a.year)" }
        return "\(m[a.month - 1]) \(a.year) – \(m[b.month - 1]) \(b.year)"
    }

    /// "Each takes a new name, like 2026-01-29.pdf", "3 of 10 take new names, like …", or nil when
    /// every file keeps its own.
    static func renaming(_ g: FilingCardGroup) -> String? {
        let renamed = g.toFile.compactMap { s in s.best?.proposedName.flatMap { $0 == s.fileName ? nil : $0 } }
        guard let sample = renamed.first else { return nil }
        if renamed.count == 1, g.toFile.count == 1 { return "Takes a new name: \(sample)" }
        return renamed.count == g.toFile.count ? "Each takes a new name, like \(sample)"
            : "\(renamed.count) of \(g.toFile.count) take new names, like \(sample)"
    }

    static func fileButton(_ g: FilingCardGroup) -> String {
        (g.destination.createsAccountFolder ? "Create and File " : "File ") + "\(g.toFile.count)"
    }

    /// What Trash may take: the copies proven the same file as their twin, byte for byte. One
    /// matched by its page text alone may be the signed or filled-in copy, so it stays.
    static func removable(_ g: FilingCardGroup) -> [FilingSuggestion] {
        (g.alreadyFiled + g.copies).filter(\.removalProven)
    }

    /// Where the copies' twins are, so Trash is never a blind click.
    static func trashHelp(_ g: FilingCardGroup) -> String {
        let folders = Set(removable(g).flatMap(\.alreadyFiledAt))
        let whereFiled = folders.isEmpty ? "" : " Already filed in " + folders.sorted().joined(separator: ", ") + "."
        return "Moves the copies that are the same file, byte for byte, to the Trash; ⌘Z puts them back." + whereFiled
    }

    static func leftBehind(_ g: FilingCardGroup) -> String {
        if g.toFile.isEmpty {
            let n = g.members.count
            return (n == 1 ? "It is already in your folders, or a copy of a file that is."
                           : "All \(n) are already in your folders, or copies of files that are.") + textOnly(g)
        }
        var parts: [String] = []
        let filed = g.alreadyFiled.count
        if filed > 0 { parts.append("\(filed) \(filed == 1 ? "is" : "are") already in your folders") }
        let copies = g.copies.count
        if copies > 0 { parts.append("\(copies) \(copies == 1 ? "is a copy" : "are copies") of another file here") }
        return parts.joined(separator: "; ") + ". Filing the other \(g.toFile.count) leaves \(filed + copies == 1 ? "it" : "them") where \(filed + copies == 1 ? "it is" : "they are")."
            + textOnly(g)
    }

    /// The caveat for matches on page text alone, which Trash doesn't offer: "" when there are none.
    static func textOnly(_ g: FilingCardGroup) -> String {
        let n = g.alreadyFiled.count + g.copies.count - removable(g).count
        guard n > 0 else { return "" }
        return n == 1 ? " One matches by its text only, not as the same file, so compare before removing it."
                      : " \(n) match by their text only, not as the same files, so compare before removing them."
    }
}
