import SwiftUI
import AppKit
import Events
import Design

/// The toolbar's Go-to control in both of its states: the pill you click, and the field it becomes.
///
/// One view, not two, because the states are one control morphing: the width animates between
/// them, where a `ToolbarItem` swapping views would cross-fade.
public struct GoToFieldBar: View {

    /// Closed at the rung the row resolved, or open at the width and placeholder it resolved. Both
    /// come from `WorkspaceBarMetrics.styles`: the row, not the control, decides its size.
    public enum Mode: Equatable {
        case closed(CommandPaletteBarStyle)
        case open(GoToFieldLayout)
    }

    let mode: Mode
    @Binding var query: String
    let chord: String
    /// Bumped by the host to claim the caret: on open, and on ⌘K while open, where it also selects
    /// the text so the next keystroke replaces it.
    let focusToken: Int
    let accent: Color
    let onOpen: () -> Void
    /// −1 for ↑, +1 for ↓.
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    public init(mode: Mode, query: Binding<String>, chord: String, focusToken: Int, accent: Color,
                onOpen: @escaping () -> Void, onMove: @escaping (Int) -> Void,
                onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.mode = mode
        self._query = query
        self.chord = chord
        self.focusToken = focusToken
        self.accent = accent
        self.onOpen = onOpen
        self.onMove = onMove
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    @Environment(\.appFontScale) private var scale

    public var body: some View {
        // One root view for both states, and it must stay one. Returning the pill from one branch
        // and the field from the other changes the toolbar item's content type, which leaves
        // `NSToolbarItem.view` nil after the field closes: the item still counts as visible but
        // draws nothing, and a resize doesn't bring it back. Keep the switch inside the container.
        HStack(spacing: 0) {
            switch mode {
            case .closed(let style):
                CommandPaletteBar(style: style, chord: chord, action: onOpen)
            case .open(let layout):
                open(layout)
            }
        }
    }

    private func open(_ layout: GoToFieldLayout) -> some View {
        HStack(spacing: CommandPaletteBarMetrics.contentGap) {
            Image(systemName: "magnifyingglass")
                .scaledFont(.system(size: 12, weight: .medium))
                .frame(width: CommandPaletteBarMetrics.glyphWidth)
                .foregroundStyle(accent)
            GoToTextField(
                text: $query,
                placeholder: layout.placeholder == .full
                    ? GoToFieldMetrics.fullPlaceholder : GoToFieldMetrics.shortPlaceholder,
                scale: scale,
                focusToken: focusToken,
                onMove: onMove, onSubmit: onSubmit, onCancel: onCancel)
            trailing
        }
        .padding(.horizontal, CommandPaletteBarMetrics.horizontalPadding)
        .padding(.vertical, CommandPaletteBarMetrics.verticalPadding)
        .frame(width: layout.width)
        // The pill's resting wash, plus an accent ring saying the caret is here: the one control on
        // this row that holds keystrokes.
        .background(
            Capsule()
                .fill(.quaternary.opacity(0.5))
                .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
        )
        .accessibilityLabel("Go to")
    }

    /// The `esc` keycap while the field is empty (the key that closes it), and a clear button once
    /// there is something to clear.
    @ViewBuilder private var trailing: some View {
        if query.isEmpty {
            ShortcutKeycap(GoToFieldMetrics.closeKeycap)
        } else {
            Button {
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .hoverInk()
            }
            .buttonStyle(.hoverAffordance(.inline))
            .help("Clear")
            .accessibilityLabel("Clear")
        }
    }
}

/// The field itself, in AppKit.
///
/// Not a SwiftUI `TextField`: in a `ToolbarItem`, `@FocusState` can't put the caret in one, which
/// is exactly what ⌘K needs, and a field focused behind SwiftUI's back loses the caret on a later
/// re-render while the focus state still reads `false`. With AppKit owning it, ↑ ↓ ↩ esc arrive
/// through the field editor's `doCommandBy` as `moveUp:`, `moveDown:`, `insertNewline:` and
/// `cancelOperation:`.
struct GoToTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let scale: CGFloat
    let focusToken: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    /// One display frame. Short enough that the caret arrives without a visible wait, long enough
    /// that the runloop gets to mount the toolbar item between attempts.
    static let retryInterval: TimeInterval = 1.0 / 60.0
    /// ~0.6s of frames. Generous: running out leaves a dead field, and an unused attempt costs
    /// nothing, since the loop stops once the window appears.
    static let focusAttempts = 36

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.font = ScaledFont.system(size: GoToFieldMetrics.textPointSize).nsFont(scale: scale)
        field.placeholderString = placeholder
        // Low hugging and low compression resistance: the field absorbs whatever width the capsule
        // has, so the keycap beside it is not the part squeezed.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        let font = ScaledFont.system(size: GoToFieldMetrics.textPointSize).nsFont(scale: scale)
        if field.font != font { field.font = font }
        context.coordinator.callbacks = (onMove, onSubmit, onCancel)
        guard context.coordinator.claimedToken != focusToken else { return }
        context.coordinator.claimedToken = focusToken
        claimFocus(field, attemptsLeft: Self.focusAttempts)
    }

    /// Claims the caret, retrying: the first update can run before the field is in a window, where
    /// `makeFirstResponder` silently does nothing. Each retry re-reads the field's window.
    ///
    /// **The retry must be `asyncAfter`.** A bare `DispatchQueue.main.async` block queued during a
    /// main-queue drain runs in that same drain, so every attempt would be spent before the SwiftUI
    /// update mounts the toolbar item. A frame between attempts lets the runloop mount it.
    private func claimFocus(_ field: NSTextField, attemptsLeft: Int) {
        guard let window = field.window else {
            guard attemptsLeft > 0 else {
                // Logged because nothing else shows it: the field is on screen but ignores typing.
                // The panel logs the matching half when its anchor runs out.
                Logger.shared.warning("[palette] the Go to field never reached a window — it opened without the caret")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
                claimFocus(field, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        window.makeFirstResponder(field)
        // Selected, not appended to: ⌘K on an open field means "search for something else", so the
        // old query should go in one keystroke.
        field.currentEditor()?.selectAll(nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, callbacks: (onMove, onSubmit, onCancel))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        var callbacks: (onMove: (Int) -> Void, onSubmit: () -> Void, onCancel: () -> Void)
        /// The last focus token acted on, so an ordinary re-render does not re-select the text
        /// under the user mid-edit.
        var claimedToken: Int?

        init(text: Binding<String>,
             callbacks: (onMove: (Int) -> Void, onSubmit: () -> Void, onCancel: () -> Void)) {
            self.text = text
            self.callbacks = callbacks
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The four keys the list needs, taken from the field editor before it acts on them. `true`
        /// means handled, so the arrows don't also move the caret and ↩ inserts no newline;
        /// everything else stays AppKit's.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                callbacks.onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                callbacks.onMove(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                callbacks.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                callbacks.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

