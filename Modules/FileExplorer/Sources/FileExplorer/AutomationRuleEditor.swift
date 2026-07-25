import AppKit
import SwiftUI
import Sync

// MARK: - Condition type (the editor's type picker)

/// The editable *type* of a condition, decoupled from its value so the editor can offer a picker and
/// swap the underlying ``AutomationCondition`` while keeping the row.
private enum ConditionType: String, CaseIterable, Identifiable {
    case folderNamed, nameMatches, kindIs, mentionsAll, largerThanMB, untouchedForDays, contentContains
    var id: String { rawValue }

    var label: String {
        switch self {
        case .folderNamed: return "In a folder named"
        case .nameMatches: return "Name matches"
        case .kindIs: return "Kind is"
        case .largerThanMB: return "Larger than"
        case .untouchedForDays: return "Not modified in"
        case .contentContains: return "Text contains"
        case .mentionsAll: return "Mentions the words"
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
        case .mentionsAll: self = .mentionsAll
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
        case .mentionsAll: return .mentionsAll(["invoice"])
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
    /// The folder destinations resolve against (the folder being previewed). When non-nil, a Browse…
    /// button appears and relativizes the picked folder against this root; nil hides Browse.
    let browseRoot: URL?
    let onSave: (AutomationRule) -> Void
    let onCancel: () -> Void

    private let ruleID: UUID
    private let wasEnabled: Bool
    private let isNew: Bool

    @State private var name: String
    @State private var matchMode: AutomationRule.MatchMode
    @State private var rows: [DraftCondition]
    @State private var destination: String

    init(rule: AutomationRule, accent: Color, browseRoot: URL? = nil,
         onSave: @escaping (AutomationRule) -> Void, onCancel: @escaping () -> Void) {
        self.accent = accent
        self.browseRoot = browseRoot
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
            conditions: rows.map { Self.canonicalized($0.condition) },
            destinationTemplate: destination.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Save-time canonicalization: a `mentionsAll` row's free-typed words become the exact tokens
    /// the engine matches with (`FilingEngine.nameTokens` — lowercased, stopwords and bare numbers
    /// dropped, sorted). Editing keeps the raw text; only the saved rule is canonical, so an entry
    /// like "Tesla-Model-3" can never save in a form that silently never fires. `internal` so tests
    /// can pin it.
    nonisolated static func canonicalized(_ condition: AutomationCondition) -> AutomationCondition {
        guard case .mentionsAll(let tokens) = condition else { return condition }
        return .mentionsAll(FilingEngine.nameTokens(tokens.joined(separator: " ")).sorted())
    }

    /// A `mentionsAll` row whose visible text canonicalizes to NOTHING (all stopwords / bare
    /// numbers / 1-char fragments). Saving it would silently drop the condition — and in an
    /// all-of rule that *broadens* the rule to whatever the other conditions match — so Save is
    /// blocked and the row explains itself instead. `internal` so tests can pin it.
    nonisolated static func isUnmatchableMentions(_ condition: AutomationCondition) -> Bool {
        guard case .mentionsAll(let tokens) = condition else { return false }
        let hasVisibleText = tokens.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasVisibleText else { return false }   // a blank row is plain "incomplete", not a trap
        if case .mentionsAll(let canonical) = Self.canonicalized(condition) { return canonical.isEmpty }
        return false
    }

    private var hasUnmatchableMentionsRow: Bool {
        rows.contains { Self.isUnmatchableMentions($0.condition) }
    }

    /// The Save gate: runnable AND no unmatchable-mentions row. The second half is what makes
    /// the `isUnmatchableMentions` warning's promise real — canonicalization would save such a
    /// row as `.mentionsAll([])`, which the evaluator ignores, silently BROADENING an all-of
    /// rule to whatever its other conditions match (and batch-eligible rules then blind-file on
    /// it). `internal` so tests can pin the gate without a view.
    nonisolated static func canSave(isRunnable: Bool, conditions: [AutomationCondition]) -> Bool {
        isRunnable && !conditions.contains(where: isUnmatchableMentions)
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
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
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
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").padding(3).contentShape(Rectangle())
            }
                .buttonStyle(.hoverAffordance(.inline))
                .padding(-3)
                .foregroundStyle(.secondary)
                .help("Remove this condition")
        }
    }

    @ViewBuilder
    private func valueEditor(_ condition: Binding<AutomationCondition>) -> some View {
        switch condition.wrappedValue {
        case .folderNamed:
            HStack(spacing: 5) {
                TextField("Downloads", text: stringBinding(condition))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                Button {
                    if let name = pickFolderName() { stringBinding(condition).wrappedValue = name }
                } label: {
                    Image(systemName: "folder").padding(3).contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent)).controlSize(.small)
                .padding(-3)
                .help("Pick a folder — its name fills in")
            }
        case .nameMatches:
            TextField("*.pdf", text: stringBinding(condition))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
        case .contentContains:
            TextField("invoice", text: stringBinding(condition))
                .textFieldStyle(.roundedBorder).controlSize(.small)
        case .mentionsAll:
            VStack(alignment: .leading, spacing: 3) {
                TextField("tesla, insurance", text: tokensBinding(condition))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .help("The file must mention every word — in its name or its text. Separate with commas.")
                if Self.isUnmatchableMentions(condition.wrappedValue) {
                    Text("These words are too generic to match on — add a distinctive word (a vendor, topic, or year).")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .kindIs:
            Picker("", selection: kindBinding(condition)) {
                ForEach(FileKind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 130)
        case .largerThanMB:
            HStack(spacing: 5) {
                TextField("100", value: intBinding(condition), format: .number)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                Text("MB").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .untouchedForDays:
            HStack(spacing: 5) {
                TextField("365", value: intBinding(condition), format: .number)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 64)
                Text("days").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("File it into")
                Spacer()
                if browseRoot != nil {
                    Button(action: browseForDestination) {
                        Label("Browse…", systemImage: "folder")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverAffordance(.segment, tint: accent))
                    .controlSize(.small)
                }
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
            // The caption states which of the two destination forms the field currently holds, so
            // a leading slash is a visible choice, never a silent reinterpretation.
            if destination.trimmingCharacters(in: .whitespaces).hasPrefix("/") {
                Text("An absolute folder path (starts with “/”) — this rule only acts in the provider that contains that folder. Remove the leading slash to make it relative to the provider root instead.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Relative to the provider root\(browseRoot.map { " (\($0.lastPathComponent))" } ?? ""). Tokens fill from each file — a token a file can’t supply flags it as “needs a look” in the preview.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Opens a folder picker and returns the picked folder's name (its last path component) — for the
    /// "in a folder named …" condition, which matches on a file's parent-folder name, not a path.
    private func pickFolderName() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder Name"
        panel.message = "Pick a folder — the rule matches files whose parent folder has this name."
        if let browseRoot { panel.directoryURL = browseRoot }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.lastPathComponent
    }

    /// Opens a folder picker rooted at the provider root (`browseRoot`) and sets the destination to
    /// the picked folder's path relative to it — so Browse yields the same relative path the preview
    /// resolves against (both anchor at the provider root). Tokens like {year} can be appended after.
    private func browseForDestination() {
        guard let browseRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to file matching files into."
        panel.directoryURL = browseRoot
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        if let relative = Self.relativePath(of: picked, under: browseRoot) {
            destination = relative
        } else {
            let alert = NSAlert()
            alert.messageText = "Pick a folder inside \(browseRoot.lastPathComponent)"
            alert.informativeText = "Automations file into the folder you’re previewing, so the destination has to be inside it. You can append tokens like {year} after choosing."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// The path of `target` relative to `base`, or nil when `target` is not inside `base` (an empty
    /// string when they’re the same folder). Symlinks are resolved so /var and /private/var match.
    static func relativePath(of target: URL, under base: URL) -> String? {
        let baseComponents = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let targetComponents = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard targetComponents.count >= baseComponents.count,
              Array(targetComponents.prefix(baseComponents.count)) == baseComponents else { return nil }
        return targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(assembled) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // Gate on the RAW rows, not `assembled`: canonicalization already stripped the
                // unmatchable row there, which is exactly the silent broadening being blocked.
                .disabled(!Self.canSave(isRunnable: assembled.isRunnable, conditions: rows.map(\.condition)))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func sectionLabel(_ text: String) -> some View {
        // The app-wide eyebrow spec: caption2 semibold, .textCase uppercase, 0.4 kerning.
        Text(text)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
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
                // Clamp the high end too, so `mb * bytesPerMB` in the evaluator can never overflow
                // (1_000_000 = bytesPerMB); a 13+ digit paste would otherwise reach the multiply.
                case .largerThanMB: condition.wrappedValue = .largerThanMB(min(max(0, newValue), Int.max / 1_000_000))
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

    /// Free-text round-trip for a `mentionsAll` row. While editing, the WHOLE field is held as a
    /// single element so get(set(text)) == text — no per-keystroke splitting or trimming, which
    /// would eat spaces as they're typed and yank the caret. Canonicalization (tokenizer splits,
    /// lowercase, stopwords) happens once, at save (see `canonicalized`); a stored canonical array
    /// displays back as its comma-joined form.
    private func tokensBinding(_ condition: Binding<AutomationCondition>) -> Binding<String> {
        Binding(
            get: {
                if case .mentionsAll(let tokens) = condition.wrappedValue { return tokens.joined(separator: ", ") }
                return ""
            },
            set: { newValue in
                guard case .mentionsAll = condition.wrappedValue else { return }
                condition.wrappedValue = .mentionsAll([newValue])
            }
        )
    }
}
