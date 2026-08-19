import SwiftUI
import AppKit
import Events
import Design

/// The toolbar's Go-to control in both of its states: the pill you click, and the field it becomes.
///
/// One view rather than two, because the two states are one control morphing — the width animates
/// between them, and a `ToolbarItem` that swapped one view for another would cross-fade instead.
public struct GoToFieldBar: View {

    /// Closed, at the rung the row resolved for it; or open, at the width and placeholder the row
    /// resolved for it. Both come out of `WorkspaceBarMetrics.styles` — the field does not get to
    /// decide its own width, for the same reason the pill does not decide its own rung.
    public enum Mode: Equatable {
        case closed(CommandPaletteBarStyle)
        case open(GoToFieldLayout)
    }

    let mode: Mode
    @Binding var query: String
    let chord: String
    /// Bumped by the host to claim the caret — on open, and again on ⌘K while already open, where
    /// it also selects what is there so the next keystroke replaces it.
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
        // **One root view for both states, and it has to be one.** Returning the pill from one
        // branch and the field from another changes the toolbar item's content type, and measured
        // in the app that leaves `NSToolbarItem.view` NIL after the field closes — the item stays
        // in `NSToolbar.items`, still counts as visible, and draws nothing. The control vanished
        // from the row on close and a resize did not bring it back. The conditional is a CHILD of
        // a stable container now.
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
        // The same resting wash as the pill it grew out of, with the accent ring saying the caret
        // is here — the field is the one control on this row that holds keystrokes.
        .background(
            Capsule()
                .fill(.quaternary.opacity(0.5))
                .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
        )
        .accessibilityLabel("Go to")
    }

    /// `esc` while the field is empty — the key that closes it — and a clear button once there is
    /// something to clear, which is the more useful of the two at that point and the one the user
    /// can reach with the mouse they are already holding.
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
/// **Not a SwiftUI `TextField`, and the reason was measured in this app rather than assumed**
/// (ROADMAP_V4 §7, 2026-08-18). A SwiftUI `TextField` in a `ToolbarItem` does materialise as a
/// focusable AppKit control and does type — but `@FocusState` cannot put the caret in it, with the
/// state owned by the field's own view or by the scene root. ⌘K is precisely that: focus claimed
/// with no click to ride in on. Worse, a SwiftUI field focused behind SwiftUI's back is one
/// re-render from losing the caret — with the root focus state still reading `false`, focus granted
/// by a click was revoked inside two seconds and the typing that followed went nowhere.
///
/// With AppKit owning the field, ↑ ↓ ↩ esc arrive through the field editor's `doCommandBy` —
/// verified in the same probe to deliver `moveUp:`, `moveDown:`, `insertNewline:` and
/// `cancelOperation:` from this exact toolbar slot.
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
    /// ~0.6s of frames. Generous because the cost of running out is a dead field, and the cost of
    /// an unused attempt is nothing — the loop stops the moment the window appears.
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
        // Hugging low, compression high: the field is the part of the row that should absorb
        // whatever width the capsule was given, and the keycap beside it is the part that must not
        // be squeezed.
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

    /// Claiming the caret, with a retry rather than a single shot.
    ///
    /// The first update after the field is created can run before it is in a window, and
    /// `makeFirstResponder` on a windowless view is a silent no-op — which would read as "⌘K opened
    /// a field you then have to click". The retry re-reads the field's window each time rather than
    /// capturing one.
    ///
    /// **The retry has to be `asyncAfter`, and three attempts was not a budget.** Measured in the
    /// running app (2026-08-19): with a bare `DispatchQueue.main.async` every attempt was spent
    /// before the field was mounted — the main queue drains blocks queued *during* a drain in the
    /// same pass, so all three ran back-to-back inside one runloop turn, ahead of the SwiftUI
    /// update that installs the toolbar item. The app said so (`claimFocus GAVE UP — never
    /// mounted`) and ⌘K opened a field with no caret. A frame between attempts is what lets the
    /// runloop do the mounting this is waiting for.
    private func claimFocus(_ field: NSTextField, attemptsLeft: Int) {
        guard let window = field.window else {
            guard attemptsLeft > 0 else {
                // Said out loud, because this failure has no other trace: the field is on screen
                // and simply does not take what you type, which reads as ⌘K being broken rather
                // than as focus never having been claimed. The panel logs the matching half when
                // its anchor runs out.
                Logger.shared.warning("[palette] the Go to field never reached a window — it opened without the caret")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
                claimFocus(field, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        window.makeFirstResponder(field)
        // Selected, not appended to: ⌘K on an already-open field means "search for something else",
        // and a remembered query the user did not just type is the one they most need replaced in
        // a single keystroke.
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

        /// The four keys the list needs, taken from the field editor before it acts on them.
        ///
        /// `true` means handled — the arrows must NOT also move the caret, and ↩ must not insert a
        /// newline into a single-line field. Everything else is returned unhandled, so word
        /// movement, selection and deletion stay exactly what AppKit does everywhere else.
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

