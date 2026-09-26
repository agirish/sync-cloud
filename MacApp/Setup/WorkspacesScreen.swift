import Design
import FileExplorer
import SwiftUI
import Sync

/// The bridge from "here is what I found" to "here is what to do".
///
/// **Nothing to decide, which is why it has no Skip and no number.** Every workspace on it is one
/// keystroke away later; the screen exists because a sheet that ends on a summary tells the user
/// what it did and not what they can now do.
struct WorkspacesScreen: View {
    @ObservedObject var model: SetupModel
    let hue: LiquidGlassHue

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "What you can do now",
                         blurb: "Four workspaces, ⌘1 to ⌘4, on the locations you turned on. "
                             + "Organize also uses what was just learned.")

            // **A `Grid`, because an `HStack` gave three cards three heights.** Each card is as
            // tall as its own blurb wraps — Compare's is three lines, Edit's two — so the row's
            // bottom edge stepped twice across cards that are otherwise identical. A `Grid` row
            // hands every cell the row's height, and the card fills it.
            Grid(horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    ForEach(Self.plainWorkspaces, id: \.workspace) { entry in
                        workspaceCard(entry)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                HStack(spacing: 6) {
                    Image(systemName: Workspace.filing.symbol)
                        .scaledFont(.caption)
                        .foregroundStyle(.tint)
                    Text(Workspace.filing.title).scaledFont(.callout.weight(.semibold))
                    ShortcutKeycap(Self.chord(for: .filing))
                    Spacer(minLength: 0)
                }
                ForEach(OrganizeLens.allCases, id: \.self) { lens in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(lens.title)
                            .scaledFont(.caption.weight(.medium))
                            .frame(width: 78, alignment: .leading)
                        Text(line(for: lens))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            Text("Every suggestion here waits for you, and every run is one ⌘Z. Rules are the one "
                 + "exception: once you write one, it files without asking.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text("Help ▸ SyncCloud Help, ⌘?, explains each workspace. "
                 + "Window ▸ Keyboard Shortcuts, ⌘/, lists every shortcut.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The workspace's own chord, taken from its position in the bar — the same rule
    /// `WorkspaceCommands` numbers the segments by, so the card cannot claim a key the bar does
    /// not give it.
    static func chord(for workspace: Workspace) -> String {
        guard let index = Workspace.allCases.firstIndex(of: workspace),
              let chord = AppChord.workspace(index + 1) else { return "" }
        return chord.display
    }

    /// The three workspaces that are one card each. Organize gets its own block below, because
    /// what was just learned lands in its lenses.
    static let plainWorkspaces: [(workspace: Workspace, blurb: String)] = [
        (.browse, "One tree at full width. Where SyncCloud opens."),
        (.compare, "Two folders side by side, copy either way, one ⌘Z."),
        (.editor, "Text and Markdown, in place, autosaved."),
    ]

    private func workspaceCard(_ entry: (workspace: Workspace, blurb: String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: entry.workspace.symbol)
                    .scaledFont(.caption)
                    .foregroundStyle(.tint)
                Text(entry.workspace.title).scaledFont(.callout.weight(.semibold))
                Spacer(minLength: 0)
                ShortcutKeycap(Self.chord(for: entry.workspace))
            }
            Text(entry.blurb)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
    }

    /// What each lens says, with the two lines that use what was just learned.
    private func line(for lens: OrganizeLens) -> String {
        switch lens {
        case .toFile:
            guard model.walkState.isDone else {
                return "Files by folder name. Learn a folder to do better."
            }
            let loose = model.looseRoutes.count
            let ready = SetupLooseFileRouting.readyCount(model.looseRoutes)
            guard loose > 0 else { return "No loose files in \(model.walkRootName)." }
            return "\(loose) loose file\(loose == 1 ? "" : "s") in \(model.walkRootName). "
                + "\(ready) ha\(ready == 1 ? "s" : "ve") a suggested home by name."
        case .duplicates:
            return "Copies, even under different names."
        case .renames:
            return "Names that won't sync or don't match their folder."
        case .restructure:
            guard let example = restructureExample else {
                return "Folders whose siblings disagree about their shape."
            }
            return example
        case .rules:
            return "Automate the moves you repeat."
        case .storage:
            return "What takes the space, and where."
        }
    }

    /// The first shape finding, said in the lens's own terms — or nil when there is no profile to
    /// find one in, which is the Learn-skipped case.
    private var restructureExample: String? {
        guard model.preview != nil else { return nil }
        // The findings the Structure screen already derived, not a fresh detector pass per redraw.
        guard let finding = model.previewReadings.shapes.values
            .sorted(by: { $0.family < $1.family }).first else { return nil }
        let name = (finding.family as NSString).lastPathComponent
        return "\(name) uses \(finding.schemes.count) shapes across \(finding.memberCount) folders. "
            + "Restructure proposes one."
    }
}

/// The Why panel beside Workspaces: where to start, rather than why it asks.
struct WorkspacesWhy: View {
    let hue: LiquidGlassHue

    var body: some View {
        SetupWhyPanel(title: "Where to start",
                      footnoteLead: "Nothing to decide here.",
                      footnote: "Every workspace on this screen is one keystroke away later.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Organize ▸ To File. The loose files are the quickest win, and each "
                     + "suggestion shows why before you accept it.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Then Compare, when you want two locations kept in step.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
