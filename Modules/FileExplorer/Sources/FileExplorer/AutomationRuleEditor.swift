import SwiftUI
import Sync

// MARK: - Condition type (the editor's type picker)

/// The editable *type* of a condition, decoupled from its value so the editor can offer a picker and
/// swap the underlying ``AutomationCondition`` while keeping the row.
private enum ConditionType: String, CaseIterable, Identifiable {
    case folderNamed, nameMatches, kindIs, largerThanMB, untouchedForDays, contentContains
    var id: String { rawValue }

    var label: String {
        switch self {
        case .folderNamed: return "In a folder named"
        case .nameMatches: return "Name matches"
        case .kindIs: return "Kind is"
        case .largerThanMB: return "Larger than"
        case .untouchedForDays: return "Not modified in"
        case .contentContains: return "Text contains"
        }
    }

    init(_ condition: AutomationCondition) {
        switch condition {
        case .folderNamed: self = .folderNamed
        case .nameMatches: self = .nameMatches
        case .kindIs: self = .kindIs
        case .largerThanMB: self = .largerThanMB
        case .untouchedForDays: self = .untouchedForDays
        case .contentContains: self = .contentContains
        }
    }

    /// A fresh condition of this type with sensible starting values.
    func makeDefault() -> AutomationCondition {
        switch self {
        case .folderNamed: return .folderNamed("Downloads")
        case .nameMatches: return .nameMatches("*.pdf")
        case .kindIs: return .kindIs(.pdf)
        case .largerThanMB: return .largerThanMB(100)
        case .untouchedForDays: return .untouchedForDays(365)
        case .contentContains: return .contentContains("invoice")
        }
    }
}

/// A condition with a stable identity for the editor's list, so add/remove never confuses two rows
/// that momentarily hold equal values.
private struct DraftCondition: Identifiable {
    let id = UUID()
    var condition: AutomationCondition
}

// MARK: - Rule editor

/// The plain-words rule builder (N2). Edits a working copy and hands the finished rule back on Save;
/// Cancel discards. No file access here — this only shapes the rule; the preview does the evaluation.
struct AutomationRuleEditor: View {
    let accent: Color
    let onSave: (AutomationRule) -> Void
    let onCancel: () -> Void

    private let ruleID: UUID
    private let wasEnabled: Bool
    private let isNew: Bool

    @State private var name: String
    @State private var matchMode: AutomationRule.MatchMode
    @State private var rows: [DraftCondition]
    @State private var destination: String

    init(rule: AutomationRule, accent: Color,
         onSave: @escaping (AutomationRule) -> Void, onCancel: @escaping () -> Void) {
        self.accent = accent
        self.onSave = onSave
        self.onCancel = onCancel
        self.ruleID = rule.id
        self.wasEnabled = rule.enabled
        self.isNew = rule.conditions.isEmpty && rule.name.isEmpty && rule.destinationTemplate.isEmpty
        _name = State(initialValue: rule.name)
        _matchMode = State(initialValue: rule.matchMode)
        _rows = State(initialValue: rule.conditions.map { DraftCondition(condition: $0) })
        _destination = State(initialValue: rule.destinationTemplate)
    }

    private var assembled: AutomationRule {
        AutomationRule(
            id: ruleID,
            name: name,
            enabled: wasEnabled,
            matchMode: matchMode,
            conditions: rows.map(\.condition),
            destinationTemplate: destination
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    conditionsSection
                    destinationSection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 500, height: 520)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gearshape.2").foregroundStyle(accent)
            Text(isNew ? "New automation" : "Edit automation")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Name")
            TextField("Invoices", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("When a file matches")
                if rows.count > 1 {
                    Picker("", selection: $matchMode) {
                        Text("all of").tag(AutomationRule.MatchMode.all)
                        Text("any of").tag(AutomationRule.MatchMode.any)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .controlSize(.small)
                }
                Spacer()
            }

            if rows.isEmpty {
                Text("Add at least one condition — all on-device.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach($rows) { $row in
                    conditionRow($row.condition) { rows.removeAll { $0.id == row.id } }
                }
            }

            Menu {
                ForEach(ConditionType.allCases) { type in
                    Button(type.label) { rows.append(DraftCondition(condition: type.makeDefault())) }
                }
            } label: {
                Label("Add condition", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func conditionRow(_ condition: Binding<AutomationCondition>, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: typeBinding(condition)) {
                ForEach(ConditionType.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 155)
            .controlSize(.small)

            valueEditor(condition)

            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this condition")
        }
    }

    @ViewBuilder
    private func valueEditor(_ condition: Binding<AutomationCondition>) -> some View {
        switch condition.wrappedValue {
        case .folderNamed:
            TextField("Downloads", text: stringBinding(condition))
                .textFieldStyle(.roundedBorder).controlSize(.small)
        case .nameMatches:
            TextField("*.pdf", text: stringBinding(condition))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .font(.system(size: 11.5, design: .monospaced))
        case .contentContains:
            TextField("invoice", text: stringBinding(condition))
                .textFieldStyle(.roundedBorder).controlSize(.small)
        case .kindIs:
            Picker("", selection: kindBinding(condition)) {
                ForEach(FileKind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 130)
        case .largerThanMB:
            HStack(spacing: 5) {
                TextField("100", value: intBinding(condition), format: .number)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                Text("MB").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .untouchedForDays:
            HStack(spacing: 5) {
                TextField("365", value: intBinding(condition), format: .number)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                Text("days").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("File it into")
                Spacer()
                Menu {
                    ForEach(AutomationEvaluator.supportedTokens, id: \.self) { token in
                        Button(token) { destination += token }
                    }
                } label: {
                    Label("Insert token", systemImage: "curlybraces")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }
            TextField("Documents/Invoices/{year}", text: $destination)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("Relative to \(name.isEmpty ? "the provider" : "the provider root"). Tokens fill from each file — a token a file can’t supply flags it as “needs a look” in the preview.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(assembled) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!assembled.isRunnable)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }

    // MARK: Sub-bindings into a condition's type and value

    private func typeBinding(_ condition: Binding<AutomationCondition>) -> Binding<ConditionType> {
        Binding(
            get: { ConditionType(condition.wrappedValue) },
            set: { newType in
                // Only rebuild if the type actually changed, so retyping the same kind keeps the value.
                if ConditionType(condition.wrappedValue) != newType {
                    condition.wrappedValue = newType.makeDefault()
                }
            }
        )
    }

    private func stringBinding(_ condition: Binding<AutomationCondition>) -> Binding<String> {
        Binding(
            get: {
                switch condition.wrappedValue {
                case .folderNamed(let s), .nameMatches(let s), .contentContains(let s): return s
                default: return ""
                }
            },
            set: { newValue in
                switch condition.wrappedValue {
                case .folderNamed: condition.wrappedValue = .folderNamed(newValue)
                case .nameMatches: condition.wrappedValue = .nameMatches(newValue)
                case .contentContains: condition.wrappedValue = .contentContains(newValue)
                default: break
                }
            }
        )
    }

    private func intBinding(_ condition: Binding<AutomationCondition>) -> Binding<Int> {
        Binding(
            get: {
                switch condition.wrappedValue {
                case .largerThanMB(let n), .untouchedForDays(let n): return n
                default: return 0
                }
            },
            set: { newValue in
                switch condition.wrappedValue {
                case .largerThanMB: condition.wrappedValue = .largerThanMB(max(0, newValue))
                case .untouchedForDays: condition.wrappedValue = .untouchedForDays(max(0, newValue))
                default: break
                }
            }
        )
    }

    private func kindBinding(_ condition: Binding<AutomationCondition>) -> Binding<FileKind> {
        Binding(
            get: { if case .kindIs(let k) = condition.wrappedValue { return k } else { return .pdf } },
            set: { condition.wrappedValue = .kindIs($0) }
        )
    }
}
