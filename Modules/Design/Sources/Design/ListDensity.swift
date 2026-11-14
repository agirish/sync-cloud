import AppKit
import SwiftUI

/// How tightly the long lists (the Differences table, Duplicates group cards, Filing suggestions)
/// pack their rows. Comfortable is the default look; Compact is the opt-in for scanning 1,000+
/// rows. Stored under `ListDensity.defaultsKey`, like the other appearance options in
/// `LiquidGlass`.
public enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    /// UserDefaults key for the selected density (a raw value), read via `@AppStorage` by Settings'
    /// Appearance tab and every list view that honours it.
    public static let defaultsKey = "listDensity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// The row measurements for this density. Comfortable's values are the app's original
    /// constants, so it renders pixel-identical to the look before the setting existed
    /// (`ListDensityTests`).
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

/// Row measurements per density, in one small testable type instead of scattered view literals.
public struct ListDensityMetrics: Equatable, Sendable {
    /// Vertical padding of a card's always-visible header row (Duplicates group header).
    public let cardHeaderVerticalPadding: CGFloat
    /// Vertical padding of a row inside an expanded card (a duplicate copy row).
    public let cardRowVerticalPadding: CGFloat
    /// Spacing between cards in a card list (Duplicates groups, Filing suggestions).
    public let cardListSpacing: CGFloat
    /// Outer padding around a card list.
    public let cardListPadding: CGFloat
    /// Minimum row height override for `Table`s; nil leaves the system default untouched, so
    /// comfortable doesn't alter the table look.
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
    /// Only compact passes a non-nil `base`. Comfortable pins nothing, and a `Table` left on
    /// `usesAutomaticRowHeights` grows with its cell font on its own; compact pins 20pt, so without
    /// this the larger text sizes would be clipped. Grow only (`max(1, …)`): this is a text-size
    /// setting, not a second density control, and shrinking further would clip the icons, which
    /// keep their own size.
    static func tableRowHeight(_ base: CGFloat?, fontScale: CGFloat) -> CGFloat? {
        base.map { $0 * max(1, fontScale) }
    }
}

public extension View {
    /// Applies a density to a `Table`/`List` subtree. Comfortable restores the default look;
    /// compact tightens the rows.
    ///
    /// A SwiftUI `Table` ignores every environment lever on macOS: `defaultMinListRowHeight`,
    /// `controlSize` and even the ambient font never reach its NSTableView or its cells. So compact
    /// pins the AppKit `rowHeight` directly via `TableDensityApplier`; the environment minimum
    /// still serves a plain `List`. Cell fonts don't inherit either; table cells opt in per view
    /// (see `DifferenceNameCell`).
    ///
    /// The structure stays the same across densities, with no `@ViewBuilder` branch: a branch would
    /// recreate the Table and the applier on every toggle, so the applier's saved originals would
    /// never be restored. `transformEnvironment` leaves the value alone when there is no override,
    /// so comfortable stays pixel-identical to the default look.
    func listDensity(_ density: ListDensity) -> some View {
        modifier(ListDensityModifier(density: density))
    }
}

/// Carries `listDensity(_:)`'s body so it can read the ambient `appFontScale`.
///
/// A `ViewModifier`, not a `@ViewBuilder` branch, so the structure stays stable across density and
/// text-size changes, which the applier's restore path depends on (see `listDensity(_:)`).
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
