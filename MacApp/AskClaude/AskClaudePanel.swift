import AppKit
import SwiftUI
import Sync
import Design

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
    var onSendOffer: (UUID) -> Void = { _ in }
    /// A download card's buttons (TE258).
    var onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void = { _, _ in }
    /// Filing help's card buttons (TE255).
    var onFilingCard: (AskClaudeFilingAction) -> Void = { _ in }
    /// A card of changes: its ticks and row menus (TE267).
    var onPlanCard: (UUID, AskClaudePlanAction) -> Void = { _, _ in }
    /// A button under Claude's question (decision GB), by its place in the row.
    var onChoice: (UUID, Int) -> Void = { _, _ in }
    /// Where the panel wants its window, top-left within `container` (AskClaudeWindow.swift).
    var onPlace: (CGRect) -> Void = { _ in }

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var caret = AskClaudeComposerCaret()
    @State private var spentText = ""
    @AppStorage(AskClaudePrivacy.readsFilesKey) private var readsFiles = false
    @State private var showsPlace = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 372
    static let margin: CGFloat = 10
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720
    static let minHeight: CGFloat = 320
    /// Where a new panel starts: a chat's height, growing with the thread up to the window's.
    static let startHeight: CGFloat = 420
    /// How close to a side of the window a drop docks the panel there.
    static let snapZone: CGFloat = 56

    // TE248, round 3: docked right (the default), docked left, or floating where it was dropped.
    // One size in every placement, so moving never changes it (round 2 switched a docked panel's
    // full height for the floating one's on drop, and the jump read as the panel resizing itself).
    // Resized from its inner edge, its bottom edge and the corner between them, by AppKit handles:
    // SwiftUI gestures laid over the thread's scroll view lost the mouse to it. The move is
    // measured in window coordinates: measured in the panel's own, the moving panel fed its own
    // movement back into the drag and it jittered.
    enum Placement: String { case right, left, floating }
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

    private func docked(_ placement: Placement, width: CGFloat) -> CGPoint {
        placement == .left ? CGPoint(x: Self.margin, y: 8) : CGPoint(x: container.width - width - Self.margin, y: 8)
    }

    private func clamped(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(Self.margin, point.x), max(Self.margin, container.width - size.width - Self.margin)),
                y: min(max(8, point.y), max(8, container.height - size.height - 10)))
    }

    private var origin: CGPoint {
        if let liveOrigin { return liveOrigin }
        switch placement {
        case .floating: return clamped(CGPoint(x: storedX, y: storedY), size: size)
        case .left, .right: return docked(placement, width: size.width)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 }
            thread
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                composer
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottom = $0 }
        }
        .frame(width: size.width, height: size.height)
        // The frosted backdrop and the shadow are its window's (AskClaudeWindow.swift).
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .overlay { resizeHandles }
        .onChange(of: CGRect(origin: origin, size: size), initial: true) { _, frame in onPlace(frame) }
        .onAppear {
            // A draft left when the panel closed comes back with it.
            draft = chat.draft
            composerFocused = true
            refreshSpent()
        }
        // Kept as it's typed: a window torn down needn't say goodbye to its views.
        .onChange(of: draft) { _, typed in chat.draft = typed }
        // Something attached from a row's menu: the caret goes to the box for the question (TE263).
        .onChange(of: chat.attachments) { _, now in if !now.isEmpty { composerFocused = true } }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudeSpend.didChange)) { _ in refreshSpent() }
        // The limit is set in Settings, which writes it straight to the defaults.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in refreshSpent() }
        // The field gives up focus while it's disabled for a question; it takes it back after,
        // and VoiceOver hears that the answer is in.
        .onChange(of: chat.isRunning) { _, running in
            guard !running else { return }
            composerFocused = true
            if case .assistant = chat.items.last(where: { if case .receipt = $0.kind { false } else { true } })?.kind {
                AccessibilityNotification.Announcement("Claude answered").post()
            }
        }
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
                    if dropped.x <= Self.margin + Self.snapZone {
                        placementRaw = Placement.left.rawValue
                    } else if dropped.x + size.width >= container.width - Self.margin - Self.snapZone {
                        placementRaw = Placement.right.rawValue
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

    /// The inner side edge (the trailing one when floating), the bottom edge, and the corner
    /// between them, each a band just inside the border: the panel's window ends at its edge, so a
    /// band straddling it lost its outer half.
    private var resizeHandles: some View {
        let inner: AskClaudeResizeHandle.Edge = placement == .right ? .leading : .trailing
        let corner: AskClaudeResizeHandle.Edge = placement == .right ? .bottomLeading : .bottomTrailing
        let band: CGFloat = 6
        return ZStack {
            handle(inner)
                .frame(width: band)
                .padding(.vertical, Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: inner == .leading ? .leading : .trailing)
            handle(.bottom)
                .frame(height: band)
                .padding(.horizontal, Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            handle(corner)
                .frame(width: Radius.card, height: Radius.card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner == .bottomLeading ? .bottomLeading : .bottomTrailing)
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
            case .bottomLeading: next = CGSize(width: start.width - dx, height: start.height + dy)
            case .bottomTrailing: next = CGSize(width: start.width + dx, height: start.height + dy)
            }
            liveSize = next
        }, onEnd: {
            let final = size
            storedWidth = final.width
            if edge != .leading && edge != .trailing { storedHeight = final.height }
            liveSize = nil
            resizeStart = nil
        }, onDoubleClick: {
            // The bottom edge's double-click goes back to fitting the thread.
            guard edge != .leading && edge != .trailing else { return }
            withDesignAnimation(.spring(duration: 0.25), reduceMotion: reduceMotion) { storedHeight = 0 }
        })
        // Dragging can't be done by VoiceOver; the panel's size has no other control to name.
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .symbolRenderingMode(.hierarchical)
                    .font(.headline)
                // The title, and under it what the next question will describe (TE260).
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude").font(.headline)
                    Text(place.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(place.fullPath)
                }
            }
            .help("Drag the header to move. Drop it at the left or right side to dock it there; double-click to dock it right.")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            AskClaudeHeaderButton(symbol: "checkmark.shield", help: "What Claude sees, and what it may see", label: "What Claude Sees",
                                  isOn: showsPlace) { showsPlace.toggle() }
                .popover(isPresented: $showsPlace, arrowEdge: .bottom) {
                    AskClaudePlaceMenu(place: place, readsFiles: $readsFiles, spent: spentText, accentFill: accentFill, onAccent: onAccent,
                                       onGoTo: { showsPlace = false; onGoToFolder() },
                                       onSetHidden: { hidden in showsPlace = false; onSetHidden(hidden) },
                                       onEditHiddenList: { showsPlace = false; onOpenSettings() })
                        .presentedNativeControlAccent()
                }
            AskClaudeHeaderButton(symbol: "plus.bubble", help: "New chat", label: "New Chat") { chat.startOver() }
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
        .onTapGesture(count: 2) {
            withDesignAnimation(.spring(duration: 0.25), reduceMotion: reduceMotion) {
                placementRaw = Placement.right.rawValue
            }
        }
    }

    private var thread: some View {
        ScrollView {
                // **A plain VStack, not a lazy one.** The lazy stack went blank after scrolling to
                // the bottom while an answer grew (2026-10-31: the thread showed nothing while
                // chat.json held every message); a chat's few hundred rows don't need laziness.
                VStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty {
                        Text("Ask about your files, or tell me what to open: a folder, a file, a tab, another cloud, or a place in SyncCloud. I can look things up and move your view, and propose changes, which happen only when you click Apply.")
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                    let latestReceipt = chat.items.last { if case .receipt = $0.kind { true } else { false } }?.id
                    ForEach(chat.items) { item in
                        AskClaudeThreadRow(item: item, accent: accent, accentFill: accentFill, onAccent: onAccent, onOpenSettings: onOpenSettings,
                                           linkTargets: chat.linkTargets, onReveal: onReveal, onSendOffer: onSendOffer,
                                           onDownloadCard: onDownloadCard,
                                           onFilingCard: onFilingCard,
                                           onPlanCard: onPlanCard, onChoice: onChoice,
                                           isLatestReceipt: item.id == latestReceipt, isRunning: chat.isRunning)
                            // Rows that didn't change aren't redrawn as each word streams in.
                            .equatable()
                    }
                    if chat.isRunning && chat.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary).font(.caption)
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
        .contentMargins(.trailing, placement == .right ? 0 : 6, for: .scrollIndicators)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.attachments.isEmpty { attachmentChips }
            HStack(spacing: 6) {
                TextField("Ask a question, or say what to open", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
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
                        draft = shown
                        return .handled
                    }
                    .disabled(chat.isRunning)
                    .background(AskClaudeComposerCaret.Anchor(caret: caret))
                if chat.isRunning {
                    Button(action: chat.stop) { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop")
                        .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(accent)
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.well))
            .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(.separator.opacity(0.6)))
        }
        .padding(12)
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
                            Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .font(.caption)
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isRunning else { return }
        draft = ""
        chat.rememberSent(text)
        onAsk(text)
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
/// Asked of the field editor in the box's own window, found through a zero-sized view in the box:
/// the key window's could be another's. Asked through `firstRect(forCharacterRange:)`, which
/// TextKit 1 and 2 both answer; reaching for `layoutManager` would drop a TextKit 2 view back to 1.
@MainActor
final class AskClaudeComposerCaret {
    fileprivate weak var anchor: NSView?

    func isOnEdgeLine(up: Bool) -> Bool {
        // No field editor in front (it hasn't come up yet): nothing to move the caret through.
        guard let view = anchor?.window?.firstResponder as? NSTextView else { return true }
        return Self.isOnEdgeLine(of: view, up: up)
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

    struct Anchor: NSViewRepresentable {
        let caret: AskClaudeComposerCaret
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            caret.anchor = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { caret.anchor = view }
    }
}

/// One entry in the thread.
private struct AskClaudeThreadRow: View, Equatable {
    let item: AskClaudeChat.Item
    let accent: Color
    let accentFill: Color
    let onAccent: Color
    let onOpenSettings: () -> Void
    let linkTargets: [String: String]
    let onReveal: (String) -> Void
    let onSendOffer: (UUID) -> Void
    let onDownloadCard: (UUID, AskClaudeDownloadAction) -> Void
    let onFilingCard: (AskClaudeFilingAction) -> Void
    let onPlanCard: (UUID, AskClaudePlanAction) -> Void
    let onChoice: (UUID, Int) -> Void
    /// A card applies only once the question that offered it has finished.
    /// The newest receipt shows its summary; older ones fold to an icon, so the thread doesn't
    /// repeat “Sent screen …” under every answer.
    var isLatestReceipt = false
    /// While a question runs, an offer's Send waits: the send would be refused.
    var isRunning = false
    @State private var showsSent = false

    /// What the row draws from; the closures never change what it shows.
    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.linkTargets == b.linkTargets && a.isLatestReceipt == b.isLatestReceipt
            && a.isRunning == b.isRunning && a.accent == b.accent && a.accentFill == b.accentFill && a.onAccent == b.onAccent
    }

    static let revealScheme = "synccloud-askclaude"

    /// The answer's text with every known file name made a link that reveals it (TE245).
    ///
    /// - **The answer's own links are dropped**: a link Claude writes could point anywhere (a file
    ///   name or passage can carry text that asks for one), and only names this chat has seen may
    ///   be clicked.
    /// - **Longest names first, whole words only, no overlaps**, so "2024 Tax.pdf" isn't cut into
    ///   by "Tax.pdf", and "notes" doesn't link inside "footnotes".
    private func linked(_ text: String) -> AttributedString {
        var attributed = Self.markdown(text)
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        let plain = String(attributed.characters)
        for (found, path) in AskClaudeLinks.matches(of: linkTargets, in: plain) {
            let start = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let lower = attributed.characters.index(attributed.startIndex, offsetBy: start)
            let upper = attributed.characters.index(lower, offsetBy: length)
            var components = URLComponents()
            components.scheme = Self.revealScheme
            components.host = "reveal"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            if let url = components.url { attributed[lower..<upper].link = url }
        }
        return attributed
    }

    var body: some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .foregroundStyle(onAccent)
                .background(accentFill, in: RoundedRectangle(cornerRadius: Radius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You: \(text)")
        case .assistant(let text):
            Text(linked(text))
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
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.card))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Claude: \(text)")
        case .step(let label, let isError):
            Label(label, systemImage: isError ? "exclamationmark.circle" : "checkmark")
                .font(.caption)
                .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        case .moved(let note):
            Label(note, systemImage: "arrow.turn.down.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .accessibilityHint("Use Back to return")
        case .note(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .offer(let passage, let sent):
            VStack(alignment: .leading, spacing: 6) {
                Text("The on-device model read \(passage.fileName) here. Claude can read \(passage.whereInFile) itself for a fuller answer.")
                    .font(.caption)
                HStack(spacing: 8) {
                    Button(sent ? "Sent" : "Send to Claude") { onSendOffer(item.id) }
                        .controlSize(.small)
                        .disabled(sent || isRunning)
                        .help("Sends only this passage of the file to Claude, once.")
                    Text("\(passage.whereInFile) · about \(passage.tokens.formatted()) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        case .download(let download, let state):
            downloadCard(download, state)
        case .filing(let card):
            filingCard(card)
        case .plan(let plan):
            planCard(plan)
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
            .font(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.well))
        case .receipt(let receipt):
            Button { showsSent.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    if isLatestReceipt { Text(Self.summary(receipt)) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(isLatestReceipt ? "What this question sent" : Self.summary(receipt))
            .accessibilityLabel(Self.summary(receipt))
            .popover(isPresented: $showsSent, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.summary(receipt)).font(.callout)
                    Text("\(receipt.model.isEmpty ? "" : receipt.model + " · ")\(receipt.rounds) round\(receipt.rounds == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(receipt.screenText)
                            .font(.system(.caption2, design: .monospaced))
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
    }

    /// TE258: offered, downloading, then done, failed or timed out; Not Now folds it to a line.
    @ViewBuilder
    private func downloadCard(_ download: AskClaudeDownload, _ state: AskClaudeChat.DownloadState) -> some View {
        let size = download.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let verb = download.purpose == .read ? "Download and Read" : "Download and Open"
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .offered:
                Label(download.summary, systemImage: "icloud.and.arrow.down").font(.caption)
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
                    Text("Downloading \(download.fileName)…" + (size.map { " \($0)" } ?? "")).font(.caption)
                }
                Button("Stop Waiting") { onDownloadCard(item.id, .stopWaiting) }
                    .controlSize(.small)
                    .help("Stops waiting here. The download itself goes on until the cloud app finishes it.")
            case .done:
                Label("Downloaded \(download.fileName).", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            case .declined:
                Label("Didn’t download \(download.fileName).", systemImage: "icloud").font(.caption).foregroundStyle(.secondary)
            case .failed(let why):
                Label("Couldn’t download \(download.fileName): \(why).", systemImage: "exclamationmark.circle").font(.caption)
                retry()
            case .timedOut:
                Label("\(download.fileName) didn’t arrive within ten minutes.", systemImage: "exclamationmark.circle").font(.caption)
                retry()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
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
                            Text(folder.label).font(.caption.weight(.medium)).lineLimit(2).truncationMode(.head)
                        }
                        Text("\(index == 0 ? "" : "Runner-up · ")\(folder.confidence) · \(folder.reason)\(folder.note.map { " · \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary)
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
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if card.canRefine {
                    Button("Refine with Claude…") { onFilingCard(.refine(card.filePath)) }
                        .controlSize(.small)
                        .help("Opens this file’s folder in Organize and refines its suggestion there. The price is shown before anything is sent.")
                }
            case .noProfile:
                Label("No folder survey yet, so there’s nothing of how you file to go by.", systemImage: "folder.badge.questionmark")
                    .font(.caption)
                Button("Open Setup") { onFilingCard(.openSetup) }
                    .controlSize(.small)
                    .help("Setup’s folder survey learns how you file; this answer comes from it.")
            case .outside(let surveyed):
                Label("Your folder survey covers \(surveyed); \(card.place ?? "that place") isn’t in it.", systemImage: "folder.badge.questionmark")
                    .font(.caption)
            case .noMatch:
                Label("No folder in your folder survey fits \(card.fileName).", systemImage: "folder.badge.questionmark")
                    .font(.caption)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// TE267: rows by the folder they go to, each with its tick and its folder's menu. Trash rows
    /// are red and never ticked for them.
    private func planCard(_ plan: AskClaudePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Text(plan.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    if let heading = Self.heading(entry.group, count: entry.rows.count) {
                        Text(heading).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                    }
                    ForEach(entry.rows) { row in planRow(row) }
                }
            }
            if let left = plan.leftHere {
                Text(left).font(.caption2).foregroundStyle(.secondary)
            }
            if let more = plan.more {
                Text(more).font(.caption2).foregroundStyle(.secondary)
            }
            planFooter(plan)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    /// TE262: Apply and Not Now; then applying, done with Undo, or partly done.
    @ViewBuilder
    private func planFooter(_ plan: AskClaudePlan) -> some View {
        let count = plan.runnable.count
        switch plan.state {
        case .proposed:
            HStack(spacing: 8) {
                Text(isRunning ? "Apply waits for Claude to finish." : "Nothing changes until you click Apply.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Not Now") { onPlanCard(item.id, .notNow) }.controlSize(.small)
                Button(count == 0 ? "Apply" : "Apply \(count) Change\(count == 1 ? "" : "s")") { onPlanCard(item.id, .apply) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accentedProminent()
                    .disabled(count == 0 || isRunning)
                    .help("Makes the ticked changes, checking each one again first. One Undo takes them all back.")
            }
        case .applying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Applying \(count) change\(count == 1 ? "" : "s")…").font(.caption)
            }
        case .applied, .partlyApplied:
            VStack(alignment: .leading, spacing: 6) {
                Label(plan.summary ?? "Applied.", systemImage: plan.state == .applied ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(plan.state == .applied ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                if plan.undoName != nil {
                    HStack(spacing: 8) {
                        Button("Undo") { onPlanCard(item.id, .undo) }
                            .controlSize(.small)
                            .help("Takes back everything this card did, as Edit ▸ Undo does.")
                        Text("Also in Edit ▸ Undo").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        case .undone:
            Label("Undone: everything is back where it was.", systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.secondary)
        case .declined:
            Text("Not applied.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func heading(_ group: AskClaudePlan.Group, count: Int) -> String? {
        switch group {
        case .folder(let label): return label.isEmpty ? nil : "→ \(label) · \(count)"
        case .needsPick: return "Needs Your Pick · \(count)"
        case .alreadyFiled: return "Already Filed · \(count)"
        case .emptied: return nil
        }
    }

    private func planRow(_ row: AskClaudePlan.Row) -> some View {
        let plan: AskClaudePlan? = if case .plan(let p) = item.kind { p } else { nil }
        let editable = plan?.state == .proposed && row.refusal == nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: Binding(get: { row.ticked }, set: { onPlanCard(item.id, .tick(row.id, $0)) })) {
                    Text(row.name)
                        .font(.caption)
                        .strikethrough(row.refusal != nil || row.applied == false)
                        .foregroundStyle(row.refusal != nil ? AnyShapeStyle(.secondary)
                                         : row.isTrash ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                }
                .toggleStyle(.checkbox)
                .disabled(!editable)
                if row.applied == true { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green) }
                Spacer(minLength: 4)
                if let confidence = row.confidence, !row.isTrash {
                    Text(confidence).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                } else if row.isTrash {
                    Text("Trash").font(.caption2.weight(.medium)).foregroundStyle(.red)
                }
            }
            HStack(spacing: 4) {
                Text(([row.refusal.map { "Can’t apply: \($0)" }, row.result, row.reason, row.note,
                       plan?.subtitle.isEmpty == true ? row.folderLabel.map { "→ \($0)" } : nil] as [String?])
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(row.refusal != nil || row.applied == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if case .move = row.change, editable, !row.choices.isEmpty || plan?.subtitle.isEmpty == false {
                    Menu {
                        ForEach(Array(row.choices.enumerated()), id: \.offset) { _, choice in
                            Button(choice.label) { onPlanCard(item.id, .choose(row.id, choice)) }
                        }
                        if !row.choices.isEmpty { Divider() }
                        Button("Choose Folder…") { onPlanCard(item.id, .chooseFolder(row.id)) }
                    } label: {
                        Text(row.group == .needsPick ? "Choose" : (row.folderLabel.map { ($0 as NSString).lastPathComponent } ?? "Folder"))
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Where this file goes")
                }
            }
            .padding(.leading, 20)
        }
    }

    private func retry() -> some View {
        HStack(spacing: 8) {
            Button("Try Again") { onDownloadCard(item.id, .download) }.controlSize(.small)
            Button("Reveal in Finder") { onDownloadCard(item.id, .revealInFinder) }
                .controlSize(.small)
                .help("Shows it in Finder, where you can download it yourself.")
        }
    }

    static func summary(_ r: AskClaudeChat.Receipt) -> String {
        let screen = r.screenUnchanged ? "screen unchanged"
            : (r.rowsSent == r.rowsTotal ? "screen · \(r.rowsSent) rows" : "screen · \(r.rowsSent) of \(r.rowsTotal) rows")
        let tokens = (r.promptTokens + r.outputTokens).formatted(.number.notation(.compactName))
        return "Sent \(screen) · \(tokens) tokens · \(AskClaudeSpend.format(r.costUSD))"
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
                .font(.system(size: 13, weight: .medium))
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
    static func matches(of targets: [String: String], in text: String) -> [(range: Range<String.Index>, path: String)] {
        var found: [(range: Range<String.Index>, path: String)] = []
        for (name, path) in targets.sorted(by: { ($0.key.count, $0.key) > ($1.key.count, $1.key) }) {
            var search = text.startIndex..<text.endIndex
            while let hit = text.range(of: name, options: [.caseInsensitive], range: search) {
                search = hit.upperBound..<text.endIndex
                guard isWholeWord(hit, in: text), !found.contains(where: { $0.range.overlaps(hit) }) else { continue }
                found.append((hit, path))
            }
        }
        return found
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
    enum Edge { case leading, trailing, bottom, bottomLeading, bottomTrailing }

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
            case .bottomLeading: .bottomLeft
            case .bottomTrailing: .bottomRight
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

/// What a card of changes asks for (TE267).
enum AskClaudePlanAction: Equatable {
    case tick(Int, Bool)
    /// A row sent to one of its menu's folders.
    case choose(Int, AskClaudePlan.Choice)
    /// Choose Folder… on a row's menu.
    case chooseFolder(Int)
    /// TE262: the card's own buttons.
    case apply, notNow, undo
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
