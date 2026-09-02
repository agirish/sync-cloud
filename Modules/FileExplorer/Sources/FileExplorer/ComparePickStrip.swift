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

    /// The armed file's name, shown on its own so it can be truncated without taking the
    /// surrounding sentence with it.
    public let fileName: String
    public let onCancel: () -> Void

    /// Read here rather than passed in, so the strip cannot drift from the rest of the window's hue.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    /// The widest the name may draw before it truncates.
    ///
    /// **A ceiling, because the first cut had none and the bar was unreadable.** Real filenames are
    /// not short — the one this was found on was "Irrigation system check 10-10-2024 ( Clock C )
    /// readvised new templet.3-18.pdf" — and an unbounded name pushed the hint and the Cancel
    /// button off past the window's edge. Middle truncation keeps the two ends that identify a
    /// file: what it is, and which version of it.
    static let nameWidth: CGFloat = 260

    public init(fileName: String, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.onCancel = onCancel
    }

    /// The whole mode, in one sentence, for VoiceOver — and the seam the sentence is asserted on.
    ///
    /// **Internal rather than inlined at the modifier**, because a SwiftUI `Text` cannot be read
    /// back off a mounted view and the words are the thing under test: the name is bounded and
    /// truncates, and the instruction must NOT be inside the run that truncates with it.
    var accessibilityDescription: String {
        "Comparing with \(fileName). Click another file in either pane, or press escape to cancel."
    }

    public var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(glassHue.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(glassHue.accentColor.opacity(0.30), lineWidth: 1)
                    }
            }
    }

    /// Split from the chrome for the reason ``PaneActionBar/content`` is: a shape-backed container
    /// renders empty offscreen and takes its content with it, so a snapshot of the whole strip
    /// shows only the stroke. Everything this view positions lives here.
    var content: some View {
        HStack(spacing: 8) {
            Image(systemName: PaneGlyph.compare)
                .scaledFont(.system(size: 12, weight: .medium))
                .foregroundStyle(glassHue.accentColor)

            Text("Comparing with")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()

            Text(fileName)
                .scaledFont(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.nameWidth, alignment: .leading)
                .help(fileName)

            Text("— click another file in either pane")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Text("Cancel")
                    .scaledFont(.system(size: 11.5))
            }
            .buttonStyle(.hoverAffordance(.segment, tint: glassHue.accentColor))
            .controlSize(.small)
            .shortcutKeycap("esc")
            .help(ShortcutHint.tooltip("Cancel the comparison pick", "esc"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
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
