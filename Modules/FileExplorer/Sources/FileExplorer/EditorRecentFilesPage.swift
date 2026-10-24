import SwiftUI
import Design

/// **Edit's empty page once it has files to offer** (TE58): the files Edit opened last, a New
/// Note button, and one sentence on the other ways in.
///
/// With nothing remembered — a first launch, or after Clear Menu — the page is `fallback`, the
/// sentence it has always been.
struct EditorRecentFilesPage<Fallback: View>: View {
    @ObservedObject var recents: EditorRecentFiles
    /// A row's click: the host's hand-off, so the pane follows the file as from any other door.
    let open: (String) -> Void
    /// **⌘N's closure itself**, as the header's ＋ is — `nil` draws no button.
    let newNote: (() -> Void)?
    /// Where New Note makes its file, by the name the ＋'s tooltip uses.
    let newNoteFolder: String
    /// The page's way to the folded list (TE77), kept beside New Note.
    let showTextFiles: (() -> Void)?
    let accent: Color
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.appFontScale) private var scale
    /// The list's width, for whether the folder column fits.
    @State private var listWidth: CGFloat = 0

    /// The page's heading and its New Note button.
    static var title: String { "Recent" }
    static var newNoteTitle: String { "New Note" }
    static var removeTitle: String { "Remove from Recents" }

    /// **What the page says under its buttons** — where New Note's file goes, then ⌘O. Its own
    /// words rather than `emptyCaption`'s: the list above is how to open a file again, so this says
    /// how to open one that is not in it. It names no file: New Note opens a naming row filled with
    /// the first free name (`Untitled 2.md` when `Untitled.md` is taken), not a file made outright.
    static func caption(folderName: String) -> String {
        "New Note asks for a name, then makes the file in \(folder(folderName)). To open a different file, select a text file "
            + "or a PDF file in Browse, Compare or Organize and press \(AppChord.openInEditor.display)."
    }

    /// The folder New Note names — Notes, where ⌘N goes with no folder in the pane.
    static func folder(_ name: String) -> String {
        name.isEmpty ? EditorRecentFiles.notesFallbackName : name
    }

    /// **Below this list width the folder column goes**, so the name keeps room in the narrowest
    /// document column (260pt): a name squeezed to "R…" beside its folder says neither.
    static var folderColumnMinimumListWidth: CGFloat { 320 }

    var body: some View {
        Group {
            if recents.shown.isEmpty {
                fallback()
            } else {
                page(recents.shown)
            }
        }
        // Each time the page appears: a file deleted since the last look is no longer offered.
        .task { await recents.refreshShown() }
    }

    private func page(_ files: [EditorRecentFile]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.title)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                list(files)
                buttons
                Text(Self.caption(folderName: newNoteFolder))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
    }

    private func list(_ files: [EditorRecentFile]) -> some View {
        // Once a minute, so "2 min ago" does not stay two minutes for the length of a coffee.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 1) {
                ForEach(files) { file in
                    row(file, now: context.date, showsFolder: listWidth >= Self.folderColumnMinimumListWidth)
                }
            }
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { listWidth = $0 }
    }

    private func row(_ file: EditorRecentFile, now: Date, showsFolder: Bool) -> some View {
        let folderWidth = FontSize.scaledBox(90, basePoint: 11, scale: scale)
        return Button { open(file.path) } label: {
            HStack(spacing: 8) {
                Image(systemName: EditorFileRailView.rowSymbol(file.kind == .pdf ? .pdf : .text))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(file.name)
                    .scaledFont(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if showsFolder {
                    Text(file.folderName)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: folderWidth, alignment: .leading)
                }
                Text(EditorRecentFiles.when(file.openedAt, now: now))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(EditorFileRailView.rowOutline)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent, shape: EditorFileRailView.rowShape))
        // The whole path, which the row has no room for.
        .help(file.path)
        .accessibilityLabel("\(file.name), in \(file.folderName), opened \(EditorRecentFiles.when(file.openedAt, now: now))")
        .contextMenu {
            Button(Self.removeTitle) { recents.remove(path: file.path) }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if newNote != nil || showTextFiles != nil {
            HStack(spacing: 8) {
                if let newNote {
                    Button(action: newNote) {
                        Label(Self.newNoteTitle, systemImage: "plus")
                            .scaledFont(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    // The seam every filled button takes its hue through (`ProminentAccent`).
                    .accentedProminent()
                    // ⌥ shows ⌘N and ⌃⌘T on the page's two buttons (TE194).
                    .shortcutKeycap(AppChord.newTextFile.display)
                    .help(ShortcutHint.tooltip(EditorWorkspaceView.newTextFileTitle(folderName: Self.folder(newNoteFolder)),
                                               AppChord.newTextFile.display))
                }
                if let showTextFiles {
                    Button(action: showTextFiles) {
                        Label(EditorWorkspaceView.showTextFilesTitle, systemImage: EditorRailTab.files.symbol)
                            .scaledFont(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(accent)
                    .shortcutKeycap(AppChord.editorTextFiles.display)
                    .help(ShortcutHint.tooltip("Show the folder’s files beside the document",
                                               AppChord.editorTextFiles.display))
                }
            }
        }
    }
}

extension EditorRecentFiles {
    /// Where New Note goes with no folder to name — `EditorNewFileFolder.notesName` in the app.
    nonisolated static let notesFallbackName = "Notes"
}
