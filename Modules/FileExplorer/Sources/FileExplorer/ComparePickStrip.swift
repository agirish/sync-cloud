import Design
import SwiftUI

/// The mode indicator for ``ComparePick``: one file armed, waiting for its counterpart.
///
/// Not an `OperationBannerView`, because banners auto-dismiss on `BannerDismissScheduler`'s timers
/// and a mode indicator that vanishes while the mode runs would leave the next click opening a
/// comparison with nothing on screen saying why. This strip stands exactly as long as the pick.
///
/// It names the ways out, since a mode with an invisible exit is a trap: click a file to finish,
/// esc or Cancel to abandon. Clicking the armed row again also cancels; its marker says so.
public struct ComparePickStrip: View {

    /// The armed file's name, shown on its own so it can be truncated without taking the
    /// surrounding sentence with it.
    public let fileName: String
    public let onCancel: () -> Void

    /// Read here rather than passed in, so the strip cannot drift from the rest of the window's hue.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    /// The widest the name may draw before it truncates. Real filenames run long, and an unbounded
    /// one pushes the hint and Cancel past the window's edge. Middle truncation keeps the two ends
    /// that identify a file: what it is, and which version.
    static let nameWidth: CGFloat = 260

    public init(fileName: String, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.onCancel = onCancel
    }

    /// The whole mode in one sentence, for VoiceOver. Internal rather than inlined so tests can
    /// read it, since a mounted `Text` can't be read back; the instruction must stay outside the
    /// truncating name.
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

/// The marker a row wears while it is the file armed for comparison (see ``ComparePick``). A
/// visible mark rather than a tint, because clicking the armed row again cancels the pick, and a
/// reader who can't see which row is armed can't find that undo.
struct ComparePickBadge: View {
    let fonts: PaneRowFonts
    /// The pane's accent, passed rather than read from `.tint` — see `PaneSearchAnnotation.accent`.
    let accent: Color

    var body: some View {
        Image(systemName: PaneGlyph.compare)
            .font(fonts.cloudBadge)
            .foregroundStyle(accent)
            .help("Armed for comparison — click another file to compare, or click this row again to cancel")
            .accessibilityLabel("Armed for comparison")
    }
}
