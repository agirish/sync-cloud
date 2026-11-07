import SwiftUI
import Design

/// Where the rail's folder sits, as the folder line's menu offers it: every level from the top of
/// the pane's source down to the folder, and the folders inside it.
///
/// Built by the host from the Edit header's location segments for the pane's folder
/// (`EditorHeaderLocation`), so every name is one the pane's breadcrumb draws and every target the
/// path that crumb would send. A pick moves the left pane and the rail follows, since it lists that
/// pane's folder: a way to steer the folded pane, not a second place to stand.
public struct EditorFolderTrail: Equatable, Sendable {
    /// The top of the source first, the rail's folder last. A `nil` target is named and not
    /// offered: a folder outside the pane's source, which the pane can't reach without switching
    /// source. The last level's is always `nil`, being the folder already listed.
    public var levels: [EditorDocumentLocation.Segment]
    /// The rail's folder as a pane target, which a subfolder's target is built from, or `nil`
    /// outside the pane's source, where a subfolder is no more reachable than its parent.
    public var currentTarget: String?
    /// The folders inside, by name, in Finder's order (``EditorRail/Survey/folders``).
    public var subfolders: [String]

    public init(levels: [EditorDocumentLocation.Segment], currentTarget: String?, subfolders: [String]) {
        self.levels = levels
        self.currentTarget = currentTarget
        self.subfolders = subfolders
    }

    /// How many subfolders the menu lists before offering the rest: hundreds would make a menu
    /// taller than the screen, and the pane is the place to read those.
    static let subfolderCap = 40

    /// Where a pick of the subfolder `name` sends the pane, or `nil` when it cannot go.
    func target(forSubfolder name: String) -> String? {
        currentTarget.map { $0.isEmpty ? name : $0 + "/" + name }
    }

    /// The levels in the menu's order: the folder first, the top of the source last, as Finder's
    /// path menu has them. Under the subfolders, the whole menu then reads one way.
    var upward: [EditorDocumentLocation.Segment] { levels.reversed() }

    /// Whether the menu has anywhere to go. A trail with no door (a folder outside the pane's source
    /// with nothing inside) draws the plain line rather than a menu of greyed rows.
    var offersAnything: Bool {
        levels.contains { $0.target != nil } || (currentTarget != nil && !subfolders.isEmpty)
    }

    /// The item past the cap that opens the file pane on the folder.
    static func showAllTitle(count: Int) -> String { "Show All \(count) in the File Pane" }

    /// The menu's tooltip and VoiceOver hint.
    static let help = "Go to an enclosing folder or a folder inside this one"
}

/// The Files tab's folder line: the folder's name and, where the pane can go somewhere from it, a
/// menu down to its subfolders and up to the top of the source. A `Menu` in the button style, as
/// the header location's folded "…" is, so the label draws at the row's 11pt with the hover wash;
/// AppKit's pop-up draws its own label and ignores the app's text size.
struct EditorRailFolderMenu: View {
    let name: String
    let trail: EditorFolderTrail?
    let accent: Color
    let onGoTo: ((String) -> Void)?
    /// Opens the file pane, already on this folder: the menu's way to the subfolders past
    /// ``EditorFolderTrail/subfolderCap``. `nil` (the previews) lists the first ones only.
    var onShowAll: (() -> Void)? = nil

    var body: some View {
        if let trail, let onGoTo, trail.offersAnything {
            Menu {
                items(trail, onGoTo: onGoTo)
            } label: {
                line(chevron: true)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .menuIndicator(.hidden)
            // Back out the label's padding, so the folder glyph sits where it does on the other
            // tabs and doesn't step sideways when the tab changes.
            .padding(.horizontal, -4)
            .help(EditorFolderTrail.help)
            .accessibilityLabel("Folder: \(name)")
            .accessibilityHint(EditorFolderTrail.help)
        } else {
            line(chevron: false)
        }
    }

    /// The folder glyph, the name, and the chevron that says it opens.
    private func line(chevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .scaledFont(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(name)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if chevron {
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func items(_ trail: EditorFolderTrail, onGoTo: @escaping (String) -> Void) -> some View {
        if trail.currentTarget != nil, !trail.subfolders.isEmpty {
            Section("Folders in \(name)") {
                ForEach(trail.subfolders.prefix(EditorFolderTrail.subfolderCap), id: \.self) { folder in
                    if let target = trail.target(forSubfolder: folder) {
                        Button { onGoTo(target) } label: { Label(folder, systemImage: "folder") }
                    }
                }
                // A door, not a greyed line. Counts the whole folder, as Finder's Show All does,
                // rather than the leftover.
                if trail.subfolders.count > EditorFolderTrail.subfolderCap, let onShowAll {
                    Button(EditorFolderTrail.showAllTitle(count: trail.subfolders.count), action: onShowAll)
                }
            }
        }
        Section {
            ForEach(Array(trail.upward.enumerated()), id: \.offset) { index, level in
                if index == 0 {
                    // The folder being listed: ticked, and not a door, since a pick would send the
                    // pane where it already is.
                    Toggle(isOn: .constant(true)) { Label(level.name, systemImage: "folder") }
                        .disabled(true)
                } else if let target = level.target {
                    Button { onGoTo(target) } label: { Label(level.name, systemImage: "folder") }
                } else {
                    Button {} label: { Label(level.name, systemImage: "folder") }
                        .disabled(true)
                }
            }
        }
    }
}
