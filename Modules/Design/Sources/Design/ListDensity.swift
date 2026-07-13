import SwiftUI

/// How tightly the long lists (the Differences table, Tidy group cards, Filing suggestions)
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
                showsSecondaryDetail: true
            )
        case .compact:
            return ListDensityMetrics(
                cardHeaderVerticalPadding: 7,
                cardRowVerticalPadding: 6,
                cardListSpacing: 6,
                cardListPadding: 8,
                tableMinRowHeight: 20,
                showsSecondaryDetail: false
            )
        }
    }
}

/// Pure row measurements per density — a small testable type so the numbers live in one
/// place instead of scattered across view literals.
public struct ListDensityMetrics: Equatable, Sendable {
    /// Vertical padding of a card's always-visible header row (Tidy group header).
    public let cardHeaderVerticalPadding: CGFloat
    /// Vertical padding of a row inside an expanded card (a duplicate copy row).
    public let cardRowVerticalPadding: CGFloat
    /// Spacing between cards in a card list (Tidy groups, Filing suggestions).
    public let cardListSpacing: CGFloat
    /// Outer padding around a card list.
    public let cardListPadding: CGFloat
    /// Minimum row height override for `Table`s; nil leaves the system default untouched
    /// (comfortable must not alter the current table look).
    public let tableMinRowHeight: CGFloat?
    /// Whether rows show their secondary size/date detail line; compact hides it.
    public let showsSecondaryDetail: Bool
}

public extension View {
    /// Applies a density to a `Table`/`List` subtree. Comfortable is the identity — the
    /// current look, untouched by construction; compact lowers the minimum row height.
    @ViewBuilder
    func listDensity(_ density: ListDensity) -> some View {
        if let minRowHeight = density.metrics.tableMinRowHeight {
            self.environment(\.defaultMinListRowHeight, minRowHeight)
        } else {
            self
        }
    }
}
