import Design
import SwiftUI
import Sync

/// The selection-driven file-action bar docked at the bottom of the active pane: what is selected,
/// and what can be done with it.
///
/// The summary ("12 selected · 340 MB") reserves a stable width, because its digits and unit change
/// with every click and, sized to content, would move every button after it under the cursor. A
/// hidden twin with the widest realistic summary sets the frame; the real text draws inside it and
/// truncates. The reference is a string, not a pt constant, so it is right at every text size.
///
/// One movement is left in: Compare appears only for a selection it can act on (one folder or two
/// files), and a permanent gap for an often-absent button would be a phantom change.
/// `PaneActionBarStabilityTests` asserts the button region is pixel-identical across the swing.
public struct PaneActionBar: View {
    /// "12 selected · 340 MB"; see `SelectionSummary.text(for:)`.
    public let summaryText: String
    /// Whether this selection has a comparison to offer at all: one folder, or two files. The rule
    /// is `PaneLogic.compareOffer(for:)`, which the host also acts on, so the button's presence and
    /// action can't disagree. One word serves both, since they are mutually exclusive, and this
    /// surface never says "Compare files", so the sidebar's Compare keeps one meaning.
    public let showsCompare: Bool
    /// What the Compare button says: "Compare" for a comparison this click completes, "Compare
    /// with…" where it arms a pick and asks for the second file. Supplied by the host, which owns
    /// the rule (`PaneLogic.CompareOffer.buttonTitle`), so the label and the action cannot drift.
    public var compareTitle: String = "Compare"
    /// Already localised against the other pane's name ("Copy to Dropbox") by the caller, which is
    /// the only place that knows it.
    public let copyTitle: String
    public let moveTitle: String
    public let copySymbol: String
    public let moveSymbol: String
    /// What the transfer actually does with the destination, which the title cannot say: it names
    /// a whole side ("iCloud (right)"), true of every folder over there, while the operation puts
    /// each item at its own matching path. Nothing else on screen states that rule. Optional so a
    /// caller with no sibling pane to describe simply omits it.
    public let transferHelp: String?

    public let onCompare: () -> Void
    public let onCopy: () -> Void
    public let onMove: () -> Void
    public let onDelete: () -> Void
    public let onClear: () -> Void

    /// Read here rather than passed in, so the bar cannot drift from the rest of the window's hue.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }

    /// The widest summary the bar realistically renders, used to reserve the leading zone. Wide
    /// enough that real text truncates only in absurd cases (a four-digit selection of terabytes),
    /// narrow enough not to waste the row. `8` is the widest digit in most faces, and this string
    /// is only measured, never displayed.
    static let summaryWidthReference = "888 selected · 888.8 MB"

    public init(summaryText: String, showsCompare: Bool, compareTitle: String = "Compare",
                copyTitle: String, moveTitle: String,
                copySymbol: String, moveSymbol: String, transferHelp: String? = nil,
                onCompare: @escaping () -> Void, onCopy: @escaping () -> Void,
                onMove: @escaping () -> Void, onDelete: @escaping () -> Void,
                onClear: @escaping () -> Void) {
        self.summaryText = summaryText
        self.showsCompare = showsCompare
        self.compareTitle = compareTitle
        self.copyTitle = copyTitle
        self.moveTitle = moveTitle
        self.copySymbol = copySymbol
        self.moveSymbol = moveSymbol
        self.transferHelp = transferHelp
        self.onCompare = onCompare
        self.onCopy = onCopy
        self.onMove = onMove
        self.onDelete = onDelete
        self.onClear = onClear
    }

    public var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // A subtle accent-tinted glass, not a gray material or a solid slab. The buttons carry
            // the accent chrome; the bar only hints at the hue.
            .accentGlassCapsule(glassHue.accentColor, strength: 0.12)
            .overlay(Capsule().strokeBorder(glassHue.accentColor.opacity(0.35), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The row itself, separated from the glass chrome around it.
    ///
    /// Split so the layout can be pixel-tested: a `.glassEffect` container renders empty offscreen,
    /// content and all, so a snapshot of the whole bar shows only the stroke. Every position this
    /// file owns lives in here, and this is what `PaneActionBarStabilityTests` renders.
    var content: some View {
        let accent = glassHue.accentColor
        return HStack(spacing: 8) {
            // The hidden twin sizes the zone; the real summary draws inside it and truncates, so
            // this element's width doesn't depend on its text. Monospaced digits steady the count.
            summaryLabel(Self.summaryWidthReference, accent: accent)
                .hidden()
                .overlay(alignment: .leading) {
                    summaryLabel(summaryText, accent: accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 4)
                .accessibilityLabel(summaryText)

            if showsCompare {
                actionBarButton(compareTitle, systemImage: PaneGlyph.compare, accent: accent,
                                help: compareTitle == "Compare with…"
                                    ? ShortcutHint.tooltip("Pick a second file to compare this one with — in either pane",
                                                           AppChord.compareTwoFiles.display)
                                    : "Compare just this folder, or the two selected files",
                                action: onCompare)
            }
            actionBarButton(copyTitle, systemImage: copySymbol, accent: accent, help: transferHelp,
                            writes: true, action: onCopy)
            actionBarButton(moveTitle, systemImage: moveSymbol, accent: accent, help: transferHelp,
                            writes: true, action: onMove)

            // No New Folder, to keep the bar compact; it lives in the pane's nav cluster and its
            // right-click menu.
            Spacer(minLength: 6)

            actionBarButton("Delete", systemImage: "trash", accent: accent, role: .destructive,
                            help: ShortcutHint.tooltip("Move the selected items to the Trash", AppChord.deleteSelection.display),
                            keycap: AppChord.deleteSelection.display, writes: true, action: onDelete)

            // ✕ dismisses the selection (the file lists offer no deselect gesture; Escape does the
            // same). At the trailing edge, separated from the actions, so it reads as "close this
            // bar" rather than pairing visually with the ✓ in the summary.
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.system(size: 14))
                    .hoverInk()
                    .padding(.leading, 4)
            }
            .buttonStyle(.hoverAffordance(.inline))
            .shortcutKeycap("esc")
            .help(ShortcutHint.tooltip("Clear selection", "esc"))
            .accessibilityLabel("Clear selection")
        }
    }

    /// The summary's content, rendered twice: once hidden to fix the zone's width, once visible.
    /// One builder, so the two can't disagree about font, weight or spacing and make the reserved
    /// width wrong.
    private func summaryLabel(_ text: String, accent: Color) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .scaledFont(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(accent)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// One button in the bar: the same `ActionBarButtonStyle` the differences header uses, at
    /// `.primary`, which fills at opacity 1. **Don't fill it below opacity 1**: `AccentFill`'s
    /// deepened colour sits right at 4.55:1, so any alpha lets the surface through and drops the
    /// white label under the contrast floor.
    ///
    /// The destructive red needs no deepening (it already carries white) but goes through the same
    /// call, so there is one rule instead of a special case.
    private func actionBarButton(_ title: String, systemImage: String, accent: Color,
                                 role: ButtonRole? = nil, help: String? = nil,
                                 keycap: String? = nil, writes: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        return Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.actionBar(.primary,
                                tint: AccentFill.deepened(isDestructive ? .red : accent),
                                onTint: isDestructive ? .onFillLabel(.red) : glassHue.onAccentLabelColor))
        // Between the style and `.help`: the keycap goes above any `.disabled` (none here), with
        // `.help` outside it so the tooltip keeps the control's description on the accessibility
        // element. A nil keycap withholds both the badge and the hint.
        .shortcutKeycap(keycap)
        // Copy, Move and Delete grey with the reason while a long run is going.
        .lockedDuringRun(writes)
        // `.help` takes a non-optional, and `.help("")` renders an empty tooltip box rather than
        // none, so the presence check has to happen somewhere.
        .modifier(OptionalHelp(text: help))
    }
}

/// Applies `.help` only when a string is present.
///
/// This still branches, so the two arms are two structural identities; it is a modifier only so
/// the button's chain reads as one expression. Safe because the buttons hold no state, and
/// `transferHelp` changes only with the active pane, which rebuilds the bar anyway. **Don't use
/// this pattern around anything stateful.**
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
