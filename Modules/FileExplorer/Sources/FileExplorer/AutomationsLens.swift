import SwiftUI
import Sync
import Design

// MARK: - Automations glyph vocabulary

/// The Automations lens's own iconography, kept distinct from the duplicate finder's
/// (`wand.and.stars` / `checkmark.seal.fill`), Filing's (`folder.badge.gearshape` / trays), and the
/// Name Normalizer's (`textformat.abc` / `checkmark.shield`) so the four lenses never share a symbol.
enum AutomationsGlyph {
    /// Signature symbol — turning gears, for the intro and lens picker.
    static let lens = "gearshape.2"
    static let preview = "eye"
    static let newRule = "plus"
    static let wouldFile = "arrow.forward.circle.fill"
    static let needsAttention = "exclamationmark.triangle.fill"
    static let alreadyThere = "checkmark.circle"
}

/// SF Symbol for a condition, so each building block reads at a glance in a rule's chip row.
func automationConditionIcon(_ condition: AutomationCondition) -> String {
    switch condition {
    case .folderNamed: return "folder"
    case .nameMatches: return "textformat"
    case .kindIs(let kind): return automationKindIcon(kind)
    case .largerThanMB: return "scalemass"
    case .untouchedForDays: return "clock"
    case .contentContains: return "text.magnifyingglass"
    case .mentionsAll: return "memories"
    }
}

func automationKindIcon(_ kind: FileKind) -> String {
    switch kind {
    case .image: return "photo"
    case .pdf: return "doc.richtext"
    case .video: return "film"
    case .audio: return "music.note"
    case .archive: return "archivebox"
    case .document: return "doc.text"
    }
}

/// A compact label for a condition chip (shorter than ``AutomationCondition/summary``).
func automationConditionChipText(_ condition: AutomationCondition) -> String {
    switch condition {
    case .folderNamed(let name): return "in \(name.isEmpty ? "…" : name)"
    case .nameMatches(let glob): return glob.isEmpty ? "name …" : glob
    case .kindIs(let kind): return kind.label
    case .largerThanMB(let mb): return "> \(mb) MB"
    case .untouchedForDays(let days): return "\(days)d untouched"
    case .contentContains(let term): return "“\(term.isEmpty ? "…" : term)”"
    case .mentionsAll(let tokens):
        let cleaned = tokens.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "mentions …" }
        let shown = cleaned.prefix(3).joined(separator: " + ")
        return "mentions " + shown + (cleaned.count > 3 ? " +\(cleaned.count - 3)" : "")
    }
}

// MARK: - Automations lens

/// The Automations lens's host-owned view state.
///
/// It lives outside the lens because the lens's controls ride ``TidyView``'s shared header card
/// now: the "Preview all" button is rendered up there and has to be able to flip this lens into
/// its results view. Owned by the host as a `@StateObject`, so it survives the lens being
/// rebuilt.
@MainActor
public final class AutomationsLensState: ObservableObject {
    /// True once the user has asked to see dry-run results — keeps the results view up until they
    /// go back.
    @Published public var viewingResults = false
    public init() {}
}

/// The Automations workspace (N2): the one home for the user's rules — authored plain-words
/// automations and rules taught by example (the migrated "remembered" rules, now `mentions`
/// conditions). Rules steer Organize's suggestions on every scan; here they can also be dry-run
/// over the focused folder and their matches filed for real after per-file confirmation. Rendered
/// inside ``TidyView``'s content card, so this view provides only the inner rule-list /
/// previewing / results states.
public struct AutomationsLens: View {
    @ObservedObject public var syncManager: FileSyncManager
    @ObservedObject private var state: AutomationsLensState
    /// The rules to list — already filtered by the header card's search. The lens never reads
    /// `syncManager.automationRules` for its list, so what's on screen is exactly what the
    /// header counted.
    private let rules: [AutomationRule]

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private let providerName: String?
    /// The provider root that rule destinations resolve against — the same anchor the preview uses
    /// (NOT the focused subfolder). Passed to the rule editor so its Browse… button relativizes a
    /// picked folder against the provider root, yielding the exact path the preview will resolve.
    private let destinationRoot: URL?
    /// Kicks off a dry-run preview (host owns the root/provider derivation). nil = all enabled rules,
    /// a rule id = just that rule.
    private let onPreview: (UUID?) -> Void
    /// Quick Look a matched file (absolute path — the same convention Organize's cards use).
    /// nil hides the Preview affordances on the dry-run rows and the per-file review.
    private let onQuickLook: ((String) -> Void)?
    /// Reveal a matched file in Finder (absolute path). nil hides the Reveal affordances.
    private let onReveal: ((String) -> Void)?

    /// The rule being created or edited in the sheet, if any. A per-card Edit opens this; the
    /// header card's "New rule" goes through the host's own editor sheet instead.
    @State private var editingRule: AutomationRule?

    /// Per-file "ask each time" filing — the cursor, its queue, and the approvals. The rules live
    /// in `FilingWalkthrough` (a tested value type) rather than in four loose `@State` vars,
    /// because this is the gate in front of `applyAutomationFiling`, which moves files.
    @State private var filing = FilingWalkthrough()

    public init(
        syncManager: FileSyncManager,
        state: AutomationsLensState,
        rules: [AutomationRule],
        providerName: String? = nil,
        destinationRoot: URL? = nil,
        onQuickLook: ((String) -> Void)? = nil,
        onReveal: ((String) -> Void)? = nil,
        onPreview: @escaping (UUID?) -> Void
    ) {
        self.syncManager = syncManager
        self.state = state
        self.rules = rules
        self.providerName = providerName
        self.destinationRoot = destinationRoot
        self.onQuickLook = onQuickLook
        self.onReveal = onReveal
        self.onPreview = onPreview
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }
    private var provider: String { providerName ?? "this provider" }
    private var runnableRuleCount: Int { syncManager.automationRules.filter { $0.enabled && $0.isRunnable }.count }

    public var body: some View {
        Group {
            if syncManager.isRunningAutomationDryRun {
                previewingState
            } else if let filingRow = filing.current {
                filingReviewState(filingRow)
            } else if state.viewingResults, let report = syncManager.automationDryRun {
                resultsState(report)
            } else {
                rulesState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncManager.ensureAutomationRulesLoaded() }
        .sheet(item: $editingRule) { rule in
            AutomationRuleEditor(
                rule: rule,
                accent: accent,
                browseRoot: destinationRoot,
                onSave: { saved in
                    syncManager.upsertAutomationRule(saved)
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
        }
    }

    private func newRule() { editingRule = AutomationRule(name: "") }

    private func runPreview(only: UUID? = nil) {
        state.viewingResults = true
        onPreview(only)
    }

    // MARK: Rules management

    @ViewBuilder
    private var rulesState: some View {
        if syncManager.automationRules.isEmpty {
            EmptyStateView(
                icon: AutomationsGlyph.lens,
                tint: accent,
                title: "Automate where loose files go",
                message: "Write a plain-words rule — “PDFs that mention ‘invoice’ belong in Documents/Invoices/{year}” — and preview exactly which files it would file. Every test runs on your Mac; nothing is sent to the cloud.",
                caption: "Rules steer Organize's suggestions, and preview here before anything is filed — every move needs your confirmation.",
                primary: .init("New rule", systemImage: AutomationsGlyph.newRule, handler: newRule)
            )
        } else {
            // No header row here any more: the shared LensHeaderCard above carries this lens's
            // count, its New rule / Preview all controls, and its search. This card renders the
            // list only — which is also what makes the workspace's header height a promise
            // instead of a per-lens accident.
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: densityMetrics.cardListSpacing) {
                        ForEach(rules) { rule in
                            AutomationRuleCard(
                                rule: rule,
                                accent: accent,
                                canPreview: rule.isRunnable && destinationRoot != nil,
                                // The disabled Preview button's tooltip must name the REAL blocker: a
                                // complete rule with no focused provider folder doesn't need "a
                                // condition and destination" — it needs a folder to preview over.
                                previewHelp: !rule.isRunnable
                                    ? "Give the rule a condition and destination to preview it"
                                    : destinationRoot == nil
                                    ? "Focus a provider folder first — the preview runs over the focused folder"
                                    : "Preview just this rule over the focused folder",
                                densityMetrics: densityMetrics,
                                onToggle: { syncManager.setAutomationRule(id: rule.id, enabled: $0) },
                                onPreview: { runPreview(only: rule.id) },
                                onEdit: { editingRule = rule },
                                onDelete: { syncManager.removeAutomationRule(id: rule.id) }
                            )
                        }
                    }
                    .padding(densityMetrics.cardListPadding)
                    .animation(.easeInOut(duration: 0.2), value: rules.map(\.id))
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Previewing

    private var previewingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.automationDryRunStatus.isEmpty ? "Previewing…" : syncManager.automationDryRunStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelAutomationDryRun() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Results

    private func resultsState(_ report: AutomationDryRunReport) -> some View {
        VStack(spacing: 0) {
            resultsHeader(report)
            Divider().opacity(0.5)
            previewBanner
            summaryStrip(report)
            Divider().opacity(0.5)
            if report.rows.isEmpty {
                EmptyStateView(
                    icon: AutomationsGlyph.alreadyThere,
                    tint: .secondary,
                    title: "No files matched your rules",
                    message: "Nothing in \((report.root as NSString).lastPathComponent) matched an enabled rule. Adjust a rule or preview a different folder.",
                    secondary: .init("Back to rules", systemImage: "chevron.left", handler: { state.viewingResults = false })
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedRows(report)) { group in
                            VStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                                ruleGroupHeader(group)
                                ForEach(group.rows) { row in
                                    AutomationDryRunRowView(
                                        row: row, accent: accent,
                                        densityMetrics: densityMetrics,
                                        onQuickLook: onQuickLook.map { ql in { ql(row.id) } },
                                        onReveal: onReveal.map { rv in { rv(row.id) } }
                                    )
                                }
                            }
                        }
                    }
                    .padding(densityMetrics.cardListPadding)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func resultsHeader(_ report: AutomationDryRunReport) -> some View {
        HStack(spacing: 10) {
            Button(action: { state.viewingResults = false }) { Label("Rules", systemImage: "chevron.left") }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover(tint: accent)
            Text("Previewed \((report.root as NSString).lastPathComponent)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: { runPreview(only: nil) }) { Label("Preview again", systemImage: "arrow.clockwise") }
                .chromeButtonStyle(glassLevel)
                .controlSize(.small)
                .chromeHover(tint: accent)
            let fileable = report.rows.filter { $0.destinationDir != nil }
            if !fileable.isEmpty {
                Button(action: { filing.start(fileable) }) {
                    Label("File \(fileable.count)…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .controlSize(.small)
                .help("File these \(fileable.count) file\(fileable.count == 1 ? "" : "s") one at a time, confirming each. Moves real files; undoes with ⌘Z.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The counts at a glance — scanned / would-file / needs-a-look / already-there.
    private func summaryStrip(_ report: AutomationDryRunReport) -> some View {
        HStack(spacing: 8) {
            statPill(report.filesScanned, "scanned", .secondary)
            statPill(report.wouldFileCount, "would file", SemanticColor.success)
            if report.needsAttentionCount > 0 { statPill(report.needsAttentionCount, "need a look", SemanticColor.warning) }
            if report.alreadyThereCount > 0 { statPill(report.alreadyThereCount, "already there", .secondary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func statPill(_ count: Int, _ label: String, _ color: Color) -> some View {
        Pill(.standard, tint: color, count: count, label: label)
    }

    private func ruleGroupHeader(_ group: RuleGroup) -> some View {
        HStack(spacing: 7) {
            Image(systemName: AutomationsGlyph.lens)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(group.name.isEmpty ? "Untitled rule" : group.name)
                .font(.system(size: 11, weight: .semibold))
            Text("\(group.rows.count)")
                .font(PillVariant.mini.numberFont).monospacedDigit()
                .foregroundStyle(.secondary)
                .pillSurface(.mini, tint: .secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private var previewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.circle.fill").foregroundStyle(accent)
            Text("A preview — nothing has moved yet. “File …” walks you through the matches.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(accent.opacity(0.10))
    }

    // MARK: Filing (per-file "ask each time")

    /// Records a decision and, when that was the last file, applies the approved set as ONE
    /// reversible run. `advance` returns non-nil exactly at the end, so the apply happens in one
    /// place rather than being re-derived from the cursor by the caller.
    private func advanceFiling(approved: Bool) {
        guard let toFile = filing.advance(approved: approved) else { return }
        guard !toFile.isEmpty else { return }
        Task { await syncManager.applyAutomationFiling(rows: toFile) }
    }

    @ViewBuilder
    private func filingReviewState(_ row: AutomationDryRunRow) -> some View {
        let isCollision: Bool = { if case .needsAttention = row.verdict { return true } else { return false } }()
        VStack(spacing: 16) {
            Text("File \(filing.displayPosition) of \(filing.queue.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Image(nsImage: FileIconCache.icon(name: row.fileName, isDirectory: false))
                    .resizable().frame(width: 44, height: 44)
                Text(row.fileName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(accent)
                    Text(row.destinationLabel ?? "its destination")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent)
                        .lineLimit(1).truncationMode(.middle)
                }
                if isCollision {
                    Text("A file with this name is already there — it’ll be kept as a copy.")
                        .font(.system(size: 11)).foregroundStyle(SemanticColor.warning)
                        .multilineTextAlignment(.center)
                }
                // Inspection before deciding: Quick Look the file or see it in Finder — the same
                // Preview/Reveal pair Organize's cards offer, since "File or skip?" is exactly the
                // moment the user needs to check what the file actually is.
                if onQuickLook != nil || onReveal != nil {
                    HStack(spacing: 9) {
                        if let onQuickLook {
                            Button(action: { onQuickLook(row.id) }) { Label("Preview", systemImage: "eye") }
                                .controlSize(.small)
                                .help("Quick Look this file before deciding")
                        }
                        if let onReveal {
                            Button(action: { onReveal(row.id) }) { Label("Reveal", systemImage: RevealGlyph.inFinder) }
                                .controlSize(.small)
                                .help("Show this file in Finder")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: 380)
            .lensCard()
            HStack(spacing: 10) {
                Button(action: { advanceFiling(approved: false) }) {
                    Label("Skip", systemImage: "arrow.uturn.forward").frame(minWidth: 66)
                }
                .controlSize(.large)
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button(action: { advanceFiling(approved: true) }) {
                    Label("File", systemImage: "tray.and.arrow.down.fill").frame(minWidth: 66)
                }
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            Button("Cancel") { filing.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .padding(.top, 2)
            Text("Filing moves real files into \(provider). The whole run undoes with ⌘Z.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: Grouping

    /// The result rows grouped by their rule, preserving first-appearance order.
    private func groupedRows(_ report: AutomationDryRunReport) -> [RuleGroup] {
        var order: [UUID] = []
        var byRule: [UUID: RuleGroup] = [:]
        for row in report.rows {
            if byRule[row.ruleID] == nil {
                order.append(row.ruleID)
                byRule[row.ruleID] = RuleGroup(id: row.ruleID, name: row.ruleName, rows: [])
            }
            byRule[row.ruleID]?.rows.append(row)
        }
        return order.compactMap { byRule[$0] }
    }

    private struct RuleGroup: Identifiable {
        let id: UUID
        let name: String
        var rows: [AutomationDryRunRow]
    }
}

// MARK: - Rule card

/// One automation as a card: enable toggle, name, its conditions as chips, its destination as a pill,
/// and Preview-this-rule / Edit / Delete.
private struct AutomationRuleCard: View {
    let rule: AutomationRule
    let accent: Color
    let canPreview: Bool
    /// The Preview button's tooltip — names the real blocker when disabled (host computes it,
    /// since only the host knows whether a provider folder is focused).
    let previewHelp: String
    /// Row measurements per the appearance density setting (D4). Comfortable must render this card
    /// pixel-identical to the pre-density look.
    let densityMetrics: ListDensityMetrics
    let onToggle: (Bool) -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Mirrors `rule.enabled` so the switch binds to local `@State` (a plain `Binding`) rather than a
    /// captured closure — the latter trips Swift 6's `@Sendable`-setter check on `Binding(set:)`.
    @State private var isEnabled: Bool

    init(rule: AutomationRule, accent: Color, canPreview: Bool, previewHelp: String,
         densityMetrics: ListDensityMetrics,
         onToggle: @escaping (Bool) -> Void, onPreview: @escaping () -> Void,
         onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.accent = accent
        self.canPreview = canPreview
        self.previewHelp = previewHelp
        self.densityMetrics = densityMetrics
        self.onToggle = onToggle
        self.onPreview = onPreview
        self.onEdit = onEdit
        self.onDelete = onDelete
        _isEnabled = State(initialValue: rule.enabled)
    }

    private var completeConditions: [AutomationCondition] { rule.conditions.filter { $0.isComplete } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                // labelsHidden leaves VoiceOver announcing a bare switch in a card full of
                // switches — name whose rule this one enables.
                .accessibilityLabel("Rule \(rule.name.isEmpty ? "Untitled rule" : rule.name) enabled")
                .padding(.top, 1)
                .onChange(of: isEnabled) { _, newValue in onToggle(newValue) }
                .onChange(of: rule.enabled) { _, newValue in
                    if newValue != isEnabled { isEnabled = newValue }
                }
            VStack(alignment: .leading, spacing: 7) {
                nameRow
                // The condition chips are the secondary detail compact hides (D4); the rule's
                // name and destination pill still say what it is and where it files.
                if densityMetrics.showsSecondaryDetail { conditionRow }
                DestinationPill(template: rule.destinationTemplate, accent: accent)
            }
            actions
        }
        .padding(.horizontal, 14).padding(.vertical, densityMetrics.cardRowVerticalPadding)
        .lensCard(fillOpacity: rule.enabled ? 0.5 : 0.25)
        .opacity(rule.enabled ? 1 : 0.7)
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(rule.enabled ? .primary : .secondary)
            if !rule.isRunnable {
                Pill(.mini, tint: SemanticColor.warning, text: "incomplete")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var conditionRow: some View {
        if completeConditions.isEmpty {
            Text("No conditions yet — this rule won’t match anything.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                if completeConditions.count > 1 {
                    Text(rule.matchMode == .all ? "ALL" : "ANY")
                        .font(.system(size: 9, weight: .bold)).kerning(0.4)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(accent.opacity(0.14)))
                }
                ForEach(Array(completeConditions.enumerated()), id: \.offset) { _, condition in
                    ConditionChip(icon: automationConditionIcon(condition),
                                  text: automationConditionChipText(condition))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onPreview) { Image(systemName: AutomationsGlyph.preview).padding(4).contentShape(Rectangle()) }
                .disabled(!canPreview)
                .help(previewHelp)
            Button(action: onEdit) { Image(systemName: "pencil").padding(4).contentShape(Rectangle()) }
                .help("Edit this rule")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash").padding(4).contentShape(Rectangle()) }
                .help("Delete this rule")
                .foregroundStyle(SemanticColor.error)
        }
        // Padded out for the wash, pulled back so the row's action cluster keeps its width.
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .padding(-4)
        .padding(.top, 1)
    }
}

// MARK: - Condition chip & destination pill

/// A single condition rendered as an icon + compact label chip.
/// Internal (not private) so the snapshot tests can pin its wrapping inside ``FlowLayout``.
struct ConditionChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// The rule's destination template as an accent-tinted pill, e.g. "→ 📁 Documents/Invoices/{year}".
private struct DestinationPill: View {
    let template: String
    let accent: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
            Image(systemName: "folder.fill").font(.system(size: 9))
            Text(template.isEmpty ? "set a destination" : template)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(template.isEmpty ? Color.secondary : accent)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((template.isEmpty ? Color.primary : accent).opacity(PillVariant.fillOpacity)))
    }
}

// MARK: - Dry-run row

/// One matched file in the dry run: icon, name, what would happen, and a verdict chip.
/// Right-click offers Preview (Quick Look) / Reveal so a match can be inspected before filing —
/// the same pair Organize's suggestion cards carry.
private struct AutomationDryRunRowView: View {
    let row: AutomationDryRunRow
    let accent: Color
    /// Row measurements per the appearance density setting (D4). Comfortable must render this row
    /// pixel-identical to the pre-density look.
    let densityMetrics: ListDensityMetrics
    var onQuickLook: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: FileIconCache.icon(name: row.fileName, isDirectory: false))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fileName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            verdictChip
        }
        .padding(.horizontal, 14)
        // This row's comfortable padding (9) is smaller than the shared card-row metric (11), so
        // clamp rather than substitute: comfortable stays exactly 9; compact tightens to the
        // metric's 6.
        .padding(.vertical, min(9, densityMetrics.cardRowVerticalPadding))
        .lensCard()
        .contentShape(Rectangle())
        .contextMenu {
            if let onQuickLook {
                Button(action: onQuickLook) { Label("Preview", systemImage: "eye") }
            }
            if let onReveal {
                Button(action: onReveal) { Label("Reveal in Finder", systemImage: RevealGlyph.inFinder) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch row.verdict {
        case .wouldFile(let destination):
            HStack(spacing: 5) {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                Text(destination)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .needsAttention(let reason):
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .alreadyThere:
            // Fully redundant with the "Already there" verdict chip, so it's the one detail line
            // compact can drop (D4). The "would file" destination and "needs a look" reason stay
            // in both densities — without them the row loses what would happen / what's wrong.
            if densityMetrics.showsSecondaryDetail {
                Text("already in its destination")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var verdictChip: some View {
        let (text, color, icon): (String, Color, String) = {
            switch row.verdict {
            case .wouldFile: return ("Would file", SemanticColor.success, AutomationsGlyph.wouldFile)
            case .needsAttention: return ("Needs a look", SemanticColor.warning, AutomationsGlyph.needsAttention)
            case .alreadyThere: return ("Already there", .secondary, AutomationsGlyph.alreadyThere)
            }
        }()
        return Pill(.mini, tint: color, systemImage: icon, text: text)
    }
}

// MARK: - Flow layout

/// A minimal wrapping layout: places children left-to-right, breaking to a new line when the next
/// child won't fit. Used for a rule's condition chips so they wrap inside the card. Each child's
/// width is clamped to the container's, so one over-wide chip (a long `mentions` phrase) is
/// proposed the container width — its truncating Text elides — instead of drawing past the card
/// border. The geometry lives in ``FlowLayoutMath`` so it's testable without Layout subviews.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        FlowLayoutMath.place(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
                             maxWidth: proposal.width ?? .infinity,
                             spacing: spacing, lineSpacing: lineSpacing).total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = FlowLayoutMath.place(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
                                              maxWidth: bounds.width,
                                              spacing: spacing, lineSpacing: lineSpacing).placements
        for (subview, placement) in zip(subviews, placements) {
            subview.place(at: CGPoint(x: bounds.minX + placement.origin.x,
                                      y: bounds.minY + placement.origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(placement.size))
        }
    }
}

/// The pure line-breaking math behind ``FlowLayout``: given the children's ideal sizes, computes
/// where each lands and the total footprint. Every width is clamped to `maxWidth` up front, so an
/// over-wide child can never be placed (or proposed a size) past the container's trailing edge.
enum FlowLayoutMath {
    struct Placement: Equatable {
        let origin: CGPoint
        let size: CGSize
    }

    static func place(
        sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat
    ) -> (placements: [Placement], total: CGSize) {
        var placements: [Placement] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for ideal in sizes {
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (placements, CGSize(width: min(widest, maxWidth), height: y + lineHeight))
    }
}
