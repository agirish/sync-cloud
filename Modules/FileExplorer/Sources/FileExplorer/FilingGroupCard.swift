import SwiftUI
import Sync
import Design

/// Every statement going to one account folder, as one card: "Charles Schwab ••7863 · 10
/// statements", filed with one click (design §5.1, cards mockup v6). What File N does is always on
/// the card: From where, Moves to where, the folders it makes, the dates and the evidence, and what
/// it leaves (copies already filed, duplicates in the inbox). Its files are rows to look at.
struct FilingGroupCard: View {
    let group: FilingCardGroup
    let densityMetrics: ListDensityMetrics
    let onFile: () -> Void
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
    @State private var measuredNarrow = false
    private var narrow: Bool { isNarrow ?? measuredNarrow }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    FilingGroupText.titleText(group)
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
                    // With the rows folded away, the names File N gives still show, at every density.
                    if !isExpanded, let renaming = FilingGroupText.renaming(group) {
                        Text(renaming)
                            .scaledFont(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !group.alreadyFiled.isEmpty || !group.copies.isEmpty { leftBehindRow }
                }
                Spacer(minLength: 8)
                FilingConfidencePill(confidence: group.destination.confidence)
            }
            if isExpanded {
                Divider()
                FilingFileRows(members: group.members, inGroup: true, narrow: narrow, accent: hueAccent, hooks: rowHooks)
            }
            if group.toFile.isEmpty {
                // Every member is already filed or a copy: nothing for File N to move.
                nothingToFileRow
            } else {
                // Every button while it fits; below that, File N and Choose a Folder… with the rest
                // in ⋯, so the row never outgrows the narrow column beside Ask Claude.
                ViewThatFits(in: .horizontal) {
                    actionRow(compact: false)
                    actionRow(compact: true)
                }
            }
            if let rememberAccount { FilingRememberAccountRow(remember: rememberAccount) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, max(densityMetrics.cardHeaderVerticalPadding, 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowWidth } action: { measuredNarrow = $0 }
        .lensCard()
        .popover(isPresented: $editingPath, arrowEdge: .bottom) {
            if let pathEditor {
                FilingPathEditor(hooks: pathEditor) { editingPath = false }
                    .presentedNativeControlAccent()
            }
        }
    }

    /// File N, Choose a Folder…, Edit Path…, the archive offer, File Once Here and Show Files;
    /// compact puts all but the first two in ⋯.
    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: 9) {
            Button(action: onFile) {
                Label(FilingGroupText.fileButton(group) + (onMoveOutOfArchive == nil ? "" : " in \(archiveName)"),
                      systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
            .chromeHover().lockedDuringRun()
            Button(action: onChooseFolder) { Label("Choose a Folder…", systemImage: "folder") }
                .controlSize(.small).lockedDuringRun()
            if compact {
                Menu {
                    if pathEditor != nil { Button("Edit Path…") { editingPath = true } }
                    if let onMoveOutOfArchive {
                        Button("Move Out of \(archiveName), Then File", action: onMoveOutOfArchive)
                    }
                    Button(isExpanded ? "Hide Files" : "Show \(group.members.count) Files") { toggleExpanded() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions")
                .help("More actions")
                if let onFileOnce, !copies.isEmpty { FilingFileOnceMenu(copies: copies, onFileOnce: onFileOnce) }
            } else {
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
                if let onFileOnce, !copies.isEmpty { FilingFileOnceMenu(copies: copies, onFileOnce: onFileOnce) }
                showFilesButton
            }
        }
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

    /// Nothing left to move: what is in the folders already, and the copies to the Trash.
    private var nothingToFileRow: some View {
        HStack(spacing: 9) {
            let copies = group.alreadyFiled + group.copies
            Button("Move \(copies.count) to Trash") { onTrashCopies(copies) }
                .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                .lockedDuringRun()
                .help(FilingGroupText.trashHelp(group))
            showFilesButton
        }
    }

    private var leftBehindRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.on.doc.fill").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.caution)
            Text(FilingGroupText.leftBehind(group))
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            let copies = group.alreadyFiled + group.copies
            if !group.toFile.isEmpty {
            Button("Move \(copies.count) to Trash") { onTrashCopies(copies) }
                .buttonStyle(.hoverAffordance(.inline))
                .scaledFont(.system(size: 11))
                .lockedDuringRun()
                .help(FilingGroupText.trashHelp(group))
            }
        }
    }
}

/// A card's confidence, as the mockup draws it: High, Medium, or Pick a home.
struct FilingConfidencePill: View {
    let confidence: FilingConfidence?

    var body: some View {
        switch confidence {
        case .high?: Pill(.mini, tint: SemanticColor.success, systemImage: "checkmark", text: "High")
        case .medium?: Pill(.mini, tint: SemanticColor.warning, systemImage: "circle.dashed", text: "Medium")
        default: Pill(.mini, tint: SemanticColor.warning, systemImage: "questionmark", text: "Pick a home")
        }
    }
}

/// The group card's words, apart so they can be tested.
enum FilingGroupText {
    static func bank(_ g: FilingCardGroup) -> String {
        g.account.institutionName.isEmpty ? titleCased(g.account.institution) : g.account.institutionName
    }

    /// `charles schwab` as `Charles Schwab`.
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func noun(_ g: FilingCardGroup) -> String {
        switch g.account.kind {
        case .statement: return "statement"
        case .taxForm: return "tax form"
        case .other: return "document"
        }
    }

    /// "American Express ••2002 · 2 statements".
    static func title(_ g: FilingCardGroup) -> String {
        let n = g.members.count
        return "\(bank(g)) ••\(g.account.ending) · \(n) \(noun(g))\(n == 1 ? "" : "s")"
    }

    /// ``title(_:)`` with the ending set in the muted monospaced face.
    static func titleText(_ g: FilingCardGroup) -> Text {
        let n = g.members.count
        return Text(bank(g) + " ")
            + Text("••" + g.account.ending).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            + Text(" · \(n) \(noun(g))\(n == 1 ? "" : "s")")
    }

    static func why(_ g: FilingCardGroup) -> String {
        // A new account: say so, and where its name came from.
        if g.destination.createsAccountFolder, let reason = g.destination.reasons.first {
            var s = reason
            if let r = g.dateRange { s += " · " + range(r.first, r.last) }
            return s + " · check before filing"
        }
        // The dates covered, then the evidence: "Jan and Oct 2026 · account number on page 1 of both".
        let n = g.members.count
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

    /// Where the copies' twins are, so Trash is never a blind click.
    static func trashHelp(_ g: FilingCardGroup) -> String {
        let folders = Set(g.alreadyFiled.flatMap(\.alreadyFiledAt))
        let whereFiled = folders.isEmpty ? "" : " Already filed in " + folders.sorted().joined(separator: ", ") + "."
        return "Moves the copies to the Trash; ⌘Z puts them back." + whereFiled
    }

    static func leftBehind(_ g: FilingCardGroup) -> String {
        if g.toFile.isEmpty {
            let n = g.members.count
            return n == 1 ? "It is already in your folders, or a copy of a file that is."
                          : "All \(n) are already in your folders, or copies of files that are."
        }
        var parts: [String] = []
        let filed = g.alreadyFiled.count
        if filed > 0 { parts.append("\(filed) \(filed == 1 ? "is" : "are") already in your folders") }
        let copies = g.copies.count
        if copies > 0 { parts.append("\(copies) \(copies == 1 ? "is a copy" : "are copies") of another file here") }
        return parts.joined(separator: "; ") + ". Filing the other \(g.toFile.count) leaves \(filed + copies == 1 ? "it" : "them") where \(filed + copies == 1 ? "it is" : "they are")."
    }
}
