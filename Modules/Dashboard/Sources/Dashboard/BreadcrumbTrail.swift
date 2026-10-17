import Foundation

/// Pure model behind the per-pane breadcrumb in `PaneHeader`: splits a relative path into
/// clickable crumbs and folds the middle of deep paths into an ellipsis menu.
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

    /// **The compact trail: every folder above the current one behind the ellipsis, the current one
    /// spelled out** — what a pane too narrow for its whole trail shows (asked 2026-10-17, of Edit's
    /// one-column pane, where the full trail came out as "C…6 › 2…0"). The name you are in is the
    /// one worth reading; the rest are a click away in the menu, in order.
    public static func compactItems(for crumbs: [Crumb]) -> [Item] {
        guard let last = crumbs.last else { return [] }
        return crumbs.count == 1 ? [.crumb(last)] : [.collapsed(Array(crumbs.dropLast())), .crumb(last)]
    }

    /// Display name for a pane's root crumb: **the source's own name** — "iCloud", "OneDrive
    /// (EMP)", whatever the user renamed it to — falling back to the root folder's last component,
    /// and to `"Root"` for a path with no usable component.
    ///
    /// Naming the crumb after the folder was right only while a source *was* a folder. Once roots
    /// widened to the account itself, the last component became `OneDrive-AcmeCorporationWorldwide`
    /// — an id, not a name — and before that it was `Documents` for every source on the machine,
    /// so the one crumb that identifies which cloud you are looking at said the same word in every
    /// pane. The source's display name is the thing the user recognises, it is what the source
    /// picker and the tab strip already call it, and it honours a rename.
    ///
    /// The fallback is not dead code: `PaneBreadcrumb.providerName` is optional for callers that
    /// have no source in hand, and an unresolved source must still produce a crumb.
    public static func rootDisplayName(forRootPath rootPath: String, providerName: String? = nil) -> String {
        if let providerName, !providerName.isEmpty { return providerName }
        let name = rootPath.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "Root" : name
    }
}
