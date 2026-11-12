import AppKit
import SwiftUI
import Settings
import Sync
import Design
import UniformTypeIdentifiers

/// Ask Claude’s panel: the window’s right-hand column, top to bottom, drawn beside the workspace or,
/// in a window too narrow to share the row, over its right edge. Its width comes from its parent.
struct AskClaudePanel: View {
    @ObservedObject var chat: AskClaudeChat
    /// The folder Claude sees, for the header and the shield's popover.
    let place: AskClaudePlace
    let accent: Color
    let accentFill: Color
    let onAccent: Color
    /// The window's accent, Tint and glass level, for the surfaces the column draws.
    var hue: LiquidGlassHue = .none
    var tint: Double = 0
    var level: GlassLevel = .frosted
    let onAsk: (String) -> Void
    let onClose: () -> Void
    /// Opens Settings on one of the Ask Claude tab's pages: General for the model menu,
    /// Privacy for the hidden list, Key & Spending for a key or limit problem.
    let onOpenSettings: (SettingsSubTab) -> Void
    /// The column paints as the surface style says: a header card over a thread card in Cards, one flush
    /// area under a hairline in Unified.
    var surface: SurfaceStyle = .unified
    /// Bumped to bring the text box the keyboard: opening the panel, ⌘J, Ask Claude About This.
    /// Only these move the keyboard into the column.
    var focusToken = 0
    /// Whether the keyboard goes to the text box when the panel appears. False when it was restored
    /// open at launch: a window that comes back with the chat open must not take the keyboard from
    /// the file list the person was working in.
    var takesKeyboardOnAppear = true
    /// Whether a question is being spoken, for ⌘J, which does nothing while one is.
    var onTalkingChange: (Bool) -> Void = { _ in }
    /// The shield's choice of what Claude gets from the folder on screen: ask each time, share
    /// without asking, or hide it.
    var onSetAccess: (AskClaudeFolderAccess) -> Void = { _ in }
    /// Shows the folder's pane where the workspace has folded it away.
    var onGoToFolder: () -> Void = {}
    /// Reveals a file named in an answer.
    var onReveal: (String) -> Void = { _ in }
    /// Sends an offered passage.
    var onSendOffer: (UUID, AskClaudeChat.OfferPart) -> Void = { _, _ in }
    /// A tick on a found-names card: the card, and the file by path.
    var onFoundTick: (UUID, String) -> Void = { _, _ in }
    /// A download card's buttons.
    var onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void = { _, _ in }
    /// Filing help's card buttons.
    var onFilingCard: (AskClaudeFilingAction) -> Void = { _ in }
    /// A card of changes: its ticks and row menus.
    var onPlanCard: (UUID, AskClaudePlanAction) -> Void = { _, _ in }
    /// A button under Claude's question, by its place in the row.
    var onChoice: (UUID, Int) -> Void = { _, _ in }
    /// A rule card's Save (true) or Not Now.
    var onRuleCard: (UUID, Bool) -> Void = { _, _ in }
    /// What a settings card reads and does.
    var settingsBridge = AskClaudeSettingsBridge()
    /// What a PDF card reads and does.
    var pdfBridge = AskClaudePDFBridge()
    /// What a Refine card does and reads.
    var refineBridge = AskClaudeRefineBridge()
    /// A spoken question's Send, so its bubble shows it was spoken; `onAsk` without it.
    var onAskSpoken: ((String) -> Void)?
    /// The words of the names on screen, for the transcriber to listen for (`AskClaudeVoiceHints`).
    var voiceHints: () -> [String] = { [] }
    /// Where a spoken question's audio comes from: the microphone, or a file in tests.
    var voiceSource: () -> AskClaudeVoiceSource = { AskClaudeMicrophone() }
    /// What the suggestion chip above the box may be about (TE309); nil shows none.
    var suggestions: AskClaudeSuggestionSources?
    /// What the rows on screen say, for the starters (TE347b); asked only while they show.
    var starterSignals: () -> AskClaudeStarters.Signals = { .init() }
    /// One more starter from the on-device model, given those shown; nil for none (decision NN).
    var modelStarter: (([String]) async -> String?)?
    /// The box's words after a pause in typing, for the screen guess to start on (TE347c).
    var onDraftPause: ((String) -> Void)?
    /// Words the app wrote (a starter, the suggestion chip): sent with the screen, never guessed
    /// about (V3). Nil sends them as typed.
    var onAskWritten: ((String) -> Void)?

    /// The model's starter and the rule starters it was written beside.
    @State private var extraStarter: (key: String, question: String)?
    @ObservedObject private var suggestionFeed = AskClaudeSuggestionFeed.shared

    @State private var draft = ""
    /// Whether the panel has opened in this hosting view, and whether it has just left its place in
    /// the window that it may be about to enter again (docked beside the workspace, or over it).
    @State private var hasAppeared = false
    @State private var leavingForAnotherWindow = false
    @FocusState private var composerFocused: Bool
    @State private var caret = AskClaudeComposerCaret()
    @State private var spentText = ""
    @State private var showsPlace = false
    /// Past Chats in place of the thread (TE306), and the past chat opened from it.
    @State private var showsPast = false
    @State private var pastOpened: UUID?
    /// Whether an API key is saved, asked without reading it: when the panel opens and whenever the
    /// Keychain item changes, not on every draw. Nil until asked.
    @State private var keySaved: Bool?
    @StateObject private var voice = AskClaudeVoice()
    /// The turn whose bar shows, and the wait before a bar the mouse left goes: the bar hangs a
    /// little past its row, and the mouse crosses the gap to reach it.
    @State private var hovered: AskClaudeHoverKey?
    @State private var hoverEnd: Task<Void, Never>?
    /// What the box held when Edit put a question in it, for Cancel to put back.
    @State private var draftBeforeEdit = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 372
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720
    /// The column's width while its inner (left) edge is dragged: dragging left widens it.
    /// `base` is the width when the drag began; `translation` is cumulative. Held to the panel's
    /// own width range, and to `room` when the window leaves less.
    static func pinnedDragWidth(base: Double, translation: CGFloat, room: Double = .infinity) -> Double {
        let widest = max(Double(minWidth), min(Double(maxWidth), room))
        return min(max(base - Double(translation), Double(minWidth)), widest)
    }

    var body: some View {
        layout
        .onAppear {
            // Moving the hosting view between the docked column and the overlay takes the panel out
            // of one place in the window and into the next, which SwiftUI reports as a
            // disappearance and an appearance. That is not the panel opening: the draft is
            // already here and the keyboard stays where it is.
            leavingForAnotherWindow = false
            guard !hasAppeared else { return }
            hasAppeared = true
            // A draft left when the panel closed comes back with it.
            draft = chat.draft
            if takesKeyboardOnAppear { composerFocused = true }
            refreshSpent()
            keySaved = settingsBridge.keyIsSaved()
        }
        .onReceive(NotificationCenter.default.publisher(for: AnthropicKeychain.didChange)) { _ in
            keySaved = settingsBridge.keyIsSaved()
        }
        // Kept as it's typed: a window torn down needn't say goodbye to its views.
        .onChange(of: draft) { _, typed in chat.draft = typed }
        // A pause in typing starts the screen guess, so it's usually in by Send (U1).
        .task(id: draft) {
            let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let onDraftPause, words.split(separator: " ").count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            onDraftPause(words)
        }
        // Something attached from a row's menu: the caret goes to the box for the question.
        .onChange(of: chat.attachments) { _, now in if !now.isEmpty { composerFocused = true } }
        // Edit Message on a caught-key card: the message comes back to the box.
        .onChange(of: chat.draftToRestore) { _, message in
            guard let message else { return }
            // Added to what's being typed, never in its place.
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message : draft + "\n" + message
            chat.draftToRestore = nil
            composerFocused = true
        }
        // Posted from wherever a cost is recorded, Organize's Refine off the main thread included.
        .onReceive(NotificationCenter.default.publisher(for: AskClaudeSpend.didChange).receive(on: RunLoop.main)) { _ in refreshSpent() }
        // The limit is set in Settings, which writes it straight to the defaults.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in refreshSpent() }
        // The box takes the keyboard back once the answer is in, and VoiceOver hears that it is.
        // It stays open while Claude answers, and so does listening: what is said or typed
        // meanwhile waits for the answer to end.
        .onChange(of: chat.isRunning) { _, running in
            guard !running else { return }
            if mayTakeKeyboardBack { composerFocused = true }
            if case .assistant = chat.items.last(where: { if case .receipt = $0.kind { false } else { true } })?.kind {
                AccessibilityNotification.Announcement("Claude answered").post()
            }
        }
        // Back to the box once a spoken question is sent or thrown away.
        .onChange(of: voice.isActive) { _, active in if !active, mayTakeKeyboardBack { composerFocused = true } }
        .onChange(of: draft) { _, typed in if !typed.isEmpty { voice.notice = nil } }
        .background(AskClaudeTalkKeys(onKey: talkKey, onEscape: escape, onGone: { voice.cancel() }))
        .onChange(of: focusToken) { composerFocused = true }
        .onChange(of: voice.isActive) { _, active in onTalkingChange(active) }
        // A question being spoken stops when the panel goes, but not when it only moves window:
        // the appearance that follows in the same turn says it was a move.
        .onDisappear {
            leavingForAnotherWindow = true
            DispatchQueue.main.async { if leavingForAnotherWindow { voice.cancel() } }
        }
        // Esc does not close it: it stops talking or an edit, and nothing else (P4).
        .onExitCommand(perform: {})
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask Claude")
    }

    /// The column. The header is as tall as the panes' headers, so their rule runs across it. Cards
    /// draws two cards, like every other column; Unified draws one flush area, and the column's slot
    /// gives it the surface.
    @ViewBuilder private var layout: some View {
        if surface == .cards {
            VStack(spacing: 0) {
                header
                    .frame(height: LiquidGlass.headerHeight)
                    .bottomSectionCard(.cards, level: level, hue: hue, tint: tint)
                VStack(spacing: 0) {
                    content
                }
                .bottomSectionCard(.cards, level: level, hue: hue, tint: tint)
            }
        } else {
            VStack(spacing: 0) {
                header
                    .frame(height: LiquidGlass.headerHeight)
                    .columnHeaderRule(.unified)
                content
            }
        }
    }

    /// The thread and the box, or Past Chats in their place.
    @ViewBuilder private var content: some View {
        if showsPast, let past = chat.pastChats {
            AskClaudePastChatsView(past: past, opened: $pastOpened, accentFill: accentFill, onAccent: onAccent,
                                   isRunning: chat.isRunning, defaults: chat.settingsDefaults,
                                   onContinue: { id in if chat.continuePast(id) { closePast() } },
                                   onNewChat: { chat.newChat(); closePast() },
                                   onOpenSettings: { onOpenSettings(.privacy) })
        } else {
            thread
            hairline
            composer
        }
    }

    private func closePast() {
        showsPast = false
        pastOpened = nil
        composerFocused = true
    }

    private var header: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .symbolRenderingMode(.hierarchical)
                        .scaledFont(.headline)
                    // The title, and under it what the next question will describe.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(showsPast ? "Past Chats" : "Claude").scaledFont(.headline)
                        Text(showsPast ? (chat.pastChats?.keep.subtitle ?? "") : place.subtitle)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(place.fullPath)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
            }
            AskClaudeHeaderButton(symbol: "checkmark.shield", help: "What Claude sees, and what it may see", label: "What Claude Sees",
                                  isOn: showsPlace) { showsPlace.toggle() }
                .popover(isPresented: $showsPlace, arrowEdge: .bottom) {
                    AskClaudePlaceMenu(place: place, spent: spentText, accentFill: accentFill, onAccent: onAccent,
                                       onGoTo: { showsPlace = false; onGoToFolder() },
                                       onSetAccess: { access in showsPlace = false; onSetAccess(access) },
                                       onEditHiddenList: { showsPlace = false; onOpenSettings(.privacy) })
                        .presentedNativeControlAccent()
                }
            if chat.pastChats != nil, keySaved != false {
                AskClaudeHeaderButton(symbol: "clock", help: showsPast ? "Back to the chat" : "Past chats", label: "Past Chats",
                                      isOn: showsPast) {
                    if showsPast { closePast() } else { showsPast = true }
                }
            }
            AskClaudeHeaderButton(symbol: "plus.bubble", help: "New chat", label: "New Chat") { chat.newChat(); closePast() }
                .disabled(chat.items.isEmpty && !chat.isRunning)
            AskClaudeHeaderButton(symbol: "xmark", help: ShortcutHint.tooltip("Close", AppChord.askClaude.display), label: "Close", action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The step the plain stack of newest rows moves by; the rest are lazy.
    static let recentRows = 12

    /// How many of `count` rows go in the lazy stack. The boundary moves a whole `recent` rows at a
    /// time, so the plain stack holds `recent` to `2 * recent - 1` rows once there are that many:
    /// a row crossing into the lazy stack is a new view and loses its state (an open disclosure,
    /// say), and this way rows cross once every `recent` items, not with each new one.
    static func lazyRowCount(_ count: Int, recent: Int = recentRows) -> Int {
        guard recent > 0, count >= 2 * recent else { return 0 }
        return (count - recent) / recent * recent
    }

    /// One row of the thread, with what it needs from its neighbours (`turns`, the latest receipt).
    private func threadRow(_ item: AskClaudeChat.Item, turns: AskClaudeTurns, retries: Bool, latestReceipt: UUID?) -> some View {
        let key = turns.hoverKey(of: item)
        return AskClaudeThreadRow(item: item, accent: accent, accentFill: accentFill, onAccent: onAccent, hue: hue, onOpenSettings: onOpenSettings,
                           linkTargets: chat.linkTargets, onReveal: onReveal, onSendOffer: onSendOffer, onFoundTick: onFoundTick,
                           sharesAnswers: chat.sharesAnswers, onSharesAnswers: { chat.setSharesAnswers($0) },
                           sharesNames: chat.sharesNames, onSharesNames: { chat.setSharesNames($0) },
                           onFoundEdit: { chat.editFound($0, $1) },
                           onDownloadCard: onDownloadCard,
                           onFilingCard: onFilingCard,
                           onPlanCard: onPlanCard, onChoice: onChoice, onRuleCard: onRuleCard,
                           settingsBridge: settingsBridge, pdfBridge: pdfBridge, refineBridge: refineBridge,
                           pdfThumbnails: chat.pdfThumbnails[item.id] ?? [:],
                           isLatestReceipt: item.id == latestReceipt, isRunning: chat.isRunning,
                           isExpired: chat.cardIsExpired(item.id),
                           isGrowing: chat.isRunning && item.id == chat.items.last?.id,
                           turnActions: turnActions(for: item, turns: turns, retries: retries),
                           showsBar: key != nil && hovered == key,
                           onTurnAction: { turnAction($0, on: item.id) },
                           onHover: { inside in if let key { hover(key, inside) } },
                           onUndoNote: { chat.undoNote($0) })
            // Rows that didn't change aren't redrawn as each word streams in.
            .equatable()
    }

    private var thread: some View {
        ScrollView {
                // The outer stack is plain: a lazy one can go blank after scrolling to the bottom
                // while an answer grows. The older rows inside it are lazy (below).
                VStack(alignment: .leading, spacing: 10) {
                    if let earlier = chat.earlier {
                        AskClaudePastLinesView(lines: earlier.lines, accentFill: accentFill, onAccent: onAccent)
                            // Not drawn again as each word of the new answer streams in.
                            .equatable()
                            .opacity(0.6)
                        let offers = !chat.isRunning && !chat.items.contains(where: Self.isQuestion)
                        AskClaudeEarlierLine.priced(title: "Earlier · Claude doesn’t see this", defaults: chat.settingsDefaults,
                                                    resume: { offers ? earlier.resume(model: $0, now: Date()) : nil },
                                                    onContinue: { chat.continuePast(earlier.id) })
                    }
                    // Under an earlier chat too, without the intro: the next question starts a new chat (V1).
                    if chat.items.isEmpty { starters(intro: chat.earlier == nil) }
                    let latestReceipt = chat.items.last { if case .receipt = $0.kind { true } else { false } }?.id
                    let turns = AskClaudeTurns(chat.items)
                    // Retry is for the last answer only, and only once nothing runs.
                    let retries = chat.lastQuestion.map { chat.canRewind(from: $0) } ?? false
                    // Older rows are lazy, so a long chat scrolls and opens at the cost of what is
                    // on screen, not of every row (200 answers took 117 ms a scroll step, and 900 ms to
                    // lay out, as one plain stack). The newest rows stay a plain stack: a lazy stack
                    // can go blank after scrolling to the bottom while an answer grows, and that is
                    // where answers grow. The boundary moves in steps (`lazyRowCount`).
                    let lazy = Self.lazyRowCount(chat.items.count)
                    let older = chat.items.prefix(lazy)
                    if !older.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(older) { item in
                                threadRow(item, turns: turns, retries: retries, latestReceipt: latestReceipt)
                            }
                        }
                    }
                    ForEach(chat.items.dropFirst(lazy)) { item in
                        threadRow(item, turns: turns, retries: retries, latestReceipt: latestReceipt)
                    }
                    if chat.currentResume != nil {
                        // Read again inside, so a change in the model menu prices it afresh.
                        AskClaudeEarlierLine.priced(title: "Your next question starts a new chat · Claude won’t see what’s above",
                                                    defaults: chat.settingsDefaults, resume: { _ in chat.currentResume },
                                                    onContinue: { chat.continueThisChat() })
                        if !chat.items.isEmpty { starters(intro: false) }
                    }
                    if chat.isRunning && chat.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary).scaledFont(.caption)
                        }
                        .id("thinking")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Opens at the newest message and stays there as the thread grows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }

    static func isQuestion(_ item: AskClaudeChat.Item) -> Bool {
        if case .user = item.kind { true } else { false }
    }

    /// What the next question carries after Continue.
    private var continueNote: String? {
        if chat.isCarrying { return "Your next question carries the earlier chat to Claude as text." }
        guard chat.continuing else { return nil }
        // Priced as Continue's button was, so the two agree.
        let cost = chat.continuingCost ?? 0
        return cost > 0 ? "Your next question reads this chat back in to Claude once, about \(AskClaudeSpend.format(cost))."
                        : "Your next question carries this chat on."
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if continueNote != nil {
                // Drawn again when the model menu changes, so its price follows it.
                AskClaudeWithModel(defaults: chat.settingsDefaults) { _ in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Label(continueNote ?? "", systemImage: "arrow.uturn.forward")
                            .fixedSize(horizontal: false, vertical: true)
                        if chat.isCarrying {
                            Spacer(minLength: 4)
                            Button("Cancel") { chat.cancelCarry() }.buttonStyle(.link)
                                .help("Ask without the earlier chat")
                        }
                    }
                    .scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            if chat.editing != nil { editingLine }
            if let waiting = chat.queued { queuedLine(waiting) }
            if let suggestions, !startersShow { AskClaudeSuggestionChip(sources: suggestions, chat: chat, listening: voice.isActive, draft: draft, keySaved: keySaved == true, accent: accent, onSend: { send($0, spoken: false, written: true) }, onOpenSettings: { onOpenSettings(.claudeGeneral) }) }
            if !chat.attachments.isEmpty { attachmentChips }
            if voice.isActive { listeningStrip }
            if let notice = voice.notice, !voice.isActive {
                Label(notice, systemImage: "mic.slash")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !voice.isActive { textLine }
                // The box's bottom row: which model and style the next question goes to, then the
                // mic, then Stop or Send.
                HStack(spacing: 6) {
                    AskClaudeModelMenu(defaults: chat.settingsDefaults, chatModel: chat.chatModel,
                                       contextTokens: chat.contextTokens, onOpenSettings: { onOpenSettings(.claudeGeneral) })
                        .disabled(chat.isRunning || voice.isActive)
                        .opacity(voice.isActive ? 0.55 : 1)
                    Spacer(minLength: 0)
                    micButton
                    // Stop stays while a question is said over an answer.
                    if !voice.isActive || chat.isRunning { sendOrStop }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.well))
            .overlay(RoundedRectangle(cornerRadius: Radius.well)
                .strokeBorder(AskClaudeTint.hairline(hue, accent: accent, dark: colorScheme == .dark, neutral: 0.6)))
        }
        .padding(12)
    }

    /// The box's text line. While a question is spoken, the listening strip stands in for it.
    private var textLine: some View {
        TextField("Ask a question, or say what to open", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($composerFocused)
            .onSubmit(send)
            // Up and Down walk the questions typed before, like a shell (AskClaudePromptHistory);
            // inside a question of several lines they move the caret until it's on the edge line.
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard press.isPlainKeystroke else { return .ignored }
                let up = press.key == .upArrow
                guard caret.isOnEdgeLine(up: up) else { return .ignored }
                guard let shown = up ? chat.recallOlder(than: draft) : chat.recallNewer(than: draft) else {
                    return .ignored
                }
                if !caret.show(shown, atStart: up) { draft = shown }
                return .handled
            }
            .background(AskClaudeComposerCaret.Anchor(caret: caret))
    }

    /// What is being said, while it is said: the settled words, the ones the transcriber may still
    /// change greyed after them, a level meter, the keys, and where it is heard.
    private var listeningStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heardSoFar)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(1...6)
            HStack(spacing: 8) {
                AskClaudeLevelMeter(levels: voice.levels, color: Self.voiceColor)
                Text(voice.phase == .finishing ? "Sending…" : "Tap ⌥Space to send · Esc cancels")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("On this Mac", systemImage: "lock")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .help("Your voice is turned into text on this Mac. Only the text is sent, as typed text is.")
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Self.voiceColor.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.well))
        .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(Self.voiceColor.opacity(0.55)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(listeningLabel)
    }

    /// The voice's own colour, apart from the accent, as the roadmap's mockups draw it.
    static let voiceColor = Color.purple

    /// What they typed before talking, then what they said, its unsettled tail greyed.
    private var heardSoFar: AttributedString {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch voice.phase {
        case .starting where typed.isEmpty: return Self.greyed("Starting…")
        case .installing: return Self.greyed("Downloading the speech model to this Mac…")
        default: break
        }
        var text = AttributedString([typed, voice.settled].filter { !$0.isEmpty }.joined(separator: " "))
        let tail = voice.tentative.isEmpty && text.characters.isEmpty ? "Listening…" : voice.tentative
        if !tail.isEmpty { text += Self.greyed((text.characters.isEmpty ? "" : " ") + tail) }
        return text
    }

    private static func greyed(_ text: String) -> AttributedString {
        var greyed = AttributedString(text)
        greyed.foregroundColor = .secondary
        return greyed
    }

    private var listeningLabel: String {
        switch voice.phase {
        case .installing: "Downloading the speech model"
        case .finishing: "Sending what you said"
        default: "Listening. Press Option-Space to send, Escape to cancel. " + [voice.settled, voice.tentative].joined(separator: " ")
        }
    }

    private var micButton: some View {
        Button(action: toggleTalk) {
            Image(systemName: voice.isActive ? "mic.fill" : "mic")
                .scaledFont(.body)
                .foregroundStyle(voice.isActive ? AnyShapeStyle(Self.voiceColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .disabled(voice.phase == .finishing)
        .help(ShortcutHint.tooltip(voice.isActive ? "Send what you said" : "Talk", "⌥Space"))
        .accessibilityLabel(voice.isActive ? "Send what you said" : "Talk")
    }

    /// The divider under the header and over the composer, in the accent.
    private var hairline: some View {
        Rectangle()
            .fill(AskClaudeTint.hairline(hue, accent: accent, dark: colorScheme == .dark, neutral: 0.5))
            .frame(height: 1)
    }

    @ViewBuilder private var sendOrStop: some View {
        if chat.isRunning {
            Button(action: chat.stop) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
                .help("Stop")
                .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").scaledFont(.title2).foregroundStyle(accent)
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send")
            .accessibilityLabel("Send")
        }
    }

    /// While an edited question is in the box: sending it takes back the one it edits.
    private var editingLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").foregroundStyle(.secondary)
            Text("Editing your question. Sending it takes back what came after.")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") {
                chat.cancelEdit()
                draft = draftBeforeEdit
                composerFocused = true
            }
            .help("Puts the box back as it was, and the chat stays as it is")
        }
        .buttonStyle(.link)
        .scaledFont(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(accent.opacity(0.14), in: Capsule())
    }

    /// What a row offers: Copy and Edit on a question, Copy and Retry on an answer's rows and its
    /// receipt. Edit only for a question from the box, Retry only on the last answer.
    private func turnActions(for item: AskClaudeChat.Item, turns: AskClaudeTurns, retries: Bool) -> [AskClaudeTurnAction] {
        switch item.kind {
        case .user:
            return [.copy] + (chat.canEdit(item.id) ? [.edit] : [])
        case .assistant, .receipt:
            guard let question = turns.question(of: item) else { return [] }
            return (turns.answered.contains(question) ? [.copy] : []) + (retries && question == chat.lastQuestion ? [.retry] : [])
        default:
            return []
        }
    }

    private func turnAction(_ action: AskClaudeTurnAction, on id: UUID) {
        switch action {
        case .copy:
            if let question = chat.question(id) {
                AskClaudeAnswerCopy.write(question: question)
            } else if let answer = chat.answer(inTurnOf: id) {
                AskClaudeAnswerCopy.write(answer)
            }
        case .edit:
            let before = draft
            guard let text = chat.beginEdit(id) else { return }
            draftBeforeEdit = before
            // The question replaces what was being typed; Cancel brings that back.
            draft = text
            composerFocused = true
        case .retry:
            chat.retryLast()
        }
    }

    /// The mouse over a turn, or leaving it: a bar goes a moment after, so it can be reached.
    private func hover(_ key: AskClaudeHoverKey, _ inside: Bool) {
        hoverEnd?.cancel()
        if inside {
            hovered = key
            return
        }
        guard hovered == key else { return }
        hoverEnd = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            hovered = nil
        }
    }

    /// The question waiting for the answer to end: "Next: … · Edit · Cancel", with Send once
    /// nothing runs (after a Stop or a problem, it waits for them to say).
    private func queuedLine(_ waiting: AskClaudeChat.Queued) -> some View {
        let about = waiting.attachments.isEmpty ? "" : " · about " + waiting.attachments.map(\.name).joined(separator: ", ")
        return HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("Next: \(waiting.text.replacingOccurrences(of: "\n", with: " "))\(about)")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(waiting.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !chat.isRunning {
                Button("Send") { chat.sendQueuedNow() }
                    .help("Sends it now")
            }
            Button("Edit") {
                guard let text = chat.editQueued() else { return }
                // In front of what is being typed, never in its place.
                let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = typed.isEmpty ? text : text + "\n" + typed
                composerFocused = true
            }
            .help("Puts it back in the text box")
            Button("Cancel") { chat.cancelQueued() }
                .help("Throws it away")
        }
        .buttonStyle(.link)
        .scaledFont(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(accent.opacity(0.14), in: Capsule())
    }

    /// What the next question is about: a chip per row attached from its menu, each with ✕.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.attachments) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Button { chat.detach(item.path) } label: {
                            Image(systemName: "xmark").scaledFont(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .scaledFont(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                    .help(item.path)
                    .frame(maxWidth: 200)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached")
    }

    private func send() { send(spoken: false) }

    /// Return or Send. While Claude answers, the question waits for the answer to end.
    private func send(spoken: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if chat.isRunning {
            queue(text, spoken: spoken)
        } else {
            // An edited question takes back the one it edits, and all after it, but not when it is
            // held back for a key: then nothing is sent to take its place.
            if AskClaudeKeyCatch.key(in: text) == nil { chat.finishEdit() }
            send(text, spoken: spoken)
        }
    }

    /// A question that waits for the answer: held back, like one sent, when it holds a key.
    private func queue(_ text: String, spoken: Bool) {
        if chat.catchKey(text) { return }
        chat.rememberSent(text)
        chat.queue(text, spoken: spoken)
    }

    // MARK: Starters (TE347b)

    /// Wherever the next question starts a new chat (V1). TE309's chip stays away meanwhile: its
    /// suggestion leads the starters instead (B-R8).
    private var startersShow: Bool { chat.items.isEmpty || chat.currentResume != nil }

    /// TE309's chip as it would show over an empty box, so a new chat's starters can lead with it.
    /// Not the box as it is: typing would take it out of the starters and move the rest up.
    private var suggestionChip: AskClaudeSuggestionChip? {
        suggestions.map {
            AskClaudeSuggestionChip(sources: $0, chat: chat, listening: false, draft: "", keySaved: keySaved == true,
                                    accent: accent, onSend: { _ in }, onOpenSettings: {})
        }
    }

    @ViewBuilder private func starters(intro: Bool) -> some View {
        let chip = suggestionChip
        let suggestion = chip?.isOn == true ? chip?.suggestion(now: suggestionFeed.now) : nil
        let rules = ruleStarters(suggested: suggestion?.question)
        let key = place.fullPath + "|" + rules.joined(separator: "|")
        let extra = extraStarter?.key == key ? extraStarter?.question : nil
        AskClaudeEmptyState(keySaved: keySaved, starters: rules, extra: extra, showsIntro: intro,
                            startersEnabled: !chat.isRunning && !voice.isActive, bridge: settingsBridge,
                            accent: accent, hue: hue, defaults: chat.settingsDefaults,
                            onStarter: { question in
                                if let suggestion, question == suggestion.question { chip?.recordClick(suggestion) }
                                send(question, spoken: false, written: true)
                            })
            // The model writes only while the box is empty; the first key stops it (U4).
            .task(id: draft.isEmpty && keySaved == true ? key : nil) {
                guard draft.isEmpty, keySaved == true, let modelStarter, extraStarter?.key != key else { return }
                if let kept = AskClaudeStarterCache.shared.question(for: key) {
                    extraStarter = (key, kept)
                    return
                }
                // Passing through folders writes nothing.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let question = await modelStarter(rules), !Task.isCancelled else { return }
                AskClaudeStarterCache.shared.keep(question, for: key)
                withDesignAnimation(.easeIn(duration: 0.3), reduceMotion: reduceMotion) { extraStarter = (key, question) }
            }
    }

    /// The rules' starters for the screen, led by TE309's suggestion.
    private func ruleStarters(suggested: String?) -> [String] {
        var screen = place.starterScreen
        if !place.isHidden { screen.signals = starterSignals() }
        screen.signals.suggested = suggested
        return AskClaudeStarters.questions(for: screen)
    }

    /// The box's text, or a starter's, which goes exactly as if typed and leaves the box as it was.
    private func send(_ text: String, spoken: Bool, written: Bool = false) {
        guard !text.isEmpty, !chat.isRunning else { return }
        // A key never leaves the Mac in a message, nor joins the remembered questions.
        if chat.catchKey(text) { return }
        chat.rememberSent(text)
        if spoken, let onAskSpoken { onAskSpoken(text) } else if written, let onAskWritten { onAskWritten(text) } else { onAsk(text) }
    }

    /// ⌥Space or the mic, tap to toggle: starts listening, or sends what was said. While Claude
    /// answers, what was said waits for the answer, as typing does.
    private func toggleTalk() {
        if voice.isActive {
            voice.finish()
            return
        }
        voice.start(from: voiceSource(), hints: voiceHints()) { heard in
            // Into the box after anything typed first, then sent as typing is.
            draft = [draft.trimmingCharacters(in: .whitespacesAndNewlines), heard].filter { !$0.isEmpty }.joined(separator: " ")
            send(spoken: true)
        }
    }

    /// Esc, with nothing spoken: stops an edit, and does nothing else. It never closes the panel,
    /// which its Close button, ⌘W and ⌘J do.
    private func escape() -> Bool {
        if showsPast {
            if pastOpened != nil { pastOpened = nil } else { closePast() }
            return true
        }
        guard chat.editing != nil else { return false }
        chat.cancelEdit()
        draft = draftBeforeEdit
        composerFocused = true
        return true
    }

    /// Whether the keyboard is the panel's to take back: only if it was already in the column.
    /// Without this an answer finishing or voice stopping would pull the keyboard off the file list.
    private var mayTakeKeyboardBack: Bool {
        AskClaudeColumnView.holder(in: NSApp.keyWindow) != nil
    }

    private func talkKey(_ key: AskClaudeTalkKey) -> Bool {
        switch key {
        case .toggle(let isRepeat):
            if !isRepeat { toggleTalk() }
            return true
        case .cancel:
            guard voice.isActive else { return false }
            voice.cancel()
            return true
        }
    }

    private func refreshSpent() {
        let defaults = UserDefaults.standard
        let spent = AskClaudeSpend.spent(in: defaults)
        let limit = AskClaudeSpend.limit(in: defaults)
        spentText = limit > 0
            ? "\(AskClaudeSpend.format(spent)) of \(AskClaudeSpend.format(limit))"
            : AskClaudeSpend.format(spent)
    }
}

/// Where the box's caret is, for Up and Down: on the first line Up recalls, on the last Down does.
/// Asked of the field editor in the box's own window, found through a view behind the box: the key
/// window's could be another's. Asked through `firstRect(forCharacterRange:)`, which TextKit 1 and
/// 2 both answer; reaching for `layoutManager` would drop a TextKit 2 view back to 1.
@MainActor
final class AskClaudeComposerCaret {
    fileprivate weak var anchor: NSView?

    private var editor: NSTextView? { anchor?.window?.firstResponder as? NSTextView }

    func isOnEdgeLine(up: Bool) -> Bool {
        // No field editor in front (it hasn't come up yet): nothing to move the caret through.
        guard let editor else { return true }
        return Self.isOnEdgeLine(of: editor, up: up)
    }

    /// Puts a recalled question in the box with the caret at its start after Up and its end after
    /// Down, so the same key again goes on to the next question rather than through this one's
    /// lines. Written through the field editor, which tells the binding as typing does; false with
    /// no field editor in front, for the caller to set the text itself.
    func show(_ text: String, atStart: Bool) -> Bool {
        guard let editor else { return false }
        Self.show(text, in: editor, atStart: atStart)
        return true
    }

    static func show(_ text: String, in editor: NSTextView, atStart: Bool) {
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        let caret = NSRange(location: atStart ? 0 : (editor.string as NSString).length, length: 0)
        // Not `scrollRangeToVisible`: called here, inside SwiftUI's key dispatch, it can wait on the
        // text view's layout and never return.
        editor.setSelectedRange(caret)
    }

    static func isOnEdgeLine(of view: NSTextView, up: Bool) -> Bool {
        // Mid-composition (an input method's marked text), the arrows belong to it.
        guard !view.hasMarkedText() else { return false }
        let length = (view.string as NSString).length
        let selection = view.selectedRange()
        let caret = up ? selection.location : NSMaxRange(selection)
        let edge = up ? 0 : length
        guard caret != edge else { return true }
        let caretLine = view.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        let edgeLine = view.firstRect(forCharacterRange: NSRange(location: edge, length: 0), actualRange: nil)
        return abs(caretLine.midY - edgeLine.midY) < max(1, edgeLine.height / 2)
    }

    /// Sits behind the field at its size, so it must never take the field's clicks.
    struct Anchor: NSViewRepresentable {
        let caret: AskClaudeComposerCaret
        func makeNSView(context: Context) -> NSView {
            let view = PassThrough(frame: .zero)
            caret.anchor = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { caret.anchor = view }

        final class PassThrough: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// The panel's accent paints over its pane surface. None has no hue of its own (its accent is the
/// system's, which would repaint the panel in a colour nobody picked), so it keeps the stock grays
/// at their `neutral` opacities.
enum AskClaudeTint {
    /// A divider or a field's edge. `neutral` is the separator's opacity under None.
    static func hairline(_ hue: LiquidGlassHue, accent: Color, dark: Bool, neutral: Double) -> AnyShapeStyle {
        hue == .none ? AnyShapeStyle(.separator.opacity(neutral)) : AnyShapeStyle(accent.opacity(dark ? 0.28 : 0.26))
    }

    /// Claude's bubbles and the opening note. `neutral` is the gray's opacity under None.
    static func bubble(_ hue: LiquidGlassHue, accent: Color, dark: Bool, neutral: Double) -> AnyShapeStyle {
        hue == .none ? AnyShapeStyle(.quaternary.opacity(neutral)) : AnyShapeStyle(accent.opacity(dark ? 0.16 : 0.11))
    }
}

/// One entry in the thread.
private struct AskClaudeThreadRow: View, Equatable {
    let item: AskClaudeChat.Item
    let accent: Color
    let accentFill: Color
    let onAccent: Color
    let hue: LiquidGlassHue
    let onOpenSettings: (SettingsSubTab) -> Void
    let linkTargets: [String: String]
    let onReveal: (String) -> Void
    let onSendOffer: (UUID, AskClaudeChat.OfferPart) -> Void
    let onFoundTick: (UUID, String) -> Void
    /// The chat's "Share answers without asking" tick, and how a card sets it.
    let sharesAnswers: Bool
    let onSharesAnswers: (Bool) -> Void
    /// The lookup card's "Share lookups without asking" tick, and Customize's changes.
    var sharesNames = false
    var onSharesNames: (Bool) -> Void = { _ in }
    var onFoundEdit: (UUID, AskClaudeChat.FoundEdit) -> Void = { _, _ in }
    let onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void
    let onFilingCard: (AskClaudeFilingAction) -> Void
    let onPlanCard: (UUID, AskClaudePlanAction) -> Void
    let onChoice: (UUID, Int) -> Void
    let onRuleCard: (UUID, Bool) -> Void
    let settingsBridge: AskClaudeSettingsBridge
    let pdfBridge: AskClaudePDFBridge
    let refineBridge: AskClaudeRefineBridge
    var pdfThumbnails: [Int: CGImage] = [:]
    /// The newest receipt shows its summary; older ones fold to an icon, so the thread doesn't
    /// repeat “Sent screen …” under every answer.
    var isLatestReceipt = false
    /// While a question runs, an offer's Send waits: the send would be refused.
    var isRunning = false
    /// A card from an earlier session: drawn with its buttons off (TE306).
    var isExpired = false
    /// The answer still arriving: the newest item while a question runs.
    var isGrowing = false
    /// Copy, Edit and Retry, as this row offers them: on the bar a question or receipt shows while
    /// hovered, and on the right-click menu and VoiceOver's actions.
    var turnActions: [AskClaudeTurnAction] = []
    var showsBar = false
    var onTurnAction: (AskClaudeTurnAction) -> Void = { _ in }
    /// The mouse entering or leaving the row, for which turn's bar shows.
    var onHover: (Bool) -> Void = { _ in }
    /// Undo on a ✎ Noted line (TE307).
    var onUndoNote: (UUID) -> Void = { _ in }
    @State private var showsSent = false
    /// The card row whose details are open; one at a time.
    @State private var openRow: Int?
    @Environment(\.colorScheme) private var colorScheme

    /// What the row draws from; the closures never change what it shows.
    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.linkTargets == b.linkTargets && a.isLatestReceipt == b.isLatestReceipt && a.sharesAnswers == b.sharesAnswers
            && a.sharesNames == b.sharesNames && a.isExpired == b.isExpired
            && a.isRunning == b.isRunning && a.isGrowing == b.isGrowing && a.accent == b.accent && a.accentFill == b.accentFill && a.onAccent == b.onAccent
            && a.hue == b.hue && a.pdfThumbnails == b.pdfThumbnails && a.turnActions == b.turnActions && a.showsBar == b.showsBar
    }

    static let revealScheme = "synccloud-askclaude"

    /// The answer's text with every known file name made a link that reveals it.
    ///
    /// - The answer's own links are dropped: a link Claude writes could point anywhere (a file name
    ///   or passage can carry text that asks for one), and only names this chat has seen may be
    ///   clicked.
    /// - Longest names first, whole words only, no overlaps, so "2024 Tax.pdf" isn't cut into by
    ///   "Tax.pdf", and "notes" doesn't link inside "footnotes".
    ///
    /// Drawn as its blocks: lists, tables and code as well as inline markdown. While it is still
    /// arriving, only what has `settled` is drawn.
    private func answer(_ text: String) -> [AskClaudeMarkdown.Block] {
        AskClaudeMarkdown.linked(AskClaudeMarkdown.blocks(isGrowing ? AskClaudeMarkdown.settled(text) : text),
                                 targets: linkTargets, scheme: Self.revealScheme, underline: accentFill)
    }

    var body: some View {
        switch item.kind {
        // The bar's actions, for whoever doesn't hover, on the right-click menu. Only on a
        // question, an answer and its receipt: a card keeps its own clicks. VoiceOver finds them
        // as actions on the question's bubble and on the answer's receipt.
        case .user, .assistant, .receipt:
            content
                .onHover(perform: onHover)
                .contextMenu {
                    ForEach(turnActions) { action in
                        Button(menuTitle(action), systemImage: action.symbol) { onTurnAction(action) }
                    }
                }
        default:
            if isExpired && Self.expires(item.kind) {
                VStack(alignment: .leading, spacing: 4) {
                    content.disabled(true).opacity(0.75)
                    Text("From an earlier session, so its buttons are off.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                content.onHover(perform: onHover)
            }
        }
    }

    static func expires(_ kind: AskClaudeChat.Item.Kind) -> Bool { AskClaudeChat.expires(kind) }


    private func menuTitle(_ action: AskClaudeTurnAction) -> String {
        switch action {
        case .copy: if case .user = item.kind { "Copy Question" } else { "Copy Answer" }
        case .edit: "Edit Question"
        case .retry: "Retry"
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user(let text):
            // A spoken question carries a small mic.
            (item.spoken == true ? Text("\(Image(systemName: "mic")) \(text)") : Text(text))
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(onAccent)
                .background(accentFill, in: RoundedRectangle(cornerRadius: Radius.card))
                // One element of its own over the selectable text, not the text's: while a question
                // runs, SwiftUI's label for a node backed by the selectable text's AppKit view asks
                // that view, whose label asks the node, until the stack runs out and an assistive
                // app reading the panel crashes SyncCloud.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(item.spoken == true ? "You said: \(text)" : "You: \(text)")
                .modifier(AskClaudeTurnVoiceOverActions(actions: turnActions, title: menuTitle, perform: onTurnAction))
                // Its bar shows beside the bubble while hovered.
                .modifier(AskClaudeBarBeside(shows: showsBar && !turnActions.isEmpty) {
                    AskClaudeTurnBar(actions: turnActions, perform: onTurnAction)
                        .onHover(perform: onHover)
                        .accessibilityHidden(true)
                })
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(let text):
            AskClaudeAnswerView(blocks: answer(text))
                .tint(accentFill)
                .environment(\.openURL, OpenURLAction { url in
                    // Only this chat's own reveal links, to paths it has seen; nothing else opens.
                    guard url.scheme == Self.revealScheme,
                          let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
                          linkTargets.values.contains(path)
                    else { return .discarded }
                    onReveal(path)
                    return .handled
                })
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(AskClaudeTint.bubble(hue, accent: accent, dark: colorScheme == .dark, neutral: 0.7),
                            in: RoundedRectangle(cornerRadius: Radius.card))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .step(let label, let isError):
            Label(label, systemImage: isError ? "exclamationmark.circle" : "checkmark")
                .scaledFont(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        case .moved(let note):
            Label(note, systemImage: "arrow.turn.down.right")
                .scaledFont(.callout.weight(.medium))
                .foregroundStyle(accent)
                .accessibilityHint("Use Back to return")
        case .note(let text):
            Text(text).scaledFont(.callout).foregroundStyle(.secondary)
        case .found(let found):
            foundCard(item.id, found)
        case .reads(let group):
            readsCard(item.id, group)
        case .offer(let passage, let sent):
            if passage.answer != nil || passage.whole != nil {
                heldAnswerCard(item.id, passage, passageSent: sent)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // Read with no answer to show (the on-device model was unavailable or failed):
                    // only the passage can go, by the share every other card names.
                    Text("Read \(passage.fileName) on this Mac. Claude can answer from the content it came from if you share it.")
                        .scaledFont(.callout)
                    HStack(spacing: 8) {
                        Button(AskClaudeHeldAnswer.passageButton(passage.whereInFile, sent: sent, answerSent: false)) { onSendOffer(item.id, .passage) }
                            .controlSize(.small)
                            .disabled(sent || isRunning)
                            .help("Shares only this content of the file with Claude, once.")
                        Text("\(passage.whereInFile) · about \(passage.tokens.formatted()) tokens")
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
            }
        case .download(let download, let state):
            downloadCard(download, state)
        case .filing(let card):
            filingCard(card)
        case .plan(let plan):
            planCard(plan)
        case .rule(let card):
            ruleCard(card)
        case .settings(let card):
            AskClaudeSettingCardView(itemID: item.id, card: card, bridge: settingsBridge, accent: accent, hue: hue)
        case .noted(let noted, let undone):
            AskClaudeNotedRow(noted: noted, undone: undone, accent: accent, isRunning: isRunning) { onUndoNote(item.id) }
        case .tryAnother(let line):
            Label(line.text, systemImage: "arrow.triangle.2.circlepath")
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .refine(let card):
            AskClaudeRefineCardView(itemID: item.id, card: card, bridge: refineBridge, accent: accent, hue: hue, isRunning: isRunning)
        case .pdf(let card):
            AskClaudePDFCardView(itemID: item.id, card: card, bridge: pdfBridge, accent: accent, hue: hue,
                                 isRunning: isRunning, thumbnails: pdfThumbnails)
        case .choices(let choices, let used):
            HStack(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button(choice.label) { onChoice(item.id, index) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(choice.sends == nil ? "Say where in the text box." : "Answers with “\(choice.sends ?? "")”.")
                }
            }
            .disabled(used || isRunning)
        case .problem(let problem):
            VStack(alignment: .leading, spacing: 6) {
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.primary)
                if problem.opensSettings {
                    Button("Open Settings ▸ Ask Claude") { onOpenSettings(.keyAndSpending) }.controlSize(.small)
                }
            }
            .scaledFont(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.well))
        case .receipt(let receipt):
            // The answer's bar shows at the far end of its receipt's line while the answer is
            // hovered, drawn over the line: laid out beside the receipt, even unseen, it would take
            // the receipt's width and wrap it onto two lines.
            receiptButton(receipt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if showsBar && !turnActions.isEmpty {
                        AskClaudeTurnBar(actions: turnActions, perform: onTurnAction)
                            .onHover(perform: onHover)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private func receiptButton(_ receipt: AskClaudeChat.Receipt) -> some View {
        Button { showsSent.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                if isLatestReceipt { Text(receipt.summary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
        .help(isLatestReceipt ? "What this question sent" : receipt.summary)
        .accessibilityLabel(receipt.summary)
        .modifier(AskClaudeTurnVoiceOverActions(actions: turnActions, title: menuTitle, perform: onTurnAction))
        .popover(isPresented: $showsSent, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(receipt.summary).scaledFont(.callout)
                Text("\(receipt.modelName.map { $0 + " · " } ?? "")\(receipt.rounds) round\(receipt.rounds == 1 ? "" : "s")")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                if receipt.screenWithheld == true, receipt.screenAsked != true {
                    Text(AskClaudeChat.Receipt.notSent)
                        .scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(receipt.screenText)
                        .scaledFont(ScaledFont.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
                }
            }
            .padding(12)
            .frame(width: 360)
            .presentedNativeControlAccent()
        }
    }

    /// A download: offered, downloading, then done, failed or timed out; Not Now folds it to a line.
    @ViewBuilder
    private func downloadCard(_ download: AskClaudeDownload, _ state: AskClaudeChat.DownloadState) -> some View {
        let size = download.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let verb = download.purpose == .read ? "Download and Read" : "Download and Open"
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .offered:
                Label(download.summary, systemImage: "icloud.and.arrow.down").scaledFont(.callout)
                HStack(spacing: 8) {
                    Button(verb) { onDownloadCard(item.id, .download) }
                        .controlSize(.small)
                        .help("Downloads it to this Mac, then \(download.purpose == .read ? "Claude reads it" : "it opens"). Claude never downloads without this click.")
                    Button("Not Now") { onDownloadCard(item.id, .notNow) }
                        .controlSize(.small)
                }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(download.fileName)…" + (size.map { " \($0)" } ?? "")).scaledFont(.callout)
                }
                Button("Stop Waiting") { onDownloadCard(item.id, .stopWaiting) }
                    .controlSize(.small)
                    .help("Stops waiting here. The download itself goes on until the cloud app finishes it.")
            case .done:
                Label("Downloaded \(download.fileName).", systemImage: "checkmark").scaledFont(.callout).foregroundStyle(.secondary)
            case .declined:
                Label("Didn’t download \(download.fileName).", systemImage: "icloud").scaledFont(.callout).foregroundStyle(.secondary)
            case .failed(let why):
                Label("Couldn’t download \(download.fileName): \(why).", systemImage: "exclamationmark.circle").scaledFont(.callout)
                retry()
            case .timedOut:
                Label("\(download.fileName) didn’t arrive within ten minutes.", systemImage: "exclamationmark.circle").scaledFont(.callout)
                retry()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// What a file says, held for their click: Apple Intelligence's answer exactly as it would go,
    /// when there is one, then what sharing gets them and the shares: the answer, the passage it
    /// came from, and all the text read. Nothing leaves until a click.
    private func heldAnswerCard(_ id: UUID, _ passage: AskClaudePassage, passageSent: Bool) -> some View {
        let answerSent = passage.answerSent == true
        let wholeSent = passage.wholeSent == true
        let anySent = answerSent || passageSent || wholeSent
        return VStack(alignment: .leading, spacing: 6) {
            // Whose words these are and which file: Apple's on-device model's, not Claude's and not
            // a search (`AskClaudeReading.answerOnDevice`). Claude's own question isn't shown: it
            // goes with the answer when shared.
            if passage.autoShared == .answerAndText {
                // A folder shared without asking: the answer and the page went; all of the document
                // still waits here.
                Label("Read \(passage.fileName) on this Mac. Claude has \(passage.whereInFile).", systemImage: "doc.text.magnifyingglass")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let answer = passage.answer {
                Label("Apple Intelligence read \(passage.fileName) on this Mac:", systemImage: "apple.intelligence")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(answer)
                    .scaledFont(.callout)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.well))
                    // Its own element, as the question's bubble is: a label on the selectable
                    // text's node loops while a question runs.
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Apple Intelligence read \(passage.fileName) on this Mac: \(answer)")
            } else {
                Label("Read \(passage.fileName) on this Mac.", systemImage: "doc.text.magnifyingglass")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            // What sharing is for, before the buttons: more from Claude. A card whose answer went
            // without asking still offers what's left.
            if !anySent || (passage.autoShared != nil && !(passageSent || wholeSent)) {
                Text(AskClaudeHeldAnswer.lead)
                    .scaledFont(.callout.weight(.medium))
            }
            if passage.autoShared == .answerForThisChat {
                HStack(spacing: 6) {
                    Text("Shared with Claude, as you chose for this chat.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    if sharesAnswers {
                        Button("Ask Again") { onSharesAnswers(false) }
                            .buttonStyle(.link)
                            .scaledFont(.footnote)
                            .help("Asks before sharing an answer again, from the next one on.")
                    }
                }
            }
            // Three shares don't fit the panel's width side by side; they stack when they don't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heldAnswerButtons(id, passage, passageSent: passageSent) }
                VStack(alignment: .leading, spacing: 6) { heldAnswerButtons(id, passage, passageSent: passageSent) }
            }
            if passage.answer != nil, passage.autoShared == nil, !answerSent {
                Toggle(AskClaudeHeldAnswer.answersTick, isOn: Binding(get: { sharesAnswers }, set: { onSharesAnswers($0) }))
                    .toggleStyle(.checkbox)
                    .scaledFont(.footnote)
                    .help("From the next file on, Apple Intelligence’s answer goes to Claude without waiting for a click; its card still offers page text and the whole document. A new chat asks again.")
            }
            if let whole = passage.whole, let wholeWhere = passage.wholeWhere, !wholeSent {
                Text(AskClaudeHeldAnswer.wholeSize(wholeWhere, isAll: passage.wholeIsAll == true, words: AskClaudeHeldAnswer.words(in: whole)))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(anySent ? "Claude has what you shared." : "Nothing from the file has gone to Claude.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// Names held for their click: a search inside files, or a lookup beyond the folder on screen.
    /// A plain table first, Name, Folder and Date, then Share Details (every file, every detail) or
    /// Customize…, which picks the files and the details. Nothing leaves until a click.
    private func foundCard(_ id: UUID, _ found: AskClaudeFoundNames) -> some View {
        let sent = found.sent == true
        let customizing = found.customized && !sent && found.files != nil
        let empty = found.files?.isEmpty == true
        return VStack(alignment: .leading, spacing: 6) {
            Label(AskClaudeHeldAnswer.foundTitle(found), systemImage: "doc.text.magnifyingglass")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if customizing {
                foundCustomize(id, found)
            } else {
                if !empty { foundTable(found) }
                if !sent {
                    Text(AskClaudeHeldAnswer.lead).scaledFont(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        Button(empty ? AskClaudeHeldAnswer.shareResult : AskClaudeHeldAnswer.shareDetails) { onSendOffer(id, .names) }
                            .controlSize(.small)
                            .disabled(isRunning)
                        if found.files != nil, !empty {
                            Button(AskClaudeHeldAnswer.customize) { onFoundEdit(id, .customize(true)) }
                                .controlSize(.small)
                        }
                    }
                }
                Text(AskClaudeHeldAnswer.foundFoot(found, ticked: found.ticked.count))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            if found.source != nil {
                Toggle(AskClaudeHeldAnswer.namesTick, isOn: Binding(get: { sharesNames }, set: { onSharesNames($0) }))
                    .toggleStyle(.checkbox)
                    .scaledFont(.footnote)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// The files as a table, Name, Folder and Date, no ticks; past a dozen it scrolls in the card.
    @ViewBuilder
    private func foundTable(_ found: AskClaudeFoundNames) -> some View {
        Group {
            // Once shared, only what went.
            if let files = found.files.map({ found.sent == true ? found.ticked : $0 }) {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("Name")
                            Text("Folder")
                            Text("Date")
                        }
                        .scaledFont(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        ForEach(files, id: \.path) { file in
                            GridRow {
                                Text(file.name).scaledFont(.callout).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(file.folder).scaledFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Text(AskClaudeHeldAnswer.foundDate(file)).scaledFont(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: files.count > AskClaudeHeldAnswer.foundShown ? 260 : nil)
                if found.sent != true, found.count > files.count {
                    Text(AskClaudeHeldAnswer.foundMore(shown: files.count, of: found.count))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                // A card saved before ticks: its names, as it showed them.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(found.names.prefix(6).enumerated()), id: \.offset) { _, name in
                        Text(name).scaledFont(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.well))
    }

    /// Customize what Claude gets: the details as ticks (names always go), the files as ticks with
    /// Select All and None, and a share that names what goes.
    @ViewBuilder
    private func foundCustomize(_ id: UUID, _ found: AskClaudeFoundNames) -> some View {
        let files = found.files ?? []
        let ticked = found.ticked.count
        let details = found.chosenDetails
        Text(AskClaudeHeldAnswer.customizeTitle).scaledFont(.callout.weight(.medium))
        Text(AskClaudeHeldAnswer.detailsLead).scaledFont(.footnote).foregroundStyle(.secondary)
        HStack(spacing: 10) {
            ForEach(AskClaudeFoundNames.detailKeys, id: \.self) { key in
                Toggle(key.capitalized, isOn: Binding(get: { details.contains(key) }, set: { _ in onFoundEdit(id, .detail(key)) }))
                    .toggleStyle(.checkbox)
                    .scaledFont(.footnote)
            }
        }
        HStack(spacing: 4) {
            Text(found.noun == "item" ? "Items" : "Files").scaledFont(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { onFoundEdit(id, .all(true)) }.buttonStyle(.link).scaledFont(.footnote)
            Text("·").scaledFont(.footnote).foregroundStyle(.secondary)
            Button("None") { onFoundEdit(id, .all(false)) }.buttonStyle(.link).scaledFont(.footnote)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(files, id: \.path) { file in foundRow(id, found, file, sent: false) }
            }
        }
        .frame(maxHeight: files.count > AskClaudeHeldAnswer.foundShown ? 260 : nil)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.well))
        HStack(spacing: 8) {
            Button(AskClaudeHeldAnswer.customShareButton(ticked: ticked, details: details, noun: found.noun)) { onSendOffer(id, .names) }
                .controlSize(.small)
                .disabled(isRunning || ticked == 0)
            Button("Cancel") { onFoundEdit(id, .customize(false)) }
                .controlSize(.small)
        }
        Text(AskClaudeHeldAnswer.customizeFoot(ticked: ticked, details: details))
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
    }

    /// Every file one question read, on one card: each file's tick, name and answer, then one set
    /// of shares, one tick for the rest of the chat, one footnote.
    private func readsCard(_ id: UUID, _ group: AskClaudeReadGroup) -> some View {
        let ticked = group.ticked
        let answered = ticked.filter { $0.answer != nil }.count
        let anySent = group.answersSent == true || group.textSent == true || group.wholeSent == true
        let locked = group.wholeSent == true || (group.textSent == true && group.autoShared != .answerAndText)
            || (group.answersSent == true && group.autoShared == nil)
        return VStack(alignment: .leading, spacing: 6) {
            Label(AskClaudeHeldAnswer.readsTitle(group), systemImage: group.files.contains { $0.answer != nil } ? "apple.intelligence" : "doc.text.magnifyingglass")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            ForEach(Array(group.files.enumerated()), id: \.offset) { index, file in
                let isOn = !(group.unticked ?? []).contains(index)
                // The answer sits beside the tick, not in its label: a Toggle reads its label for
                // VoiceOver, and selectable text read that way loops until the stack runs out.
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(get: { isOn }, set: { _ in if let path = file.path { onFoundTick(id, path) } })) {
                        Text(file.fileName).scaledFont(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    // Not while the question runs: a read joining the card moves it to the foot of
                    // the thread, out from under the pointer.
                    .disabled(locked || isRunning)
                    if let answer = file.answer {
                        Text(answer)
                            .scaledFont(.callout)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.well))
                            .padding(.leading, 20)
                    }
                }
            }
            if group.autoShared == .answerForThisChat {
                HStack(spacing: 6) {
                    Text("Shared with Claude, as you chose for this chat.").scaledFont(.footnote).foregroundStyle(.secondary)
                    if sharesAnswers {
                        Button("Ask Again") { onSharesAnswers(false) }.buttonStyle(.link).scaledFont(.footnote)
                    }
                }
            }
            if !(group.wholeSent == true || (group.textSent == true && group.autoShared != .answerAndText)) {
                Text(AskClaudeHeldAnswer.lead).scaledFont(.callout.weight(.medium))
            }
            VStack(alignment: .leading, spacing: 6) {
                if group.files.contains(where: { $0.answer != nil }) {
                    Button(AskClaudeHeldAnswer.readsAnswersButton(answered, sent: group.answersSent == true)) { onSendOffer(id, .answer) }
                        .controlSize(.small)
                        .disabled(group.answersSent == true || isRunning || answered == 0)
                }
                if group.autoShared != .answerAndText {
                    Button(AskClaudeHeldAnswer.readsContentButton(ticked.count, sent: group.textSent == true)) { onSendOffer(id, .passage) }
                        .controlSize(.small)
                        .disabled(group.textSent == true || isRunning || ticked.isEmpty)
                }
                Button(AskClaudeHeldAnswer.readsAllButton(ticked.count, sent: group.wholeSent == true, isAll: group.allIsAll)) { onSendOffer(id, .whole) }
                    .controlSize(.small)
                    .disabled(group.wholeSent == true || isRunning || ticked.isEmpty || !group.wholeFits(under: AskClaudeReading.wholeTokens))
            }
            if group.wholeSent != true, !ticked.isEmpty {
                Text(AskClaudeHeldAnswer.readsSize(group))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            if group.autoShared == nil, group.answersSent != true, group.files.contains(where: { $0.answer != nil }) {
                Toggle(AskClaudeHeldAnswer.answersTick, isOn: Binding(get: { sharesAnswers }, set: { onSharesAnswers($0) }))
                    .toggleStyle(.checkbox)
                    .scaledFont(.footnote)
            }
            Text(anySent ? "Claude has what you shared." : "Nothing from these files has gone to Claude.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// One found file: its tick, name, and the folder and date that go with it.
    private func foundRow(_ id: UUID, _ found: AskClaudeFoundNames, _ file: AskClaudeFoundNames.File, sent: Bool) -> some View {
        let isOn = !(found.unticked ?? []).contains(file.path)
        return Toggle(isOn: Binding(get: { isOn }, set: { _ in onFoundTick(id, file.path) })) {
            HStack(spacing: 6) {
                Text(file.name).scaledFont(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(AskClaudeHeldAnswer.foundDetail(file))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(sent)
    }

    @ViewBuilder
    private func heldAnswerButtons(_ id: UUID, _ passage: AskClaudePassage, passageSent: Bool) -> some View {
        let answerSent = passage.answerSent == true
        let wholeSent = passage.wholeSent == true
        if passage.answer != nil {
            Button(AskClaudeHeldAnswer.answerButton(sent: answerSent)) { onSendOffer(id, .answer) }
                .controlSize(.small)
                .disabled(answerSent || isRunning)
                .help("Lets Claude see only the answer above, once.")
        }
        if passage.autoShared != .answerAndText {
            Button(AskClaudeHeldAnswer.passageButton(passage.whereInFile, sent: passageSent, answerSent: answerSent)) { onSendOffer(id, .passage) }
                .controlSize(.small)
                .disabled(passageSent || isRunning)
                .help("Lets Claude see the text of \(passage.whereInFile) of \(passage.fileName) itself, about \(passage.tokens.formatted()) tokens, once.")
        }
        if let wholeWhere = passage.wholeWhere, let whole = passage.whole {
            Button(AskClaudeHeldAnswer.wholeButton(wholeWhere, isAll: passage.wholeIsAll == true, sent: wholeSent)) { onSendOffer(id, .whole) }
                .controlSize(.small)
                .disabled(wholeSent || isRunning)
                .help("Lets Claude see the text of \(wholeWhere) of \(passage.fileName), about \(AskClaudePassage.estimatedTokens(whole).formatted()) tokens, once.")
        }
    }

    /// Filing help: where the file fits by their own conventions, each folder with Go to Folder and
    /// Move Here; Refine with Claude when the answer isn't High; Setup when there's no profile.
    @ViewBuilder
    private func filingCard(_ card: AskClaudeFilingCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card.kind {
            case .suggestions:
                ForEach(Array(card.folders.enumerated()), id: \.offset) { index, folder in
                    // TE327: a new folder shows how it's named, and its buttons make it.
                    let isNew = folder.isNew == true
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: isNew ? "folder.badge.plus" : "folder").foregroundStyle(isNew ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                            Text(folder.label).scaledFont(.callout.weight(.medium)).lineLimit(2).truncationMode(.head)
                        }
                        Text("\(index == 0 ? "" : "Runner-up · ")\(isNew ? "New folder · " : "")\(folder.confidence) · \(folder.reason)\(folder.note.map { " · \($0)" } ?? "")")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                        AskClaudeFolderNameLine(folder: folder)
                        HStack(spacing: 6) {
                            AskClaudeNewFolderButtons.goTo(folder) { onFilingCard(.goTo($0)) }
                            Button(isNew ? "Make and Move Here" : "Move Here") { onFilingCard(.moveHere(item: item.id, file: card.filePath, folder: folder.path, label: folder.label)) }
                                .controlSize(.small)
                                .help(isNew ? "Makes a card with the new folder and the move. Nothing changes until you click Apply; one Undo takes both back."
                                            : "Makes this a card with one move. Nothing moves until you click Apply.")
                        }
                    }
                }
                if let kept = card.nameKept { Text(kept).scaledFont(.footnote).foregroundStyle(.secondary) }
                if let names = card.names {
                    AskClaudeHeldNamesStrip(names: names, count: card.folders.filter { $0.newName != nil }.count, canShare: true) { onFilingCard(.shareNames(item: item.id)) }
                }
                if let days = card.staleDays {
                    Text("From a survey \(days) days old: folders made since aren’t known. Update the Survey is in Organize ▸ Restructure.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
                if card.canRefine {
                    Button("Refine with Claude…") { onFilingCard(.refine(card.filePath)) }
                        .controlSize(.small)
                        .help("Opens this file’s folder in Organize and refines its suggestion there. The price is shown before anything is sent.")
                }
            case .noProfile:
                Label("No folder survey yet, so there’s nothing of how you file to go by.", systemImage: "folder.badge.questionmark")
                    .scaledFont(.callout)
                Button("Open Setup") { onFilingCard(.openSetup) }
                    .controlSize(.small)
                    .help("Setup’s folder survey learns how you file; this answer comes from it.")
            case .outside(let surveyed):
                Label("Your folder survey covers \(surveyed); \(card.place ?? "that place") isn’t in it.", systemImage: "folder.badge.questionmark")
                    .scaledFont(.callout)
            case .noMatch:
                Label("No folder in your folder survey fits \(card.fileName).", systemImage: "folder.badge.questionmark")
                    .scaledFont(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// A correction offered as a rule: its words, its folder and where this file goes. Saved only
    /// on the click.
    private func ruleCard(_ card: AskClaudeRuleCard) -> some View {
        let added = Set(card.added)
        let words = card.words.enumerated().reduce(Text("")) { text, entry in
            let word = Text(entry.element)
            let shown = added.contains(entry.element) ? word.bold().foregroundColor(accent) : word
            return entry.offset == 0 ? shown : text + Text(" · ") + shown
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(card.title).scaledFont(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(card.also.isEmpty ? "Mentions any of" : "Mentions any of these, and also “\(card.also.joined(separator: "” and “"))”")
                .scaledFont(.footnote).foregroundStyle(.secondary)
            words.scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Label(card.destination, systemImage: "folder")
                .scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.exampleLine + (card.sourceLine.map { " " + $0 } ?? ""))
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch card.state {
            case .offered:
                HStack(spacing: 8) {
                    Text(isRunning ? "Save waits for Claude to finish." : "Runs free on your Mac, in To File and Ask Claude.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Not Now") { onRuleCard(item.id, false) }
                    Button(card.added.isEmpty ? "Save Rule" : "Add Words") { onRuleCard(item.id, true) }
                        .buttonStyle(.borderedProminent)
                        .accentedProminent()
                        .disabled(isRunning)
                        .help("Saves the rule. Edit it or switch it off in Organize ▸ Rules.")
                }
                .controlSize(.small)
                .padding(.top, 4)
            case .saved:
                Label("Saved “\(card.rule.name)”. Edit it in Organize ▸ Rules.", systemImage: "checkmark.circle")
                    .scaledFont(.callout).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .declined:
                Text("Not saved.").scaledFont(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// A card of changes: one line per item, grouped by the folder it goes to, and a click opens a
    /// row's details. Text follows the app's text size. Every line is held to the card's width: a
    /// long name shortens in the middle, a long path wraps in the details, and nothing sizes the
    /// card from its own text.
    private func planCard(_ plan: AskClaudePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.title).scaledFont(.headline)
                if !plan.subtitle.isEmpty {
                    Text(plan.subtitle)
                        .scaledFont(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 1) {
                    planGroupHeading(entry.group, count: entry.rows.count)
                    ForEach(entry.rows) { row in planRow(row, plan: plan) }
                }
            }
            if let left = plan.leftHere {
                Text(left).scaledFont(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let names = plan.names {
                AskClaudeHeldNamesStrip(names: names, count: plan.namedRows.count, canShare: plan.state == .proposed) { onPlanCard(item.id, .shareNames) }
            }
            planFooter(plan)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// "Girish - 2025" with "in Travel · 3" beside it; the full path is in each row's details.
    private func planGroupHeading(_ group: AskClaudePlan.Group, count: Int) -> some View {
        let (title, detail): (String, String?) = {
            switch group {
            case .folder(let label):
                let parts = label.components(separatedBy: " › ")
                let parent = parts.count > 1 ? "in \(parts[parts.count - 2]) · " : ""
                return (parts.last ?? label, label.isEmpty ? nil : "\(parent)\(count)")
            case .needsPick: return ("Needs Your Pick", "\(count)")
            case .alreadyFiled: return ("Already Filed", "\(count)")
            case .emptied: return ("Emptied Folders", nil)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).scaledFont(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).scaledFont(.footnote).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(group == .needsPick ? "Open a row to pick its folder" : { if case .folder(let l) = group { return l } else { return "" } }())
    }

    /// The SF Symbol for a file by its kind.
    static func symbol(for name: String, change: AskClaudePlan.Change) -> String {
        switch change {
        case .newFolder: return "folder.badge.plus"
        case .trashIfEmptied: return "folder"
        case .rename: return "pencil"
        default: break
        }
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return "film" }
        return "doc"
    }

    private func planRow(_ row: AskClaudePlan.Row, plan: AskClaudePlan) -> some View {
        let editable = plan.state == .proposed && row.refusal == nil
        let isOpen = openRow == row.id
        let dotColor: Color = row.refusal != nil ? .secondary
            : row.isTrash ? .red
            : row.group == .needsPick ? .orange
            : row.confidence == AskClaudeFiling.label(.high) ? .green
            : row.confidence == nil ? .clear : .orange
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Toggle("", isOn: Binding(get: { row.ticked }, set: { onPlanCard(item.id, .tick(row.id, $0)) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!editable)
                    .accessibilityLabel(row.name)
                Image(systemName: Self.symbol(for: row.name, change: row.change))
                    .scaledFont(.callout).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(row.newName ?? row.name)
                    .scaledFont(.body)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(row.refusal != nil || row.applied == false)
                    .foregroundStyle(row.refusal != nil ? AnyShapeStyle(.secondary) : row.isTrash ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if row.applied == true {
                    Image(systemName: "checkmark").scaledFont(.callout).foregroundStyle(.green)
                }
                // Its own width, never squeezed by the name: shortened here, so the name takes what's left.
                HStack(spacing: 5) {
                    // TE331: a folder they set, which teaches a rule at Apply.
                    if row.teaches {
                        // Label-colour words; the accent is the hairline (DS1).
                        Text("Your pick").scaledFont(.footnote).foregroundStyle(.primary)
                            .padding(.horizontal, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.6), lineWidth: 1))
                            .help("You chose this folder. After Apply, the card offers a rule for files like it.")
                    }
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(AskClaudeThreadRowShortening.shortened(AskClaudeThreadRowShortening.destinationWord(row), to: 18))
                        .scaledFont(.callout)
                        .foregroundStyle(row.group == .needsPick ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .fixedSize()
                Image(systemName: "chevron.right")
                    .scaledFont(.footnote).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { openRow = isOpen ? nil : row.id }
            .help("Click for where it goes and why")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isOpen ? "Closes its details" : "Opens its details")
            AskClaudeRowNameLine(row: row)
            if isOpen { planDetails(row, editable: editable) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(isOpen ? AnyShapeStyle(accent.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.control))
    }

    /// A row's details: where exactly, why, the file, and what else it could do.
    private func planDetails(_ row: AskClaudePlan.Row, editable: Bool) -> some View {
        let line: (String, String) -> AnyView = { key, value in
            AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key).scaledFont(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(value).scaledFont(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            })
        }
        var fileFacts: [String] = []
        if let size = row.size { fileFacts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let modified = row.modified { fileFacts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        if let from = row.fromLabel { fileFacts.append("in \(from)") }
        let destination: String? = {
            switch row.change {
            case .move: return row.folderLabel
            case .newFolder(_, let name): return row.folderLabel.map { "\($0) › \(name)" }
            case .rename(_, let to): return "Renamed to \(to)"
            case .trash: return "The Trash"
            case .trashIfEmptied(let folders): return "The Trash, if empty: " + folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            }
        }()
        // Not for an unsure row: its folder isn't decided.
        let folderPath: String? = {
            guard row.group != .needsPick, case .move(_, let to) = row.change else { return nil }
            return to
        }()
        // The item itself, while it is still where the card found it.
        let previewable: Bool = {
            switch row.change {
            case .move, .rename, .trash: return row.applied != true
            case .newFolder, .trashIfEmptied: return false
            }
        }()
        return VStack(alignment: .leading, spacing: 5) {
            if let refusal = row.refusal { line("Can’t", refusal).foregroundStyle(.orange) }
            if let result = row.result { line("Result", result) }
            if row.group == .needsPick {
                line("Goes to", "Not decided: pick one below")
            } else if let destination {
                line("Goes to", destination)
            }
            if let reason = row.reason { line("Why", reason) }
            AskClaudeNameDetails(row: row, editable: editable) { onPlanCard(item.id, .setName(row.id, $0)) }
            if editable, case .newFolder(_, let name) = row.change {
                AskClaudeNewFolderNameField(name: name) { onPlanCard(item.id, .renameFolder(row.id, $0)) }
            }
            if row.teaches, row.wasUnsure != true, let was = row.pickedFromLabel { line("Was", was) }
            if let note = row.note { line("Note", note) }
            if !fileFacts.isEmpty { line("File", fileFacts.joined(separator: " · ")) }
            // Only a real choice: one folder is already said by Goes To.
            if editable, case .move = row.change, row.choices.count > 1 || row.group == .needsPick {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Folders").scaledFont(.callout).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(row.choices.enumerated()), id: \.offset) { _, choice in
                            let chosen = row.group != .needsPick && folderPath == choice.path
                            Button { onPlanCard(item.id, .choose(row.id, choice)) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(chosen ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                                    Text(choice.label.components(separatedBy: " › ").suffix(2).joined(separator: " › "))
                                        .lineLimit(2).truncationMode(.head)
                                    // Only when it says something: every choice of an unsure row is unsure.
                                    if let confidence = choice.confidence, confidence != AskClaudeFiling.label(.low) {
                                        Text(confidence).foregroundStyle(.secondary)
                                    }
                                }
                                .scaledFont(.callout)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(choice.label)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // One line when they fit, else two: a narrow panel would cut "Choose Folder…" short.
            let choose = editable && { if case .move = row.change { true } else { false } }()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { detailButtons(row, choose: choose, preview: previewable, folder: folderPath) }
                    .fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    if choose { Button("Choose Folder…") { onPlanCard(item.id, .chooseFolder(row.id)) }.fixedSize() }
                    HStack(spacing: 6) { detailButtons(row, choose: false, preview: previewable, folder: folderPath) }
                        .fixedSize()
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.leading, 25)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailButtons(_ row: AskClaudePlan.Row, choose: Bool, preview: Bool, folder: String?) -> some View {
        if choose { Button("Choose Folder…") { onPlanCard(item.id, .chooseFolder(row.id)) } }
        if preview { Button("Quick Look") { onPlanCard(item.id, .quickLook(row.change.path)) } }
        if let folder { Button("Go to Folder") { onPlanCard(item.id, .goTo(folder)) } }
    }

    /// Apply and Not Now; then applying, done with Undo, or partly done. Next asks for the next
    /// card, whatever this one's state.
    @ViewBuilder
    private func planFooter(_ plan: AskClaudePlan) -> some View {
        let count = plan.runnable.count
        VStack(alignment: .leading, spacing: 8) {
            switch plan.state {
            case .proposed:
                HStack(spacing: 8) {
                    Text(isRunning ? "Apply waits for Claude to finish." : "Nothing changes until you click Apply.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Not Now") { onPlanCard(item.id, .notNow) }
                    Button(count == 0 ? "Apply" : "Apply \(count)") { onPlanCard(item.id, .apply) }
                        .buttonStyle(.borderedProminent)
                        .accentedProminent()
                        .disabled(count == 0 || isRunning)
                        .help("Makes the ticked changes, checking each one again first. One Undo takes them all back.")
                }
            case .applying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Applying \(count) change\(count == 1 ? "" : "s")…").scaledFont(.callout)
                }
            case .applied, .partlyApplied:
                Label(plan.summary ?? "Applied.", systemImage: plan.state == .applied ? "checkmark.circle" : "exclamationmark.circle")
                    .scaledFont(.callout)
                    .foregroundStyle(plan.state == .applied ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                if plan.undoName != nil {
                    HStack(spacing: 8) {
                        Button("Undo") { onPlanCard(item.id, .undo) }
                            .help("Takes back everything this card did, as Edit ▸ Undo does.")
                        Text("Also in Edit ▸ Undo").scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .undone:
                // What the undo did, once it ran (`recordUndo`); a card saved before that says
                // only that it was undone.
                Label(plan.summary.flatMap { $0.hasPrefix("Undone") ? $0 : nil } ?? "Undone.", systemImage: "arrow.uturn.backward")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            case .declined:
                Text("Not applied.").scaledFont(.callout).foregroundStyle(.secondary)
            }
            if let label = plan.nextLabel, plan.nextAsk != nil {
                Divider()
                HStack(spacing: 8) {
                    Text(plan.more ?? "").scaledFont(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(label) { onPlanCard(item.id, .next) }
                        .disabled(isRunning)
                        .help("Asks Claude for the next card of loose files.")
                }
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    private func retry() -> some View {
        HStack(spacing: 8) {
            Button("Try Again") { onDownloadCard(item.id, .download) }.controlSize(.small)
            Button("Reveal in Finder") { onDownloadCard(item.id, .revealInFinder) }
                .controlSize(.small)
                .help("Shows it in Finder, where you can download it yourself.")
        }
    }

}

/// A turn's actions for VoiceOver. Attached once, whatever the actions are: an `if` per action
/// would swap the whole bubble for another view each time Edit or Retry comes or goes, at every
/// run's start and end, dropping selected text and rebuilding the accessibility element just as a
/// run begins.
private struct AskClaudeTurnVoiceOverActions: ViewModifier {
    let actions: [AskClaudeTurnAction]
    let title: (AskClaudeTurnAction) -> String
    let perform: (AskClaudeTurnAction) -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(title(action)) { perform(action) }
            }
        }
    }
}

/// One of the header's icon buttons: a fixed hit area, a hover wash, and its own tooltip.
private struct AskClaudeHeaderButton: View {
    let symbol: String
    let help: String
    /// What VoiceOver says: the name alone, without the tooltip's shortcut.
    var label: String? = nil
    /// Lit while what it opens is showing.
    var isOn = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(ScaledFont.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background((hovering || isOn) && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// Where an answer names a file this chat has seen.
enum AskClaudeLinks {
    /// Each place in `text` naming one of `targets` (name → path): longest names first, whole
    /// words only, never overlapping, so "2024 Tax.pdf" isn't cut into by "Tax.pdf" and "notes"
    /// doesn't link inside "footnotes".
    ///
    /// A name without an extension (a folder, nearly always) is often an ordinary word too: it
    /// links only spelled as the folder is, and never before 's. So "all-pages scans" leaves the
    /// Scans folder alone and "Shweta's passport" leaves the Shweta folder, while
    /// "Passport/Shweta" still links.
    ///
    /// A name with an extension links in any case, unless another file's name differs from it
    /// only in case (iCloud's Notes.txt, Dropbox's notes.txt): then only the exact spelling links.
    static func matches(of targets: [String: String], in text: String) -> [(range: Range<String.Index>, path: String)] {
        var found: [(range: Range<String.Index>, path: String)] = []
        let caseVariants = Dictionary(grouping: targets.keys, by: { $0.lowercased() })
        for (name, path) in targets.sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) {
            let isWord = !hasExtension(name)
            let exactOnly = isWord || (caseVariants[name.lowercased()]?.count ?? 0) > 1
            var search = text.startIndex..<text.endIndex
            while let hit = text.range(of: name, options: exactOnly ? [] : [.caseInsensitive], range: search) {
                search = hit.upperBound..<text.endIndex
                guard isWholeWord(hit, in: text), !found.contains(where: { $0.range.overlaps(hit) }) else { continue }
                if isWord, isPossessive(after: hit, in: text) { continue }
                found.append((hit, path))
            }
        }
        return found
    }

    /// Whether `name` ends in a file extension: a dot and one to five letters or digits, not all
    /// digits ("Tax.pdf" does; "Checking 6436" and "v1.2" don't).
    static func hasExtension(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && !ext.allSatisfy(\.isNumber)
    }

    /// Whether 's or ’s follows `range`, ending a word.
    static func isPossessive(after range: Range<String.Index>, in text: String) -> Bool {
        let rest = text[range.upperBound...]
        guard rest.hasPrefix("'s") || rest.hasPrefix("’s") else { return false }
        let end = rest.index(rest.startIndex, offsetBy: 2)
        return end == text.endIndex || !(text[end].isLetter || text[end].isNumber)
    }

    /// `attributed` with its own links dropped and each of `targets` linked under `scheme`. A link
    /// carries a thin underline in its own colour at half strength: colour alone doesn't read as
    /// clickable in a bubble that is itself tinted.
    static func linked(_ attributed: AttributedString, targets: [String: String], scheme: String, underline: Color) -> AttributedString {
        var attributed = attributed
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        let plain = String(attributed.characters)
        for (found, path) in matches(of: targets, in: plain) {
            let start = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: length)
            var components = URLComponents()
            components.scheme = scheme
            components.host = "reveal"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let url = components.url else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: underline.opacity(0.5))
        }
        return attributed
    }

    /// Whether `range` starts and ends at a word's edge.
    static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return !(before?.isLetter == true || before?.isNumber == true) && !(after?.isLetter == true || after?.isNumber == true)
    }
}

/// What a download card's button asks for.
enum AskClaudeDownloadAction: Equatable {
    case download, stopWaiting, notNow, revealInFinder
}

/// What a card of changes asks for.
enum AskClaudePlanAction: Equatable {
    case tick(Int, Bool)
    /// A row sent to one of its menu's folders.
    case choose(Int, AskClaudePlan.Choice)
    /// Choose Folder… in a row's details.
    case chooseFolder(Int)
    /// A new folder's name, edited in its details (TE327).
    case renameFolder(Int, String)
    /// The name a move lands under, typed in its details, or nil to keep its own (TE328).
    case setName(Int, String?)
    /// Share Names and Folders (TE328).
    case shareNames
    /// The card's own buttons.
    case apply, notNow, undo
    /// A row's details: Quick Look on the item, Go to Folder on where it goes.
    case quickLook(String)
    case goTo(String)
    /// Next 10: asks for the next card.
    case next
}

/// What filing help's card asks for.
enum AskClaudeFilingAction: Equatable {
    case goTo(String)
    /// Refine with Claude for this file, in Organize.
    case refine(String)
    case openSetup
    /// Move Here: the card becomes a one-row plan card.
    case moveHere(item: UUID, file: String, folder: String, label: String)
    /// Share Names and Folders (TE328).
    case shareNames(item: UUID)
}

/// How a card row says where it goes, short.
enum AskClaudeThreadRowShortening {
    /// `text` cut in the middle to `limit` characters: "Girish - 2025" stays, a long one keeps both ends.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// Where a row goes, short, for the end of its line.
    static func destinationWord(_ row: AskClaudePlan.Row) -> String {
        if row.group == .needsPick { return "Pick a folder" }
        switch row.change {
        case .trash, .trashIfEmptied: return "Trash"
        case .rename(_, let to): return to
        default: return row.folderLabel.map { $0.components(separatedBy: " › ").last ?? $0 } ?? ""
        }
    }
}

extension AskClaudeChat.Receipt {
    /// The sheet's words for a screen that stayed on this Mac (TE347c).
    static let notSent = "Your screen wasn’t sent: this question looked unrelated to your files. Claude can ask for it, and Retry sends it."

    /// The line under an answer: what it sent and cost, led by the model's name when it changed.
    var summary: String {
        let rows = rowsSent == rowsTotal ? "\(rowsSent) rows" : "\(rowsSent) of \(rowsTotal) rows"
        let screen = screenAsked == true ? "screen when Claude asked · \(rows)"
            : screenWithheld == true ? "no screen"
            : screenUnchanged ? "screen unchanged" : "screen · \(rows)"
        let tokens = (promptTokens + outputTokens).formatted(.number.notation(.compactName))
        let named = showsModel == true ? modelName.map { $0 + " · " } ?? "" : ""
        let notes = self.notes.map { $0.receiptWords + " · " } ?? ""
        return "\(named)Sent \(notes)\(screen) · \(tokens) tokens · \(AskClaudeSpend.format(costUSD))"
    }

    /// The model that answered, by its short name; the fallback's, marked, when one answered any
    /// round instead of the one asked for. Nil for a receipt that never heard from a model.
    var modelName: String? {
        if let fallbackModel { return AskClaudeModels.name(ofServed: fallbackModel) + ", fallback" }
        guard !model.isEmpty else { return nil }
        if let requested, requested != model { return AskClaudeModels.name(ofServed: model) + ", fallback" }
        return AskClaudeModels.name(ofServed: model)
    }
}

/// The held-answer card's words, apart from the view so a test reads them.
enum AskClaudeHeldAnswer {
    /// What sharing is for, above the buttons: the answer is already on their screen, so the card
    /// says what sharing gets them.
    static let lead = "Get more insights from Claude:"

    /// The held-answer card's tick: answers only, never page text.
    static let answersTick = "Share answers without asking for the rest of this chat"

    /// The held answer's button: the box above it.
    static func answerButton(sent: Bool) -> String { sent ? "Answer Shared" : "Share This Answer" }

    /// The passage's button, naming where its content is from — "Share Content from Page 2",
    /// "Also Share Content from Pages 1–2" once the answer has gone. "Content", not the page or
    /// the file: only text goes, never the document, and only the passage the answer came from. A
    /// file without pages says "the Document", or "All Content from the Document" when the passage
    /// is the whole of its text (`AskClaudeReading.claudePassage`).
    static func passageButton(_ whereInFile: String, sent: Bool, answerSent: Bool) -> String {
        let content: String
        if whereInFile.hasPrefix("page") {
            content = "Content from " + whereInFile.prefix(1).uppercased() + whereInFile.dropFirst()
        } else {
            content = whereInFile == "the text" ? "All Content from the Document" : "Content from the Document"
        }
        if sent { return "Content Shared" }
        return answerSent ? "Also Share \(content)" : "Share \(content)"
    }

    /// Share All Content's button: "Share All Content from the Document" only when it is all of
    /// it; otherwise the pages it is, "Share Content from Pages 1–40", or the first part of a file
    /// without pages. Never "all" of what wasn't read (`AskClaudeReading.wholeDocument`).
    static func wholeButton(_ wholeWhere: String, isAll: Bool, sent: Bool) -> String {
        if sent { return isAll ? "All Content Shared" : "Content Shared" }
        if isAll { return "Share All Content from the Document" }
        if wholeWhere.hasPrefix("page") { return "Share Content from " + wholeWhere.prefix(1).uppercased() + wholeWhere.dropFirst() }
        return "Share the First Part of the Document"
    }

    /// How much Share All Content sends, before the click: pages when there are any, and words.
    static func wholeSize(_ wholeWhere: String, isAll: Bool, words: Int) -> String {
        let about = "about \(roundedWords(words).formatted()) word\(words == 1 ? "" : "s")"
        if isAll {
            let pages = wholeWhere.hasPrefix("all ") && wholeWhere != "all of it" ? String(wholeWhere.dropFirst(4)) + ", " : ""
            return "All content: \(pages)\(about)."
        }
        let part = wholeWhere.prefix(1).uppercased() + wholeWhere.dropFirst()
        return "\(part): \(about), not the whole document."
    }

    static func words(in text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// A group card's title: who read how many files.
    static func readsTitle(_ group: AskClaudeReadGroup) -> String {
        let files = "\(group.files.count) files"
        if group.autoShared == .answerAndText { return "Read \(files) on this Mac. Claude has the passages that answer." }
        return group.files.contains { $0.answer != nil } ? "Apple Intelligence read \(files) on this Mac:" : "Read \(files) on this Mac:"
    }

    /// The group's shares, counting the ticked files.
    static func readsAnswersButton(_ ticked: Int, sent: Bool) -> String {
        sent ? "Answers Shared" : ticked == 1 ? "Share This Answer" : ticked == 0 ? "Share Answers" : "Share \(ticked) Answers"
    }

    static func readsContentButton(_ ticked: Int, sent: Bool) -> String {
        sent ? "Content Shared" : ticked == 1 ? "Share Content from 1 File" : ticked == 0 ? "Share Content" : "Share Content from \(ticked) Files"
    }

    /// Never "all" of what wasn't all read, as on the one-file card: "Share What Was Read from 3
    /// Files" when any ticked file's text stops short of its end.
    static func readsAllButton(_ ticked: Int, sent: Bool, isAll: Bool = true) -> String {
        let what = isAll ? "All Content" : "What Was Read"
        if sent { return isAll ? "All Content Shared" : "Content Shared" }
        return ticked == 1 ? "Share \(what) from 1 File" : ticked == 0 ? "Share \(what)" : "Share \(what) from \(ticked) Files"
    }

    /// How much all the ticked files' text is, and whether it fits one share.
    static func readsSize(_ group: AskClaudeReadGroup) -> String {
        let words = group.ticked.reduce(0) { $0 + Self.words(in: AskClaudeReadGroup.allText($1)) }
        let about = "about \(roundedWords(words).formatted()) word\(words == 1 ? "" : "s")"
        let what = group.allIsAll ? "All content" : "What was read, not all of every file"
        return group.wholeFits(under: AskClaudeReading.wholeTokens)
            ? "\(what): \(about)." : "\(what): \(about), too long to share at once. Untick some files."
    }

    /// A found-names card's title: who found them, what, where. It credits Spotlight, or SyncCloud
    /// when only the folders it has opened were searched.
    static func foundTitle(_ found: AskClaudeFoundNames) -> String {
        let title = foundTitleWords(found)
        return found.count == 0 ? String(title.dropLast()) + "." : title
    }

    private static func foundTitleWords(_ found: AskClaudeFoundNames) -> String {
        let files = found.count == 0 ? "no \(found.noun)s" : found.count == 1 ? "1 \(found.noun)" : "\(found.count) \(found.noun)s"
        switch found.source {
        case nil: return "Spotlight found \(files) mentioning “\(found.words)” in \(found.folderLabel), on this Mac:"
        case .names:
            return found.fromIndex == false
                ? "SyncCloud found \(files) named “\(found.words)” in \(found.folderLabel), among the folders it has opened:"
                : "Spotlight found \(files) named “\(found.words)” in \(found.folderLabel), on this Mac:"
        case .listing: return "\(found.folderLabel) holds \(files), on this Mac:"
        }
    }

    static let shareDetails = "Share Details"
    /// A search inside files that found nothing: "none" waits for a click too.
    static let shareResult = "Share This Result"

    /// Under a table that holds only some of them (a page of a longer list): "60 of 200 shown".
    static func foundMore(shown: Int, of total: Int) -> String {
        "\(shown) of \(total) shown; Claude is told how to see the rest if you share."
    }
    static let customize = "Customize…"
    static let customizeTitle = "Customize what Claude gets"
    static let detailsLead = "Details, with each name"
    /// The lookup card's tick: lookups go without asking until New Chat.
    static let namesTick = "Share lookups without asking for the rest of this chat"

    /// A found file's date in the table: "Sep 2, 2026".
    static func foundDate(_ file: AskClaudeFoundNames.File) -> String {
        file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
    }

    /// Customize's share, naming what goes: "Share 18 Files with Folder and Date", "Share 19 Files
    /// with All Details", "Share 18 Names Only" with every detail unticked.
    static func customShareButton(ticked: Int, details: [String], noun: String) -> String {
        guard ticked > 0 else { return "Share" }
        if details.isEmpty { return ticked == 1 ? "Share 1 Name Only" : "Share \(ticked) Names Only" }
        let things = ticked == 1 ? "1 \(noun.capitalized)" : "\(ticked) \(noun.capitalized)s"
        let with = details.count == AskClaudeFoundNames.detailKeys.count ? "All Details"
            : AskClaudeChat.listed(details.map(\.capitalized))
        return "Share \(things) with \(with)"
    }

    /// Customize's footnote: what goes, plainly. "Claude gets 18 names, each with its folder and date."
    static func customizeFoot(ticked: Int, details: [String]) -> String {
        guard ticked > 0 else { return "Not shared yet. Nothing is ticked." }
        let names = ticked == 1 ? "1 name" : "\(ticked) names"
        let with = details.isEmpty ? ", and nothing else" : ", each with its \(AskClaudeChat.listed(details))"
        return "Not shared yet. Claude gets \(names)\(with). No file content."
    }

    /// Past this many files the card's list scrolls.
    static let foundShown = 12

    /// A found file's folder and date, as the card shows them beside its name.
    static func foundDetail(_ file: AskClaudeFoundNames.File) -> String {
        [file.folder, file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// What the shares send, before the click; who has what, after.
    static func foundFoot(_ found: AskClaudeFoundNames, ticked: Int) -> String {
        if found.sent == true {
            if found.files?.isEmpty == true { return "Claude has the result you shared." }
            let names = ticked == 1 ? "1 name" : "\(ticked) names"
            if found.namesOnly == true { return "Claude has the \(names) you shared, and nothing else." }
            let details = found.chosenDetails
            if found.customized, details.count < AskClaudeFoundNames.detailKeys.count {
                return "Claude has the \(names) you shared, each with its \(AskClaudeChat.listed(details))."
            }
            return "Claude has the list you shared."
        }
        if found.files?.isEmpty == true { return "Not shared yet. Share This Result tells Claude none matched. No file content." }
        return "Not shared yet. Share Details sends each \(found.noun)’s name, folder, kind, size, date and tags. No file content."
    }

    /// Words to two significant figures past 1,000: a size, not a count.
    static func roundedWords(_ words: Int) -> Int {
        guard words >= 1_000 else { return words }
        let step = words >= 10_000 ? 1_000 : 100
        return (words + step / 2) / step * step
    }
}

extension AskClaudeChat {
    /// The cards whose buttons go off once their session has passed. Refine and Try Another run on
    /// Organize's clock, not the chat's, and keep theirs.
    nonisolated static func expires(_ kind: Item.Kind) -> Bool {
        switch kind {
        case .user, .assistant, .step, .moved, .receipt, .problem, .note, .refine, .tryAnother: false
        default: true
        }
    }
}
