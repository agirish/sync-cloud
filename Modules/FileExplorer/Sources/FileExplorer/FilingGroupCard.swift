import SwiftUI
import Sync
import Design

/// Every statement going to one account folder, as one card: "10 Charles Schwab statements →
/// Traditional IRA 7863", filed with one click, expandable to pull a file out (design §5.1). What
/// File N does is always on the card: the folder, its new levels, the name the files take and the
/// months they cover, and what it leaves (copies already filed, duplicates in the inbox).
struct FilingGroupCard: View {
    let group: FilingCardGroup
    let densityMetrics: ListDensityMetrics
    let onFile: () -> Void
    let onChooseFolder: () -> Void
    let onPullOut: (FilingSuggestion) -> Void
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

    @State private var expanded: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    /// Shown open when it is short enough to read at a glance.
    private var isExpanded: Bool { expanded ?? (group.members.count <= 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .scaledFont(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(FilingGroupText.title(group))
                        .scaledFont(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        breadcrumb
                        if let pathEditor {
                            Button("Edit Path…") { editingPath = true }
                                .buttonStyle(.hoverAffordance(.inline))
                                .scaledFont(.system(size: 11))
                                .help("Type where these go, anywhere in your folders; missing folders are made when you file")
                                .popover(isPresented: $editingPath, arrowEdge: .bottom) {
                                    FilingPathEditor(hooks: pathEditor) { editingPath = false }
                                        .presentedNativeControlAccent()
                                }
                        }
                    }
                    Text(FilingGroupText.why(group))
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let naming = FilingGroupText.naming(group) {
                        Text(naming)
                            .scaledFont(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    if !group.alreadyFiled.isEmpty || !group.copies.isEmpty { leftBehindRow }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ConfidenceMeter(tier: FilingConfidenceTier.of(group.destination.confidence))
                    Pill(.mini, tint: group.destination.confidence == .high ? SemanticColor.success : SemanticColor.warning,
                         systemImage: group.destination.confidence == .high ? "checkmark" : "circle.dashed",
                         text: group.destination.confidence == .high ? "High" : "Medium")
                }
            }
            HStack(spacing: 9) {
                Button(action: onFile) {
                    Label(FilingGroupText.fileButton(group) + (onMoveOutOfArchive == nil ? "" : " in \(archiveName)"),
                          systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                .chromeHover().lockedDuringRun()
                .disabled(group.toFile.isEmpty)
                if let onMoveOutOfArchive {
                    Button(action: onMoveOutOfArchive) { Label("Move Out of \(archiveName), Then File", systemImage: "archivebox") }
                        .controlSize(.small).lockedDuringRun()
                        .help("These are newer than anything in the account, so it looks live again: move its folder beside the archive, then file them. ⌘Z undoes both.")
                }
                Button(action: onChooseFolder) { Label("Choose a Folder…", systemImage: "folder") }
                    .controlSize(.small).lockedDuringRun()
                    .disabled(group.toFile.isEmpty)
                Button {
                    withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) { expanded = !isExpanded }
                } label: {
                    Label(isExpanded ? "Hide Files" : "Show Files",
                          systemImage: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel(isExpanded ? "Hide the \(group.members.count) files" : "Show the \(group.members.count) files")
            }
            if let onFileOnce, !group.allCopies.isEmpty {
                FilingCopiesRow(copies: group.allCopies, onFileOnce: onFileOnce)
            }
            if let rememberAccount { FilingRememberAccountRow(remember: rememberAccount) }
            if isExpanded { memberList }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
        .lensCard()
    }

    private var breadcrumb: some View {
        let comps = FilingGroupText.breadcrumb(group)
        let newStart = comps.count - group.destination.newSegments.count
        return HStack(spacing: 4) {
            ForEach(Array(comps.enumerated()), id: \.offset) { i, comp in
                if i > 0 { Text("›").scaledFont(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary) }
                let isNew = i >= newStart
                HStack(spacing: 3) {
                    Text(comp)
                        .scaledFont(.system(size: 12, weight: i == comps.count - 1 ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(isNew ? hueAccent : (i == comps.count - 1 ? Color.primary : Color.secondary))
                    if isNew {
                        Text("NEW")
                            .scaledFont(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(hueAccent.opacity(PillVariant.fillOpacity)))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Into " + comps.joined(separator: ", "))
    }

    private var leftBehindRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.on.doc.fill").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.caution)
            Text(FilingGroupText.leftBehind(group))
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            let copies = group.alreadyFiled + group.copies
            Button("Move \(copies.count) to Trash") { onTrashCopies(copies) }
                .buttonStyle(.hoverAffordance(.inline))
                .scaledFont(.system(size: 11))
                .lockedDuringRun()
                .help(FilingGroupText.trashHelp(group))
        }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.members) { s in
                HStack(spacing: 8) {
                    Text(s.fileName)
                        .scaledFont(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("\(s.fileName), files as \(FilingGroupText.landing(s))")
                    Image(systemName: "arrow.right").scaledFont(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(FilingGroupText.landing(s))
                        .scaledFont(.system(size: 12, design: .monospaced))
                        .foregroundStyle(s.isAlreadyFiled || s.duplicateOf != nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Pull Out") { onPullOut(s) }
                        .buttonStyle(.hoverAffordance(.inline))
                        .scaledFont(.system(size: 11))
                        .help("Show “\(s.fileName)” as its own card")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.leading, 38)
        .padding(.top, 2)
    }
}

/// The group card's words, apart so they can be tested.
enum FilingGroupText {
    static func bank(_ g: FilingCardGroup) -> String {
        g.account.institutionName.isEmpty
            ? g.account.institution.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            : g.account.institutionName
    }

    static func noun(_ g: FilingCardGroup) -> String {
        switch g.account.kind {
        case .statement: return "statement"
        case .taxForm: return "tax form"
        case .other: return "document"
        }
    }

    static func title(_ g: FilingCardGroup) -> String {
        let n = g.members.count
        return "\(n) \(bank(g)) \(noun(g))\(n == 1 ? "" : "s")"
    }

    static func why(_ g: FilingCardGroup) -> String {
        // A new account: say so, and where its name came from.
        if g.destination.createsAccountFolder, let reason = g.destination.reasons.first {
            var s = reason
            if let r = g.dateRange { s += " · " + range(r.first, r.last) }
            return s + " · check before filing"
        }
        var s = "Account ••\(g.account.ending) on page 1 of all \(g.members.count)"
        if let r = g.dateRange { s += " · " + range(r.first, r.last) }
        if g.destination.confidence != .high { s += " · check before filing" }
        return s
    }

    static func range(_ a: DocumentFacts.Period, _ b: DocumentFacts.Period) -> String {
        let m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if a == b || (a.year == b.year && a.month == b.month) { return "\(m[a.month - 1]) \(a.year)" }
        if a.year == b.year { return "\(m[a.month - 1])–\(m[b.month - 1]) \(a.year)" }
        return "\(m[a.month - 1]) \(a.year) – \(m[b.month - 1]) \(b.year)"
    }

    /// "Named like its neighbours: Brokerage Statement_2026-01-31_863.PDF", when the files take one.
    static func naming(_ g: FilingCardGroup) -> String? {
        guard let sample = g.toFile.first?.best?.proposedName ?? g.members.first?.best?.proposedName else { return nil }
        return "Named like the files already there: \(sample)"
    }

    static func breadcrumb(_ g: FilingCardGroup) -> [String] {
        let path = g.destination.path
        let root = g.members.first?.providerRoot
        if let root, path.hasPrefix(root + "/") {
            return [(root as NSString).lastPathComponent] + path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        }
        return (path as NSString).abbreviatingWithTildeInPath.split(separator: "/").map(String.init)
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
        var parts: [String] = []
        let filed = g.alreadyFiled.count
        if filed > 0 { parts.append("\(filed) \(filed == 1 ? "is" : "are") already in your folders") }
        let copies = g.copies.count
        if copies > 0 { parts.append("\(copies) \(copies == 1 ? "is a copy" : "are copies") of another file here") }
        return parts.joined(separator: "; ") + ". Filing the other \(g.toFile.count) leaves \(filed + copies == 1 ? "it" : "them") where \(filed + copies == 1 ? "it is" : "they are")."
    }

    /// Where one member lands: its new name, or what keeps it from moving.
    static func landing(_ s: FilingSuggestion) -> String {
        if s.isAlreadyFiled { return "already filed" }
        if s.duplicateOf != nil { return "a copy of another file here" }
        return s.best?.proposedName ?? s.fileName
    }
}
