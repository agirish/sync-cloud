import AppKit
import SwiftUI
import Settings
import Sync
import Design
import UniformTypeIdentifiers

/// Ask Claude’s panel (RD69, v7.0): attached to the window, hanging from its toolbar button over
/// the right edge of the content (decision DO). It covers the content’s right side while open and
/// pushes nothing narrower.
struct AskClaudePanel: View {
    @ObservedObject var chat: AskClaudeChat
    /// The folder Claude sees, for the header and the shield's popover (TE260).
    let place: AskClaudePlace
    let accent: Color
    let accentFill: Color
    let onAccent: Color
    /// The window's accent, Tint and glass level (TE291). The panel is a window of its own, so it
    /// paints a pane's surface itself — a gray popover read as a system popup over the app.
    var hue: LiquidGlassHue = .none
    var tint: Double = 0
    var level: GlassLevel = .frosted
    let onAsk: (String) -> Void
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    /// The area the panel lives in, for keeping a moved panel inside the window (TE248).
    var container: CGSize = .zero
    /// Puts the folder on screen on the Never show Claude list (true) or takes it off (TE246).
    var onSetHidden: (Bool) -> Void = { _ in }
    /// Shows the folder's pane where the workspace has folded it away (TE260).
    var onGoToFolder: () -> Void = {}
    /// Reveals a file named in an answer (TE245).
    var onReveal: (String) -> Void = { _ in }
    /// Sends an offered passage (decision DS).
    var onSendOffer: (UUID, AskClaudeChat.OfferPart) -> Void = { _, _ in }
    /// A tick on a found-names card (his call on TE320): the card, and the file by path.
    var onFoundTick: (UUID, String) -> Void = { _, _ in }
    /// A download card's buttons (TE258).
    var onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void = { _, _ in }
    /// Filing help's card buttons (TE255).
    var onFilingCard: (AskClaudeFilingAction) -> Void = { _ in }
    /// A card of changes: its ticks and row menus (TE285).
    var onPlanCard: (UUID, AskClaudePlanAction) -> Void = { _, _ in }
    /// A button under Claude's question (decision GB), by its place in the row.
    var onChoice: (UUID, Int) -> Void = { _, _ in }
    /// A rule card's Save (true) or Not Now (TE286).
    var onRuleCard: (UUID, Bool) -> Void = { _, _ in }
    /// What a settings card reads and does (TE290).
    var settingsBridge = AskClaudeSettingsBridge()
    /// What a PDF card reads and does (TE294).
    var pdfBridge = AskClaudePDFBridge()
    /// Where the panel wants its window, top-left within `container` (AskClaudeWindow.swift).
    var onPlace: (CGRect) -> Void = { _ in }
    /// A spoken question's Send (TE311), so its bubble shows it was spoken; `onAsk` without it.
    var onAskSpoken: ((String) -> Void)?
    /// The words of the names on screen, for the transcriber to listen for (`AskClaudeVoiceHints`).
    var voiceHints: () -> [String] = { [] }
    /// Where a spoken question's audio comes from: the microphone, or a file in tests.
    var voiceSource: () -> AskClaudeVoiceSource = { AskClaudeMicrophone() }

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var caret = AskClaudeComposerCaret()
    @State private var spentText = ""
    @AppStorage(AskClaudePrivacy.readsFilesKey) private var readsFiles = false
    @State private var showsPlace = false
    /// Whether an API key is saved (TE315), asked without reading it: when the panel opens and
    /// whenever the Keychain item changes, not on every draw. Nil until asked.
    @State private var keySaved: Bool?
    @StateObject private var voice = AskClaudeVoice()
    /// The turn whose bar shows (TE296), and the wait before a bar the mouse left goes: the bar
    /// hangs a little past its row, and the mouse crosses the gap to reach it.
    @State private var hovered: AskClaudeHoverKey?
    @State private var hoverEnd: Task<Void, Never>?
    /// What the box held when Edit put a question in it, for Cancel to put back.
    @State private var draftBeforeEdit = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 372
    static let margin: CGFloat = 10
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720
    static let minHeight: CGFloat = 320
    /// Where a new panel starts: a chat's height, growing with the thread up to the window's.
    static let startHeight: CGFloat = 420
    /// How close to a side of the window a drop docks the panel there.
    static let snapZone: CGFloat = 56

    // TE248, round 3: docked right (the default), docked left, or floating where it was dropped;
    // TE288 adds the two bottom corners, where the panel grows upward from the window's bottom.
    // One size in every placement, so moving never changes it (round 2 switched a docked panel's
    // full height for the floating one's on drop, and the jump read as the panel resizing itself).
    // Resized from its inner edge, its bottom edge and the corner between them, by AppKit handles:
    // SwiftUI gestures laid over the thread's scroll view lost the mouse to it. The move is
    // measured in window coordinates: measured in the panel's own, the moving panel fed its own
    // movement back into the drag and it jittered.
    enum Placement: String {
        case right, left, bottomRight, bottomLeft, floating
        var isRight: Bool { self == .right || self == .bottomRight }
        var isBottom: Bool { self == .bottomRight || self == .bottomLeft }
    }
    @AppStorage("askClaudePanelPlacement") private var placementRaw = Placement.right.rawValue
    @AppStorage("askClaudePanelWidth") private var storedWidth: Double = 372
    /// 0 is automatic: the panel fits its thread, from `startHeight` up to the window's height.
    /// Dragging the bottom edge sets a height; double-clicking it goes back to automatic.
    @AppStorage("askClaudePanelChosenHeight") private var storedHeight: Double = 0
    /// The thread's content and the panel's other parts, measured, for the automatic height.
    @State private var threadHeight: CGFloat = 0
    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0
    @AppStorage("askClaudePanelX") private var storedX: Double = 0
    @AppStorage("askClaudePanelY") private var storedY: Double = 8
    @State private var liveOrigin: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragStartMouse: CGPoint?
    @State private var liveSize: CGSize?
    @State private var resizeStart: CGSize?

    private var placement: Placement { Placement(rawValue: placementRaw) ?? .right }

    private var tallest: CGFloat { max(Self.minHeight, container.height - 18) }

    private var size: CGSize {
        let widest = max(Self.minWidth, min(Self.maxWidth, container.width - 2 * Self.margin))
        let width = min(widest, max(Self.minWidth, liveSize?.width ?? CGFloat(storedWidth)))
        let automatic = max(Self.startHeight, top + bottom + threadHeight)
        let wanted = liveSize?.height ?? (storedHeight > 0 ? CGFloat(storedHeight) : automatic)
        return CGSize(width: width, height: min(tallest, max(Self.minHeight, wanted)))
    }

    /// A docked panel's top-left: under the toolbar, or its bottom edge on the window's.
    static func docked(_ placement: Placement, size: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(x: placement.isRight ? container.width - size.width - margin : margin,
                y: placement.isBottom ? max(8, container.height - size.height - 10) : 8)
    }

    /// Where a panel dropped with its top-left at `point` docks, or nil to float there. Near a side
    /// it docks at that side's top or bottom, whichever edge of the window it is nearer; near the
    /// bottom alone, at the nearer bottom corner. The top has no zone of its own: dropped under the
    /// toolbar away from the sides, it floats there, as before the bottom could dock.
    static func dock(droppedAt point: CGPoint, size: CGSize, in container: CGSize) -> Placement? {
        let topGap = point.y - 8
        let bottomGap = container.height - 10 - (point.y + size.height)
        let low = bottomGap < topGap
        if point.x <= margin + snapZone { return low ? .bottomLeft : .left }
        if point.x + size.width >= container.width - margin - snapZone { return low ? .bottomRight : .right }
        if low && bottomGap <= snapZone { return point.x + size.width / 2 < container.width / 2 ? .bottomLeft : .bottomRight }
        return nil
    }

    private func clamped(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(Self.margin, point.x), max(Self.margin, container.width - size.width - Self.margin)),
                y: min(max(8, point.y), max(8, container.height - size.height - 10)))
    }

    private var origin: CGPoint {
        if let liveOrigin { return liveOrigin }
        switch placement {
        case .floating: return clamped(CGPoint(x: storedX, y: storedY), size: size)
        default: return Self.docked(placement, size: size, in: container)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                hairline
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 }
            thread
            VStack(spacing: 0) {
                hairline
                composer
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottom = $0 }
        }
        .frame(width: size.width, height: size.height)
        // A pane's surface and accent wash (TE291), so the panel reads as part of the window at
        // every accent and Tint, over the ground for its text the other floating panels have, as
        // thick as theirs at every level (IA) and the window's own dark ground in dark (HZ).
        // Solid is opaque, like the panes; Frosted and Clear keep their glass, the window's content
        // showing blurred through the backdrop (AskClaudeWindow.swift), which also owns the
        // rounding and the shadow — so the ground is square, as it always was.
        .contentSurface(hue: hue, tint: tint)
        // With None in light at Clear, the window's own white film instead: this window's backdrop
        // is already the window's material, so the film is all that makes it the window's glass.
        .glassPanelGround(level: level, hue: hue, tint: tint,
                          opacity: LiquidGlass.panelTakesWindowGlass(level: level, hue: hue, dark: colorScheme == .dark)
                              ? LiquidGlass.clearNoneLightVeil : level.groundedBackingOpacity,
                          cornerRadius: 0)
        // The floating panels' glass, so at Clear in light it is clear glass as Settings' is (TE316).
        .floatingPanelGlass(level, cornerRadius: Radius.card)
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .overlay { resizeHandles }
        .onChange(of: CGRect(origin: origin, size: size), initial: true) { _, frame in onPlace(frame) }
        .onAppear {
            // A draft left when the panel closed comes back with it.
            draft = chat.draft
            composerFocused = true
            refreshSpent()
            keySaved = settingsBridge.keyIsSaved()
        }
        .onReceive(NotificationCenter.default.publisher(for: AnthropicKeychain.didChange)) { _ in
            keySaved = settingsBridge.keyIsSaved()
        }
        // Kept as it's typed: a window torn down needn't say goodbye to its views.
        .onChange(of: draft) { _, typed in chat.draft = typed }
        // Something attached from a row's menu: the caret goes to the box for the question (TE263).
        .onChange(of: chat.attachments) { _, now in if !now.isEmpty { composerFocused = true } }
        // Edit Message on a caught-key card: the message comes back to the box (TE290 step 7).
        .onChange(of: chat.draftToRestore) { _, message in
            guard let message else { return }
            // Added to what's being typed, never in its place.
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message : draft + "\n" + message
            chat.draftToRestore = nil
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudeSpend.didChange)) { _ in refreshSpent() }
        // The limit is set in Settings, which writes it straight to the defaults.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in refreshSpent() }
        // The box takes the keyboard back once the answer is in, and VoiceOver hears that it is.
        // It stays open while Claude answers (TE297), and so does listening: what is said or
        // typed meanwhile waits for the answer to end.
        .onChange(of: chat.isRunning) { _, running in
            guard !running else { return }
            composerFocused = true
            if case .assistant = chat.items.last(where: { if case .receipt = $0.kind { false } else { true } })?.kind {
                AccessibilityNotification.Announcement("Claude answered").post()
            }
        }
        // Back to the box once a spoken question is sent or thrown away.
        .onChange(of: voice.isActive) { _, active in if !active { composerFocused = true } }
        .onChange(of: draft) { _, typed in if !typed.isEmpty { voice.notice = nil } }
        .background(AskClaudeTalkKeys(onKey: talkKey, onGone: { voice.cancel() }))
        .onDisappear { voice.cancel() }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask Claude")
    }

    /// Measured on the screen, from where the mouse went down: the panel's own window moves under
    /// the drag, so its coordinates (even `.global`, which is the window's) would feed the move
    /// back into itself.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                let start = dragStart ?? origin
                let startMouse = dragStartMouse ?? mouse
                dragStart = start
                dragStartMouse = startMouse
                liveOrigin = clamped(CGPoint(x: start.x + mouse.x - startMouse.x, y: start.y - (mouse.y - startMouse.y)), size: size)
            }
            .onEnded { _ in
                let dropped = liveOrigin ?? origin
                withDesignAnimation(.spring(duration: 0.25), reduceMotion: reduceMotion) {
                    if let dock = Self.dock(droppedAt: dropped, size: size, in: container) {
                        placementRaw = dock.rawValue
                    } else {
                        placementRaw = Placement.floating.rawValue
                        storedX = dropped.x
                        storedY = dropped.y
                    }
                    liveOrigin = nil
                }
                dragStart = nil
                dragStartMouse = nil
            }
    }

    /// The inner side edge (the trailing one when floating), the free end (the bottom edge, or the
    /// top one when docked at the bottom), and the corner between them, each a band just inside the
    /// border: the panel's window ends at its edge, so a band straddling it lost its outer half.
    private var resizeHandles: some View {
        let right = placement.isRight
        let low = placement.isBottom
        let inner: AskClaudeResizeHandle.Edge = right ? .leading : .trailing
        let end: AskClaudeResizeHandle.Edge = low ? .top : .bottom
        let corner: AskClaudeResizeHandle.Edge = switch (low, right) {
        case (false, true): .bottomLeading
        case (false, false): .bottomTrailing
        case (true, true): .topLeading
        case (true, false): .topTrailing
        }
        let cornerAlignment: Alignment = switch corner {
        case .bottomLeading: .bottomLeading
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        default: .bottomTrailing
        }
        let band: CGFloat = 6
        return ZStack {
            handle(inner)
                .frame(width: band)
                .padding(.vertical, Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .leading : .trailing)
            handle(end)
                .frame(height: band)
                .padding(.horizontal, Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: low ? .top : .bottom)
            handle(corner)
                .frame(width: Radius.card, height: Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
        }
    }

    private func handle(_ edge: AskClaudeResizeHandle.Edge) -> some View {
        AskClaudeResizeHandle(edge: edge, onDrag: { dx, dy in
            let start = resizeStart ?? size
            resizeStart = start
            var next = start
            switch edge {
            case .leading: next.width = start.width - dx
            case .trailing: next.width = start.width + dx
            case .bottom: next.height = start.height + dy
            case .top: next.height = start.height - dy
            case .bottomLeading: next = CGSize(width: start.width - dx, height: start.height + dy)
            case .bottomTrailing: next = CGSize(width: start.width + dx, height: start.height + dy)
            case .topLeading: next = CGSize(width: start.width - dx, height: start.height - dy)
            case .topTrailing: next = CGSize(width: start.width + dx, height: start.height - dy)
            }
            liveSize = next
        }, onEnd: {
            let final = size
            storedWidth = final.width
            if edge != .leading && edge != .trailing { storedHeight = final.height }
            liveSize = nil
            resizeStart = nil
        }, onDoubleClick: {
            // The free end's double-click goes back to fitting the thread.
            guard edge != .leading && edge != .trailing else { return }
            withDesignAnimation(.spring(duration: 0.25), reduceMotion: reduceMotion) { storedHeight = 0 }
        })
        // Dragging can't be done by VoiceOver; the panel's size has no other control to name.
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 2) {
            // Double-click docks it right, on the title and the space beside it but not the
            // buttons: a double-click gesture over a button holds each click until the double-click
            // interval runs out (0.35 s measured), and the shield's popover came up that late.
            HStack(spacing: 0) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .symbolRenderingMode(.hierarchical)
                        .scaledFont(.headline)
                    // The title, and under it what the next question will describe (TE260).
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Claude").scaledFont(.headline)
                        Text(place.subtitle)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(place.fullPath)
                    }
                }
                .help("Drag the header to move. Drop it at a side or the bottom to dock it there; double-click to dock it top right.")
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withDesignAnimation(.spring(duration: 0.25), reduceMotion: reduceMotion) {
                    placementRaw = Placement.right.rawValue
                }
            }
            AskClaudeHeaderButton(symbol: "checkmark.shield", help: "What Claude sees, and what it may see", label: "What Claude Sees",
                                  isOn: showsPlace) { showsPlace.toggle() }
                .popover(isPresented: $showsPlace, arrowEdge: .bottom) {
                    AskClaudePlaceMenu(place: place, readsFiles: $readsFiles, spent: spentText, accentFill: accentFill, onAccent: onAccent,
                                       onGoTo: { showsPlace = false; onGoToFolder() },
                                       onSetHidden: { hidden in showsPlace = false; onSetHidden(hidden) },
                                       onEditHiddenList: { showsPlace = false; onOpenSettings() })
                        .presentedNativeControlAccent()
                }
            AskClaudeHeaderButton(symbol: "plus.bubble", help: "New chat", label: "New Chat") { chat.newChat() }
                .disabled(chat.items.isEmpty && !chat.isRunning)
            AskClaudeHeaderButton(symbol: "xmark", help: ShortcutHint.tooltip("Close", AppChord.askClaude.display), label: "Close", action: onClose)
                // ⌘J closes it from its own window too: while the panel is key, the menu's ⌘J
                // belongs to no scene and is off.
                .keyboardShortcut(AppChord.askClaude.key, modifiers: AppChord.askClaude.modifiers)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private var thread: some View {
        ScrollView {
                // **A plain VStack, not a lazy one.** The lazy stack went blank after scrolling to
                // the bottom while an answer grew (2026-10-31: the thread showed nothing while
                // chat.json held every message); a chat's few hundred rows don't need laziness.
                VStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty {
                        AskClaudeEmptyState(keySaved: keySaved, starters: AskClaudeStarters.questions(for: place.starterScreen),
                                            startersEnabled: !chat.isRunning && !voice.isActive, bridge: settingsBridge,
                                            accent: accent, hue: hue, onStarter: { send($0, spoken: false) })
                    }
                    let latestReceipt = chat.items.last { if case .receipt = $0.kind { true } else { false } }?.id
                    let turns = AskClaudeTurns(chat.items)
                    // Retry is for the last answer only, and only once nothing runs (TE296).
                    let retries = chat.lastQuestion.map { chat.canRewind(from: $0) } ?? false
                    ForEach(chat.items) { item in
                        let key = turns.hoverKey(of: item)
                        AskClaudeThreadRow(item: item, accent: accent, accentFill: accentFill, onAccent: onAccent, hue: hue, onOpenSettings: onOpenSettings,
                                           linkTargets: chat.linkTargets, onReveal: onReveal, onSendOffer: onSendOffer, onFoundTick: onFoundTick,
                                           onDownloadCard: onDownloadCard,
                                           onFilingCard: onFilingCard,
                                           onPlanCard: onPlanCard, onChoice: onChoice, onRuleCard: onRuleCard,
                                           settingsBridge: settingsBridge, pdfBridge: pdfBridge,
                                           pdfThumbnails: chat.pdfThumbnails[item.id] ?? [:],
                                           isLatestReceipt: item.id == latestReceipt, isRunning: chat.isRunning,
                                           isGrowing: chat.isRunning && item.id == chat.items.last?.id,
                                           turnActions: turnActions(for: item, turns: turns, retries: retries),
                                           showsBar: key != nil && hovered == key,
                                           onTurnAction: { turnAction($0, on: item.id) },
                                           onHover: { inside in if let key { hover(key, inside) } })
                            // Rows that didn't change aren't redrawn as each word streams in.
                            .equatable()
                            // A question's bar hangs over the row below it.
                            .zIndex(key != nil && hovered == key ? 1 : 0)
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threadHeight = $0 }
        }
        // Opens at the newest message and stays there as the thread grows.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // Docked left or floating, the resize band runs down the trailing edge: the scroll bar
        // moves in past it, or a drag on the bar would resize the panel.
        .contentMargins(.trailing, placement.isRight ? 0 : 6, for: .scrollIndicators)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.editing != nil { editingLine }
            if let waiting = chat.queued { queuedLine(waiting) }
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
                // The box's bottom row (TE292): which model and style the next question goes to,
                // then the mic (TE311), then Stop or Send.
                HStack(spacing: 6) {
                    AskClaudeModelMenu(defaults: chat.settingsDefaults, chatModel: chat.chatModel,
                                       contextTokens: chat.contextTokens, onOpenSettings: onOpenSettings)
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

    /// What is being said, while it is said (TE311): the settled words, the ones the transcriber
    /// may still change greyed after them, a level meter, the keys, and where it is heard.
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

    /// The divider under the header and over the composer, in the accent (TE291).
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

    /// While an edited question is in the box (TE296): sending it takes back the one it edits.
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

    /// What a row offers (TE296): Copy and Edit on a question, Copy and Retry on an answer's rows
    /// and its receipt. Edit only for a question from the box, Retry only on the last answer.
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

    /// The question waiting for the answer to end (TE297): "Next: … · Edit · Cancel", with Send
    /// once nothing runs (after a Stop or a problem, it waits for them to say).
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

    /// What the next question is about (TE263): a chip per row attached from its menu, each with ✕.
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

    /// Return or Send. While Claude answers, the question waits for the answer to end (TE297).
    private func send(spoken: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if chat.isRunning {
            queue(text, spoken: spoken)
        } else {
            // An edited question takes back the one it edits, and all after it (TE296) — not
            // when it is held back for a key: then nothing is sent to take its place.
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

    /// The box's text, or a starter's (TE299), which goes exactly as if typed and leaves the box
    /// as it was.
    private func send(_ text: String, spoken: Bool) {
        guard !text.isEmpty, !chat.isRunning else { return }
        // A key never leaves the Mac in a message, nor joins the remembered questions (TE290 step 7).
        if chat.catchKey(text) { return }
        chat.rememberSent(text)
        if spoken, let onAskSpoken { onAskSpoken(text) } else { onAsk(text) }
    }

    /// ⌥Space or the mic: starts listening, or sends what was said (decision II, tap to toggle).
    /// While Claude answers, what was said waits for the answer, as typing does (TE297).
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
        // Not `scrollRangeToVisible`: called here, inside SwiftUI's key dispatch, it waited on the
        // text view's layout and never returned (2026-10-31, an offscreen test window).
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

/// The panel's accent paints over its pane surface (TE291). None has no hue of its own — its
/// accent is the system's, which would repaint the panel in a colour nobody picked — so it keeps
/// the stock grays, each at the opacity it had before.
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
    let onOpenSettings: () -> Void
    let linkTargets: [String: String]
    let onReveal: (String) -> Void
    let onSendOffer: (UUID, AskClaudeChat.OfferPart) -> Void
    let onFoundTick: (UUID, String) -> Void
    let onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void
    let onFilingCard: (AskClaudeFilingAction) -> Void
    let onPlanCard: (UUID, AskClaudePlanAction) -> Void
    let onChoice: (UUID, Int) -> Void
    let onRuleCard: (UUID, Bool) -> Void
    let settingsBridge: AskClaudeSettingsBridge
    let pdfBridge: AskClaudePDFBridge
    var pdfThumbnails: [Int: CGImage] = [:]
    /// A card applies only once the question that offered it has finished.
    /// The newest receipt shows its summary; older ones fold to an icon, so the thread doesn't
    /// repeat “Sent screen …” under every answer.
    var isLatestReceipt = false
    /// While a question runs, an offer's Send waits: the send would be refused.
    var isRunning = false
    /// The answer still arriving: the newest item while a question runs.
    var isGrowing = false
    /// Copy, Edit and Retry, as this row offers them (TE296): on the bar a question or receipt
    /// shows while hovered, and on the right-click menu and VoiceOver's actions.
    var turnActions: [AskClaudeTurnAction] = []
    var showsBar = false
    var onTurnAction: (AskClaudeTurnAction) -> Void = { _ in }
    /// The mouse entering or leaving the row, for which turn's bar shows.
    var onHover: (Bool) -> Void = { _ in }
    @State private var showsSent = false
    /// The card row whose details are open; one at a time.
    @State private var openRow: Int?
    @Environment(\.colorScheme) private var colorScheme

    /// What the row draws from; the closures never change what it shows.
    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.linkTargets == b.linkTargets && a.isLatestReceipt == b.isLatestReceipt
            && a.isRunning == b.isRunning && a.isGrowing == b.isGrowing && a.accent == b.accent && a.accentFill == b.accentFill && a.onAccent == b.onAccent
            && a.hue == b.hue && a.pdfThumbnails == b.pdfThumbnails && a.turnActions == b.turnActions && a.showsBar == b.showsBar
    }

    static let revealScheme = "synccloud-askclaude"

    /// The answer's text with every known file name made a link that reveals it (TE245).
    ///
    /// - **The answer's own links are dropped**: a link Claude writes could point anywhere (a file
    ///   name or passage can carry text that asks for one), and only names this chat has seen may
    ///   be clicked.
    /// - **Longest names first, whole words only, no overlaps**, so "2024 Tax.pdf" isn't cut into
    ///   by "Tax.pdf", and "notes" doesn't link inside "footnotes".
    ///
    /// Drawn as its blocks (TE298): lists, tables and code as well as inline markdown. While it is
    /// still arriving, only what has `settled` is drawn.
    private func answer(_ text: String) -> [AskClaudeMarkdown.Block] {
        AskClaudeMarkdown.linked(AskClaudeMarkdown.blocks(isGrowing ? AskClaudeMarkdown.settled(text) : text),
                                 targets: linkTargets, scheme: Self.revealScheme, underline: accentFill)
    }

    var body: some View {
        switch item.kind {
        // The bar's actions, for whoever doesn't hover, on the right-click menu (TE296). Only on a
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
            content.onHover(perform: onHover)
        }
    }


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
            // A spoken question carries a small mic (TE311).
            (item.spoken == true ? Text("\(Image(systemName: "mic")) \(text)") : Text(text))
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(onAccent)
                .background(accentFill, in: RoundedRectangle(cornerRadius: Radius.card))
                // One element of its own over the selectable text, not the text's: while a question
                // runs, SwiftUI's label for a node backed by the selectable text's AppKit view asks
                // that view, whose label asks the node, until the stack runs out (an assistive app
                // reading the panel, found under lldb).
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(item.spoken == true ? "You said: \(text)" : "You: \(text)")
                .modifier(AskClaudeTurnVoiceOverActions(actions: turnActions, title: menuTitle, perform: onTurnAction))
                // Its bar hangs just under the bubble, over the row below, while hovered (TE296).
                .overlay(alignment: .bottomTrailing) {
                    if showsBar && !turnActions.isEmpty {
                        AskClaudeTurnBar(actions: turnActions, perform: onTurnAction)
                            .alignmentGuide(.bottom) { $0[.top] - 3 }
                            .onHover(perform: onHover)
                            .accessibilityHidden(true)
                    }
                }
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
        case .offer(let passage, let sent):
            if passage.answer != nil || passage.whole != nil {
                heldAnswerCard(item.id, passage, passageSent: sent)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The on-device model read \(passage.fileName) here. Claude can read \(passage.whereInFile) itself for a fuller answer.")
                        .scaledFont(.callout)
                    HStack(spacing: 8) {
                        Button(sent ? "Sent" : "Send to Claude") { onSendOffer(item.id, .passage) }
                            .controlSize(.small)
                            .disabled(sent || isRunning)
                            .help("Sends only this passage of the file to Claude, once.")
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
                    Button("Open Settings ▸ Intelligence", action: onOpenSettings).controlSize(.small)
                }
            }
            .scaledFont(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.well))
        case .receipt(let receipt):
            // The answer's bar hangs under its receipt while the answer is hovered (TE296), over
            // the row below as a question's does: laid out beside it, even unseen, it took the
            // receipt's width and wrapped it onto two lines.
            receiptButton(receipt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    if showsBar && !turnActions.isEmpty {
                        AskClaudeTurnBar(actions: turnActions, perform: onTurnAction)
                            .alignmentGuide(.bottom) { $0[.top] - 3 }
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
                ScrollView([.horizontal, .vertical]) {
                    Text(receipt.screenText)
                        .scaledFont(ScaledFont.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 260)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
            }
            .padding(12)
            .frame(width: 360)
            .presentedNativeControlAccent()
        }
    }

    /// TE258: offered, downloading, then done, failed or timed out; Not Now folds it to a line.
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

    /// **What a file says, held for their click** (decision IU, TE319): Apple Intelligence's
    /// answer exactly as it would go, when there is one, then what sharing gets them and the
    /// shares: the answer, the passage it came from, and all the text read. Nothing leaves until
    /// a click.
    private func heldAnswerCard(_ id: UUID, _ passage: AskClaudePassage, passageSent: Bool) -> some View {
        let answerSent = passage.answerSent == true
        let wholeSent = passage.wholeSent == true
        let anySent = answerSent || passageSent || wholeSent
        return VStack(alignment: .leading, spacing: 6) {
            // Whose words these are and which file (his calls on TE319): Apple's on-device model's,
            // not Claude's and not a search — `AskClaudeReading.answerOnDevice`. Claude's own
            // question isn't shown: it goes with the answer when shared.
            if let answer = passage.answer {
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
            // What sharing is for, before the buttons (his call on TE319): more from Claude.
            if !anySent {
                Text(AskClaudeHeldAnswer.lead)
                    .scaledFont(.callout.weight(.medium))
            }
            // Three shares don't fit the panel's width side by side; they stack when they don't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heldAnswerButtons(id, passage, passageSent: passageSent) }
                VStack(alignment: .leading, spacing: 6) { heldAnswerButtons(id, passage, passageSent: passageSent) }
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

    /// **Names a content search found, held for their click** (decision IV, TE320): every file,
    /// each with a tick and its folder and date (his call: show what goes, and let them pick),
    /// then Share N Files and Share Names Only. Nothing leaves until a click.
    private func foundCard(_ id: UUID, _ found: AskClaudeFoundNames) -> some View {
        let sent = found.sent == true
        let ticked = found.files == nil ? found.count : found.ticked.count
        return VStack(alignment: .leading, spacing: 6) {
            Label(AskClaudeHeldAnswer.foundTitle(found), systemImage: "doc.text.magnifyingglass")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Group {
                if let files = found.files {
                    // Past a dozen the list scrolls in the card rather than pushing the chat down.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(files, id: \.path) { file in foundRow(id, found, file, sent: sent) }
                        }
                    }
                    .frame(maxHeight: files.count > AskClaudeHeldAnswer.foundShown ? 260 : nil)
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
            if !sent {
                Text(AskClaudeHeldAnswer.lead).scaledFont(.callout.weight(.medium))
            }
            HStack(spacing: 8) {
                Button(AskClaudeHeldAnswer.foundShareButton(ticked: ticked, namesOnly: false, sent: sent && found.namesOnly != true)) { onSendOffer(id, .names) }
                    .controlSize(.small)
                    .disabled(sent || isRunning || ticked == 0)
                Button(AskClaudeHeldAnswer.foundShareButton(ticked: ticked, namesOnly: true, sent: sent && found.namesOnly == true)) { onSendOffer(id, .namesOnly) }
                    .controlSize(.small)
                    .disabled(sent || isRunning || ticked == 0)
            }
            Text(AskClaudeHeldAnswer.foundFoot(found, ticked: ticked))
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
        Button(AskClaudeHeldAnswer.passageButton(passage.whereInFile, sent: passageSent, answerSent: answerSent)) { onSendOffer(id, .passage) }
            .controlSize(.small)
            .disabled(passageSent || isRunning)
            .help("Lets Claude see the text of \(passage.whereInFile) of \(passage.fileName) itself, about \(passage.tokens.formatted()) tokens, once.")
        if let wholeWhere = passage.wholeWhere, let whole = passage.whole {
            Button(AskClaudeHeldAnswer.wholeButton(wholeWhere, isAll: passage.wholeIsAll == true, sent: wholeSent)) { onSendOffer(id, .whole) }
                .controlSize(.small)
                .disabled(wholeSent || isRunning)
                .help("Lets Claude see the text of \(wholeWhere) of \(passage.fileName), about \(AskClaudePassage.estimatedTokens(whole).formatted()) tokens, once.")
        }
    }

    /// TE255: where the file fits by their own conventions, each folder with Go to Folder; Refine
    /// with Claude when the answer isn't High (decision EY); Setup when there's no profile.
    @ViewBuilder
    private func filingCard(_ card: AskClaudeFilingCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card.kind {
            case .suggestions:
                ForEach(Array(card.folders.enumerated()), id: \.offset) { index, folder in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folder.label).scaledFont(.callout.weight(.medium)).lineLimit(2).truncationMode(.head)
                        }
                        Text("\(index == 0 ? "" : "Runner-up · ")\(folder.confidence) · \(folder.reason)\(folder.note.map { " · \($0)" } ?? "")")
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button("Go to Folder") { onFilingCard(.goTo(folder.path)) }
                                .controlSize(.small)
                                .help("Shows this folder in Browse. Nothing is moved.")
                            Button("Move Here") { onFilingCard(.moveHere(item: item.id, file: card.filePath, folder: folder.path, label: folder.label)) }
                                .controlSize(.small)
                                .help("Makes this a card with one move. Nothing moves until you click Apply.")
                        }
                    }
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

    /// TE286: a correction offered as a rule — its words, its folder and where this file goes.
    /// Saved only on the click (decision GX).
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
            Text("\(card.fileName) goes to \(AskClaudeRuleCard.readable(card.example))"
                 + (card.checkedDate ? "." : ". Page 1 wasn’t read, so the year and month weren’t checked."))
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

    /// A card of changes (TE285, TE262; redone after his first use, decision GG): one line per
    /// item, grouped by the folder it goes to, and a click opens a row's details. Text follows the
    /// app's text size. Every line is held to the card's width: a long name shortens in the
    /// middle, a long path wraps in the details, and nothing sizes the card from its own text.
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
                Text(row.name)
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
            // One line when they fit, else two: a narrow panel cut "Choose Folder…" short.
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

    /// TE262: Apply and Not Now; then applying, done with Undo, or partly done. Next asks for the
    /// next card, whatever this one's state (decision GG).
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

/// A turn's actions for VoiceOver (TE296), one named action each, in place of
/// `accessibilityActions { … }` holding buttons. That swap was made against a crash (an assistive
/// app reading the panel while a question runs sends SwiftUI's label lookup round in a loop until the
/// stack runs out), but it wasn't the cause: the label on the question's selectable text was.
private struct AskClaudeTurnVoiceOverActions: ViewModifier {
    let actions: [AskClaudeTurnAction]
    let title: (AskClaudeTurnAction) -> String
    let perform: (AskClaudeTurnAction) -> Void

    func body(content: Content) -> some View {
        content
            .action(.copy, in: actions, title: title, perform: perform)
            .action(.edit, in: actions, title: title, perform: perform)
            .action(.retry, in: actions, title: title, perform: perform)
    }
}

private extension View {
    @ViewBuilder
    func action(_ action: AskClaudeTurnAction, in actions: [AskClaudeTurnAction], title: (AskClaudeTurnAction) -> String,
                perform: @escaping (AskClaudeTurnAction) -> Void) -> some View {
        if actions.contains(action) {
            accessibilityAction(named: Text(title(action))) { perform(action) }
        } else {
            self
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

/// Where an answer names a file this chat has seen (TE245).
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
    /// carries a thin underline in its own colour at half strength: colour alone didn't read as
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

/// One of the panel's resize handles: an AppKit view, so the drag and the resize cursor belong to
/// it even where it lies over the thread's scroll view. The drag is reported in window points,
/// right and down positive, measured from where it began.
struct AskClaudeResizeHandle: NSViewRepresentable {
    enum Edge { case leading, trailing, bottom, top, bottomLeading, bottomTrailing, topLeading, topTrailing }

    let edge: Edge
    let onDrag: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    let onEnd: () -> Void
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.edge = edge
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        if view.edge != edge {
            view.edge = edge
            view.window?.invalidateCursorRects(for: view)
        }
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var edge: Edge = .bottom
        var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        private var start: NSPoint?
        private var dragged = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            let position: NSCursor.FrameResizePosition = switch edge {
            case .leading: .left
            case .trailing: .right
            case .bottom: .bottom
            case .top: .top
            case .bottomLeading: .bottomLeft
            case .bottomTrailing: .bottomRight
            case .topLeading: .topLeft
            case .topTrailing: .topRight
            }
            addCursorRect(bounds, cursor: .frameResize(position: position, directions: .all))
        }

        // On the screen, not in the window: resizing the panel moves its window under the drag.
        override func mouseDown(with event: NSEvent) {
            dragged = false
            if event.clickCount == 2 { onDoubleClick(); return }
            start = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            dragged = true
            let point = NSEvent.mouseLocation
            onDrag(point.x - start.x, start.y - point.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            // A click that didn't drag sets nothing: it used to store the automatic height as a
            // chosen one, so the panel stopped growing with the thread.
            if dragged { onEnd() }
            dragged = false
        }
    }
}

/// What a download card's button asks for (TE258).
enum AskClaudeDownloadAction: Equatable {
    case download, stopWaiting, notNow, revealInFinder
}

/// What a card of changes asks for (TE285).
enum AskClaudePlanAction: Equatable {
    case tick(Int, Bool)
    /// A row sent to one of its menu's folders.
    case choose(Int, AskClaudePlan.Choice)
    /// Choose Folder… in a row's details.
    case chooseFolder(Int)
    /// TE262: the card's own buttons.
    case apply, notNow, undo
    /// A row's details: Quick Look on the item, Go to Folder on where it goes.
    case quickLook(String)
    case goTo(String)
    /// Next 10 (decision GG): asks for the next card.
    case next
}

/// What filing help's card asks for (TE255).
enum AskClaudeFilingAction: Equatable {
    case goTo(String)
    /// Refine with Claude for this file, in Organize.
    case refine(String)
    case openSetup
    /// Move Here (decision FE): the card becomes a one-row plan card.
    case moveHere(item: UUID, file: String, folder: String, label: String)
}

/// How a card row says where it goes, short (decision GG).
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
    /// The line under an answer: what it sent and cost, led by the model's name when it changed.
    var summary: String {
        let screen = screenUnchanged ? "screen unchanged"
            : (rowsSent == rowsTotal ? "screen · \(rowsSent) rows" : "screen · \(rowsSent) of \(rowsTotal) rows")
        let tokens = (promptTokens + outputTokens).formatted(.number.notation(.compactName))
        let named = showsModel == true ? modelName.map { $0 + " · " } ?? "" : ""
        return "\(named)Sent \(screen) · \(tokens) tokens · \(AskClaudeSpend.format(costUSD))"
    }

    /// The model that answered, by its short name; the fallback's, marked, when one answered any
    /// round instead of the one asked for (TE292). Nil for a receipt that never heard from a model.
    var modelName: String? {
        if let fallbackModel { return AskClaudeModels.name(ofServed: fallbackModel) + ", fallback" }
        guard !model.isEmpty else { return nil }
        if let requested, requested != model { return AskClaudeModels.name(ofServed: model) + ", fallback" }
        return AskClaudeModels.name(ofServed: model)
    }
}

/// The held-answer card's words (decision IU, TE319), apart from the view so a test reads them.
enum AskClaudeHeldAnswer {
    /// What sharing is for, above the buttons (his calls on TE319, after "Send to Claude" beside
    /// "Send the Text", then "Share This with Claude": the answer is already on their screen, so
    /// the card says what sharing gets them).
    static let lead = "Get more insights from Claude:"

    /// The held answer's button: the box above it.
    static func answerButton(sent: Bool) -> String { sent ? "Answer Shared" : "Share This Answer" }

    /// The passage's button, naming where its content is from — "Share Content from Page 2",
    /// "Also Share Content from Pages 1–2" once the answer has gone. "Content", not the page or
    /// the file (his call on TE319): only text goes, never the document, and only the passage the
    /// answer came from. A file without pages says "the Document", or "All Content from the
    /// Document" when the passage is the whole of its text (`AskClaudeReading.claudePassage`).
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

    /// A found-names card's title: who searched, for what, where.
    static func foundTitle(_ found: AskClaudeFoundNames) -> String {
        let files = found.count == 1 ? "1 file" : "\(found.count) files"
        return "Spotlight found \(files) mentioning “\(found.words)” in \(found.folderLabel), on this Mac:"
    }

    /// Past this many files the card's list scrolls.
    static let foundShown = 12

    /// A share's button, naming what goes and for how many (his call on TE320: "Share 7 Files"
    /// read as sending the files): "Share 7 Names with File Details", "Share 7 Names Only".
    static func foundShareButton(ticked: Int, namesOnly: Bool, sent: Bool) -> String {
        if sent { return namesOnly ? "Names Shared" : "Names with File Details Shared" }
        let names = ticked == 1 ? "1 Name" : ticked == 0 ? "Names" : "\(ticked) Names"
        return namesOnly ? "Share \(names) Only" : "Share \(names) with File Details"
    }

    /// A found file's folder and date, as the card shows them beside its name.
    static func foundDetail(_ file: AskClaudeFoundNames.File) -> String {
        [file.folder, file.modified.map { $0.formatted(date: .abbreviated, time: .omitted) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// What the shares send, before the click; who has what, after.
    static func foundFoot(_ found: AskClaudeFoundNames, ticked: Int) -> String {
        if found.sent == true {
            return found.namesOnly == true ? "Claude has the names you shared." : "Claude has the list you shared."
        }
        return "Not shared yet. File details are each file’s folder, kind, size, date and tags. No file content."
    }

    /// Words to two significant figures past 1,000: a size, not a count.
    static func roundedWords(_ words: Int) -> Int {
        guard words >= 1_000 else { return words }
        let step = words >= 10_000 ? 1_000 : 100
        return (words + step / 2) / step * step
    }
}
