import Design
import SwiftUI

/// The mode indicator for ``ComparePick`` — one file armed, waiting for its counterpart.
///
/// **Not `OperationBannerView`, and that is a correctness point rather than a style one.** Banners
/// auto-dismiss on `BannerDismissScheduler`'s timers (5s on success, 10s on warning). A mode
/// indicator that disappears while the mode is still running is a lie about the state of the
/// window: the next click would still open a comparison, and nothing on screen would say why. This
/// strip stands for exactly as long as the pick does.
///
/// **It states the three ways out, because a mode with an invisible exit is a trap.** Clicking a
/// file completes it (that is the prompt), esc or Cancel abandon it, and clicking the armed row
/// again cancels — the last is discoverable from the row's own marker rather than from here, since
/// naming all three would make the strip a paragraph.
public struct ComparePickStrip: View {

    /// The sentence naming the armed file — ``ComparePick/prompt``.
    public let prompt: String
    public let onCancel: () -> Void

    /// Read here rather than passed in, so the strip cannot drift from the rest of the window's hue.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    public init(prompt: String, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onCancel = onCancel
    }

    public var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(glassHue.accentColor.opacity(0.12))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(glassHue.accentColor.opacity(0.35), lineWidth: 1)
                    }
            }
    }

    /// Split from the chrome for the reason ``PaneActionBar/content`` is: a shape-backed container
    /// renders empty offscreen and takes its content with it, so a snapshot of the whole strip
    /// shows only the stroke. Everything this view is responsible for positioning lives here.
    var content: some View {
        HStack(spacing: 8) {
            Image(systemName: PaneGlyph.compare)
                .scaledFont(.system(size: 12, weight: .medium))
                .foregroundStyle(glassHue.accentColor)

            Text(prompt)
                .scaledFont(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("esc to cancel")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.system(size: 13))
                    .hoverInk()
            }
            .buttonStyle(.hoverAffordance(.inline))
            .shortcutKeycap("esc")
            .help(ShortcutHint.tooltip("Cancel the comparison pick", "esc"))
            .accessibilityLabel("Cancel the comparison pick")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
    }
}

/// The marker a row wears while it is the file armed for comparison — see ``ComparePick``.
///
/// **It is also the off switch**, which is why it is a visible mark rather than a subtle tint:
/// clicking the armed row again cancels the pick, and that is the natural undo for a mode whose
/// only anchor in the panes is this one row. A reader who cannot see which row is armed cannot
/// find that undo.
struct ComparePickBadge: View {
    let fonts: PaneRowFonts

    var body: some View {
        Image(systemName: PaneGlyph.compare)
            .font(fonts.cloudBadge)
            .foregroundStyle(.tint)
            .help("Armed for comparison — click another file to compare, or click this row again to cancel")
            .accessibilityLabel("Armed for comparison")
    }
}
