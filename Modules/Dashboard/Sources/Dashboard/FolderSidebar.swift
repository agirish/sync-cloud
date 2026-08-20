import SwiftUI
import AppKit
import Design

/// One row of the Browse sidebar: a remembered folder, under the heading that remembered it.
public struct FolderSidebarRow: Identifiable, Equatable, Sendable {

    /// Why this folder is listed. The two lists are `FolderJumpStore`'s, unchanged — pins are
    /// curated, recents are the last eight places visited under this root.
    public enum Group: String, Sendable, CaseIterable {
        case pinned = "Pinned"
        case recents = "Recents"
    }

    public let group: Group
    /// The path relative to the pane's provider root — what the pane is navigated to.
    public let relativePath: String
    /// The folder's own name, which is what the row reads.
    public let name: String
    /// The folders above it, shown **only when another row on screen has the same name**.
    ///
    /// Two `Legal` folders under different clients is the case that matters, and it is the one the
    /// ⌘K palette had to be rebuilt twice to be able to see: a sidebar that lists them both as
    /// "Legal" offers two rows that are indistinguishable and one of them goes to the wrong place.
    /// Always showing the parent would be the other failure — a 180pt column of two-line rows where
    /// almost every second line is redundant.
    public let detail: String?
    /// False when the root did not answer — the whole list is then "everything remembered,
    /// unchecked" (`FolderJumpStore.reachable`), which is a sleeping drive rather than a folder
    /// that has gone.
    public let isAvailable: Bool

    public var id: String { "\(group.rawValue)/\(relativePath)" }

    public init(group: Group, relativePath: String, name: String,
                detail: String?, isAvailable: Bool) {
        self.group = group
        self.relativePath = relativePath
        self.name = name
        self.detail = detail
        self.isAvailable = isAvailable
    }
}

/// The sidebar's rules, separate from its view so both can be asserted without mounting anything.
public enum FolderSidebarModel {

    /// The store's two lists as rows, pins first.
    ///
    /// The store already guarantees the two do not overlap (`recentPaths` subtracts the pins), so
    /// nothing here re-filters; what it adds is the leaf name, and the parent path for the rows
    /// that need one to be told apart.
    /// - Parameter rootName: the provider's own display name, used as the parent of a folder that
    ///   sits at the top level. **Found by rendering it**: a pinned `Clients/Legal` beside a recent
    ///   top-level `Legal` drew one row with "Clients" under it and one with nothing, because the
    ///   top-level row's parent path is the empty string. Two rows reading "Legal" where only one
    ///   is qualified is the same ambiguity this rule exists to remove, half-fixed. Naming the root
    ///   is the convention `StorageLensView.displayFolder` already uses for the same case.
    public static func rows(_ remembered: RememberedFolders, rootName: String) -> [FolderSidebarRow] {
        let sources: [(FolderSidebarRow.Group, [String])] =
            [(.pinned, remembered.pinned), (.recents, remembered.recents)]
        // Counted across BOTH groups: a pin and a recent can share a leaf as easily as two pins,
        // and the reader is looking at one column, not two lists.
        var leafCounts: [String: Int] = [:]
        for (_, paths) in sources {
            for path in paths { leafCounts[leaf(of: path), default: 0] += 1 }
        }
        return sources.flatMap { group, paths in
            paths.map { path in
                let name = leaf(of: path)
                let parent = (path as NSString).deletingLastPathComponent
                let collides = (leafCounts[name] ?? 0) > 1
                let qualifier = parent.isEmpty ? rootName : parent
                return FolderSidebarRow(
                    group: group,
                    relativePath: path,
                    name: name,
                    detail: collides && !qualifier.isEmpty ? qualifier : nil,
                    isAvailable: remembered.rootIsAvailable)
            }
        }
    }

    /// **Where the sidebar can exist at all** — Browse, and nowhere else.
    ///
    /// Gated on the workspace rather than on `layoutMode`: the lens workspaces are single-source
    /// too, and their pane is the 220pt-clamped rail, which has no room for a 180pt column beside
    /// it. This is the question the *menu item* asks, so it stays live on Browse with the sidebar
    /// switched off — that item is how you switch it on.
    ///
    /// `Workspace` is not visible from this module, so the caller supplies the verdict rather than
    /// the value; the point of having it here is that the two questions below are written once.
    public static func appliesTo(isBrowse: Bool) -> Bool { isBrowse }

    /// **Whether the column is on screen**, which is a different question from the one above and
    /// the one that decides whether resolving its rows is worth a `stat` of the provider root.
    ///
    /// Both callers must agree or the sidebar draws rows nobody refreshed — or refreshes rows
    /// nobody draws. Written once for that reason.
    public static func isShowing(isBrowse: Bool, preference: Bool) -> Bool {
        appliesTo(isBrowse: isBrowse) && preference
    }

    /// The rows of one group, in order — the view's `ForEach` and the tests read the same list.
    public static func rows(_ rows: [FolderSidebarRow], in group: FolderSidebarRow.Group) -> [FolderSidebarRow] {
        rows.filter { $0.group == group }
    }

    /// What a click on a row means: **⌘ opens a new tab, a plain click switches this pane.**
    ///
    /// Injectable rather than reading `NSEvent.modifierFlags` at the call site, for the reason
    /// `DashboardViews` gives for the same trick: the flags are the state of the machine's
    /// keyboard, so a test can only pin this by being handed them.
    public static func opensInNewTab(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command)
    }

    /// Whether a row can be opened at all. An unavailable row stays listed — deleting a pin because
    /// a drive is asleep would cost the user their pins — but it refuses, the same way the ⌘K
    /// palette's unavailable rows do.
    public static func canOpen(_ row: FolderSidebarRow) -> Bool { row.isAvailable }

    private static func leaf(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// **Browse's remembered-folders sidebar.** The pins and recents `FolderJumpStore` has always held
/// were reachable only through the pane header's jump menu and the ⌘K field; Browse is one pane at
/// full width and has the room to keep them on screen.
///
/// **Folders only.** The Left/Right *provider* sidebar was removed on purpose when the provider
/// became a header dropdown, and this must not quietly bring it back: there is no provider row
/// here, and the list is scoped to whichever provider the pane is already on.
public struct FolderSidebarView: View {
    /// Fixed, and the same 180pt at every text size — the pane beside it is the resizable one, and
    /// a sidebar that grew with the type size would take the file column's width to do it.
    public static let width: CGFloat = 180

    private let rows: [FolderSidebarRow]
    private let currentRelativePath: String
    private let accent: Color
    private let onOpen: (FolderSidebarRow, Bool) -> Void
    private let onTogglePin: (FolderSidebarRow) -> Void

    public init(rows: [FolderSidebarRow], currentRelativePath: String, accent: Color,
                onOpen: @escaping (FolderSidebarRow, Bool) -> Void,
                onTogglePin: @escaping (FolderSidebarRow) -> Void) {
        self.rows = rows
        self.currentRelativePath = currentRelativePath
        self.accent = accent
        self.onOpen = onOpen
        self.onTogglePin = onTogglePin
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(FolderSidebarRow.Group.allCases, id: \.self) { group in
                            let groupRows = FolderSidebarModel.rows(rows, in: group)
                            if !groupRows.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.rawValue)
                                        .scaledFont(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 2)
                                    ForEach(groupRows) { row(for: $0) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Not "no folders": an empty sidebar is the *first-run* state, and the sentence that helps is
    /// the one that says how it fills.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing remembered yet")
                .scaledFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Folders you visit appear here, and pinning one keeps it at the top.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
    }

    private func row(for row: FolderSidebarRow) -> some View {
        let isCurrent = row.relativePath == currentRelativePath
        let canOpen = FolderSidebarModel.canOpen(row)
        return Button {
            onOpen(row, FolderSidebarModel.opensInNewTab(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: row.group == .pinned ? "pin.fill" : "folder")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .scaledFont(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = row.detail {
                        Text(detail)
                            .scaledFont(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // The `Spacer` above is what makes the row the full width of the column, and that is
            // load-bearing rather than cosmetic: a `hoverAffordance` row is clickable only where it
            // paints, so a row sized to its text would be readable across 180pt and clickable
            // across forty. Measured at 359 of 360 device pixels with it, 143 without —
            // `theCurrentRowFillsTheColumn` is what keeps it that way.
            //
            // (A `.frame(maxWidth: .infinity)` was added here first, on the assumption that the
            // `Spacer` was not enough. Mutating it out changed nothing, so it went: a line that
            // cannot be shown to matter is a line that will be believed to.)
            .background {
                // The pane's current folder, marked the way a Mac sidebar marks it. Weight and a
                // tinted glyph were doing this alone, which is legible next to a neighbour and
                // invisible on its own — and this is also what makes the row's real width
                // measurable, which is why `theCurrentRowFillsTheColumn` can exist at all.
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
            // Drawn rather than left to `.disabled`, which under `hoverAffordance` dims nothing.
            .opacity(canOpen ? 1 : 0.4)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent))
        .disabled(!canOpen)
        .help(canOpen ? tooltip(row) : "\(row.relativePath) — not available right now")
        .accessibilityLabel("\(row.group.rawValue): \(row.relativePath)"
                            + (canOpen ? "" : ", not available"))
        .contextMenu {
            Button("Open in New Tab") { onOpen(row, true) }
                .disabled(!canOpen)
            Button(row.group == .pinned ? "Unpin" : "Pin") { onTogglePin(row) }
        }
    }

    /// The whole path, always — the row shows a leaf and sometimes a parent, and the tooltip is
    /// where "which of the two Legals is this" is answered without waiting for a collision.
    private func tooltip(_ row: FolderSidebarRow) -> String {
        row.relativePath
    }
}
