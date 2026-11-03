import Design
import SwiftUI
import Sync

/// What an empty chat shows. With no API key saved, setting up first (TE315): what Ask Claude
/// does, where a key comes from, and the API key card, so the first question isn't the one that
/// finds out. With a key, the opening note and a few questions that fit the screen (TE299). The
/// text box stays usable either way.
struct AskClaudeEmptyState: View {
    /// Whether a key is saved, asked without reading it; nil until asked.
    let keySaved: Bool?
    let starters: [String]
    /// Off while Claude answers or a question is being spoken.
    let startersEnabled: Bool
    let bridge: AskClaudeSettingsBridge
    let accent: Color
    let hue: LiquidGlassHue
    let onStarter: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// The setup's own API key card: it isn't in the chat, so it keeps its refusal here.
    @State private var setupCard = AskClaudeSettingCard(rows: [AskClaudeSettingCard.Row(id: "intelligence.apiKey")])

    static let intro = "Ask about your files, or tell me what to open: a folder, a file, a tab, another cloud, or a place in SyncCloud. I can look things up, move your view, and change how SyncCloud looks when you ask, with Undo. Other changes, to files or settings, happen only when you click on their card."
    /// Where a key is made. Shown as text, with a link beside it.
    static let console = "platform.claude.com"
    static let consoleKeys = URL(string: "https://platform.claude.com/settings/keys")!
    /// Not a chat item, so it never meets one's id.
    static let setupCardID = UUID(uuidString: "7E315000-0000-4000-8000-000000000315")!

    var body: some View {
        if keySaved == false {
            setup
        } else {
            VStack(alignment: .leading, spacing: 10) {
                bubble(Text(Self.intro).foregroundStyle(.secondary))
                if keySaved == true, !starters.isEmpty { starterList }
            }
        }
    }

    private func bubble(_ content: some View) -> some View {
        content
            .padding(10)
            .background(AskClaudeTint.bubble(hue, accent: accent, dark: colorScheme == .dark, neutral: 0.6),
                        in: RoundedRectangle(cornerRadius: Radius.card))
    }

    // MARK: No key yet (TE315)

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            bubble(VStack(alignment: .leading, spacing: 8) {
                Text("Set Up Ask Claude").scaledFont(.headline)
                Text("Ask about your files, or tell me what to open. I can look things up and move your view; files and settings change only when you click on a card.")
                    .foregroundStyle(.secondary)
                Text("It needs a Claude API key. Make one in the Claude Console, then paste it below.")
                HStack(spacing: 8) {
                    Text(Self.console).textSelection(.enabled)
                    Link("Open the Console ↗", destination: Self.consoleKeys)
                        .help("Opens the Claude Console’s API keys page in your browser")
                }
                .scaledFont(.callout)
                Text("Claude Max, Ultra and Team plans include monthly API credit: claim it by linking a Console organization in claude.ai’s Billing settings.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true))
            AskClaudeSettingCardView(itemID: Self.setupCardID, card: setupCard, bridge: setupBridge, accent: accent, hue: hue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set Up Ask Claude")
    }

    /// The panel's bridge, but a save lands here: the record hears of it, Claude doesn't, since
    /// there is no chat yet. Once it's saved the Keychain says so and the setup gives way.
    private var setupBridge: AskClaudeSettingsBridge {
        var bridge = bridge
        let save = bridge.saveSetupKey
        bridge.saveKey = { _, row, key in
            let why = save(key)
            if setupCard.rows.indices.contains(row) { setupCard.rows[row].refusal = why }
        }
        return bridge
    }

    // MARK: Starters (TE299)

    private var starterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(starters, id: \.self) { question in
                Button { onStarter(question) } label: {
                    Label(question, systemImage: "arrow.up.circle")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Asks “\(question)”")
            }
        }
        .disabled(!startersEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions to start with")
    }
}

extension AskClaudePlace {
    /// What the starters are keyed by (TE299).
    var starterScreen: AskClaudeStarters.Screen {
        AskClaudeStarters.Screen(workspace: workspace, source: source, folder: folder, itemCount: itemCount,
                                 folderHidden: isHidden, openFile: openFile)
    }
}
