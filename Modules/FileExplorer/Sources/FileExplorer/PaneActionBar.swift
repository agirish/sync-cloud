import Design
import SwiftUI
import Sync

/// The selection-driven file-action bar docked at the bottom of the active pane: what is selected,
/// and what can be done with it.
///
/// **Why the summary reserves its width.** The bar's leading element is
/// `"12 selected · 340 MB"`, and both halves of it change width as you click around: the count's
/// digits, and the size's digits and unit. Sized to its content, it moved every button after it —
/// measured in the running app, Compare sat at x≈452 for "10.7 MB" and x≈470 for "972.2 MB", so
/// the buttons jumped ~18pt under the cursor on every selection change. Going to click Copy,
/// changing your mind, and finding Copy somewhere else is the bug.
///
/// The fix is to give the summary a *stable* width rather than a flexible one, so the row's
/// geometry stops depending on its text. A hidden twin rendered with the widest realistic summary
/// establishes the frame; the real text draws inside it and truncates. That keeps the layout
/// identical to before — buttons immediately after the summary, Delete and ✕ pushed to the trailing
/// edge — while making their positions constant.
///
/// Deriving the width from a reference *string* rather than a hard-coded number matters: the bar
/// uses `scaledFont`, so a pt constant would be wrong at every text size but the default.
///
/// One movement is deliberately left in: Compare appears only for a single selected folder, so the
/// button set genuinely differs between selecting a file and a folder. Reserving a permanent gap
/// for a button that is usually absent would trade a real change for a phantom one.
///
/// `PaneActionBarStabilityTests` renders the bar across the full summary swing and asserts the
/// button region is pixel-identical, so this cannot regress quietly.
public struct PaneActionBar: View {
    /// "12 selected · 340 MB" — see `SelectionSummary.text(for:)`.
    public let summaryText: String
    /// Compare is offered only for a single selected folder.
    public let showsCompare: Bool
    /// Already localised against the other pane's name ("Copy to Dropbox") by the caller, which is
    /// the only place that knows it.
    public let copyTitle: String
    public let moveTitle: String
    public let copySymbol: String
    public let moveSymbol: String

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
    /// is never displayed — only measured.
    static let summaryWidthReference = "888 selected · 888.8 MB"

    public init(summaryText: String, showsCompare: Bool, copyTitle: String, moveTitle: String,
                copySymbol: String, moveSymbol: String,
                onCompare: @escaping () -> Void, onCopy: @escaping () -> Void,
                onMove: @escaping () -> Void, onDelete: @escaping () -> Void,
                onClear: @escaping () -> Void) {
        self.summaryText = summaryText
        self.showsCompare = showsCompare
        self.copyTitle = copyTitle
        self.moveTitle = moveTitle
        self.copySymbol = copySymbol
        self.moveSymbol = moveSymbol
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
            // A subtle, transparent-ish accent-tinted glass — not a gray material and not a solid
            // slab. The buttons carry the accent chrome; the bar itself just whispers the hue.
            .accentGlassCapsule(glassHue.accentColor, strength: 0.12)
            .overlay(Capsule().strokeBorder(glassHue.accentColor.opacity(0.35), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The row itself, separated from the glass chrome around it.
    ///
    /// Split so the layout can be pixel-tested: a `.glassEffect` container renders *empty* offscreen
    /// and takes its content with it, so a snapshot of the whole bar shows only the stroke. The
    /// chrome is decoration; every position this file is responsible for lives in here, and this is
    /// what `PaneActionBarStabilityTests` renders.
    var content: some View {
        let accent = glassHue.accentColor
        return HStack(spacing: 8) {
            // The hidden twin sizes the zone; the real summary draws inside it and truncates, so
            // this element's width no longer depends on its text. Monospaced digits steady the
            // count within that zone as well.
            summaryLabel(Self.summaryWidthReference, accent: accent)
                .hidden()
                .overlay(alignment: .leading) {
                    summaryLabel(summaryText, accent: accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 4)
                .accessibilityLabel(summaryText)

            if showsCompare {
                actionBarButton("Compare", systemImage: PaneGlyph.compare, accent: accent, action: onCompare)
            }
            actionBarButton(copyTitle, systemImage: copySymbol, accent: accent, action: onCopy)
            actionBarButton(moveTitle, systemImage: moveSymbol, accent: accent, action: onMove)

            // New Folder is intentionally omitted here to keep the bar compact — it lives in the
            // pane's nav cluster and its right-click menu.
            Spacer(minLength: 6)

            actionBarButton("Delete", systemImage: "trash", accent: accent, role: .destructive, action: onDelete)

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
            .help("Clear selection (Esc)")
            .accessibilityLabel("Clear selection")
        }
    }

    /// The summary's content, rendered twice: once hidden to fix the zone's width, once visible.
    /// One builder so the two can never disagree about font, weight or spacing — which would make
    /// the reserved width wrong in exactly the way this is meant to prevent.
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

    /// One button in the bar — the same `ActionBarButtonStyle` the differences header uses, at
    /// `.primary`. It used to be a private lookalike with its own capsule, metrics and fill, which
    /// is how the two drifted: `ActionBarWeight.primary` fills at opacity 1, the lookalike filled at
    /// 0.9 while resting, and `AccentFill` leaves NO headroom for that — the deepened colour sits
    /// exactly on the 4.55:1 ceiling, so any alpha below 1 composites the surface behind it back in
    /// and puts the white label under the floor.
    ///
    /// The destructive red needs no deepening — it already carries white — but goes through the
    /// same call so there is one rule here instead of a special case.
    private func actionBarButton(_ title: String, systemImage: String, accent: Color,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        let isDestructive = role == .destructive
        return Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.actionBar(.primary,
                                tint: AccentFill.deepened(isDestructive ? .red : accent),
                                onTint: isDestructive ? .onFillLabel(.red) : glassHue.onAccentLabelColor))
    }
}
