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
    static let disabledRule = "pause.circle"
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
    /// Kicks off a dry-run preview of the focused folder (host owns the root/provider derivation).
    private let onPreview: () -> Void

    /// The rule being created or edited in the sheet, if any.
    @State private var editingRule: AutomationRule?
    /// True once the user has asked to see results — keeps the results view up until they go back.
    @State private var viewingResults = false

    public init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        onPreview: @escaping () -> Void
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
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
                onSave: { saved in
                    syncManager.upsertAutomationRule(saved)
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
        }
    }

    private func newRule() {
        editingRule = AutomationRule(name: "")
    }

    private func runPreview() {
        viewingResults = true
        onPreview()
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
                                onToggle: { syncManager.setAutomationRule(id: rule.id, enabled: $0) },
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
            Button(action: runPreview) { Label("Preview all", systemImage: AutomationsGlyph.preview) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(runnableRuleCount == 0)
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
                    LazyVStack(spacing: densityMetrics.cardListSpacing) {
                        ForEach(report.rows) { row in
                            AutomationDryRunRowView(row: row, accent: accent)
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
            countChip("\(report.wouldFileCount)", "would file", .green)
            if report.needsAttentionCount > 0 { countChip("\(report.needsAttentionCount)", "need a look", .orange) }
            Button(action: runPreview) { Label("Preview again", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func countChip(_ number: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(number).font(.system(size: 12, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
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
}

// MARK: - Rule card

/// One automation rendered as a card: enable toggle, name + plain-words summary, and Edit / Delete.
private struct AutomationRuleCard: View {
    let rule: AutomationRule
    let accent: Color
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Mirrors `rule.enabled` so the switch binds to local `@State` (a plain `Binding`) rather than a
    /// captured closure — the latter trips Swift 6's `@Sendable`-setter check on `Binding(set:)`.
    @State private var isEnabled: Bool

    init(rule: AutomationRule, accent: Color,
         onToggle: @escaping (Bool) -> Void, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.accent = accent
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onDelete = onDelete
        _isEnabled = State(initialValue: rule.enabled)
    }

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
            VStack(alignment: .leading, spacing: 4) {
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
                }
                Text(rule.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit this rule")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this rule")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(rule.enabled ? 0.5 : 0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(rule.enabled ? 1 : 0.72)
    }
}

// MARK: - Dry-run row

/// One matched file in the dry run: icon, name, what would happen, and a verdict chip.
private struct AutomationDryRunRowView: View {
    let row: AutomationDryRunRow
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: FileIconCache.icon(name: row.fileName, isDirectory: false))
                .resizable().frame(width: 24, height: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fileName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                detail
                Text("rule · \(row.ruleName)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            verdictChip
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
