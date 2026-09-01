import SwiftUI
import Design
import Sync

/// The Editor workspace's hard widths, in one place because the app target has to clamp against
/// them and the views have to draw at them.
///
/// **Named together rather than left as literals**, for the reason `PaneLogic.minRailWidth` is:
/// the row that holds these is divided by a fraction the user drags, and a clamp that disagrees
/// with the thing it clamps is how a column ends up too narrow to use with no way to widen it.
public enum EditorLayoutMetrics {
    /// The file rail's width. Fixed rather than draggable: it holds one column of file names, the
    /// sidebar beside it is already resizable, and a third drag handle in the row would be the
    /// third thing to explain before anyone had opened a file.
    public static let railWidth: CGFloat = 232
    /// The narrowest the document column may become. Below this a line of prose stops being a line.
    public static let minDocumentWidth: CGFloat = 260
    /// What the editor half of the row needs in total, which is what the source pane is clamped
    /// against when it is expanded.
    ///
    /// **Plus the two cards' own insets.** The rail and the document each draw as a
    /// `bottomSectionCard`, and a card pads itself by `cardInset` on every side — half a gutter, so
    /// the pair sums to one `cardGutter` between them and another half at each outer edge. That is
    /// 2 × `cardGutter` of horizontal chrome the two columns do not get to use, and leaving it out
    /// of this number is how a clamp comes to guarantee a document width it then shaves 10pt off.
    public static var minWorkspaceWidth: CGFloat {
        railWidth + minDocumentWidth + 2 * LiquidGlass.cardGutter
    }

    /// The narrowest either half of a `.split` may become.
    ///
    /// **Deliberately not ``minDocumentWidth``, which is a different question.** That one is what a
    /// document needs when it is the only thing in the column, and it is what the workspace floor
    /// is built from. This is what each of two columns needs when the reader has asked for both at
    /// once and has a window wide enough to mean it — a smaller number, because a preview beside
    /// the text is worth more than either at its comfortable width.
    public static let minSplitColumnWidth: CGFloat = 220

    /// `raw` clamped so neither half of a `.split` falls under ``minSplitColumnWidth``.
    ///
    /// **One function, because this arithmetic has already shipped a bug in each direction.**
    /// `min(max(x, lower), 1 - lower)` is not a clamp when `lower > 1 - lower`: it collapses to the
    /// constant `1 - lower` for every input. At the 810pt window floor the document column is
    /// ~391pt, well under 2 × 220, so split mode first shipped with a divider frozen at the
    /// narrowest window the app allows. The guard below fixed that where the divider is DRAWN — and
    /// the drag handler kept its own copy of the unguarded expression, so every drag at that width
    /// committed 0.4373 (or, narrower still, a negative fraction) into the remembered fraction: the
    /// divider did not move, and then jumped to a position nobody chose the moment the window was
    /// widened. Both call sites now ask this.
    public static func splitFraction(_ raw: CGFloat, in width: CGFloat) -> CGFloat {
        // Too narrow to honour two minimums: split the difference rather than pinning one side.
        guard width >= 2 * minSplitColumnWidth else { return 0.5 }
        let lower = minSplitColumnWidth / max(width, 1)
        return min(max(raw, lower), 1 - lower)
    }
}

/// The Editor workspace: the file rail, and the open document beside it.
///
/// **Manager-free, like the compare sheet and unlike the lens surfaces.** Every act this view can
/// perform — open a file, create one, save one — leaves through a closure, so the workspace can be
/// laid out and asserted without a `FileSyncManager` in the room. `ContentView+Editor` is the
/// wrapper that supplies those closures and owns the consequences.
public struct EditorWorkspaceView: View {

    @ObservedObject var document: EditorDocument

    /// The folder the sidebar has selected. Empty when there is none.
    let folder: String
    let entries: [EditorRailEntry]
    let accent: Color
    /// The label colour on the accent fill — deepened by the host so white text stays legible on
    /// every hue, the same value the workspace bar's selected segment uses.
    let onAccent: Color
    /// Edit / Preview / Split. Held by the host so it survives the workspace being torn down.
    @Binding var mode: EditorMode
    /// The width the editor takes in `.split`, as a fraction of the column.
    ///
    /// **Held by the host beside `mode`, and for the same reason.** As `@State` here it was reset
    /// to 0.5 by every workspace switch — the mode survived the round trip and the divider silently
    /// did not, which is the pair disagreeing about what the session remembers.
    @Binding var splitFraction: CGFloat
    @Binding var isNaming: Bool
    /// The name being typed in the naming row. Held by the host beside `isNaming` — see
    /// ``EditorFileRailView/typedName``.
    @Binding var typedName: String
    /// A counter ⌘N bumps, so a row that is already open still takes focus. See
    /// ``EditorFileRailView/namingFocus``.
    let namingFocus: Int
    /// The window's editor undo stack. See ``PlainTextEditor/undoManager``.
    let undoManager: UndoManager
    /// Why autosave has stopped, in the header's own words, or `nil` while it is working. A string
    /// rather than the host's enum: this view draws it and never branches on it.
    let stopped: String?
    let prefilledName: () -> String
    let refusal: (String) -> String?
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a typed name. Answers `false` when the file was not created after all, so the
    /// naming row can stay open with the name still in it.
    let onCreate: (String) -> Bool
    /// The reverse of "Open in Edit": shows the open file where it lives.
    let onRevealInBrowse: (String) -> Void

    @Environment(\.appFontScale) private var fontScale

    // The window's chrome, read straight from the shared defaults rather than threaded through the
    // initializer — the same four keys `StorageLensView` and `LensWorkspaceView` read to card
    // themselves. This view stays manager-free; these are settings, not state anybody owns.
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }

    /// The parsed document, re-derived off the main actor after the typing settles.
    @State private var blocks: [MarkdownBlock] = []
    /// Live only while the divider is being dragged; the committed value lives with the host.
    @State private var splitDrag: CGFloat?

    public init(document: EditorDocument,
                folder: String,
                entries: [EditorRailEntry],
                accent: Color,
                onAccent: Color,
                mode: Binding<EditorMode>,
                splitFraction: Binding<CGFloat>,
                isNaming: Binding<Bool>,
                typedName: Binding<String>,
                namingFocus: Int = 0,
                undoManager: UndoManager,
                stopped: String? = nil,
                prefilledName: @escaping () -> String,
                refusal: @escaping (String) -> String?,
                onOpen: @escaping (EditorRailEntry) -> Void,
                onCreate: @escaping (String) -> Bool,
                onRevealInBrowse: @escaping (String) -> Void) {
        self.document = document
        self.folder = folder
        self.entries = entries
        self.accent = accent
        self.onAccent = onAccent
        self._mode = mode
        self._splitFraction = splitFraction
        self._isNaming = isNaming
        self._typedName = typedName
        self.namingFocus = namingFocus
        self.undoManager = undoManager
        self.stopped = stopped
        self.prefilledName = prefilledName
        self.refusal = refusal
        self.onOpen = onOpen
        self.onCreate = onCreate
        self.onRevealInBrowse = onRevealInBrowse
    }

    private var folderName: String {
        folder.isEmpty ? "" : (folder as NSString).lastPathComponent
    }

    /// **Two cards, not one region with a rule down it.**
    ///
    /// The rail and the document are two different things — a list of what you could open, and the
    /// thing you have open — and every other pair of neighbours in this window says so by being two
    /// cards with a gutter between them. Drawn flat inside a single region, they were the only
    /// surfaces in the app sitting directly on the window's glass while the sidebar and the source
    /// pane beside them floated.
    ///
    /// `spacing: 0` and no padding here: `bottomSectionCard` insets itself by `cardInset`, half a
    /// gutter, so two adjacent cards come to exactly one `cardGutter` between them and line up with
    /// the pane cards at the window edge. The `Divider` went with the change — a rule down the
    /// middle of a gutter is a third edge between two that are already there, the same reason the
    /// sidebar's seam is a clear strip rather than a `Divider`.
    public var body: some View {
        HStack(spacing: 0) {
            EditorFileRailView(folderName: folderName,
                               entries: entries,
                               selectedPath: document.path,
                               accent: accent,
                               isNaming: $isNaming,
                               typedName: $typedName,
                               namingFocus: namingFocus,
                               prefilledName: prefilledName,
                               refusal: refusal,
                               onOpen: onOpen,
                               onCreate: onCreate)
                .frame(maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
            documentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        }
    }

    // MARK: - The open document

    @ViewBuilder
    private var documentColumn: some View {
        VStack(spacing: 0) {
            if document.path != nil {
                header
                Divider()
            }
            body(for: document)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // **The dot now means "autosave has stopped", not "you have not saved yet".**
                // Under autosave an unsaved buffer is the ordinary state for about two seconds at a
                // time, and a dot that blinked on through every pause in typing would be a light
                // that is always on — worth nothing at the moment it matters. So it appears only
                // when writing has actually halted, and it wears the warning colour rather than the
                // accent, because it is now a problem rather than a status.
                Circle()
                    .fill(stopped == nil ? Color.clear : Color.orange)
                    .frame(width: 6, height: 6)
                    .opacity(stopped == nil ? 0 : 1)
                    .accessibilityHidden(stopped == nil)
                    .accessibilityLabel("Not saving")
                Text(document.name)
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The way back. The hand-off into this workspace comes from a file row, so the
                    // filename is where a user looks to ask "where is this?" — and it is one item,
                    // on the one element that names the file.
                    .contextMenu {
                        if let path = document.path {
                            Button(action: { onRevealInBrowse(path) }) {
                                Label("Reveal in Browse", systemImage: "folder")
                            }
                        }
                    }
                Spacer(minLength: 0)
                // **Only for files that have something to preview.** `PairContentKind` already
                // owns which extensions are Markdown; a capsule on a `.txt` would offer two modes
                // that render the same thing.
                if document.isMarkdown {
                    EditorModeBar(mode: $mode, accent: accent, onAccent: onAccent)
                }
            }
            Text(metaLine)
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// **What the last segment says, and it is the whole visible account of autosave.**
    ///
    /// There is no "saving…" state on purpose. The write is a staged file and a rename on a local
    /// path — it finishes far inside a frame — so a spinner would be a flicker nobody can read, and
    /// the honest reading of "saved" here is "everything you have typed is on disk", which is true
    /// between keystrokes and false for at most the debounce.
    ///
    /// A stop is what actually needs saying, because it is the one state where typing is not
    /// reaching the file, and it replaces the segment rather than joining it: "saved · not saving"
    /// is a contradiction, and the stop is the half that matters.
    private var metaLine: String {
        var parts: [String] = [document.isMarkdown ? "Markdown" : "Plain text"]
        if let size = document.stamp?.size { parts.append(FileSyncManager.formatBytes(size)) }
        if document.isReadOnly {
            parts.append("read only")
        } else if let stopped {
            parts.append(stopped)
        } else {
            parts.append("saved")
        }
        return parts.joined(separator: " · ")
    }

    /// The document column, with the parse attached where it cannot be torn down.
    ///
    /// **The `.onChange` and the `.task` hang HERE, outside the branch that draws a document.**
    /// They used to be modifiers on the `VStack` in the `else` arm, which is to say they did not
    /// exist while a file was refused or while nothing was open — and `.onChange` without
    /// `initial:` does not fire when its branch is reconstructed. Opening a cloud-only file
    /// (refused, `else` arm destroyed) and then a second Markdown file rebuilt the arm with the
    /// FIRST document's blocks still in `@State`, so the preview rendered one file's headings under
    /// another file's name until the 150ms debounce and the parse had both finished. That is the
    /// exact failure the synchronous clear was added to prevent, reached through the one path where
    /// the clear was not mounted.
    private func body(for document: EditorDocument) -> some View {
        documentBody(for: document)
            // **Cleared synchronously when the FILE changes, before the debounce.** The parse is
            // deliberately late — 150ms plus however long it takes — and `blocks` is only
            // reassigned at the end of it, so without this a second file's name sits above the
            // first file's headings for at least that long.
            .onChange(of: document.path, initial: true) { _, _ in blocks = [] }
            // **The re-render is debounced, and the parse is off the main actor.** Keyed on the
            // document's version counter rather than on its text: `.task(id:)` compares its id
            // every render pass, and comparing a 4 MiB buffer per keystroke to decide whether to
            // re-parse would cost more than the parse itself. The sleep is the debounce — a new
            // keystroke cancels this task before it wakes, so a burst of typing parses once at the
            // end of it.
            .task(id: EditorParseKey(version: document.textVersion, path: document.path)) {
                guard document.isMarkdown else {
                    blocks = []
                    return
                }
                // Cancelled by the next keystroke, which is the whole mechanism.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let source = document.text
                let parsed = await Task.detached(priority: .userInitiated) {
                    MarkdownBlocks.blocks(from: source)
                }.value
                guard !Task.isCancelled else { return }
                blocks = parsed
            }
    }

    @ViewBuilder
    private func documentBody(for document: EditorDocument) -> some View {
        if let refused = document.refusal {
            // The file was chosen and could not be opened — `BoundedTextRead`'s own prose, which is
            // already written for a reader.
            caption(refused)
        } else if document.path == nil {
            caption(folder.isEmpty
                    ? "Pick a folder in the sidebar, then choose a file to edit."
                    : "Choose a file from the rail, or press \(AppChord.newTextFile.display) to make one.")
        } else {
            VStack(spacing: 0) {
                if let reason = document.readOnlyReason {
                    readOnlyBanner(reason)
                }
                surfaces(for: EditorMode.resolved(mode, isMarkdown: document.isMarkdown))
            }
        }
    }

    /// What re-parses the preview, as one value: a new version OR a different file.
    ///
    /// The path is in here because opening a second document can leave the counter unchanged —
    /// `open` writes `text`, which bumps it, but a file whose contents are identical to the last
    /// one's would still be a different document with the same rendered result. Cheap insurance,
    /// and it keeps the key's meaning "the thing being previewed", not "the buffer".
    private struct EditorParseKey: Equatable {
        var version: Int
        var path: String?
    }

    /// The writable surface, the rendered one, or both.
    @ViewBuilder
    private func surfaces(for resolved: EditorMode) -> some View {
        switch resolved {
        case .edit:
            editorSurface
        case .preview:
            MarkdownPreview(blocks: blocks, accent: accent)
        case .split:
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = EditorLayoutMetrics.splitFraction(splitDrag ?? splitFraction,
                                                                 in: width)
                let editorWidth = width * fraction
                HStack(spacing: 0) {
                    editorSurface.frame(width: editorWidth)
                    Divider()
                    // `max(0, …)` because the first layout pass can report a zero width, and
                    // `0 - 0 - 1` is the negative dimension SwiftUI logs and refuses to lay out.
                    MarkdownPreview(blocks: blocks, accent: accent)
                        .frame(width: max(0, width - editorWidth - 1))
                }
                // Compare's divider ergonomics: a 1pt rule with an invisible 12pt grab strip
                // straddling it, so the target is reachable without a visible handle.
                .overlay(alignment: .leading) {
                    splitHandle(width: width)
                        .offset(x: editorWidth - 6)
                }
                .coordinateSpace(.named(Self.splitSpace))
            }
        }
    }

    private var editorSurface: some View {
        PlainTextEditor(text: $document.text,
                        isEditable: !document.isReadOnly,
                        fontScale: fontScale,
                        documentID: document.path,
                        undoManager: undoManager)
    }

    /// The name of the row's own coordinate space, which the drag reads positions in.
    ///
    /// **A fixed space, never `.local`** — the rule `ResizeHandle` states for every other seam in
    /// the window. The strip is offset by the divider's position, so it MOVES as it is dragged, and
    /// a local x is measured against a frame that is itself following the pointer: the drag reads
    /// as though the divider were always at the leading edge. Compensating for that by hand
    /// (`editorWidth - 6 + value.location.x`) is what this replaces — the offset is a layout detail
    /// the gesture should not have to know.
    private static let splitSpace = "editorSplit"

    private func splitHandle(width: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: 12)
            // **`.pointerStyle`, not an `NSCursor.push()`/`pop()` pair.** `ContentView+SplitLayout`
            // records removing exactly that bookkeeping from the pane seam — it leaks a pushed
            // cursor whenever `onHover(false)` is not delivered, which is every time the view goes
            // away under the pointer — and `.columnResize` is what every other seam in the window
            // shows. A hand-rolled copy here was both a third copy of the leak and a divider that
            // pointed differently from its neighbours.
            .pointerStyle(.columnResize)
            .gesture(
                // `minimumDistance: 1`, matching every other seam. The default is 10, and at a
                // narrow window the divider's whole legal travel is about 20pt — a 10pt dead zone
                // takes half of it and makes fine adjustment impossible exactly where it is needed.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                    .onChanged { value in
                        guard width > 0 else { return }
                        splitDrag = EditorLayoutMetrics.splitFraction(value.location.x / width,
                                                                      in: width)
                    }
                    .onEnded { _ in
                        if let splitDrag { splitFraction = splitDrag }
                        splitDrag = nil
                    }
            )
            .accessibilityHidden(true)
    }

    private func readOnlyBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(.system(size: 11))
            Text(reason)
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func caption(_ text: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(text)
                .scaledFont(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
