import Design
import Events
import SwiftUI
import Sync

/// What an empty chat shows. With no API key saved, setting up first: what Ask Claude does, where
/// a key comes from, and the API key card, so the first question isn't the one that finds out.
/// With a key, the opening note (until its ✕ hides it, TE347a) and a few questions that fit the
/// screen. The text box stays usable either way.
struct AskClaudeEmptyState: View {
    /// Whether a key is saved, asked without reading it; nil until asked.
    let keySaved: Bool?
    let starters: [String]
    /// The on-device model's question, shown last once the pointer is off the starters (U3).
    var extra: String?
    /// TE309's suggestion where it leads the starters, with the chip's Not Now and Don't Suggest.
    var suggestion: AskClaudeStarterSuggestion?
    /// Only a chat with nothing above it opens with the intro (V1).
    var showsIntro = true
    /// Off while Claude answers or a question is being spoken.
    let startersEnabled: Bool
    let bridge: AskClaudeSettingsBridge
    let accent: Color
    let hue: LiquidGlassHue
    let onStarter: (String) -> Void
    /// The intro's ✕ writes here: the chat's own defaults, so a test never hides his intro.
    @AppStorage private var introShown: Bool
    /// Set by the ✕: this chat says once where the intro went. A new chat draws a new empty state.
    @State private var justHidIntro = false
    /// Over the starters: the model's question waits, so nothing appears under the pointer.
    @State private var overStarters = false
    @State private var shownExtra: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The setup's own API key card: it isn't in the chat, so it keeps its refusal here.
    @State private var setupCard = AskClaudeSettingCard(rows: [AskClaudeSettingCard.Row(id: "intelligence.apiKey")])

    init(keySaved: Bool?, starters: [String], extra: String? = nil, suggestion: AskClaudeStarterSuggestion? = nil,
         showsIntro: Bool = true, startersEnabled: Bool,
         bridge: AskClaudeSettingsBridge, accent: Color, hue: LiquidGlassHue, defaults: UserDefaults,
         onStarter: @escaping (String) -> Void) {
        self.keySaved = keySaved
        self.starters = starters
        self.extra = extra
        self.suggestion = suggestion
        self.showsIntro = showsIntro
        self.startersEnabled = startersEnabled
        self.bridge = bridge
        self.accent = accent
        self.hue = hue
        self.onStarter = onStarter
        _introShown = AppStorage(wrappedValue: true, AskClaudeIntro.shownKey, store: defaults)
    }

    static let intro = "Ask about your files, or tell me what to open: a folder, a file, a tab, another cloud, or a place in SyncCloud. I can look things up, move your view, and change how SyncCloud looks when you ask, with Undo. Other changes, to files or settings, happen only when you click on their card."
    /// Where a key is made. Shown as text, with a link beside it.
    static let console = "platform.claude.com"
    static let consoleKeys = URL(string: "https://platform.claude.com/settings/keys")!
    /// Shown once, in the chat whose intro was just hidden.
    static let introHidden = "Intro hidden. Settings ▸ Ask Claude ▸ General brings it back."
    /// Not a chat item, so it never meets one's id.
    static let setupCardID = UUID(uuidString: "7E315000-0000-4000-8000-000000000315")!

    var body: some View {
        if keySaved == false {
            setup
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if introShown && showsIntro {
                    introBubble
                } else if justHidIntro, showsIntro {
                    Text(Self.introHidden)
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// Always shows its ✕, quietly, so the keyboard and VoiceOver find it too (U6).
    private var introBubble: some View {
        bubble(Text(Self.intro).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 14))
            .overlay(alignment: .topTrailing) {
                Button {
                    introShown = false
                    justHidIntro = true
                    Logger.shared.info("Ask Claude: intro hidden from new chats")
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Hide the intro")
                .accessibilityLabel("Hide the intro")
            }
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
            AskClaudeSettingCardView(itemID: Self.setupCardID, card: setupCard, bridge: setupBridge, hue: hue)
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
            ForEach(starters + [shownExtra].compactMap { $0 }.filter { !starters.contains($0) }, id: \.self) { question in
                Button { onStarter(question) } label: {
                    Label(question, systemImage: "arrow.up.circle")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Asks “\(question)”")
                .modifier(SuggestionMenu(suggestion: question == suggestion?.question ? suggestion : nil))
            }
        }
        .disabled(!startersEnabled)
        .onHover { over in
            overStarters = over
            if !over, shownExtra != extra {
                withDesignAnimation(.easeIn(duration: 0.3), reduceMotion: reduceMotion) { shownExtra = extra }
            }
        }
        .onChange(of: extra, initial: true) { _, now in
            guard !overStarters || now == nil else { return }
            withDesignAnimation(.easeIn(duration: 0.3), reduceMotion: reduceMotion) { shownExtra = now }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions to start with")
    }
}

extension AskClaudePlace {
    /// What the starters are keyed by.
    var starterScreen: AskClaudeStarters.Screen {
        AskClaudeStarters.Screen(workspace: workspace, source: source, folder: folder, itemCount: itemCount,
                                 folderHidden: isHidden, openFile: openFile)
    }
}

/// TE309's suggestion where a new chat's starters lead with it, and what its chip offered beside
/// it (TE347 review): Not Now, Don't Suggest and its settings, on the right-click menu and to
/// VoiceOver.
struct AskClaudeStarterSuggestion {
    let question: String
    let kindTitle: String
    let notNow: () -> Void
    let dontSuggest: () -> Void
    let settings: () -> Void
}

private struct SuggestionMenu: ViewModifier {
    let suggestion: AskClaudeStarterSuggestion?

    func body(content: Content) -> some View {
        if let suggestion {
            content
                .contextMenu {
                    Button("Not Now", action: suggestion.notNow)
                    Button("Don’t Suggest \(suggestion.kindTitle)", action: suggestion.dontSuggest)
                    Divider()
                    Button("Suggestion Settings…", action: suggestion.settings)
                }
                .accessibilityAction(named: "Not Now", suggestion.notNow)
                .accessibilityAction(named: "Don’t Suggest \(suggestion.kindTitle)", suggestion.dontSuggest)
        } else {
            content
        }
    }
}
