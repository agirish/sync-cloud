import Foundation

/// Pure model behind the breadcrumb bar in `NavigationToolbar`: splits the focused relative
/// path into clickable crumbs and folds the middle of deep paths into an ellipsis menu.
public enum BreadcrumbTrail {

    /// One ancestor level: display name plus the relative path to re-focus on when clicked.
    public struct Crumb: Equatable, Identifiable {
        public let name: String
        public let relativePath: String
        public var id: String { relativePath }

        public init(name: String, relativePath: String) {
            self.name = name
            self.relativePath = relativePath
        }
    }

    /// One rendered element of the bar: a visible crumb, or the collapsed middle crumbs
    /// (shown as an ellipsis menu).
    public enum Item: Equatable {
        case crumb(Crumb)
        case collapsed([Crumb])
    }

    /// Deepest trail rendered without collapsing; longer trails keep the first crumb and the
    /// last two, folding the rest behind an ellipsis.
    public static let maxVisibleCrumbs = 4

    /// Splits `"Documents/Projects/App"` into crumbs whose relative paths accumulate
    /// (`"Documents"`, `"Documents/Projects"`, …). Empty components (doubled or trailing
    /// slashes) are dropped, so the resulting paths are normalized.
    public static func crumbs(forRelativePath path: String) -> [Crumb] {
        var result: [Crumb] = []
        for component in path.split(separator: "/") {
            let prefix = result.last.map { $0.relativePath + "/" } ?? ""
            result.append(Crumb(name: String(component), relativePath: prefix + component))
        }
        return result
    }

    /// Collapses deep trails to: first crumb, ellipsis menu of the middle, last two crumbs.
    public static func displayItems(for crumbs: [Crumb], maxVisible: Int = maxVisibleCrumbs) -> [Item] {
        // Below 4 crumbs there is no "middle" between the first and the last two.
        guard crumbs.count > max(maxVisible, 3) else {
            return crumbs.map(Item.crumb)
        }
        return [
            .crumb(crumbs[0]),
            .collapsed(Array(crumbs[1..<(crumbs.count - 2)])),
            .crumb(crumbs[crumbs.count - 2]),
            .crumb(crumbs[crumbs.count - 1]),
        ]
    }

    /// Which pane's focused path the bar shows: the left one, falling back to the right
    /// (same precedence the old "Focusing on:" label used). Nil when both panes are at root.
    public static func displayedFocus(leftRelativePath: String, rightRelativePath: String) -> (relativePath: String, isLeft: Bool)? {
        if !leftRelativePath.isEmpty { return (leftRelativePath, true) }
        if !rightRelativePath.isEmpty { return (rightRelativePath, false) }
        return nil
    }
}
