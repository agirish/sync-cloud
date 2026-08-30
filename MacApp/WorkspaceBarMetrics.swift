import Foundation
import CoreGraphics
import FileExplorer

/// Whether the workspace bar can afford to spell its segments out.
///
/// Six labelled segments are about 500pt — the bar carries four now, and gained one when Browse
/// shipped, which moved the icon-only rung to a wider window than before rather than changing any
/// of this arithmetic. The toolbar also has to seat the traffic lights and the trailing utility
/// pill. Measured through `styles`, the four labels need 720pt of content width beside a compact
/// ⌘K pill at the default text size (Small 701, Large 767, Largest 785) — which is why the
/// window's floor was raised from 600 to 760 rather than this rung being loosened: at 600 the bar
/// was icon-only at every text size the moment the window sat at its minimum. A
/// toolbar that does not fit does not wrap or truncate — macOS silently folds the overflow behind
/// a chevron, which is how the *only* control for switching workspace disappears. The two-level
/// picker avoided this by keeping the lens tabs out of the toolbar entirely; a flat bar cannot.
enum WorkspaceBarStyle: Equatable {
    /// Glyph and label.
    case full
    /// Glyph alone; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The bar's width arithmetic, kept pure so the shedding rule can be asserted without laying out
/// a toolbar.
///
/// **Computed, not laddered.** The obvious SwiftUI answer is `ViewThatFits` over a full rung and
/// an icon-only rung, and that is wrong twice over here. It builds every rung on every layout
/// pass — the pane bar's ten-rung ladder cost 831ms a click for exactly that reason (`772b6ca`
/// replaced it with arithmetic) — and, worse, a toolbar item is proposed its own ideal width
/// rather than the window's, so `ViewThatFits` would never see the constraint and would pick the
/// full rung at every size. Measuring the content width and doing the sum is both cheaper and the
/// only version that actually responds.
enum WorkspaceBarMetrics {

    /// The square every workspace glyph is drawn into, and the reason the two constants below are
    /// true rather than approximately true.
    ///
    /// **The four symbols are four different sizes, which is not visible from any padding literal.**
    /// Measured at `.system(size: 12, weight: .medium)`, laid out exactly as `workspaceSegment`
    /// composes them:
    ///
    /// | symbol | | glyph |
    /// |---|---|---|
    /// | `folder` | Browse | 16 × 13 |
    /// | `arrow.left.arrow.right` | Compare | 14 × 17 |
    /// | `folder.badge.gearshape` | Organize | 16 × 14 |
    /// | `chart.pie` | Storage | 15 × 15 |
    ///
    /// Three things followed from that, and all three go away by framing:
    ///
    /// - **The selected pill changed height as it travelled.** The marker is a `Capsule` sized to
    ///   its own segment inside a `matchedGeometryEffect`, so a selection moving between Compare
    ///   (25pt) and anything else (23pt) interpolated between two frames and the pill grew or shrank
    ///   mid-slide. Icon-only was worse — the four came out 21, 25, 22 and 23.
    /// - **It nested concentrically for exactly one workspace.** A capsule in a capsule is
    ///   concentric only at a uniform inset; the horizontal one is `containerPadding / 2` = 3, while
    ///   the vertical one was whatever the segment's height left — 4pt for three of the four.
    /// - **The width arithmetic under-measured the drawn bar by 5pt**, both rungs, by assuming 14
    ///   everywhere against real widths of 16, 14, 16 and 15. That is the dangerous direction: it
    ///   claims the labels fit when they do not, and an overflowing toolbar folds behind a chevron
    ///   rather than truncating — see this file's header for why that is the failure worth being
    ///   generous about.
    ///
    /// **17 is the tallest glyph, and one point clear of the widest.** `arrow.left.arrow.right`
    /// sets the height at 17; the widest are `folder` and `folder.badge.gearshape` at 16. So a
    /// square 17 clips nothing and over-reserves width by a point per segment — the safe direction
    /// by this file's own rule, and a point of room for a fifth workspace's glyph. A 16×17 frame
    /// would be the exact maxima and save 4pt across the bar; it was not taken because it spends
    /// the headroom to buy 4pt that changes no threshold.
    ///
    /// It leaves the bar's height exactly where it was — Compare had already forced 25pt segments
    /// and a 31pt bar — so this changes no other row in the toolbar.
    ///
    /// **The drawn bar grows 5pt and the computed width grows 12.** Both are real and they are not
    /// the same number: correcting the constant recovers the 5pt the sum was missing, and framing
    /// pads the three narrower glyphs out to 17 on top of that. The thresholds in this file's
    /// header moved by the 12.
    ///
    /// `theBarDrawsEverySegmentAtOneHeight` is what keeps the frame and this constant together.
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
    /// The rule that separates the tree-lookers (Browse, Compare) from the tree-actors (Organize,
    /// Storage): a 1pt `Divider` inside 2×4pt of horizontal padding. Its `segmentGap` on either
    /// side is NOT in here — it is a child of the same `HStack`, so it is counted by the gap term
    /// below like any other child.
    ///
    /// WHERE it is drawn is not this type's business and cannot be checked from here: this only
    /// ever learns how MANY there are. See `ContentView.workspaceRuleIndex`.
    static let separatorWidth: CGFloat = 1 + 8

    /// Toolbar width the bar can never have: the traffic lights and their margin, the minimum gap
    /// before the trailing group, and the utility pill (Settings, Logs, Info). Deliberately
    /// generous — being one segment too cautious costs a label, being one too optimistic costs the
    /// entire control behind an overflow chevron.
    ///
    /// **The ⌘K search pill is NOT in here**, and that is deliberate rather than an omission: its
    /// width depends on which rung *it* is showing, so charging it as a constant would mean either
    /// over-reserving whenever it is compact or under-reserving whenever it is full. It is charged
    /// per-rung in ``styles(contentWidth:labelWidths:searchLabelWidth:searchKeycapWidth:separators:)``,
    /// which is the one place the two controls' widths are added together.
    static let reservedChrome: CGFloat = 78 + 24 + 132

    /// Width of the bar with every label spelled out.
    ///
    /// - Parameters:
    ///   - labelWidths: each segment's rendered label width, in order. Measured rather than
    ///     estimated because the app scales its own type (Settings ▸ Text size), so a constant
    ///     here would be right at exactly one setting.
    ///   - separators: how many group separators the bar draws.
    static func fullWidth(labelWidths: [CGFloat], separators: Int = 1) -> CGFloat {
        guard !labelWidths.isEmpty else { return 0 }
        let segments = labelWidths.reduce(0) { $0 + $1 + segmentChrome }
        return segments + gapWidth(children: labelWidths.count + separators)
            + CGFloat(separators) * separatorWidth + containerPadding
    }

    /// The `HStack`'s spacing total. Counted over CHILDREN, not segments: each separator is a
    /// child too, so a bar of five segments and one rule has six children and five gaps — not
    /// four. Getting this wrong under-measures the bar, which is the dangerous direction: it
    /// claims the labels fit when they are a couple of points too wide to.
    static func gapWidth(children: Int) -> CGFloat {
        CGFloat(max(0, children - 1)) * segmentGap
    }

    /// Width of the bar with every label shed.
    static func iconOnlyWidth(segmentCount: Int, separators: Int = 1) -> CGFloat {
        guard segmentCount > 0 else { return 0 }
        let segments = CGFloat(segmentCount) * iconOnlySegmentWidth
        return segments + gapWidth(children: segmentCount + separators)
            + CGFloat(separators) * separatorWidth + containerPadding
    }

    /// What a window of this content width can seat — **both toolbar controls, decided together.**
    ///
    /// One function rather than two, because they compete for one row. The search pill was added
    /// after this arithmetic existed, and the tempting shape — leave `style` alone and give the
    /// pill its own threshold — is the one that breaks: each control would size itself against a
    /// width the other is also spending, both would conclude they fit, and the toolbar would go
    /// behind the overflow chevron with two green tests. Whatever is on this row is added up here.
    ///
    /// The ladder, in order, and the order is the priority:
    ///
    /// 1. **Both spelled out.**
    /// 2. **The pill drops its word.** The magnifier and the ⌘K key still say what it is and how to
    ///    open it, so the word is the cheapest thing on the row.
    /// 3. **The workspace bar drops its labels too.** Last, because it is the primary navigation:
    ///    shedding the words a user navigates by while keeping a decorative one beside them would
    ///    be backwards. There is deliberately no fourth rung dropping the ⌘K key — see
    ///    ``CommandPaletteBarStyle``.
    ///
    /// The workspace bar stays all-or-nothing within its own rung: shedding labels one segment at a
    /// time would leave a bar where some workspaces are words and others are glyphs, which reads as
    /// two different controls rather than one row of peers.
    static func styles(contentWidth: CGFloat, labelWidths: [CGFloat],
                       searchLabelWidth: CGFloat, searchKeycapWidth: CGFloat,
                       separators: Int = 1,
                       openField: OpenFieldRequest? = nil) -> ToolbarBarStyles {
        let available = contentWidth - reservedChrome
        let bar = fullWidth(labelWidths: labelWidths, separators: separators)
        if let request = openField {
            return openStyles(available: available, bar: bar, labelWidths: labelWidths,
                              separators: separators, request: request)
        }
        let searchFull = CommandPaletteBarMetrics.width(style: .full, labelWidth: searchLabelWidth,
                                                        keycapWidth: searchKeycapWidth)
        let searchCompact = CommandPaletteBarMetrics.width(style: .compact, labelWidth: searchLabelWidth,
                                                           keycapWidth: searchKeycapWidth)
        if bar + searchFull <= available { return ToolbarBarStyles(workspace: .full, search: .full) }
        if bar + searchCompact <= available { return ToolbarBarStyles(workspace: .full, search: .compact) }
        return ToolbarBarStyles(workspace: .iconOnly, search: .compact)
    }

    /// **Both answers, resolved together and cached together.** The row has to know what it looks
    /// like with the field open AND with it closed, because the field opens on a keystroke rather
    /// than on a resize — and re-deriving one of them inside a geometry callback that only fires on
    /// resize is how the toolbar comes to be laid out for the state it was in a moment ago.
    ///
    /// Resolving both here also keeps the state write coarse: the caller stores this value, and it
    /// changes only when one of the two answers does, not on every pixel of a window drag.
    static func styleSet(contentWidth: CGFloat, labelWidths: [CGFloat],
                         searchLabelWidth: CGFloat, searchKeycapWidth: CGFloat,
                         fieldKeycapWidth: CGFloat, scale: CGFloat,
                         separators: Int = 1) -> ToolbarBarStyleSet {
        ToolbarBarStyleSet(
            closed: styles(contentWidth: contentWidth, labelWidths: labelWidths,
                           searchLabelWidth: searchLabelWidth, searchKeycapWidth: searchKeycapWidth,
                           separators: separators),
            open: styles(contentWidth: contentWidth, labelWidths: labelWidths,
                         searchLabelWidth: searchLabelWidth, searchKeycapWidth: searchKeycapWidth,
                         separators: separators,
                         openField: OpenFieldRequest(keycapWidth: fieldKeycapWidth, scale: scale)))
    }

    /// The open field's share of the row. **The field takes the spare; the labels shed only when
    /// that leaves it under its floor.**
    ///
    /// Not a fourth rung on the ladder above, because the priority inverts while the field is open:
    /// closed, the pill's word is the cheapest thing on the row and the workspace labels are the
    /// last to go; open, the field is the control being *used*, and a user typing a folder name
    /// into 200pt while four labels sit beside them would be watching the row spend its width on
    /// the wrong control. So the bar sheds *for* the field — and only as far as it must, which is
    /// why this asks the labelled bar first and re-asks with glyphs rather than starting there.
    ///
    /// The result is a shed-on-open band and not a general rule: above roughly 950pt of content
    /// width the field reaches its ceiling with the labels untouched, and below roughly 710 the bar
    /// is already icon-only at rest, so nothing appears to move at either end.
    private static func openStyles(available: CGFloat, bar: CGFloat, labelWidths: [CGFloat],
                                   separators: Int, request: OpenFieldRequest) -> ToolbarBarStyles {
        func layout(spare: CGFloat) -> GoToFieldLayout {
            // `max(0,)` rather than a fallback width: a negative spare means the row cannot seat
            // the field at all, and a field drawn wider than its share is the overflow chevron.
            let width = min(max(spare, 0), request.ceiling)
            return GoToFieldLayout(width: width,
                                   placeholder: GoToFieldMetrics.placeholder(
                                       forWidth: width, keycapWidth: request.keycapWidth,
                                       scale: request.scale))
        }
        let spareWithLabels = available - bar
        if spareWithLabels >= request.floor {
            return ToolbarBarStyles(workspace: .full, search: .compact,
                                    field: layout(spare: spareWithLabels))
        }
        // Shedding buys the difference between the two bar widths. Below the floor even then, the
        // field opens as wide as it can — §7's narrow case, where the short placeholder is what
        // absorbs the rest.
        let shed = available - iconOnlyWidth(segmentCount: labelWidths.count, separators: separators)
        return ToolbarBarStyles(workspace: .iconOnly, search: .compact, field: layout(spare: shed))
    }
}

/// What the toolbar's two width-sensitive controls are showing right now.
///
/// One value, resolved in one place, for the reason `FilteredRows` is one value: two controls
/// sizing themselves against the same row from two separate decisions is how they come to disagree
/// about how much room there is.
struct ToolbarBarStyles: Equatable {
    var workspace: WorkspaceBarStyle
    var search: CommandPaletteBarStyle
    /// The open Go-to field's share of the row, or `nil` when the field is closed and the pill is
    /// what the toolbar draws. Resolved here rather than by the field, for the same reason the
    /// other two are: it is spending the same width they are.
    var field: GoToFieldLayout?

    init(workspace: WorkspaceBarStyle, search: CommandPaletteBarStyle,
         field: GoToFieldLayout? = nil) {
        self.workspace = workspace
        self.search = search
        self.field = field
    }
}

/// The row in both of its states — what it draws with the Go-to control closed, and what it draws
/// with the field open. One value so the two cannot be resolved from different widths.
struct ToolbarBarStyleSet: Equatable {
    var closed: ToolbarBarStyles
    var open: ToolbarBarStyles
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
