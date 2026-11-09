import SwiftUI
import Sync
import Design

/// The model and answer style the next question goes to, in the text box's bottom row. A pick
/// carries on in this chat and becomes the default, the same keys Settings ▸ Ask Claude shows; a
/// change there moves this chat too.
struct AskClaudeModelMenu: View {
    @AppStorage private var modelID: String
    @AppStorage private var detail: String
    private let defaults: UserDefaults
    /// The model the chat's last question went to; nil in a new chat, where nothing needs catching up.
    let chatModel: String?
    let contextTokens: Int?
    let onOpenSettings: () -> Void

    /// `defaults` is the chat's own: a test's chat must never write the app's model.
    init(defaults: UserDefaults, chatModel: String?, contextTokens: Int?, onOpenSettings: @escaping () -> Void) {
        _modelID = AppStorage(wrappedValue: AskClaudeModels.defaultModel.id, AskClaudeModels.defaultsKey, store: defaults)
        _detail = AppStorage(wrappedValue: AskClaudeDetail.brief.rawValue, AskClaudeDetail.defaultsKey, store: defaults)
        self.defaults = defaults
        self.chatModel = chatModel
        self.contextTokens = contextTokens
        self.onOpenSettings = onOpenSettings
    }

    /// A stored id this build doesn't offer shows as the model actually used, the default.
    private var current: AskClaudeModels.Option { AskClaudeModels.option(for: modelID) }
    private var currentDetail: AskClaudeDetail { AskClaudeDetail(rawValue: detail) ?? .brief }

    var body: some View {
        Menu {
            AskClaudeModelMenuItems(model: Binding(get: { current.id }, set: { modelID = $0 }),
                                    detail: Binding(get: { currentDetail.rawValue }, set: { detail = $0 }),
                                    lines: Dictionary(uniqueKeysWithValues: AskClaudeModels.options.map { ($0.id, line(for: $0)) }),
                                    onOpenSettings: onOpenSettings)
        } label: {
            Text(current.name)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .help("Which Claude answers your next question, and how fully. A change carries on in this chat.")
        .accessibilityLabel("Model and answers")
        .accessibilityValue("\(current.name), \(currentDetail.label)")
    }

    private func line(for option: AskClaudeModels.Option) -> String {
        Self.line(for: option, chatModel: chatModel, contextTokens: contextTokens, defaults: defaults, now: Date())
    }

    /// A model's second line: what it is for and what a question costs; mid-chat, for a model
    /// other than the chat's, what its first answer costs to catch up, and whether that passes the
    /// monthly limit; once the limit is reached, that it is.
    static func line(for option: AskClaudeModels.Option, chatModel: String?, contextTokens: Int?,
                     defaults: UserDefaults, now: Date) -> String {
        if case .overLimit = AskClaudeSpend.state(in: defaults, now: now) {
            return option.menuLine + " · monthly limit reached"
        }
        guard let chatModel, chatModel != option.id, let contextTokens, contextTokens > 0 else { return option.menuLine }
        let cost = AskClaudeModels.catchUpCost(contextTokens: contextTokens, to: option)
        var line = option.menuLine + " · catching up on this chat: "
            + (cost < 0.01 ? AskClaudeSpend.format(cost) : "up to " + AskClaudeSpend.format(cost))
        let limit = AskClaudeSpend.limit(in: defaults)
        if limit > 0, AskClaudeSpend.spent(in: defaults, now: now) + cost > limit { line += ", past your monthly limit" }
        return line
    }
}

/// The menu's items, apart so a test can read them through `NSHostingMenu`.
struct AskClaudeModelMenuItems: View {
    @Binding var model: String
    @Binding var detail: String
    /// Each model's second line, by id.
    let lines: [String: String]
    let onOpenSettings: () -> Void

    var body: some View {
        // Toggles, not a Picker: a menu item gets its second line (subtitle) only from a toggle or
        // button with two texts; a Picker row turns the second text into an item of its own.
        Section("Model for the next question") {
            ForEach(AskClaudeModels.options) { option in
                Toggle(isOn: Binding(get: { model == option.id }, set: { if $0 { model = option.id } })) {
                    Text(option.name)
                    Text(lines[option.id] ?? option.menuLine)
                }
            }
        }
        Picker("Answers", selection: $detail) {
            ForEach(AskClaudeDetail.allCases, id: \.rawValue) { style in
                Text(style.label).tag(style.rawValue)
            }
        }
        .pickerStyle(.inline)
        Divider()
        // On the same page as Model and Answers (TE307), so one place serves both.
        Button("Notes for Claude…", action: onOpenSettings)
        Button("Ask Claude Settings…", action: onOpenSettings)
    }
}
