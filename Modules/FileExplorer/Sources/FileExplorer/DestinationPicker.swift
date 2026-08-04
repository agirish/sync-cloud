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
/// cannot forget to teach the card what its Move button does. `onOther` returns the system panel's
/// choice (nil when cancelled), which the host commits exactly as it would the picker's own — one
/// path through the transfer, whichever surface chose the folder.
///
/// Held by the window rather than by either surface that raises it: the Tidy rail and the Organize
/// workspace are siblings, and two cards bound to two states would be two pickers to keep in step.
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
/// **Built to the Settings panel's shape**, not invented: a fixed-height title row with the shared
/// `CloseButton`, a hairline, a washed left rail carrying search and shortcuts, a hairline, and the
/// content column. That layout is why Settings reads as part of the app, and restating it here is
/// cheaper — and more honest — than a lookalike with its own rhythm.
///
/// It is an in-window overlay, **not** a sheet. A sheet is its own window with an opaque backing, so
/// the app's materials composite onto that slab instead of onto live content and render flat. Glass
/// needs something behind it. The host supplies the scrim and the surface treatment, exactly as it
/// does for `settingsCard`.
public struct DestinationPicker: View {
    let request: DestinationRequest
    /// The space the host has, so the card can clamp itself rather than hang off the window edge.
    let availableSize: CGSize
    /// Recently used destinations for this provider, most recent first.
    let recents: [String]
    /// Whether the picker offers hidden folders, matching the pane's own setting.
    let showHidden: Bool
    /// Runs the transfer into the chosen folder.
    let onCommit: (String) -> Void
    /// Hands off to the system panel for a destination outside the provider.
    let onChooseOther: () -> Void
    let onCancel: () -> Void

    // The whole Appearance model, read the same way every other surface reads it, so the picker
    // follows Clear / Frosted / Solid, the hue and the tint without a second opinion.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }

    /// The size the card opens at, remembered between uses. Folder names run long and trees run
    /// deep; a picker that reset to one shape every time would be re-dragged every time.
    @AppStorage("destinationPickerWidth") private var storedWidth: Double = 860
    @AppStorage("destinationPickerHeight") private var storedHeight: Double = 620
    /// The size mid-drag, and the size the drag started from.
    ///
    /// The anchor is captured at drag start rather than read live: `DragGesture.translation` is
    /// cumulative from the start, so folding it into a size that already includes it compounds —
    /// the same trap `PaneViewMode.draggedColumnWidth` documents for the column seams.
    @State private var dragSize: CGSize?
    @State private var dragAnchor: CGSize?

    /// Where the columns are, relative to the provider root.
    @State private var browsePath = PaneBrowsePath()
    /// The folder the footer names and Move commits to. Starts at `openAt`, then follows clicks.
    @State private var highlighted: String = ""
    @State private var query = ""
    @State private var matches: [DestinationFolder] = []
    /// Whether a walk is in flight. Distinguishes "still looking" from "looked, found nothing" —
    /// the same distinction the columns draw with their spinner. Without it the results pane
    /// asserted "No folders match" from the first keystroke, before anything had been read.
    @State private var isSearchRunning = false
    /// Whether the last walk stopped early (match limit, listing budget, or depth ceiling). The
    /// results list says so rather than presenting a partial answer as the whole one.
    @State private var isSearchTruncated = false
    /// Per-directory listings. Absent means "not asked yet"; the column shows a spinner until it
    /// lands, which is what distinguishes loading from a genuinely empty folder.
    @State private var listings: [String: [DestinationFolder]] = [:]
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    /// Names among the selection that already exist in the highlighted folder. Recomputed whenever
    /// the destination moves, so the count is never stale against the folder the footer names.
    @State private var collidingNames: [String] = []

    public init(request: DestinationRequest, availableSize: CGSize, recents: [String],
                showHidden: Bool = false,
                onCommit: @escaping (String) -> Void,
                onChooseOther: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.request = request
        self.availableSize = availableSize
        self.recents = recents
        self.showHidden = showHidden
        self.onCommit = onCommit
        self.onChooseOther = onChooseOther
        self.onCancel = onCancel
    }

    // MARK: - Metrics
    //
    // Settings' shape, one notch roomier. Its 44pt header carries a single line; this one carries a
    // title and a subtitle, and at 44 the two sat on top of each other. The rail is wider than
    // Settings' 176 because its rows are folder names rather than six fixed words, and the column
    // width is `PaneViewMode.defaultColumnWidth` verbatim — the panes' own, so a column here and a
    // column behind the card are the same object.

    private static let headerHeight: CGFloat = 62
    private static let railWidth: CGFloat = 196
    static let minSize = CGSize(width: 620, height: 460)
    /// Matches `SettingsSheetMetrics.hostMargin`'s intent: always leave the scrim visible on every
    /// side, so the card reads as floating over the window rather than replacing it.
    private static let hostMargin: CGFloat = 80

    private var maxSize: CGSize {
        CGSize(width: max(Self.minSize.width, availableSize.width - Self.hostMargin),
               height: max(Self.minSize.height, availableSize.height - Self.hostMargin))
    }
    private var cardSize: CGSize {
        let wanted = dragSize ?? CGSize(width: storedWidth, height: storedHeight)
        return CGSize(width: min(max(wanted.width, Self.minSize.width), maxSize.width),
                      height: min(max(wanted.height, Self.minSize.height), maxSize.height))
    }

    // MARK: - Derived

    private var root: String { PaneBrowsePath.normalized(request.providerRoot) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var columnDirectories: [String] { browsePath.columnDirectories(treeRoot: root) }

    /// Why Move is withheld, or nil when it is offered. One string so the footer has a single place
    /// to explain itself and the button cannot disagree with the reason beside it.
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

    /// What a Copy into the items' own folder will actually do, or nil when that is not the case.
    ///
    /// **Not** a refusal, deliberately: duplicating a file in place is a real thing to want, and the
    /// transfer supports it — `generateUniqueURL` appends " 2". But nothing said so. The move gets a
    /// refusal here because a move onto itself genuinely does nothing; a copy onto itself does
    /// something, just not the thing "Copy to this folder" sounds like. Naming the duplicate is the
    /// difference between a surprising outcome and an intended one.
    private var duplicateNotice: String? {
        guard !request.isMove, !highlighted.isEmpty,
              DestinationBrowser.allSourcesAlreadyIn(highlighted, sources: request.sourcePaths)
        else { return nil }
        if request.sourcePaths.count == 1 {
            let name = request.firstItemName
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let copy = ext.isEmpty ? "\(stem) 2" : "\(stem) 2.\(ext)"
            return "“\(name)” is already here — copying will make “\(copy)”."
        }
        return "All \(request.sourcePaths.count) items are already here — copying will make numbered duplicates."
    }

    private var canCommit: Bool { !highlighted.isEmpty && refusal == nil }
    private var verb: String { request.isMove ? "Move" : "Copy" }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                shortcutsRail
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footerBar
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // The grip rides inside the card's own corner; out on the scrim there is nothing to grab.
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // No background here — the host wraps this in `contentSurface` + `glassCardStyle`, exactly
        // as it wraps the Settings card. A background applied in here would sit on top of the
        // material and flatten it back out.
        .onAppear {
            let opening = PaneBrowsePath.normalized(request.openAt)
            highlighted = opening.isEmpty ? root : opening
            browsePath = Self.browsePath(for: highlighted, under: root)
        }
        .task(id: columnDirectories) { await loadVisibleColumns() }
        .task(id: query) { await runSearch() }
        .task(id: highlighted) { await refreshCollisions() }
        .alert("New folder in “\(displayName(of: highlighted))”", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create & \(verb.lowercased()) here") { createFolderAndCommit() }
                .disabled(FileSyncManager.validateItemName(newFolderName) != nil)
        } message: {
            Text("It will be created inside “\(displayName(of: highlighted))”.")
        }
    }

    // MARK: - Title bar

    /// Settings' header, verbatim in shape: a headline, a spacer, the shared `CloseButton`, at a
    /// fixed height rather than a padding-derived one.
    private var titleBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(verb) \(titleSubject) to…")
                    .scaledFont(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(request.sourcePaths.count == 1
                     ? "1 item · from \(request.providerName)"
                     : "\(request.sourcePaths.count) items · from \(request.providerName)")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CloseButton(action: onCancel)
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc", alignment: .center)
                .help(ShortcutHint.tooltip("Cancel", "esc"))
        }
        .padding(.horizontal, 20)
        .frame(height: Self.headerHeight)
    }

    private var titleSubject: String {
        request.sourcePaths.count == 1 ? "“\(request.firstItemName)”" : "\(request.sourcePaths.count) items"
    }

    // MARK: - Rail

    /// Search and shortcuts stand down the left, exactly as Settings' tabs do — same width, same
    /// `Color.primary.opacity(0.035)` wash, same selected-row treatment. It also fixes a layout
    /// problem the first cut had: recents dangling under the columns, competing with them for the
    /// same vertical run.
    private var shortcutsRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)

            railSectionLabel("Places")
            railRow(name: request.providerName, path: root, symbol: "externaldrive.connected.to.line.below")

            if !recents.isEmpty {
                railSectionLabel("Recent")
                ForEach(recents, id: \.self) { path in
                    railRow(name: (path as NSString).lastPathComponent, path: path, symbol: "clock.arrow.circlepath")
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    private func railSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 3)
    }

    /// One rail row. Selected rows take the hue's `accentFillColor` with `onAccentLabelColor` on
    /// top — the accent-fill model, not a wash of the accent over itself, which paints nothing.
    private func railRow(name: String, path: String, symbol: String) -> some View {
        let isSelected = PaneBrowsePath.normalized(path) == highlighted && !isSearching
        return Button {
            query = ""
            highlighted = PaneBrowsePath.normalized(path)
            browsePath = Self.browsePath(for: highlighted, under: root)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).scaledFont(.system(size: 11))
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .scaledFont(.system(size: 12))
            .foregroundStyle(isSelected ? AnyShapeStyle(glassHue.onAccentLabelColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(glassHue.accentFillColor)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment,
                                      tint: isSelected ? glassHue.onAccentLabelColor : accent))
        .padding(.horizontal, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isSearching ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            TextField("Search", text: $query)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearching { searchResults } else { browseColumns }
    }

    private var browseColumns: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columnDirectories.enumerated()), id: \.element) { depth, directory in
                        // Column and its divider travel as ONE scroll target. Left as siblings, the
                        // dividers become targets too and the stack can rest a hairline against the
                        // edge; grouped, every resting position is a column boundary.
                        HStack(spacing: 0) {
                            DestinationColumn(
                                directory: directory,
                                folders: listings[directory],
                                highlighted: highlighted,
                                onPathAt: depth < browsePath.depth ? browsePath.components[depth] : nil,
                                accent: accent,
                                onOpen: { folder in open(folder, atDepth: depth) }
                            )
                            .frame(width: PaneViewMode.defaultColumnWidth)
                            Divider()
                        }
                        .id(directory)
                    }
                }
                .scrollTargetLayout()
            }
            // Snap to column boundaries. Without this the stack rests wherever the scroll-to-
            // trailing left it, which for a card narrower than its columns means a half-column at
            // the leading edge with every folder name sliced down its middle.
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: columnDirectories) { _, dirs in
                guard let last = dirs.last else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Opens `folder` from the column at `depth`, closing any columns beyond it — the same rule
    /// `PaneBrowsePath.drill` applies in the panes, reused rather than restated.
    private func open(_ folder: DestinationFolder, atDepth depth: Int) {
        var path = browsePath
        path.drill(into: folder.name, atDepth: depth)
        browsePath = path
        highlighted = folder.path
    }

    private var searchResults: some View {
        let ranked = DestinationBrowser.ranked(matches, recents: recents, query: query, under: root)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if ranked.isEmpty {
                    // Only claim there is nothing once the walk has actually finished. Saying it
                    // while still reading directories is a wrong answer that then corrects itself.
                    if isSearchRunning {
                        ProgressView().controlSize(.small).padding(20)
                    } else {
                        // A truncated walk that found nothing has NOT established that nothing
                        // matches — it stopped looking. Saying "no folders match" there is a claim
                        // the search never earned.
                        Text(isSearchTruncated
                             ? "No matches in the folders searched — “\(query)” may be deeper in, or further afield."
                             : "No folders match “\(query)”")
                            .scaledFont(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                } else {
                    ForEach(ranked) { folder in
                        DestinationResultRow(
                            folder: folder,
                            trail: DestinationBrowser.trail(of: folder.path, under: root),
                            isHighlighted: folder.path == highlighted,
                            isRecent: recents.contains(folder.path),
                            accent: accent,
                            onAccent: glassHue.onAccentLabelColor,
                            accentFill: glassHue.accentFillColor,
                            onTap: { highlighted = folder.path }
                        )
                    }
                    // The search is bounded three ways and every one of them stops it early. Say
                    // so, rather than letting a partial list read as the complete one — the folder
                    // the user wants may simply not be in it.
                    if isSearchTruncated {
                        Label("Showing the first \(ranked.count) — narrow the search, or browse to it.",
                              systemImage: "ellipsis.circle")
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 22)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A refusal and a collision preview are never both worth saying: a refusal means the
            // move cannot happen, which makes what it would have collided with beside the point.
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(SemanticColor.warning)
                    .lineLimit(2)
            } else if let duplicateNotice {
                // Ahead of the collision preview: the items are already here, so the only names
                // they can collide with are their own, and "you'll be asked what to do" would be
                // wrong — nothing prompts, a numbered duplicate is simply made.
                Label(duplicateNotice, systemImage: "plus.square.on.square")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !collidingNames.isEmpty {
                Label(collisionSummary, systemImage: "doc.on.doc")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(collidingNames.joined(separator: ", "))
            }
            HStack(spacing: 8) {
                destinationCrumbs
                Spacer(minLength: 20)

                Button { newFolderName = ""; isCreatingFolder = true } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                // Gated on the same refusal as Move, not merely on having a folder chosen.
                // Otherwise you could create a folder inside the very folder you are moving and
                // then aim at it: the operation layer refuses that move, but only after leaving a
                // stray empty folder behind on disk.
                .disabled(!canCommit)
                .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                .keyboardShortcut("n", modifiers: [.shift, .command])
                .shortcutKeycap("⇧⌘N")

                Button("Other…") { onChooseOther() }
                    .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                    .help("Choose a folder outside \(request.providerName)")

                // The one filled capsule on the card, on the DEEPENED accent: the raw hue leaves
                // white sitting on the contrast floor, which is what `AccentFill` exists to fix.
                Button(verb) { onCommit(highlighted) }
                    .buttonStyle(.actionBar(.primary,
                                            tint: AccentFill.deepened(accent),
                                            onTint: glassHue.onAccentLabelColor))
                    .disabled(!canCommit)
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("⏎", surface: .accentFill)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.035))
    }

    /// What the collision preview says. Names the file when there is one, because the name is the
    /// whole question; counts when there are several, because a list of five would push the buttons
    /// off the row. The full list is the tooltip either way.
    ///
    /// "Conflicts", not "already exists": a name can collide because the destination holds it OR
    /// because two selected items share it and land on the same flat target. Both end in the same
    /// prompt, and one line that names the outcome covers both without asserting a cause that is
    /// only half the time true.
    private var collisionSummary: String {
        let folder = displayName(of: highlighted)
        if collidingNames.count == 1 {
            return "“\(collidingNames[0])” conflicts in \(folder) — you'll be asked what to do."
        }
        return "\(collidingNames.count) of \(request.sourcePaths.count) names conflict in \(folder) — you'll be asked about each."
    }

    /// The chosen folder as a breadcrumb, matching the pane headers rather than a raw path.
    ///
    /// A single truncated path line was the first cut, and head-truncation cut it mid-component —
    /// "…ocuments/Family/Ajji & Tata" reads as a broken string, not a location. Components let the
    /// leading ones drop cleanly and keep the folder you actually chose, which is the end.
    private var destinationCrumbs: some View {
        let components = DestinationBrowser.crumbs(for: highlighted, under: root,
                                                   providerName: request.providerName)
        return HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .scaledFont(.system(size: 10))
                .foregroundStyle(highlighted.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accent))
            if components.isEmpty {
                Text("No folder chosen").foregroundStyle(.secondary)
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 { Text("›").foregroundStyle(.tertiary) }
                    Text(component)
                        .foregroundStyle(index == components.count - 1
                                         ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .fontWeight(index == components.count - 1 ? .medium : .regular)
                        .lineLimit(1)
                        .layoutPriority(index == components.count - 1 ? 1 : 0)
                }
            }
        }
        .scaledFont(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(highlighted.isEmpty ? "No folder chosen" : "Destination \(highlighted)")
    }

    /// The corner grip. Reads a FIXED coordinate space (`.global`) for the same reason
    /// `ResizeHandle` requires one: the grip moves as the card grows, so in its own space the
    /// gesture's values feed back on themselves and the drag stutters toward zero.
    private var resizeGrip: some View {
        Image(systemName: "line.diagonal")
            .scaledFont(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 16)
            .padding(4)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let anchor = dragAnchor ?? cardSize
                        if dragAnchor == nil { dragAnchor = anchor }
                        dragSize = CGSize(width: anchor.width + value.translation.width,
                                          height: anchor.height + value.translation.height)
                    }
                    .onEnded { _ in
                        // Persist the CLAMPED size, not the raw drag: releasing past the ceiling
                        // would otherwise store a size the card can never open at.
                        storedWidth = cardSize.width
                        storedHeight = cardSize.height
                        dragAnchor = nil
                        dragSize = nil
                    }
            )
            .accessibilityLabel("Resize")
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

    /// Restats the selection against the highlighted folder.
    ///
    /// One `fileExists` per selected item, off the main actor like the listings — cheap for a
    /// handful, and the picker's whole selection is a handful by construction. Clearing first
    /// matters: without it the previous folder's count would sit under the new folder's name for
    /// as long as the stat took, which is exactly long enough to be read.
    private func refreshCollisions() async {
        collidingNames = []
        let destination = highlighted
        guard !destination.isEmpty else { return }
        let sources = request.sourcePaths
        let found = await Task.detached {
            DestinationBrowser.collidingNames(movingFrom: sources, into: destination,
                                              fileManager: FileManager.default)
        }.value
        guard !Task.isCancelled else { return }
        collidingNames = found
    }

    private func runSearch() async {
        let needle = query
        guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else {
            matches = []
            isSearchRunning = false
            return
        }
        // Debounced: typing a folder name fires this per keystroke, and each run is a bounded but
        // real directory walk, so the cheapest saving is not to start most of them.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        isSearchRunning = true
        defer { isSearchRunning = false }
        let root = root
        let showHidden = showHidden
        // `Task.detached` does NOT inherit cancellation, so a superseded keystroke's walk would
        // otherwise run to completion behind the one the user is waiting on — six keystrokes into a
        // folder name, six full walks of the provider, all but one discarded. Bridging this task's
        // cancellation into the detached one, and polling it per directory inside `search`, is what
        // makes typing cost one walk rather than one per character.
        let work = Task.detached {
            DestinationBrowser.search(needle, under: root, showHidden: showHidden,
                                      fileManager: FileManager.default,
                                      isCancelled: { Task.isCancelled })
        }
        let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        matches = found.matches
        isSearchTruncated = found.isTruncated
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
/// budget — the same reason the panes' own cells are split out.
private struct DestinationColumn: View {
    let directory: String
    /// `nil` until the listing lands, which is what the spinner distinguishes from an empty folder.
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
                        LazyVStack(spacing: 2) {
                            ForEach(folders) { folder in row(folder) }
                        }
                        .padding(.vertical, 8)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(isChosen: isChosen, isTrail: isTrail))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .padding(.horizontal, 8)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func rowBackground(isChosen: Bool, isTrail: Bool) -> some View {
        if isChosen {
            // The panes' own selection strength, so a chosen row here reads exactly as a selected
            // row in the rail behind the card.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(PaneSelectionWash.active))
        } else if isTrail {
            // Quieter than a selection: this row is the trail, not the target — the same
            // distinction `PaneColumnsView` draws.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(PaneSelectionWash.inactive * 0.6))
        } else {
            Color.clear
        }
    }
}

// MARK: - Search result row

private struct DestinationResultRow: View {
    let folder: DestinationFolder
    let trail: [String]
    let isHighlighted: Bool
    let isRecent: Bool
    let accent: Color
    let onAccent: Color
    let accentFill: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(onAccent) : AnyShapeStyle(accent.opacity(0.75)))
                Text(folder.name).scaledFont(.system(size: 12, weight: .medium))
                Text(trail.joined(separator: " › "))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(onAccent.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if isRecent {
                    Text("Recent")
                        .scaledFont(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(isHighlighted ? onAccent : accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((isHighlighted ? onAccent : accent).opacity(0.16)))
                }
            }
            .foregroundStyle(isHighlighted ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accentFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.hoverAffordance(isHighlighted ? .filled : .segment,
                                      tint: isHighlighted ? onAccent : accent))
        .padding(.horizontal, 12)
    }
}
