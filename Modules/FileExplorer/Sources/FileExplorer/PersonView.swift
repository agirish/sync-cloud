import SwiftUI
import Design
import Sync

/// Everything that is one person's, grouped by why — the answer to "all of Aditi's files".
///
/// **A find dims the tree to show where something sits; this gathers.** That is the whole reason
/// it is a different surface from the pane search that opens it: the question is not "where is
/// this string" but "what is hers", and the answer is spread across the source rather than
/// standing in one place.
///
/// Two groups in stage 1, and the order is by how much they are worth reading rather than by size.
/// **In her folders** is the tree's own filing and dominates by volume — he could reach it by
/// browsing. **Hers, filed elsewhere** is the payoff: those rows are candidate misfilings, and no
/// amount of browsing produces them.
///
/// Read-only. Nothing here writes a tag, and a row's action is Reveal — confirming a person and
/// moving a file are separate verbs, and only the second one exists yet.
public struct PersonView: View {
    let displayName: String
    let files: PersonFileSet
    let accent: Color
    /// Reveals a folder in the pane. Folders, because that group's unit is the folder.
    let onOpenFolder: (String) -> Void
    /// Reveals one file in Finder.
    let onReveal: (String) -> Void
    let onClear: () -> Void

    public init(displayName: String, files: PersonFileSet, accent: Color,
                onOpenFolder: @escaping (String) -> Void,
                onReveal: @escaping (String) -> Void,
                onClear: @escaping () -> Void) {
        self.displayName = displayName
        self.files = files
        self.accent = accent
        self.onOpenFolder = onOpenFolder
        self.onReveal = onReveal
        self.onClear = onClear
    }

    /// How many folders are listed before the rest collapse into a count.
    ///
    /// Nine folders was the mockup's number and 166 is the real one for the largest person, so the
    /// list has to stop somewhere. **The remainder is stated, never dropped** — a list that
    /// silently showed the top five would misreport the answer to the question the view exists to
    /// answer.
    private static let folderLimit = 8

    private var inFolders: Int { files.herFolders.reduce(0) { $0 + $1.files.count } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if files.total == 0 {
                        emptyState
                    } else {
                        herFoldersGroup
                        if !files.elsewhere.isEmpty { elsewhereGroup }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .scaledFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
            Text(displayName)
                .scaledFont(.system(size: 13, weight: .semibold))
            // The count is the whole set, not the rows on screen — it is the answer to the
            // question, and the folder list below is deliberately truncated.
            Text("\(files.total) hers")
                .scaledFont(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.14)))
            Spacer(minLength: 8)
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Back to the plain pane (Esc)")
            .accessibilityLabel("Clear person scope")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Her folders

    private var herFoldersGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            groupHeader(symbol: "house",
                        title: "In her folders",
                        subtitle: "The tree's own filing.",
                        amount: "\(inFolders) file\(inFolders == 1 ? "" : "s") · \(files.folderCount) folder\(files.folderCount == 1 ? "" : "s")")
            ForEach(files.herFolders.prefix(Self.folderLimit), id: \.folder) { group in
                HStack(spacing: 10) {
                    Text(group.folder)
                        .scaledFont(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text("\(group.files.count)")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Open") { onOpenFolder(group.folder) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .chromeHover()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.30)))
            }
            if files.folderCount > Self.folderLimit {
                Text("\(files.folderCount - Self.folderLimit) more folders…")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
            }
        }
    }

    // MARK: Filed elsewhere

    private var elsewhereGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            groupHeader(symbol: "sparkles",
                        title: "Hers, filed elsewhere",
                        subtitle: "Candidate misfilings — named for her, filed somewhere that is not hers.",
                        amount: "\(files.elsewhere.count) file\(files.elsewhere.count == 1 ? "" : "s")")
            ForEach(files.elsewhere) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.path)
                            .scaledFont(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        // Why this row is here, in the row. A group heading that said "named for
                        // her" would leave each row asking which of her names did it.
                        Text(file.matchedForm.map { "named in the file — “\($0)”" } ?? "named in the file")
                            .scaledFont(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Reveal") { onReveal(file.path) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .chromeHover()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.30)))
            }
        }
    }

    // MARK: Chrome

    private func groupHeader(symbol: String, title: String, subtitle: String,
                             amount: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).scaledFont(.system(size: 12.5, weight: .semibold))
                Text(subtitle).scaledFont(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(amount)
                .scaledFont(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent)
                .fixedSize()
        }
    }

    /// Nobody's, and that is an answer rather than a failure — it means the surveyed tree holds
    /// nothing under their folders and nothing naming them strongly enough to be sure.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing filed under \(displayName).")
                .scaledFont(.system(size: 12.5, weight: .semibold))
            Text("No folder in the survey is theirs, and no file names them clearly enough to say "
                 + "so on its own.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
