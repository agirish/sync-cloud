import Foundation
import CoreGraphics
import Design
import FileExplorer

/// Whether the workspace bar can afford to spell its segments out.
///
/// Measured through `styles` beside a compact ⌘K pill, the four labels need 683.8pt of content
/// width at the default text size (741.6 at Largest), under the window's 804pt minimum width
/// (`ContentView`), so the bar keeps its labels at every text size at the narrowest window. The
/// margin to watch is Largest's; a fifth segment would have to fit inside it.
///
/// A toolbar that does not fit does not wrap or truncate: macOS folds the overflow behind a
/// chevron, and the only control for switching workspace disappears.
enum WorkspaceBarStyle: Equatable {
    /// Glyph and label.
    case full
    /// Glyph alone; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The bar's width arithmetic, kept pure so the shedding rule can be asserted without laying out
/// a toolbar.
///
/// Computed, not `ViewThatFits`: that builds every rung on every layout pass, and a toolbar item is
/// proposed its own ideal width rather than the window's, so it would pick the full rung at every
/// size. Measuring the content width and doing the sum is cheaper and actually responds.
enum WorkspaceBarMetrics {

    /// The square every workspace glyph is drawn into, so the two constants below are exact.
    ///
    /// The symbols differ in size at `.system(size: 12, weight: .medium)`:
    ///
    /// | symbol | | glyph |
    /// |---|---|---|
    /// | `folder` | Browse | 16 × 13 |
    /// | `arrow.left.arrow.right` | Compare | 14 × 17 |
    /// | `folder.badge.gearshape` | Organize | 16 × 14 |
    /// | `square.and.pencil` | Editor | 15 × 15 |
    ///
    /// Unframed, the selected pill (a `Capsule` in a `matchedGeometryEffect`) would change height as
    /// it slides, nest concentrically for only some segments, and the width sum would under-measure
    /// the bar, the dangerous direction. 17 is the tallest glyph and a point clear of the widest, so
    /// it clips nothing and over-reserves slightly, the safe side.
    ///
    /// A symbol wider than this frame is clipped, not scaled, and nothing else would say so:
    /// measure a new workspace's glyph before choosing it. `theBarDrawsEverySegmentAtOneHeight`
    /// keeps the frame and this constant together.
    static let glyphSide: CGFloat = 17

    /// What a segment adds around its label: the glyph, the 6pt gap after it, and 2×12pt of
    /// horizontal padding.
    static let segmentChrome: CGFloat = glyphSide + 6 + 24
    /// A segment with no label — glyph plus 2×10pt padding, which is tighter than the labelled
    /// form because there is nothing for the padding to separate the glyph from.
    static let iconOnlySegmentWidth: CGFloat = glyphSide + 20
    /// Between segments, inside the container capsule.
    static let segmentGap: CGFloat = 4
    /// The container capsule's own inset, both edges.
    static let containerPadding: CGFloat = 6

    // No separator term: the bar is equal segments with no rule between groups, since Edit, the
    // one workspace that changes a file's contents, belongs to no group.

    /// Toolbar width the bar can never have: the traffic lights and their margin, the minimum gap
    /// before the trailing group, the utility pill (Settings, Activity Log, Info), and Ask Claude's
    /// button and its gap (44, a generous estimate). Generous on purpose: too cautious costs a
    /// label, too optimistic costs the whole control behind an overflow chevron.
    ///
    /// The ⌘K pill is not in here: its width depends on its own rung, so it is charged per rung in
    /// ``styles(contentWidth:labelWidths:searchLabelWidth:searchKeycapWidth:openField:)``.
    static let reservedChrome: CGFloat = 78 + 24 + 132 + 44

    /// Width of the bar with every label spelled out.
    ///
    /// - Parameters:
    ///   - labelWidths: each segment's rendered label width, in order. Measured, because the app
    ///     scales its own type (Settings ▸ Text size).
    static func fullWidth(labelWidths: [CGFloat]) -> CGFloat {
        guard !labelWidths.isEmpty else { return 0 }
        let segments = labelWidths.reduce(0) { $0 + $1 + segmentChrome }
        return segments + gapWidth(children: labelWidths.count) + containerPadding
    }

    /// The `HStack`'s spacing total, counted over its children. Today those are exactly the
    /// segments; counting the wrong number would under-measure the bar and claim labels fit when
    /// they do not.
    static func gapWidth(children: Int) -> CGFloat {
        CGFloat(max(0, children - 1)) * segmentGap
    }

    /// Width of the bar with every label shed.
    static func iconOnlyWidth(segmentCount: Int) -> CGFloat {
        guard segmentCount > 0 else { return 0 }
        let segments = CGFloat(segmentCount) * iconOnlySegmentWidth
        return segments + gapWidth(children: segmentCount) + containerPadding
    }

    /// What a window of this content width can seat: every control on the row, decided together.
    /// Given separate thresholds, each would size itself against width the other is spending, both
    /// would fit on paper, and the toolbar would overflow.
    ///
    /// The ladder, in priority order:
    ///
    /// 1. Both spelled out.
    /// 2. The pill drops its word; the magnifier and ⌘K key still say what it is.
    /// 3. The workspace bar drops its labels too. Last, because it is the primary navigation. There
    ///    is no rung dropping the ⌘K key; see ``CommandPaletteBarStyle``.
    ///
    /// The bar is all-or-nothing: a mix of words and glyphs would read as two different controls.
    ///
    /// With a run going, the progress capsule is on the row too. Its rungs come before the bar's
    /// labels: the full capsule while it fits, then the ring, then the labels go. The ring is never
    /// dropped: it carries the run's only stop button.
    static func styles(contentWidth: CGFloat, labelWidths: [CGFloat],
                       searchLabelWidth: CGFloat, searchKeycapWidth: CGFloat,
                       openField: OpenFieldRequest? = nil, runShowing: Bool = false) -> ToolbarBarStyles {
        let available = contentWidth - reservedChrome
        let bar = fullWidth(labelWidths: labelWidths)
        if let request = openField {
            // The open field takes the spare, so the capsule takes its ring and nothing more.
            return openStyles(available: available - (runShowing ? capsuleWidth(.ring) : 0),
                              bar: bar, labelWidths: labelWidths, request: request,
                              run: runShowing ? .ring : nil)
        }
        let searchFull = CommandPaletteBarMetrics.width(style: .full, labelWidth: searchLabelWidth,
                                                        keycapWidth: searchKeycapWidth)
        let searchCompact = CommandPaletteBarMetrics.width(style: .compact, labelWidth: searchLabelWidth,
                                                           keycapWidth: searchKeycapWidth)
        guard runShowing else {
            if bar + searchFull <= available { return ToolbarBarStyles(workspace: .full, search: .full) }
            if bar + searchCompact <= available { return ToolbarBarStyles(workspace: .full, search: .compact) }
            return ToolbarBarStyles(workspace: .iconOnly, search: .compact)
        }
        let full = capsuleWidth(.full), ring = capsuleWidth(.ring)
        if bar + searchFull + full <= available {
            return ToolbarBarStyles(workspace: .full, search: .full, run: .full)
        }
        if bar + searchCompact + full <= available {
            return ToolbarBarStyles(workspace: .full, search: .compact, run: .full)
        }
        if bar + searchCompact + ring <= available {
            return ToolbarBarStyles(workspace: .full, search: .compact, run: .ring)
        }
        return ToolbarBarStyles(workspace: .iconOnly, search: .compact, run: .ring)
    }

    /// What the capsule costs the row: its fixed frame plus the toolbar's spacing around an item.
    /// Generous for the reason ``reservedChrome`` is: measured on a probe window of this toolbar's
    /// shape, a principal item `w` wide costs about `w − 30`, so `w + 16` over-reserves. On
    /// overflow AppKit folds the trailing items, so an under-charge would hide Settings and Info.
    static func capsuleWidth(_ style: ProgressCapsuleStyle) -> CGFloat {
        let item: CGFloat = 16
        switch style {
        case .full: return ProgressCapsuleMetrics.fullWidth + item
        case .ring: return ProgressCapsuleMetrics.ringWidth + item
        }
    }

    /// Every answer, resolved and cached together: field open and closed, with and without a run.
    /// The field opens on a keystroke and a run starts on a click, not on a resize, so an answer
    /// derived in a resize-only geometry callback would describe the state of a moment ago. The
    /// caller stores this value, which changes only when an answer does, not on every pixel of a
    /// drag.
    static func styleSet(contentWidth: CGFloat, labelWidths: [CGFloat],
                         searchLabelWidth: CGFloat, searchKeycapWidth: CGFloat,
                         fieldKeycapWidth: CGFloat, scale: CGFloat) -> ToolbarBarStyleSet {
        func resolve(open: Bool, run: Bool) -> ToolbarBarStyles {
            styles(contentWidth: contentWidth, labelWidths: labelWidths,
                   searchLabelWidth: searchLabelWidth, searchKeycapWidth: searchKeycapWidth,
                   openField: open ? OpenFieldRequest(keycapWidth: fieldKeycapWidth, scale: scale) : nil,
                   runShowing: run)
        }
        return ToolbarBarStyleSet(closed: resolve(open: false, run: false),
                                  open: resolve(open: true, run: false),
                                  closedWithRun: resolve(open: false, run: true),
                                  openWithRun: resolve(open: true, run: true))
    }

    /// The open field's share of the row. The field takes the spare; the labels shed only when that
    /// leaves it under its floor.
    ///
    /// Not a rung on the ladder above, because the priority inverts while the field is open: it is
    /// the control being used, so the bar sheds for it, and only as far as it must. Wide windows
    /// reach the field's ceiling with the labels untouched, and narrow ones are icon-only at rest,
    /// so labels move on open only in the band between.
    private static func openStyles(available: CGFloat, bar: CGFloat, labelWidths: [CGFloat],
                                   request: OpenFieldRequest,
                                   run: ProgressCapsuleStyle? = nil) -> ToolbarBarStyles {
        func layout(spare: CGFloat) -> GoToFieldLayout {
            // Clamped at zero, not given a fallback width: a field drawn wider than its share
            // would push the row into the overflow chevron.
            let width = min(max(spare, 0), request.ceiling)
            return GoToFieldLayout(width: width,
                                   placeholder: GoToFieldMetrics.placeholder(
                                       forWidth: width, keycapWidth: request.keycapWidth,
                                       scale: request.scale))
        }
        let spareWithLabels = available - bar
        if spareWithLabels >= request.floor {
            return ToolbarBarStyles(workspace: .full, search: .compact,
                                    field: layout(spare: spareWithLabels), run: run)
        }
        // Shedding buys the difference between the two bar widths. Below the floor even then, the
        // field opens as wide as it can and the short placeholder absorbs the rest.
        let shed = available - iconOnlyWidth(segmentCount: labelWidths.count)
        return ToolbarBarStyles(workspace: .iconOnly, search: .compact, field: layout(spare: shed), run: run)
    }
}

/// What the toolbar's two width-sensitive controls are showing right now.
///
/// One value, resolved in one place, so controls sharing the row cannot disagree about how much
/// room there is.
struct ToolbarBarStyles: Equatable {
    var workspace: WorkspaceBarStyle
    var search: CommandPaletteBarStyle
    /// The open Go-to field's share of the row, or `nil` when it is closed and the pill is drawn.
    /// Resolved here because it spends the same width as the others.
    var field: GoToFieldLayout?
    /// The progress capsule's rung while a run is going, `nil` otherwise — charged on the same row.
    var run: ProgressCapsuleStyle?

    init(workspace: WorkspaceBarStyle, search: CommandPaletteBarStyle,
         field: GoToFieldLayout? = nil, run: ProgressCapsuleStyle? = nil) {
        self.workspace = workspace
        self.search = search
        self.field = field
        self.run = run
    }
}

/// The row in both of its states — what it draws with the Go-to control closed, and what it draws
/// with the field open. One value so the two cannot be resolved from different widths.
struct ToolbarBarStyleSet: Equatable {
    var closed: ToolbarBarStyles
    var open: ToolbarBarStyles
    /// The same two with the progress capsule on the row.
    var closedWithRun: ToolbarBarStyles
    var openWithRun: ToolbarBarStyles

    init(closed: ToolbarBarStyles, open: ToolbarBarStyles,
         closedWithRun: ToolbarBarStyles? = nil, openWithRun: ToolbarBarStyles? = nil) {
        self.closed = closed
        self.open = open
        self.closedWithRun = closedWithRun ?? ToolbarBarStyles(workspace: .iconOnly, search: .compact, run: .ring)
        self.openWithRun = openWithRun ?? ToolbarBarStyles(workspace: .iconOnly, search: .compact,
                                                           field: open.field, run: .ring)
    }

    /// The row the toolbar wears for this state.
    ///
    /// A message wears the run's row: the full capsule wherever a run's would be full, shedding
    /// ⌘K's word and then the workspace names for it. So a run's ending keeps the capsule exactly
    /// as the run left it, instead of shrinking to a bare ✓.
    func resolved(fieldOpen: Bool, runShowing: Bool, messageShowing: Bool = false) -> ToolbarBarStyles {
        guard runShowing || messageShowing else { return fieldOpen ? open : closed }
        return fieldOpen ? openWithRun : closedWithRun
    }
}

/// What the open field needs the row to know about it: its own floor and ceiling, and the two
/// measurements that decide its placeholder. Passed in rather than read, so the arithmetic stays
/// pure and a test can put the field at any width without a toolbar.
struct OpenFieldRequest: Equatable {
    var floor: CGFloat = GoToFieldMetrics.floorWidth
    var ceiling: CGFloat = GoToFieldMetrics.ceilingWidth
    /// The ⌘K/esc keycap's measured width — the field keeps a key at its trailing end.
    var keycapWidth: CGFloat
    /// Settings ▸ Text size, so the placeholder rung is decided at the size it will be drawn.
    var scale: CGFloat
}
