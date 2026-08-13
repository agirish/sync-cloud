import AppKit
import SwiftUI

/// How tightly the long lists (the Differences table, Duplicates group cards, Filing suggestions)
/// pack their rows (backlog H7). Comfortable is the app's unchanged default look; Compact is
/// the power user's opt-in for scanning 1,000+ rows. Stored in UserDefaults via
/// `ListDensity.defaultsKey`, mirroring the other appearance options in `LiquidGlass`.
public enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    /// UserDefaults key for the selected density (raw value of `ListDensity`). Read via
    /// `@AppStorage` by the Settings Appearance tab and every list view that honors it —
    /// one shared constant so the setting has a single source of truth.
    public static let defaultsKey = "listDensity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// The concrete row measurements for this density. Comfortable's values ARE the app's
    /// pre-H7 constants — comfortable must render pixel-identical to the look before the
    /// setting existed (pinned by `ListDensityTests`).
    public var metrics: ListDensityMetrics {
        switch self {
        case .comfortable:
            return ListDensityMetrics(
                cardHeaderVerticalPadding: 12,
                cardRowVerticalPadding: 11,
                cardListSpacing: 10,
                cardListPadding: 12,
                tableMinRowHeight: nil,
                showsSecondaryDetail: true,
                flatRowVerticalPadding: 6,
                treeIconSize: 17,
                logListSpacing: 6
            )
        case .compact:
            return ListDensityMetrics(
                cardHeaderVerticalPadding: 7,
                cardRowVerticalPadding: 6,
                cardListSpacing: 6,
                cardListPadding: 8,
                tableMinRowHeight: 20,
                showsSecondaryDetail: false,
                flatRowVerticalPadding: 2,
                treeIconSize: 14,
                logListSpacing: 2
            )
        }
    }
}

/// Pure row measurements per density — a small testable type so the numbers live in one
/// place instead of scattered across view literals.
public struct ListDensityMetrics: Equatable, Sendable {
    /// Vertical padding of a card's always-visible header row (Duplicates group header).
    public let cardHeaderVerticalPadding: CGFloat
    /// Vertical padding of a row inside an expanded card (a duplicate copy row).
    public let cardRowVerticalPadding: CGFloat
    /// Spacing between cards in a card list (Duplicates groups, Filing suggestions).
    public let cardListSpacing: CGFloat
    /// Outer padding around a card list.
    public let cardListPadding: CGFloat
    /// Minimum row height override for `Table`s; nil leaves the system default untouched
    /// (comfortable must not alter the current table look).
    public let tableMinRowHeight: CGFloat?
    /// Whether rows show their secondary size/date detail line; compact hides it.
    public let showsSecondaryDetail: Bool
    /// Vertical padding of a flat list row (file rows, log rows, history rows).
    public let flatRowVerticalPadding: CGFloat
    /// Side of a file row's square icon frame.
    public let treeIconSize: CGFloat
    /// `LazyVStack` spacing in the log-style windows (Activity Log, Sync History).
    public let logListSpacing: CGFloat
}

public extension ListDensity {
    /// A pinned table row height adjusted for the app's text size.
    ///
    /// Only compact ever passes a non-nil `base`. Comfortable pins nothing, and a SwiftUI
    /// `Table` left on `usesAutomaticRowHeights` measures its cells and grows on its own
    /// (verified: rows went 24pt → 28pt when the cell font went 11pt → 17pt). Compact turns that
    /// off to pin 20pt, so without this the larger text sizes would simply be clipped.
    ///
    /// The scale is clamped to `max(1, …)` — grow only, never shrink. This is a *text size*
    /// setting, not a second density control: packing rows tighter is what compact already does,
    /// and shrinking the pinned height further risks clipping the row content that is not text
    /// (the icons keep their own size).
    static func tableRowHeight(_ base: CGFloat?, fontScale: CGFloat) -> CGFloat? {
        base.map { $0 * max(1, fontScale) }
    }
}

public extension View {
    /// Applies a density to a `Table`/`List` subtree. Comfortable restores the default look;
    /// compact tightens the rows.
    ///
    /// A SwiftUI `Table` ignores every environment lever on macOS — `defaultMinListRowHeight`,
    /// `controlSize`, and even the ambient font never reach its NSTableView or its hosted
    /// cells (verified empirically against the Compare differences table; the original H7
    /// row-minimum approach rendered pixel-identical rows). So compact reaches beneath the
    /// Table and pins the AppKit `rowHeight` directly via `TableDensityApplier`; the
    /// environment minimum is still set for any plain `List` under the same modifier. Cell
    /// fonts don't inherit either — table cells opt in per-view (see `DifferenceNameCell`).
    ///
    /// The structure is deliberately STABLE across densities — no `@ViewBuilder` branch.
    /// A branch would make density toggles swap `_ConditionalContent` sides, recreating the
    /// Table AND the applier, so the applier's captured originals (its restore path) would
    /// never survive to run; with a stable structure the same applier — and the SAME
    /// NSTableView — persists across toggles and is restored in place. `transformEnvironment`
    /// leaves the value untouched when there is no override, so comfortable stays
    /// pixel-identical to the pre-density look.
    func listDensity(_ density: ListDensity) -> some View {
        modifier(ListDensityModifier(density: density))
    }
}

/// Carries `listDensity(_:)`'s body so it can read the ambient `appFontScale`.
///
/// A `ViewModifier` (not a `@ViewBuilder` branch) keeps the structure stable across both density
/// AND text-size changes, which the applier's restore path depends on — see `listDensity(_:)`.
private struct ListDensityModifier: ViewModifier {
    @Environment(\.appFontScale) private var fontScale
    let density: ListDensity

    func body(content: Content) -> some View {
        let minRowHeight = ListDensity.tableRowHeight(density.metrics.tableMinRowHeight,
                                                      fontScale: fontScale)
        return content
            .transformEnvironment(\.defaultMinListRowHeight) { value in
                if let minRowHeight { value = minRowHeight }
            }
            .background(TableDensityApplier(rowHeight: minRowHeight))
    }
}
