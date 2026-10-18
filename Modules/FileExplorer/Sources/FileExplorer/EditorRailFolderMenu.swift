import SwiftUI
import Design

/// Where the rail's folder sits, as the folder line's menu offers it: every level from the top of
/// the pane's source down to the folder, and the folders inside it.
///
/// **Built by the host from the pane's own vocabulary** — the levels are the Edit header's location
/// segments for the pane's folder (`EditorHeaderLocation`), so every name here is a word the pane's
/// breadcrumb draws, and every target is the combined path that crumb would send the pane to. A
/// pick moves the LEFT pane, and the rail follows it because the rail lists the left pane's folder:
/// the menu is a way to steer the pane while it is folded away, not a second place to stand.
public struct EditorFolderTrail: Equatable, Sendable {
    /// The top of the source first, the rail's folder last. A `nil` target is named and not
    /// offered — a folder outside the pane's source, which the pane cannot go to without switching
    /// source. The last level's is always `nil`: it is the folder already being listed.
    public var levels: [EditorDocumentLocation.Segment]
    /// The rail's folder as a pane target — what a subfolder's target is built from — or `nil`
    /// outside the pane's source, where a subfolder is no more reachable than its parent.
    public var currentTarget: String?
    /// The folders inside, by name, in Finder's order (``EditorRail/Survey/folders``).
    public var subfolders: [String]

    public init(levels: [EditorDocumentLocation.Segment], currentTarget: String?, subfolders: [String]) {
        self.levels = levels
        self.currentTarget = currentTarget
        self.subfolders = subfolders
    }

    /// How many subfolders the menu lists before it says how many more there are. A folder of
    /// hundreds is a menu taller than the screen, and the pane is the place to read those.
    static let subfolderCap = 40

    /// Where a pick of the subfolder `name` sends the pane, or `nil` when it cannot go.
    func target(forSubfolder name: String) -> String? {
        currentTarget.map { $0.isEmpty ? name : $0 + "/" + name }
    }

    /// **The levels in the menu's order: the folder first, the top of the source last** — Finder's
    /// path menu. Under the subfolders, that makes the whole menu read one way, down the tree at the
    /// top and up it from the folder.
    var upward: [EditorDocumentLocation.Segment] { levels.reversed() }

    /// Whether the menu has anywhere to go. A trail with no door at all — a folder outside the
    /// pane's source with nothing inside — draws the plain line rather than a menu of greyed rows.
    var offersAnything: Bool {
        levels.contains { $0.target != nil } || (currentTarget != nil && !subfolders.isEmpty)
    }

    /// The menu's tooltip and VoiceOver hint.
    static let help = "Go to an enclosing folder or a folder inside this one"
}

/// The Files tab's folder line: the folder's name, and — where the pane can go somewhere from it —
/// a menu down to its subfolders and up to the top of the source.
///
/// **A `Menu` in the button style**, as the header location's folded "…" is: the label is drawn as
/// written, at the row's 11pt and with the hover wash, rather than as AppKit's pop-up, which draws
/// its own label and does not take the app's text size.
struct EditorRailFolderMenu: View {
    let name: String
    let trail: EditorFolderTrail?
    let accent: Color
    let onGoTo: ((String) -> Void)?

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
            // Back out the label's padding, so the folder glyph sits where it sits on the other
            // tabs and does not step sideways when the tab changes.
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
                let more = trail.subfolders.count - EditorFolderTrail.subfolderCap
                if more > 0 {
                    Text("\(more) more — open the file pane to see them all")
                }
            }
        }
        Section {
            ForEach(Array(trail.upward.enumerated()), id: \.offset) { index, level in
                if index == 0 {
                    // The folder being listed: ticked, and not a door — a pick would send the pane
                    // to where it already is.
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
