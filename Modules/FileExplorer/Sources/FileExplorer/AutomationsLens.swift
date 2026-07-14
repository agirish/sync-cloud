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
    }
}

// MARK: - Automations lens

/// The Automations workspace (N2, preview-only): manage plain-words rules, then dry-run them over the
/// focused folder to see exactly what *would* happen — no file is moved. Rendered inside ``TidyView``'s
/// content card, so this view provides only the inner rule-list / previewing / results states.
public struct AutomationsLens: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private let providerName: String?
    /// The folder the preview scans and destinations resolve against (the focused pane's directory).
    /// Passed to the rule editor so its Browse… button opens here and yields a matching relative path.
    private let scanRoot: URL?
    /// Kicks off a dry-run preview (host owns the root/provider derivation). nil = all enabled rules,
    /// a rule id = just that rule.
    private let onPreview: (UUID?) -> Void

    /// The rule being created or edited in the sheet, if any.
    @State private var editingRule: AutomationRule?
    /// True once the user has asked to see results — keeps the results view up until they go back.
    @State private var viewingResults = false

    public init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        scanRoot: URL? = nil,
        onPreview: @escaping (UUID?) -> Void
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.scanRoot = scanRoot
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
            } else if viewingResults, let report = syncManager.automationDryRun {
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
                browseRoot: scanRoot,
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
        viewingResults = true
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
                caption: "Preview-only for now: rules show what would happen. No file is moved.",
                primary: .init("New rule", systemImage: AutomationsGlyph.newRule, handler: newRule)
            )
        } else {
            VStack(spacing: 0) {
                rulesHeader
                Divider().opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: densityMetrics.cardListSpacing) {
                        ForEach(syncManager.automationRules) { rule in
                            AutomationRuleCard(
                                rule: rule,
                                accent: accent,
                                canPreview: rule.isRunnable && scanRoot != nil,
                                onToggle: { syncManager.setAutomationRule(id: rule.id, enabled: $0) },
                                onPreview: { runPreview(only: rule.id) },
                                onEdit: { editingRule = rule },
                                onDelete: { syncManager.removeAutomationRule(id: rule.id) }
                            )
                        }
                    }
                    .padding(densityMetrics.cardListPadding)
                    .animation(.easeInOut(duration: 0.2), value: syncManager.automationRules.map(\.id))
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var rulesHeader: some View {
        let count = syncManager.automationRules.count
        return HStack(spacing: 10) {
            Image(systemName: AutomationsGlyph.lens)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
            Text("\(count) automation\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Text("· preview only, nothing is moved")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: newRule) { Label("New rule", systemImage: AutomationsGlyph.newRule) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: { runPreview(only: nil) }) { Label("Preview all", systemImage: AutomationsGlyph.preview) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(runnableRuleCount == 0 || scanRoot == nil)
                .help(runnableRuleCount == 0
                      ? "Add a rule with a condition and a destination to preview it."
                      : "Dry-run the enabled rules over the focused folder in \(provider). Nothing is moved.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
                    secondary: .init("Back to rules", systemImage: "chevron.left", handler: { viewingResults = false })
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedRows(report)) { group in
                            VStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                                ruleGroupHeader(group)
                                ForEach(group.rows) { row in
                                    AutomationDryRunRowView(row: row, accent: accent)
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
            Button(action: { viewingResults = false }) { Label("Rules", systemImage: "chevron.left") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Text("Previewed \((report.root as NSString).lastPathComponent)")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: { runPreview(only: nil) }) { Label("Preview again", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The counts at a glance — scanned / would-file / needs-a-look / already-there.
    private func summaryStrip(_ report: AutomationDryRunReport) -> some View {
        HStack(spacing: 8) {
            statPill("\(report.filesScanned)", "scanned", .secondary)
            statPill("\(report.wouldFileCount)", "would file", .green)
            if report.needsAttentionCount > 0 { statPill("\(report.needsAttentionCount)", "need a look", .orange) }
            if report.alreadyThereCount > 0 { statPill("\(report.alreadyThereCount)", "already there", .secondary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func statPill(_ number: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(number).font(.system(size: 12.5, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill((color == .secondary ? Color.primary : color).opacity(0.10)))
    }

    private func ruleGroupHeader(_ group: RuleGroup) -> some View {
        HStack(spacing: 7) {
            Image(systemName: AutomationsGlyph.lens)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent)
            Text(group.name.isEmpty ? "Untitled rule" : group.name)
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(group.rows.count)")
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private var previewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.circle.fill").foregroundStyle(accent)
            Text("Preview only — this is what the rules would do. Nothing was moved.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(accent.opacity(0.06))
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
    let onToggle: (Bool) -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Mirrors `rule.enabled` so the switch binds to local `@State` (a plain `Binding`) rather than a
    /// captured closure — the latter trips Swift 6's `@Sendable`-setter check on `Binding(set:)`.
    @State private var isEnabled: Bool

    init(rule: AutomationRule, accent: Color, canPreview: Bool,
         onToggle: @escaping (Bool) -> Void, onPreview: @escaping () -> Void,
         onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.accent = accent
        self.canPreview = canPreview
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
                .padding(.top, 1)
                .onChange(of: isEnabled) { _, newValue in onToggle(newValue) }
                .onChange(of: rule.enabled) { _, newValue in
                    if newValue != isEnabled { isEnabled = newValue }
                }
            VStack(alignment: .leading, spacing: 7) {
                nameRow
                conditionRow
                DestinationPill(template: rule.destinationTemplate, accent: accent)
            }
            actions
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(rule.enabled ? 0.5 : 0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(rule.enabled ? 1 : 0.7)
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rule.enabled ? .primary : .secondary)
            if !rule.isRunnable {
                Text("incomplete")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
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
                        .background(Capsule().fill(accent.opacity(0.12)))
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
            Button(action: onPreview) { Image(systemName: AutomationsGlyph.preview) }
                .disabled(!canPreview)
                .help(canPreview ? "Preview just this rule over the focused folder"
                                 : "Give the rule a condition and destination to preview it")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("Edit this rule")
            Button(action: onDelete) { Image(systemName: "trash") }
                .help("Delete this rule")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.top, 1)
    }
}

// MARK: - Condition chip & destination pill

/// A single condition rendered as an icon + compact label chip.
private struct ConditionChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
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
            Image(systemName: "arrow.forward").font(.system(size: 8.5, weight: .bold))
            Image(systemName: "folder.fill").font(.system(size: 9))
            Text(template.isEmpty ? "set a destination" : template)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(template.isEmpty ? Color.secondary : accent)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((template.isEmpty ? Color.primary : accent).opacity(0.10)))
    }
}

// MARK: - Dry-run row

/// One matched file in the dry run: icon, name, what would happen, and a verdict chip.
private struct AutomationDryRunRowView: View {
    let row: AutomationDryRunRow
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: FileIconCache.icon(name: row.fileName, isDirectory: false))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fileName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            verdictChip
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var detail: some View {
        switch row.verdict {
        case .wouldFile(let destination):
            HStack(spacing: 5) {
                Image(systemName: "arrow.forward").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
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
            Text("already in its destination")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var verdictChip: some View {
        let (text, color, icon): (String, Color, String) = {
            switch row.verdict {
            case .wouldFile: return ("Would file", .green, AutomationsGlyph.wouldFile)
            case .needsAttention: return ("Needs a look", .orange, AutomationsGlyph.needsAttention)
            case .alreadyThere: return ("Already there", .secondary, AutomationsGlyph.alreadyThere)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

// MARK: - Flow layout

/// A minimal wrapping layout: places children left-to-right, breaking to a new line when the next
/// child won't fit. Used for a rule's condition chips so they wrap inside the card.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                          anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
