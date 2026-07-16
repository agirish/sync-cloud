import AppKit
import SwiftUI
import Sync

// MARK: - Remembered rule card

/// One remembered filing rule (F3) as a card in the Automations lens: enable switch, the
/// plain-words trigger, the home-abbreviated destination, and Edit / Forget. Styled to sit beside
/// ``AutomationRuleCard`` while reading as the simpler, learned-by-example kind of rule it is.
struct RememberedRuleCard: View {
    let rule: FilingRule
    let accent: Color
    /// How many of the current scan's suggestions this rule accounts for (0 when unknown).
    let drivesCount: Int
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onForget: () -> Void

    /// Mirrors `rule.enabled` so the switch binds to local `@State` (a plain `Binding`) rather than
    /// a captured closure — the latter trips Swift 6's `@Sendable`-setter check on `Binding(set:)`.
    @State private var isEnabled: Bool

    init(rule: FilingRule, accent: Color, drivesCount: Int,
         onToggle: @escaping (Bool) -> Void, onEdit: @escaping () -> Void, onForget: @escaping () -> Void) {
        self.rule = rule
        self.accent = accent
        self.drivesCount = drivesCount
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onForget = onForget
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
                .help(rule.enabled ? "Disable this rule (kept for later)" : "Enable this rule")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(FilingRulePhrasing.trigger(rule.tokens))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    if drivesCount > 0 {
                        Text("drives \(drivesCount) suggestion\(drivesCount == 1 ? "" : "s")")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.forward").font(.system(size: 8.5, weight: .bold))
                    Image(systemName: "folder.fill").font(.system(size: 9))
                    Text(FilingRulePhrasing.destination(rule.destinationPath))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .help(rule.destinationPath)
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(accent.opacity(0.10)))
            }
            HStack(spacing: 2) {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Review and edit this rule")
                Button(action: onForget) { Image(systemName: "trash") }
                    .help("Forget this rule")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.top, 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(rule.enabled ? 0.5 : 0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .opacity(rule.enabled ? 1 : 0.7)
    }
}

// MARK: - Remembered rule editor

/// Reviews and edits a remembered rule's trigger words and destination. Presented right after a
/// rule is learned (the review step) and from the Automations lens's Edit button. Trigger words are
/// re-canonicalized on save with the SAME tokenizer files are matched with (`FilingEngine.nameTokens`),
/// so an entry like "tesla-model-3" can never save in a form that silently never fires; the rule's
/// `enabled` state is carried through unchanged.
struct FilingRuleEditorView: View {
    /// The sheet's title — "Review remembered rule" for the just-learned review, "Edit remembered
    /// rule" from the manage list.
    let title: String
    let original: FilingRule
    let accent: Color
    let onSave: (FilingRule) -> Void
    let onCancel: () -> Void

    @State private var tokensText: String
    @State private var destination: String

    init(title: String, original: FilingRule, accent: Color,
         onSave: @escaping (FilingRule) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.original = original
        self.accent = accent
        self.onSave = onSave
        self.onCancel = onCancel
        _tokensText = State(initialValue: original.tokens.joined(separator: ", "))
        _destination = State(initialValue: original.destinationPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "memories").foregroundStyle(accent)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            Divider()

            Form {
                Section {
                    TextField("invoice, acme", text: $tokensText)
                } header: {
                    Text("Trigger words")
                } footer: {
                    if canonicalTokens.isEmpty && !tokensText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("These words are too generic to match on — add a distinctive word (a vendor, topic, or year).")
                    } else {
                        Text("A file matches when its name or contents include all of these words. Separate with commas or spaces.")
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        TextField("Destination folder", text: $destination)
                            .font(.system(.callout, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browse() }
                    }
                } header: {
                    Text("File matching files into")
                } footer: {
                    Text(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "Choose the folder these files should be filed into."
                         : FilingRulePhrasing.destination(normalizedDestination))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 400)
    }

    /// Canonical form the engine expects — produced by the SAME tokenizer that files are matched
    /// with (split on every non-alphanumeric, lowercase, drop stopwords and short/bare-number
    /// tokens), so what saves is exactly what can fire.
    private var canonicalTokens: [String] {
        FilingEngine.nameTokens(tokensText).sorted()
    }

    private var normalizedDestination: String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : (trimmed as NSString).expandingTildeInPath
    }

    private var isValid: Bool {
        // The destination must be an absolute path: rules are matched to a provider by
        // absolute-path prefix, so a relative destination is silently filtered out of every scan
        // forever — a rule that looks saved but can never fire.
        !canonicalTokens.isEmpty && normalizedDestination.hasPrefix("/")
    }

    private func save() {
        guard isValid else { return }
        onSave(FilingRule(tokens: canonicalTokens, destinationPath: normalizedDestination, enabled: original.enabled))
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where matching files should be filed"
        if !normalizedDestination.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (normalizedDestination as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            destination = url.path
        }
    }
}
