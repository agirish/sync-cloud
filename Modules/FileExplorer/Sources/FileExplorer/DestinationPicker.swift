import Design
import Events
import SwiftUI
import Sync

/// What the picker was asked to arrange, and for which items.
public struct DestinationRequest: Equatable, Sendable {
    /// Absolute paths of the items being filed.
    public let sourcePaths: [String]
    /// Display name of the first item, for the title.
    public let firstItemName: String
    /// True for a move, false for a copy — decides the verb throughout and whether the
    /// already-there refusal applies.
    public let isMove: Bool
    /// Provider root the picker is scoped to.
    public let providerRoot: String
    /// Provider's display name, for the browse header.
    public let providerName: String
    /// Folder the picker opens on — the folder the invoking list is showing, not the root.
    public let openAt: String

    public init(sourcePaths: [String], firstItemName: String, isMove: Bool,
                providerRoot: String, providerName: String, openAt: String) {
        self.sourcePaths = sourcePaths
        self.firstItemName = firstItemName
        self.isMove = isMove
        self.providerRoot = providerRoot
        self.providerName = providerName
        self.openAt = openAt
    }
}

/// A destination question in flight: what is being filed, plus what filing it means.
///
/// The action travels with the request rather than being switched on afterwards, so adding a caller
/// cannot forget to teach the sheet what its Move button does. `onOther` returns the system panel's
/// choice (nil when cancelled), which the host commits exactly as it would the picker's own — one
/// path through the transfer, whichever surface chose the folder.
///
/// Held by the window rather than by either surface that raises it: the Tidy rail and the Organize
/// workspace are siblings, and two sheets bound to two states would be two pickers to keep in step.
public struct PendingDestination: Identifiable {
    public let id = UUID()
    public let request: DestinationRequest
    public let onCommit: (String) -> Void
    public let onOther: () -> String?

    public init(request: DestinationRequest,
                onCommit: @escaping (String) -> Void,
                onOther: @escaping () -> String?) {
        self.request = request
        self.onCommit = onCommit
        self.onOther = onOther
    }
}

/// Choose a folder to move or copy items into.
///
/// The absolute half of the app's two destination verbs. Compare's cross-pane transfer is
/// *relational* — it puts each item where its counterpart belongs, derived from the item's own
/// position — and cannot express "that folder, the one I'm looking at". This can, and does nothing
/// else: it returns one folder for the whole selection.
///
/// A sheet rather than a popover because four columns and a recents list need the room, and because
/// a move deserves to be modal to the window it acts on.
public struct DestinationPicker: View {
    let request: DestinationRequest
    /// Recently used destinations for this provider, most recent first.
    let recents: [String]
    /// Whether the picker offers hidden folders, matching the pane's own setting.
    let showHidden: Bool
    /// Runs the transfer into the chosen folder.
    let onCommit: (String) -> Void
    /// Hands off to the system panel for a destination outside the provider.
    let onChooseOther: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    // The whole Appearance model, read the same way every other surface reads it, so the picker
    // follows Clear / Frosted / Solid, the hue, and the tint slider without a second opinion.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }
    /// Floored like every other chrome surface: the sheet sits over live app content, and a truly
    /// clear one would leave its own text competing with the panes behind it.
    private var glassLevel: GlassLevel {
        (GlassLevel(rawValue: glassLevelRaw) ?? .frosted).flooredForChrome
    }

    /// The size the sheet opens at, remembered between uses. Folder names run long and trees run
    /// deep; a picker that reset to one shape every time would be re-dragged every time.
    @AppStorage("destinationPickerWidth") private var storedWidth: Double = 640
    @AppStorage("destinationPickerHeight") private var storedHeight: Double = 520
    /// The live size, tracked in a reference box rather than `@State`.
    ///
    /// Writing a geometry reading back into view state is the layout loop this project has already
    /// paid for once. The box takes the value without invalidating anything, and `onDisappear`
    /// persists it — by which point no layout depends on the write.
    @State private var liveSize = SizeBox()

    /// Where the columns are, relative to the provider root.
    @State private var browsePath = PaneBrowsePath()
    /// The folder the footer names and Move commits to. Starts at `openAt`, then follows clicks.
    @State private var highlighted: String = ""
    @State private var query = ""
    @State private var matches: [DestinationFolder] = []
    /// Per-directory listings, filled by `loadListing`. Absent means "not asked yet"; the column
    /// renders a spinner until it lands.
    @State private var listings: [String: [DestinationFolder]] = [:]
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""

    public init(request: DestinationRequest, recents: [String], showHidden: Bool = false,
                onCommit: @escaping (String) -> Void,
                onChooseOther: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.request = request
        self.recents = recents
        self.showHidden = showHidden
        self.onCommit = onCommit
        self.onChooseOther = onChooseOther
        self.onCancel = onCancel
    }

    // MARK: - Derived

    private var root: String { PaneBrowsePath.normalized(request.providerRoot) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var columnDirectories: [String] { browsePath.columnDirectories(treeRoot: root) }

    /// Why Move is withheld, or nil when it is offered. One string so the footer has a single
    /// place to explain itself and the button cannot disagree with the reason beside it.
    private var refusal: String? {
        guard !highlighted.isEmpty else { return nil }
        if DestinationBrowser.destinationIsInsideSelection(highlighted, sources: request.sourcePaths) {
            let name = (request.sourcePaths.count == 1)
                ? "“\(request.firstItemName)”"
                : "one of the selected folders"
            return "That folder is inside \(name)."
        }
        if request.isMove, DestinationBrowser.allSourcesAlreadyIn(highlighted, sources: request.sourcePaths) {
            return request.sourcePaths.count == 1
                ? "“\(request.firstItemName)” is already there."
                : "All \(request.sourcePaths.count) items are already there."
        }
        return nil
    }

    private var canCommit: Bool { !highlighted.isEmpty && refusal == nil }
    private var verb: String { request.isMove ? "Move" : "Copy" }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.08))
            if isSearching { searchResults } else { browseColumns }
            Divider().overlay(Color.primary.opacity(0.08))
            footer
        }
        // Resizable: a floor that still fits two columns and the footer's buttons, an ideal taken
        // from last time, and no ceiling — the sheet's own grip does the rest.
        .frame(minWidth: 470, idealWidth: storedWidth, maxWidth: .infinity,
               minHeight: 400, idealHeight: storedHeight, maxHeight: .infinity)
        // The app's own two-part surface, in the app's own order: the accent wash from the Tint
        // slider, then the level's material behind it. `cornerRadius: 0` because the sheet window
        // already rounds and clips — a second radius here would leave the material's corners
        // floating inside the sheet's.
        .contentSurface(hue: glassHue, tint: surfaceTint)
        .glassSurface(glassLevel, cornerRadius: 0)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { liveSize.size = $0 }
        .onDisappear {
            guard liveSize.size.width > 0, liveSize.size.height > 0 else { return }
            storedWidth = liveSize.size.width
            storedHeight = liveSize.size.height
        }
        .onAppear {
            let opening = PaneBrowsePath.normalized(request.openAt)
            highlighted = opening.isEmpty ? root : opening
            browsePath = Self.browsePath(for: highlighted, under: root)
        }
        .task(id: columnDirectories) { await loadVisibleColumns() }
        .task(id: query) { await runSearch() }
        .alert("New folder in “\(displayName(of: highlighted))”", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create & \(verb.lowercased()) here") { createFolderAndCommit() }
                .disabled(FileSyncManager.validateItemName(newFolderName) != nil)
        } message: {
            Text(newFolderName.isEmpty
                 ? "It will be created inside “\(displayName(of: highlighted))”."
                 : ((highlighted as NSString).appendingPathComponent(newFolderName) as NSString)
                    .abbreviatingWithTildeInPath)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(verb) \(titleSubject) to…")
                .scaledFont(.system(size: 13.5, weight: .semibold))
                .lineLimit(2)
            Text(request.sourcePaths.count == 1
                 ? "1 item · from \(request.providerName)"
                 : "\(request.sourcePaths.count) items · from \(request.providerName)")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(.secondary)
            searchField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private var titleSubject: String {
        request.sourcePaths.count == 1 ? "“\(request.firstItemName)”" : "\(request.sourcePaths.count) items"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(isSearching ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            TextField("Search folders in \(request.providerName)", text: $query)
                .textFieldStyle(.plain)
            if isSearching {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").hoverInk()
                }
                .buttonStyle(.hoverAffordance(.inline, tint: accent))
                .accessibilityLabel("Clear search")
            }
        }
        .scaledFont(.system(size: 12))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        // The app's one search-field recipe, so this reads as the same control as the lens
        // headers' rather than a lookalike with its own radius and fill.
        .searchFieldSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSearching ? accent.opacity(0.55) : .clear, lineWidth: 1)
        )
    }

    // MARK: - Browse

    private var browseColumns: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columnDirectories.enumerated()), id: \.element) { depth, directory in
                        DestinationColumn(
                            directory: directory,
                            folders: listings[directory],
                            highlighted: highlighted,
                            onPathAt: { depth < browsePath.depth ? browsePath.components[depth] : nil }(),
                            accent: glassHue.accentColor,
                            onOpen: { folder in open(folder, atDepth: depth) }
                        )
                        .frame(width: 190)
                        .id(directory)
                        Divider().overlay(Color.primary.opacity(0.06))
                    }
                }
            }
            .onChange(of: columnDirectories) { _, dirs in
                guard let last = dirs.last else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Opens `folder` from the column at `depth`, which closes any columns beyond it — the same
    /// rule `PaneBrowsePath.drill` applies in the panes, reused rather than restated.
    private func open(_ folder: DestinationFolder, atDepth depth: Int) {
        var path = browsePath
        path.drill(into: folder.name, atDepth: depth)
        browsePath = path
        highlighted = folder.path
    }

    // MARK: - Search results

    private var searchResults: some View {
        let ranked = DestinationBrowser.ranked(matches, recents: recents, query: query, under: root)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if ranked.isEmpty {
                    Text("No folders match “\(query)”")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(ranked) { folder in
                        DestinationResultRow(
                            folder: folder,
                            trail: DestinationBrowser.trail(of: folder.path, under: root),
                            isHighlighted: folder.path == highlighted,
                            isRecent: recents.contains(folder.path),
                            accent: glassHue.accentColor
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = folder.path }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(SemanticColor.warning)
                    .lineLimit(2)
            }
            destinationCrumbs

            HStack(spacing: 7) {
                Spacer(minLength: 0)

                Button { newFolderName = ""; isCreatingFolder = true } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                // Gated on the same refusal as Move, not merely on having a folder chosen.
                // Otherwise you could create a folder inside the very folder you are moving and
                // then aim at it: the operation layer would refuse the move (nestingViolation), but
                // only after leaving a stray empty folder behind on disk.
                .disabled(!canCommit)
                .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                .keyboardShortcut("n", modifiers: [.shift, .command])

                Button("Other…") { onChooseOther(); dismiss() }
                    .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                    .help("Choose a folder outside \(request.providerName)")

                Button("Cancel", role: .cancel) { onCancel(); dismiss() }
                    .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                    .keyboardShortcut(.cancelAction)

                // The one filled capsule in the sheet, on the DEEPENED accent: the raw hue leaves
                // white sitting on the contrast floor, which is what `AccentFill` exists to fix.
                Button(verb) { onCommit(highlighted); dismiss() }
                    .buttonStyle(.actionBar(.primary,
                                            tint: AccentFill.deepened(accent),
                                            onTint: glassHue.onAccentLabelColor))
                    .disabled(!canCommit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .scaledFont(.system(size: 12))
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    /// The chosen folder as a breadcrumb, matching the pane headers rather than a raw path.
    ///
    /// A single truncated path line is what the first cut had, and head-truncation cut it
    /// mid-component — "…ocuments/Family/Ajji & Tata" reads as a broken string, not a location.
    /// Components let the leading ones drop out cleanly and keep the folder you actually chose,
    /// which is the end, always visible.
    private var destinationCrumbs: some View {
        let components = highlighted.isEmpty
            ? []
            : [request.providerName] + DestinationBrowser.trail(of: highlighted, under: root).dropFirst()
                                     + [(highlighted as NSString).lastPathComponent]
        return HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .scaledFont(.system(size: 10))
                .foregroundStyle(highlighted.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accent))
            if components.isEmpty {
                Text("No folder chosen").foregroundStyle(.secondary)
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Text("›").foregroundStyle(.tertiary)
                    }
                    Text(component)
                        .foregroundStyle(index == components.count - 1
                                         ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fontWeight(index == components.count - 1 ? .medium : .regular)
                        .lineLimit(1)
                        .layoutPriority(index == components.count - 1 ? 1 : 0)
                }
            }
            Spacer(minLength: 0)
        }
        .scaledFont(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(highlighted.isEmpty ? "No folder chosen" : "Destination \(highlighted)")
    }

    // MARK: - Loading

    /// Lists every open column that has not been listed yet.
    ///
    /// Off the main actor: a provider root can hold thousands of entries and iCloud placeholders
    /// make even a shallow listing a disk round-trip. Results land one column at a time so the
    /// leftmost appears immediately rather than the whole stack arriving together.
    private func loadVisibleColumns() async {
        for directory in columnDirectories where listings[directory] == nil {
            let showHidden = showHidden
            let folders = await Task.detached {
                DestinationBrowser.subfolders(of: directory, showHidden: showHidden, fileManager: FileManager.default)
            }.value
            guard !Task.isCancelled else { return }
            listings[directory] = folders
        }
    }

    private func runSearch() async {
        let needle = query
        guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else {
            matches = []
            return
        }
        // Debounced: typing a folder name fires this per keystroke, and each run is a bounded but
        // real directory walk. Cancellation alone is not enough — the walk is synchronous inside
        // the detached task, so the cheapest fix is not to start it.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let root = root
        let showHidden = showHidden
        let found = await Task.detached {
            DestinationBrowser.search(needle, under: root, showHidden: showHidden, fileManager: FileManager.default)
        }.value
        guard !Task.isCancelled else { return }
        matches = found
    }

    // MARK: - New folder

    private func createFolderAndCommit() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, FileSyncManager.validateItemName(name) == nil, !highlighted.isEmpty else { return }
        let created = (highlighted as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: created), withIntermediateDirectories: false
            )
        } catch {
            Logger.shared.warning("Could not create “\(name)” in \(highlighted): \(error.localizedDescription)")
            return
        }
        Logger.shared.info("Created “\(name)” from the destination picker")
        newFolderName = ""
        onCommit(created)
        dismiss()
    }

    // MARK: - Helpers

    private func displayName(of path: String) -> String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    /// The column stack that shows `path`, given the root it is under. Anything outside the root
    /// rests at the root, which is the only stack that can honestly be drawn for it.
    static func browsePath(for path: String, under root: String) -> PaneBrowsePath {
        let normalizedRoot = PaneBrowsePath.normalized(root)
        let normalized = PaneBrowsePath.normalized(path)
        guard normalized != normalizedRoot,
              normalized.hasPrefix(normalizedRoot + "/") else { return PaneBrowsePath() }
        return PaneBrowsePath(relativePath: String(normalized.dropFirst(normalizedRoot.count + 1)))
    }
}

// MARK: - Column

/// One column of folders. A separate view so the picker's body stays inside the type checker's
/// budget — the same reason the pane's own cells are split out.
private struct DestinationColumn: View {
    let directory: String
    /// `nil` until the listing lands, which is what the spinner distinguishes from a genuinely
    /// empty folder.
    let folders: [DestinationFolder]?
    let highlighted: String
    /// Name of the folder drilled through at this depth, marked as the trail.
    let onPathAt: String?
    let accent: Color
    let onOpen: (DestinationFolder) -> Void

    var body: some View {
        Group {
            if let folders {
                if folders.isEmpty {
                    Text("Empty")
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(folders) { folder in
                                row(folder)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ folder: DestinationFolder) -> some View {
        let isChosen = folder.path == highlighted
        let isTrail = folder.name == onPathAt && !isChosen
        // One click both chooses and opens, which is what makes a column stack a picker rather than
        // a tree: there is no separate "open" gesture to discover. A Button rather than a tap
        // gesture so it goes through `HoverAffordanceStyle` — the app's one hover choke point —
        // instead of growing a private hover of its own.
        return Button { onOpen(folder) } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(isChosen ? AnyShapeStyle(accent) : AnyShapeStyle(accent.opacity(0.75)))
                Text(folder.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .scaledFont(.system(size: 9))
            }
            .scaledFont(.system(size: 12))
            .foregroundStyle(isChosen ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
            .fontWeight(isChosen ? .medium : .regular)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isChosen: isChosen, isTrail: isTrail))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.inline, tint: accent))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func rowBackground(isChosen: Bool, isTrail: Bool) -> some View {
        if isChosen {
            // The panes' own selection strength, so a chosen row here reads exactly as a selected
            // row in the rail behind the sheet.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(PaneSelectionWash.active))
                .padding(.horizontal, 4)
        } else if isTrail {
            // Quieter than a selection: this row is the trail, not the target — the same
            // distinction `PaneColumnsView` draws.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(PaneSelectionWash.inactive * 0.6))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}

/// A reference cell for the sheet's live size.
///
/// Geometry readings written into `@State` re-enter layout, which is the loop this project has
/// already debugged once. A class instance held by `@State` takes the value without invalidating
/// anything, and the size is only read back at `onDisappear`.
final class SizeBox {
    var size: CGSize = .zero
}

// MARK: - Search result row

private struct DestinationResultRow: View {
    let folder: DestinationFolder
    let trail: [String]
    let isHighlighted: Bool
    let isRecent: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.85))
            Text(folder.name).scaledFont(.system(size: 12, weight: .medium))
            Text(trail.joined(separator: " › "))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            if isRecent {
                Text("Recent")
                    .scaledFont(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.14)))
            }
        }
        .foregroundStyle(isHighlighted ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? AnyShapeStyle(accent.opacity(0.16)) : AnyShapeStyle(Color.clear))
    }
}
