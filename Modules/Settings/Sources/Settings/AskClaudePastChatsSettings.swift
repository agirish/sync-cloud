import SwiftUI
import Design
import Sync

/// Ask Claude ▸ Privacy ▸ Past chats (TE306): how long chats are kept on this Mac, and Clear All.
/// Its own section, so the page it sits on can move without it.
struct AskClaudePastChatsSettings: View {
    /// Where the chats are; nil in tests and previews that pass none, which then count none.
    var files: AskClaudePastChatFiles? = AskClaudePastChatFiles.defaultFolder.map(AskClaudePastChatFiles.init(folder:))
    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init

    /// What the menu shows. `choose` writes through `defaults`, which is this store in the app.
    @AppStorage(AskClaudePastChatKeep.defaultsKey) private var keepRaw: String = AskClaudePastChatKeep.standard.rawValue
    @State private var described: String?

    var body: some View {
        SettingsSection(
            "Past chats",
            caption: "Kept on this Mac only, and searched here. Names in a folder you hide from Claude later are hidden in them, and Continue sends only your questions from those chats."
        ) {
            SettingsRow("Keep past chats") {
                HStack(spacing: 8) {
                    Picker("Keep past chats", selection: Binding(get: { AskClaudePastChatKeep(rawValue: keepRaw) ?? .standard },
                                                                set: { choose($0) })) {
                        ForEach(AskClaudePastChatKeep.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How long a chat stays in Ask Claude’s Past Chats after its last question.")
                    Button("Clear All…", role: .destructive) {
                        clearAll(confirm: RemovalPrompt.clearPastChats(count: files?.entries().count ?? 0).ask)
                    }
                    .controlSize(.small)
                    .disabled(described == nil)
                    .help("Deletes every past chat from this Mac. Asks first.")
                    Text(described ?? "None yet").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AskClaudePastChatFiles.didChange).receive(on: DispatchQueue.main)) { _ in reload() }
    }

    private func reload() {
        described = files.flatMap { AskClaudePastChatFiles.describe($0.entries()) }
    }

    /// A shorter keep length deletes the chats past it, so it asks first when there are any.
    func choose(_ choice: AskClaudePastChatKeep, confirm: ((Int) -> Bool)? = nil) {
        let expired = files?.expired(keep: choice, now: now()).count ?? 0
        if expired > 0 {
            let ask = confirm ?? { RemovalPrompt.shortenPastChats(count: $0, keep: choice.label.lowercased()).ask() }
            guard ask(expired) else { return }
        }
        defaults.set(choice.rawValue, forKey: AskClaudePastChatKeep.defaultsKey)
        if expired > 0 {
            files?.prune(keep: choice, now: now())
            NotificationCenter.default.post(name: AskClaudePastChatFiles.didChange, object: nil)
        }
        reload()
    }

    /// Clear All asks first: every past chat goes at once.
    @discardableResult
    func clearAll(confirm: () -> Bool) -> Bool {
        RemovalPrompt.actIfConfirmed(confirm: confirm) {
            files?.clearAll()
            NotificationCenter.default.post(name: AskClaudePastChatFiles.didChange, object: nil)
            reload()
        }
    }
}
