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
    /// True for a move, false for a copy: decides the verb throughout and whether the
    /// already-there refusal applies.
    public let isMove: Bool
    /// Provider root the picker is scoped to.
    public let providerRoot: String
    /// Provider's display name, for the browse header.
    public let providerName: String
    /// Folder the picker opens on: the folder the invoking list is showing, not the root.
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
/// The action travels with the request, so a new caller can't forget to teach the card what Move
/// does. `onOther` returns the system panel's choice (nil when cancelled), which the host commits
/// exactly as it would the picker's own: one path through the transfer.
///
/// Held by the window, not by the single-source rail or Organize that raise it: they are
/// siblings, and two cards bound to two states would be two pickers to keep in step.
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

/// The one outline every selectable row in this picker draws: the rail row, a column row, and a
/// search result row. Each uses it for the ground it fills when chosen, its hit area, and the
/// shape it hands `HoverAffordanceStyle`. **Never leave the hover shape unset:** the hover style
/// and `.filled` default to a capsule, which would trace a pill around the rounded-rect ground.
/// One shared value means a ground can't disagree with the affordance over it. See
/// `HoverAffordanceOutline`.
enum DestinationRowShape {
    /// The value handed to `.hoverAffordance(_:tint:shape:)`.
    static let kind = HoverAffordanceShape.roundedRect(Radius.chip)
    /// The same shape, drawable, for the `.background` a chosen row fills and the `.contentShape`
    /// it declares. Derived from `kind` so the two can't drift.
    static let outline = kind.outline
}

/// Choose a folder to move or copy items into.
///
/// The absolute half of the app's two destination verbs. Compare's cross-pane transfer is
/// relational (each item goes where its counterpart belongs) and can't say "that folder, the one
/// I'm looking at". This can, and does nothing else: it returns one folder for the whole selection.
///
/// Built to the Settings panel's shape: a fixed-height title row with the shared `CloseButton`, a
/// hairline, a washed left rail carrying search and shortcuts, a hairline, and the content.
///
/// An in-window overlay, **not** a sheet: a sheet is its own opaque window, so the app's materials
/// would composite onto that slab and render flat. The host supplies the scrim and the surface
/// treatment, as it does for `settingsCard`.
public struct DestinationPicker: View {
    let request: DestinationRequest
    /// The space the host has, so the card can clamp itself rather than hang off the window edge.
    let availableSize: CGSize
    /// Recently used destinations for this provider, most recent first.
    let recents: [String]
    /// The window sidebar's own lists — Favorites, Locations, Recents — in its order, snapshotted
    /// by the host when the card is raised. This module cannot read the sidebar's stores itself.
    let places: [DestinationPlaceSection]
    /// Whether the picker offers hidden folders, matching the pane's own setting.
    let showHidden: Bool
    /// Runs the transfer into the chosen folder.
    let onCommit: (String) -> Void
    /// Hands off to the system panel for a destination outside the provider.
    let onChooseOther: () -> Void
    let onCancel: () -> Void
    /// A folder the picker's New Folder made, told the moment it exists, whatever happens to the
    /// transfer after it. A declined transfer refreshes no pane, so without this the new folder
    /// would go unlisted.
    let onFolderCreated: (String) -> Void

    // The whole Appearance model, read the same way every other surface reads it, so the picker
    // follows Clear / Frosted / Solid, the hue and the tint without a second opinion.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var accent: Color { glassHue.accentColor }

    /// The size the card opens at, remembered between uses: folder names run long and trees run
    /// deep, so a card that reset each time would be re-dragged each time.
    @AppStorage("destinationPickerWidth") private var storedWidth: Double = 1000
    @AppStorage("destinationPickerHeight") private var storedHeight: Double = 620
    /// The size mid-drag, and the size the drag started from. The anchor is captured at drag start:
    /// `DragGesture.translation` is cumulative, so adding it to a live size compounds (the trap
    /// `PaneViewMode.draggedColumnWidth` documents).
    @State private var dragSize: CGSize?
    @State private var dragAnchor: CGSize?

    /// Where the columns are, relative to `browseRoot`.
    @State private var browsePath = PaneBrowsePath()
    /// The source the columns browse. The request's provider until a place from another source is
    /// picked from the sidebar lists, which re-roots the columns there.
    @State private var browseRoot: String
    @State private var browseRootName: String
    /// The folder the footer names and Move commits to. Empty until one is picked: the card opens on
    /// the item's own folder (`openAt`), which is where it is, not where it goes.
    @State private var highlighted: String
    @State private var query = ""
    /// The last completed walk, kept whole: the two ways a result list can fall short word the
    /// pane's message differently, and both live on this value.
    @State private var searchOutcome: DestinationSearchOutcome = .empty
    private var matches: [DestinationFolder] { searchOutcome.matches }
    /// Whether a walk is in flight, so the results pane can tell "still looking" from "found
    /// nothing", as the columns do with their spinner.
    @State private var isSearchRunning = false
    /// Per-directory listings. Absent means "not asked yet", and the column shows a spinner; the
    /// listing's own outcome tells an empty folder from an unreadable one.
    @State private var listings: [String: DestinationFolderListing] = [:]
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    /// Names among the selection that already exist in the highlighted folder, recomputed whenever
    /// the destination moves so the count matches the folder the footer names.
    @State private var collidingNames: [String] = []
    /// Why the last folder the picker tried to make was not made, until the pick changes, so a
    /// failed Create and Move doesn't leave Move looking dead.
    @State private var failure: String?

    public init(request: DestinationRequest, availableSize: CGSize, recents: [String],
                places: [DestinationPlaceSection] = [],
                showHidden: Bool = false,
                onCommit: @escaping (String) -> Void,
                onChooseOther: @escaping () -> Void,
                onCancel: @escaping () -> Void,
                onFolderCreated: @escaping (String) -> Void = { _ in }) {
        self.onFolderCreated = onFolderCreated
        self.request = request
        self.availableSize = availableSize
        self.recents = recents
        self.places = places
        self.showHidden = showHidden
        self.onCommit = onCommit
        self.onChooseOther = onChooseOther
        self.onCancel = onCancel
        // Seeded here, not in `onAppear`: state set once the card is on screen is a change, and
        // the columns would open on the root and then jump.
        let root = PaneBrowsePath.normalized(request.providerRoot)
        _browseRoot = State(initialValue: root)
        _browseRootName = State(initialValue: request.providerName)
        _highlighted = State(initialValue: "")
        _browsePath = State(initialValue: Self.browsePath(for: Self.itemFolder(of: request), under: root))
    }

    /// The folder the items are in — where the card opens, and what the Here rows climb from.
    static func itemFolder(of request: DestinationRequest) -> String {
        let opening = PaneBrowsePath.normalized(request.openAt)
        return opening.isEmpty ? PaneBrowsePath.normalized(request.providerRoot) : opening
    }

    // MARK: - Metrics
    //
    // Settings' shape, one notch roomier: the header carries a title and a subtitle, and the rail's
    // rows are folder names. The column width is `PaneViewMode.defaultColumnWidth`, the panes' own,
    // so a column here matches one behind the card.

    private static let headerHeight: CGFloat = 62
    private static let railWidth: CGFloat = 220
    /// The preview on the right: what is in the picked folder and where the item will land.
    private static let previewWidth: CGFloat = 240
    static let minSize = CGSize(width: 780, height: 480)
    /// As `SettingsSheetMetrics.hostMargin`: the scrim stays visible on every side, so the card
    /// floats over the window rather than replacing it.
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

    /// The root the columns browse. See `browseRoot`.
    private var root: String { browseRoot }
    /// The request's own provider root, which the Here rows and the recents belong to whatever the
    /// columns are browsing.
    private var requestRoot: String { PaneBrowsePath.normalized(request.providerRoot) }
    private var itemFolder: String { Self.itemFolder(of: request) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var columnDirectories: [String] { browsePath.columnDirectories(treeRoot: root) }

    /// Whether the items are in the folder the card opened on. Not always: Organize's To File opens
    /// on its File Into root for a loose file in Downloads, and a selection can span folders; then
    /// nothing may say "now here".
    private var itemsAreHere: Bool {
        DestinationBrowser.allSourcesAlreadyIn(itemFolder, sources: request.sourcePaths)
    }

    private var hereRows: [DestinationPlace] {
        Self.hereRows(itemFolder: itemFolder, root: requestRoot, rootName: request.providerName,
                      itemsAreHere: itemsAreHere)
    }

    /// The moves recorded for this provider, less any folder the Here rows or the suggestion
    /// already show: one row per folder, or the rail's highlight has two places to sit.
    private var recentMoves: [String] {
        let shown = Set(hereRows.map(\.path) + [suggestion?.path].compactMap { $0 })
        return recents.map { canonical($0, under: requestRoot) }.filter { !shown.contains($0) }
    }

    /// The sidebar's lists, less anything already in the rail above them.
    private var placeSections: [DestinationPlaceSection] {
        DestinationPlaceSection.deduplicated(
            places, excluding: Set(hereRows.map(\.path) + recentMoves + [suggestion?.path].compactMap { $0 }))
    }

    /// The year folder the item's neighbours imply, or nil: the only suggestion offered, and only
    /// when the pattern is plain (`DestinationSuggestions.yearFolder`). Reads the item's folder's
    /// listing, which is loaded from the moment the card opens.
    private var suggestion: DestinationSuggestion? {
        guard itemsAreHere, let siblings = listings[itemFolder]?.folders.map(\.name) else { return nil }
        return DestinationSuggestions.yearFolder(for: request.sourcePaths, in: itemFolder, siblingFolders: siblings)
    }

    /// The pick is a suggested folder that does not exist yet: Move makes it first.
    private var picksNewFolder: Bool { Self.picksNewFolder(highlighted: highlighted, suggestion: suggestion) }

    nonisolated static func picksNewFolder(highlighted: String, suggestion: DestinationSuggestion?) -> Bool {
        guard let suggestion, suggestion.isNew, !highlighted.isEmpty else { return false }
        return suggestion.path == highlighted
    }

    /// Where New Folder makes its folder: inside the pick, or beside the item when nothing is
    /// picked yet ("new folder here, and move into it").
    private var newFolderParent: String { highlighted.isEmpty ? itemFolder : highlighted }

    /// Why Move is withheld, or nil when it is offered. One string so the footer has a single place
    /// to explain itself and the button cannot disagree with the reason beside it.
    private var refusal: String? {
        Self.refusal(highlighted: highlighted, picksNewFolder: picksNewFolder, request: request,
                     displayName: displayName(of:))
    }

    /// `refusal`, pure but for one `fileExists`, so the rule can be asserted without the card.
    nonisolated static func refusal(highlighted: String, picksNewFolder: Bool, request: DestinationRequest,
                                    displayName: (String) -> String) -> String? {
        guard !highlighted.isEmpty else { return nil }
        // A new folder's name taken by a file: the listing shows folders only, so the suggestion
        // reads the year as free, and Move would aim the transfer at that file.
        if picksNewFolder {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: highlighted, isDirectory: &isDirectory), !isDirectory.boolValue {
                return "A file named “\(displayName(highlighted))” is already there."
            }
        }
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
    /// Not a refusal: duplicating in place is a real thing to want, and the transfer appends " 2".
    /// A move onto itself does nothing and is refused; a copy does something, so this names it.
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
                Divider()
                previewPane
            }
            Divider()
            footerBar
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // The grip rides inside the card's own corner; on the scrim there is nothing to grab.
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // No background here: the host wraps this in `contentSurface` + `glassCardStyle`, as it
        // wraps the Settings card, and a background in here would flatten the material.
        .task(id: columnDirectories) { await loadVisibleColumns() }
        .task(id: query) { await runSearch() }
        // The pick's own listing, which the preview reads, on its own task: a folder picked from
        // search or the rail may be one no column asked for. Sharing the columns' task would
        // restart their loads on every click.
        .task(id: highlighted) {
            failure = nil
            if !highlighted.isEmpty, !picksNewFolder { await load([highlighted]) }
            await refreshCollisions()
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create & \(verb) Here") { createFolderAndCommit() }
                .disabled(FileSyncManager.validateItemName(newFolderName) != nil)
                .lockedDuringRun()
        } message: {
            Text("It will be created inside “\(displayName(of: newFolderParent))”.")
        }
    }

    // MARK: - Title bar

    /// Settings' header in shape: a headline, a spacer, the shared `CloseButton`, at a fixed
    /// height rather than a padding-derived one.
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
                .shortcutKeycap("esc")
                .help(ShortcutHint.tooltip("Cancel", "esc"))
                // "Cancel", not "Close": this dismisses a pending pick without making it, as the
                // tooltip says.
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 20)
        .frame(height: Self.headerHeight)
    }

    private var titleSubject: String {
        request.sourcePaths.count == 1 ? "“\(request.firstItemName)”" : "\(request.sourcePaths.count) items"
    }

    // MARK: - Rail

    /// Search and shortcuts down the left, as Settings' tabs are: the same
    /// `Color.primary.opacity(0.035)` wash and selected-row treatment.
    ///
    /// Here first: the folders the item sits in (now here, up one, up two) lead, because most moves
    /// are short, ending with the source's root. Then the Suggested folder, if any; then recent
    /// moves; then the window sidebar's Favorites, Locations and Recents, so every place the window
    /// offers is a place a move can go.
    private var shortcutsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    railSectionLabel(itemsAreHere ? "Here" : "Places")
                    ForEach(hereRows) { place in
                        if place.path == itemFolder && itemsAreHere && request.isMove {
                            // Back to where the card opened, with nothing picked: the items' own
                            // folder is never a move's destination. A copy may go there (it makes
                            // numbered duplicates), so for a copy it is an ordinary pick.
                            railRow(name: place.name, path: place.path, symbol: place.symbol,
                                    detail: place.detail, action: returnToItemFolder)
                        } else {
                            railRow(name: place.name, path: place.path, symbol: place.symbol,
                                    detail: place.detail) { pick(place) }
                        }
                    }

                    if let suggestion {
                        railSectionLabel("Suggested")
                        railRow(name: suggestion.name, path: suggestion.path,
                                symbol: suggestion.isNew ? "folder.badge.plus" : "folder",
                                detail: suggestion.reason) { pickSuggestion(suggestion) }
                    }

                    let moves = recentMoves
                    if !moves.isEmpty {
                        railSectionLabel("Recent Moves")
                        ForEach(moves, id: \.self) { path in
                            railRow(name: (path as NSString).lastPathComponent, path: path, symbol: "clock.arrow.circlepath",
                                    detail: Self.recentDetail(for: path, among: moves, under: requestRoot,
                                                              rootName: request.providerName)) {
                                pick(DestinationPlace(name: (path as NSString).lastPathComponent, path: path,
                                                      root: requestRoot, rootName: request.providerName))
                            }
                        }
                    }

                    ForEach(placeSections) { section in
                        railSectionLabel(section.title)
                        ForEach(section.places) { place in
                            railRow(name: place.name, path: place.path, symbol: place.symbol,
                                    detail: place.detail) { pick(place) }
                        }
                    }
                }
                .padding(.bottom, 12)
                // Frosted and Clear: the highlighted row's fill as one glass lens that glides between
                // rows, as in the Settings rail. None while searching, or when the columns have
                // browsed below every row here. On the scroll view's content, as the sidebar's lenses
                // are, so the lens scrolls with its row instead of floating over the search field.
                .selectionLensHost(Self.railLensChannel, selected: isSearching ? nil : railFocus,
                                   style: .fill(DestinationRowShape.kind, color: glassHue.accentFillColor),
                                   visibleRegion: railVisibleRegion)
            }
            .selectionLensTracksVisibleRegion(railVisibleRegion)
        }
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.035))
    }

    /// The rail row drawn as chosen: the pick, or before there is one the item's own folder (the
    /// "now here" row), so the rail says where you are while the footer says "Now in".
    private var railFocus: String {
        Self.railFocus(highlighted: highlighted, itemFolder: itemFolder, itemsAreHere: itemsAreHere)
    }

    nonisolated static func railFocus(highlighted: String, itemFolder: String, itemsAreHere: Bool) -> String {
        highlighted.isEmpty ? (itemsAreHere ? itemFolder : "") : highlighted
    }

    /// The column area's width, for `scrollToLastColumns`. Zero until first measured.
    @State private var columnsWidth: CGFloat = 0

    /// What of the rail is on screen, for the lens. See `SelectionLensVisibleRegion`.
    @State private var railVisibleRegion = SelectionLensVisibleRegion()

    /// The rail's selection lens. See `SelectionLens`.
    static let railLensChannel = SelectionLensChannel("destination.rail")

    private func railSectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 3)
    }

    /// One rail row. Selected rows take the hue's `accentFillColor` with `onAccentLabelColor` on
    /// top: the accent-fill model, not a wash of the accent over itself, which paints nothing.
    private func railRow(name: String, path: String, symbol: String,
                         detail: String? = nil, action: @escaping () -> Void) -> some View {
        let isSelected = PaneBrowsePath.normalized(path) == railFocus && !isSearching
        return Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).scaledFont(.system(size: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail)
                            .scaledFont(.system(size: 10))
                            .opacity(0.7)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .scaledFont(.system(size: 12))
            // White on Solid's fill and on dark glass; black on light glass (`selectionLensLabelInk`).
            .selectionLensLabelInk(isSelected: isSelected, onFill: glassHue.onAccentLabelColor,
                                   unselected: .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    SelectionLensTodayMarker { DestinationRowShape.outline.fill(glassHue.accentFillColor) }
                }
            }
            .selectionLensStop(Self.railLensChannel, id: PaneBrowsePath.normalized(path))
            .contentShape(DestinationRowShape.outline)
        }
        // `.filled` for the highlighted row at Solid, its ring in the on-fill colour; under the
        // lens, `.segment` washing in the accent like its neighbours (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accent,
                                        filledTint: glassHue.onAccentLabelColor,
                                        shape: DestinationRowShape.kind)
        // The full path on every row: the name, and even the parent line, can be one of two.
        .help((path as NSString).abbreviatingWithTildeInPath)
        .padding(.horizontal, 10)
    }

    /// A recent's parent, when its name alone can't tell it apart from another recent: where it
    /// sits relative to the provider. `nil` for a name no other recent shares, so the ordinary row
    /// stays one line. Written as the picker's breadcrumb writes a place ("iCloud › Clients ›
    /// Acme"), so the rail and the crumbs name one folder one way.
    nonisolated static func recentDetail(for path: String, among recents: [String], under root: String,
                             rootName: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let sharing = recents.filter { ($0 as NSString).lastPathComponent == name }
        guard sharing.count > 1 else { return nil }
        let parent = (PaneBrowsePath.normalized(path) as NSString).deletingLastPathComponent
        let relative = browsePath(for: parent, under: root).relativePath
        let folders = relative.split(separator: "/").map(String.init)
        return ([rootName] + folders).joined(separator: " › ")
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
                .help("Clear search")
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
                        // Column and divider as one scroll target: as siblings, the dividers become
                        // targets too and the stack can rest a hairline off a column boundary.
                        HStack(spacing: 0) {
                            DestinationColumn(
                                listing: listings[directory],
                                highlighted: highlighted,
                                onPathAt: depth < browsePath.depth ? browsePath.components[depth] : nil,
                                accent: accent,
                                caption: directory == itemFolder && itemsAreHere ? "Now Here" : nil,
                                moving: Set(request.sourcePaths.map(PaneBrowsePath.normalized)),
                                movingLabel: request.isMove ? "Moving" : "Copying",
                                ghost: directory == itemFolder && suggestion?.isNew == true ? suggestion : nil,
                                onPickGhost: { pickSuggestion($0) },
                                onOpen: { folder in open(folder, atDepth: depth) }
                            )
                            .frame(width: PaneViewMode.defaultColumnWidth)
                            Divider()
                        }
                        .id(directory)
                    }
                    // The width left over after the whole columns that fit, as blank space past the
                    // last one; without it the scroll clamps at the content's end and a fraction of a
                    // column shows at the leading edge.
                    Color.clear.frame(width: Self.trailingSlack(width: columnsWidth,
                                                                columnWidth: PaneViewMode.defaultColumnWidth + 1))
                }
                .scrollTargetLayout()
            }
            // Snaps to column boundaries when the user scrolls, but not for a programmatic scroll,
            // which is why the scrolls below aim at a column's leading edge.
            .scrollTargetBehavior(.viewAligned)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let opening = columnsWidth == 0
                columnsWidth = width
                // On opening: the card opens several folders deep, and a scroll view starts at its
                // leading edge, which would leave the item's own column off to the right.
                if opening { scrollToLastColumns(proxy, animated: false) }
            }
            .onChange(of: columnDirectories) { _, _ in scrollToLastColumns(proxy, animated: true) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Scrolls so the last column shows whole, with a whole column at the leading edge. Aims at the
    /// first column that lets the rest fit, by its leading edge; `scrollTo(last, anchor:
    /// .trailing)` would leave a sliver of a column at the left.
    private func scrollToLastColumns(_ proxy: ScrollViewProxy, animated: Bool) {
        let directories = columnDirectories
        guard !directories.isEmpty else { return }
        let first = Self.firstWholeColumn(count: directories.count, width: columnsWidth,
                                          columnWidth: PaneViewMode.defaultColumnWidth + 1)   // + the divider
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(directories[first], anchor: .leading) }
        } else {
            proxy.scrollTo(directories[first], anchor: .leading)
        }
    }

    /// What is left of `width` after the whole columns that fit in it.
    nonisolated static func trailingSlack(width: CGFloat, columnWidth: CGFloat) -> CGFloat {
        guard width > 0, columnWidth > 0 else { return 0 }
        return width - (width / columnWidth).rounded(.down) * columnWidth
    }

    /// The first of `count` columns to show so the last is whole in `width`: as many as fit,
    /// counted back from the end, and never a fraction.
    nonisolated static func firstWholeColumn(count: Int, width: CGFloat, columnWidth: CGFloat) -> Int {
        guard count > 0, columnWidth > 0 else { return 0 }
        let fitting = max(1, Int((width / columnWidth).rounded(.down)))
        return max(0, count - fitting)
    }

    /// Opens `folder` from the column at `depth`, closing any columns beyond it, by the panes' own
    /// `PaneBrowsePath.drill`.
    private func open(_ folder: DestinationFolder, atDepth depth: Int) {
        var path = browsePath
        path.drill(into: folder.name, atDepth: depth)
        browsePath = path
        highlighted = folder.path
    }

    /// Picks a place from the left column, re-rooting the columns when it is in another source.
    private func pick(_ place: DestinationPlace) {
        query = ""
        if place.root != browseRoot {
            browseRoot = place.root
            browseRootName = place.rootName
        }
        highlighted = canonical(place.path, under: place.root)
        browsePath = Self.browsePath(for: highlighted, under: place.root)
    }

    /// `path` in the spelling every node and column uses: one recorded through the link
    /// (`…/com~apple~CloudDocs/Documents/X`) becomes `~/Documents/X`. Compared as given, the
    /// "already there" refusal would miss it and the clash check would find the item colliding
    /// with itself.
    private func canonical(_ path: String, under root: String) -> String {
        Self.canonical(path, under: root)
    }

    nonisolated static func canonical(_ path: String, under root: String,
                                      links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> String {
        let normalized = PaneBrowsePath.normalized(path)
        guard let relative = PathBoundary.relativize(normalized, under: root, links: links) else { return normalized }
        return PathBoundary.join(root: root, relative: relative, links: links)
    }

    /// Picks the suggested folder. One that does not exist yet is picked in its parent's column,
    /// where it is drawn as a new row; Move makes it.
    private func pickSuggestion(_ suggestion: DestinationSuggestion) {
        query = ""
        browseRoot = requestRoot
        browseRootName = request.providerName
        highlighted = suggestion.path
        browsePath = Self.browsePath(for: suggestion.isNew ? itemFolder : suggestion.path, under: requestRoot)
    }

    /// Back to how the card opened: the item's own folder on show, nothing picked.
    private func returnToItemFolder() {
        query = ""
        browseRoot = requestRoot
        browseRootName = request.providerName
        highlighted = ""
        browsePath = Self.browsePath(for: itemFolder, under: requestRoot)
    }

    private var searchResults: some View {
        let ranked = DestinationBrowser.ranked(matches, recents: recents, query: query, under: root)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if ranked.isEmpty {
                    // Claim there is nothing only once the walk has finished.
                    if isSearchRunning {
                        ProgressView().controlSize(.small).padding(20)
                    } else {
                        // A walk that stopped short, or was refused a directory, hasn't shown that
                        // nothing matches; the outcome words each case.
                        Text(searchOutcome.emptyMessage(query: query))
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
                    // The list may fall short two ways, with different advice: a cap stopped the
                    // walk early, so narrowing reaches further; or an unreadable directory withheld a
                    // subtree, which no query reaches. The outcome words both.
                    if let footnote = searchOutcome.footnote(showing: ranked.count) {
                        Label(footnote, systemImage: "ellipsis.circle")
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

    // MARK: - Preview

    /// What a move does, before it does it. With nothing picked: where the item is now, and the
    /// short moves from there (the suggestion, up one, a new folder beside it). With a pick: the
    /// folders inside it with the item drawn in where it will sort, and whether a name clashes.
    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if highlighted.isEmpty { previewNowHere } else { previewDestination }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.previewWidth)
        .frame(maxHeight: .infinity)
    }

    /// Nothing picked. When the items are in the opening folder this says so and offers the short
    /// moves from it; when they are not (a loose file filed in from Downloads, a selection from
    /// several folders) it claims no "where it is now" at all.
    @ViewBuilder
    private var previewNowHere: some View {
        if itemsAreHere {
            previewCaption("Where it is now")
            Text(displayName(of: itemFolder))
                .scaledFont(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
        Text("Pick a folder to \(verb.lowercased()) \(titleSubject) into\(itemsAreHere ? ", or:" : ".")")
            .scaledFont(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if itemsAreHere {
            VStack(alignment: .leading, spacing: 4) {
                if let suggestion {
                    previewAction(suggestion.isNew ? "Into new folder “\(suggestion.name)”" : "Into “\(suggestion.name)”",
                                  symbol: suggestion.isNew ? "folder.badge.plus" : "folder") { pickSuggestion(suggestion) }
                }
                if hereRows.count > 1 {
                    let up = hereRows[1]
                    previewAction("Up to “\(up.name)”", symbol: "arrow.up") { pick(up) }
                }
                previewAction("New folder here…", symbol: "plus") { newFolderName = ""; isCreatingFolder = true }
                    .disabled(!canMakeFolder)
            }
        }
    }

    @ViewBuilder
    private var previewDestination: some View {
        let parentOfPick = (highlighted as NSString).deletingLastPathComponent
        previewCaption(picksNewFolder ? "New folder in “\(displayName(of: parentOfPick))”"
                                      : "Inside “\(displayName(of: highlighted))”")
        let existing: [String]? = picksNewFolder ? [] : listings[highlighted]?.folders.map(\.name)
        if let refusal {
            // Nothing lands here, so nothing is drawn landing: the reason, as the footer gives it.
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(SemanticColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if let existing {
            VStack(alignment: .leading, spacing: 1) {
                // By position: two selected items may share a name, and a name is no id then.
                ForEach(Array(Self.previewRows(existing: existing, moving: movingNames).enumerated()), id: \.offset) { _, row in
                    previewRow(row)
                }
            }
            .padding(6)
            .background(DestinationRowShape.outline.fill(Color.primary.opacity(0.04)))
        } else {
            ProgressView().controlSize(.small)
        }
        if refusal == nil {
            if collidingNames.isEmpty {
                Label("No name clash", systemImage: "checkmark")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(SemanticColor.success)
            } else {
                Label("\(collidingNames.count == 1 ? "“\(collidingNames[0])” is" : "\(collidingNames.count) names are") already there — you’ll be asked what to do.",
                      systemImage: "doc.on.doc")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var movingNames: [String] {
        request.sourcePaths.map { (PaneBrowsePath.normalized($0) as NSString).lastPathComponent }
    }

    private func previewCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func previewAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .scaledFont(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(DestinationRowShape.outline)
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: DestinationRowShape.kind))
    }

    @ViewBuilder
    private func previewRow(_ row: PreviewRow) -> some View {
        switch row {
        case .folder(let name):
            Label(name, systemImage: "folder.fill")
                .scaledFont(.system(size: 11.5))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 3)
        case .moving(let name):
            // The words in `.primary`, the accent in the arrow and the outline: words inked in the
            // colour they sit on fail contrast.
            Label {
                Text(name)
            } icon: {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(accent)
            }
                .scaledFont(.system(size: 11.5, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DestinationRowShape.outline.stroke(accent.opacity(0.6),
                                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .accessibilityLabel("\(name) lands here")
        case .more(let count, _):
            Text("… \(count) more")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
        }
    }

    /// One line of the preview's list.
    enum PreviewRow: Identifiable, Equatable {
        case folder(String)
        case moving(String)
        /// `count` folders left out; the second value keeps two gaps apart as identities.
        case more(Int, Int)

        var id: String {
            switch self {
            case .folder(let name): return "f:" + name
            case .moving(let name): return "m:" + name
            case .more(_, let index): return "more:\(index)"
            }
        }
    }

    /// The destination's folders with the moving items sorted in, trimmed to where they land:
    /// `context` folders either side of each, a "… N more" line for each gap. Sorted as the columns
    /// sort (`localizedStandardCompare`), so "2026" lands after "2025".
    nonisolated static func previewRows(existing: [String], moving: [String], context: Int = 3) -> [PreviewRow] {
        let movingSet = Set(moving)
        let merged = (existing.filter { !movingSet.contains($0) }.map { ($0, false) } + moving.map { ($0, true) })
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        let landing = merged.indices.filter { merged[$0].1 }
        var keep = Set<Int>()
        for index in landing {
            for near in max(0, index - context)...min(merged.count - 1, index + context) { keep.insert(near) }
        }
        var rows: [PreviewRow] = []
        var skipped = 0
        for (index, entry) in merged.enumerated() {
            if keep.contains(index) {
                if skipped > 0 { rows.append(.more(skipped, index)); skipped = 0 }
                rows.append(entry.1 ? .moving(entry.0) : .folder(entry.0))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { rows.append(.more(skipped, merged.count)) }
        return rows
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A refusal and a collision preview are never both worth saying: a refusal means the
            // move can't happen, so its collisions are beside the point.
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(SemanticColor.warning)
                    .lineLimit(2)
            } else if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(SemanticColor.warning)
                    .lineLimit(2)
            } else if let duplicateNotice {
                // Ahead of the collision preview: the items are already here, so they collide only
                // with themselves, and nothing prompts; a numbered duplicate is made.
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
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                // Gated by `canMakeFolder`, not merely on having a folder chosen: a folder made
                // inside the folder being moved would be left behind empty when the move is refused.
                .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                .keyboardShortcut(AppChord.newFolder.key, modifiers: AppChord.newFolder.modifiers)
                // Above `.disabled`, so no badge on a button whose shortcut is refused.
                .shortcutKeycap(AppChord.newFolder.display)
                .disabled(!canMakeFolder)
                .help(highlighted.isEmpty && itemsAreHere
                      ? "New folder beside “\(request.firstItemName)”, and \(verb.lowercased()) into it"
                      : "New folder inside “\(displayName(of: newFolderParent))”, and \(verb.lowercased()) into it")
                .lockedDuringRun()

                Button("Other…") { onChooseOther() }
                    .buttonStyle(.actionBar(.outline, tint: accent, onTint: glassHue.onAccentLabelColor))
                    .help("Choose a folder outside \(request.providerName)")

                // The one filled capsule on the card, on the deepened accent: white on the raw hue
                // sits at the contrast floor (see `AccentFill`).
                Button(picksNewFolder ? "Create and \(verb)" : verb) { commit() }
                    .buttonStyle(.actionBar(.primary,
                                            tint: AccentFill.deepened(accent),
                                            onTint: glassHue.onAccentLabelColor))
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("↩")
                    .disabled(!canCommit)
                    .lockedDuringRun()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.035))
    }

    /// What the collision preview says: the name when there is one, a count when there are several
    /// (a list would push the buttons off the row); the full list is the tooltip. "Conflicts", not
    /// "already exists", because two selected items sharing a name collide too, with the same
    /// prompt.
    private var collisionSummary: String {
        let folder = displayName(of: highlighted)
        if collidingNames.count == 1 {
            return "“\(collidingNames[0])” conflicts in \(folder) — you’ll be asked what to do."
        }
        return "\(collidingNames.count) of \(request.sourcePaths.count) names conflict in \(folder) — you’ll be asked about each."
    }

    /// The chosen folder as a breadcrumb, matching the pane headers rather than a raw path, so the
    /// leading components drop whole and the chosen folder, at the end, stays. Before anything is
    /// picked it names where the item is now, under "Now in", so the line is never blank.
    private var destinationCrumbs: some View {
        let isPicked = !highlighted.isEmpty
        let components = isPicked
            ? DestinationBrowser.crumbs(for: highlighted, under: root, providerName: browseRootName)
            : itemsAreHere ? DestinationBrowser.crumbs(for: itemFolder, under: requestRoot, providerName: request.providerName) : []
        return HStack(spacing: 4) {
            if isPicked {
                Image(systemName: picksNewFolder ? "folder.badge.plus" : "folder.fill")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(accent)
            } else if !components.isEmpty {
                Text("Now in").foregroundStyle(.secondary)
            }
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
        .accessibilityLabel(isPicked ? "Destination \(components.joined(separator: ", "))"
                                     : components.isEmpty ? "No folder chosen"
                                     : "No folder chosen. Now in \(components.joined(separator: ", "))")
    }

    /// The corner grip. Reads a fixed coordinate space (`.global`), as `ResizeHandle` does: the grip
    /// moves as the card grows, so in its own space the drag would feed back and stutter.
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
                        // Persist the clamped size, not the raw drag, or releasing past the ceiling
                        // would store a size the card can never open at.
                        storedWidth = cardSize.width
                        storedHeight = cardSize.height
                        dragAnchor = nil
                        dragSize = nil
                    }
            )
            .accessibilityLabel("Resize")
    }

    // MARK: - Loading

    /// Lists every open column that has not been listed yet, off the main actor: a provider root
    /// can hold thousands of entries, and iCloud placeholders make even a shallow listing a disk
    /// round-trip. Results land a column at a time, so the leftmost appears first.
    private func loadVisibleColumns() async {
        // The items' own folder too, wherever the columns have gone: the suggestion is read from it.
        await load(columnDirectories + [itemFolder])
    }

    /// Lists each directory not listed yet, in order. A listing that lands is kept even when the
    /// task has moved on: it is true of that folder whoever asked.
    private func load(_ directories: [String]) async {
        for directory in directories where listings[directory] == nil {
            let showHidden = showHidden
            let listing = await Task.detached {
                await DestinationBrowser.listSubfoldersSuspending(of: directory, showHidden: showHidden,
                                                                  fileManager: FileManager.default)
            }.value
            listings[directory] = listing
            guard !Task.isCancelled else { return }
        }
    }

    /// Restats the selection against the highlighted folder: one `fileExists` per selected item,
    /// off the main actor like the listings. Clears first, or the previous folder's count would
    /// sit under the new folder's name while the stat runs.
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
            searchOutcome = .empty
            isSearchRunning = false
            return
        }
        // Debounced: this fires per keystroke, and each run is a real (bounded) directory walk.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        isSearchRunning = true
        defer { isSearchRunning = false }
        let root = root
        let showHidden = showHidden
        // **`Task.detached` doesn't inherit cancellation**, so a superseded keystroke's walk would
        // run to completion. Bridging cancellation into it, polled per directory in `search`, makes
        // typing cost one walk rather than one per character.
        let work = Task.detached {
            DestinationBrowser.search(needle, under: root, showHidden: showHidden,
                                      fileManager: FileManager.default,
                                      isCancelled: { Task.isCancelled })
        }
        let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        searchOutcome = found
    }

    // MARK: - New folder

    /// New Folder is offered wherever its folder could be moved into: never inside the selection
    /// (it would leave an empty folder behind when the move is refused), never inside a suggested
    /// folder that does not exist yet.
    private var canMakeFolder: Bool {
        !picksNewFolder
            && !DestinationBrowser.destinationIsInsideSelection(newFolderParent, sources: request.sourcePaths)
    }

    /// Move, or for a suggested folder not there yet, make it and then move.
    private func commit() {
        guard canCommit else { return }
        guard picksNewFolder else { onCommit(highlighted); return }
        let parent = (highlighted as NSString).deletingLastPathComponent
        let name = (highlighted as NSString).lastPathComponent
        // Made since the card opened (by another window, or by hand): there is nothing to make.
        if !FileManager.default.fileExists(atPath: highlighted) {
            guard makeFolder(named: name, in: parent) != nil else { return }
        }
        onCommit(highlighted)
    }

    private func createFolderAndCommit() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, FileSyncManager.validateItemName(name) == nil, canMakeFolder else { return }
        guard let created = makeFolder(named: name, in: newFolderParent) else { return }
        newFolderName = ""
        onCommit(created)
    }

    /// Makes `name` in `parent` and tells the host, whatever happens to the transfer after it.
    private func makeFolder(named name: String, in parent: String) -> String? {
        switch Self.makeFolder(named: name, in: parent, parentName: displayName(of: parent)) {
        case .failure(let message):
            failure = message.text
            return nil
        case .success(let created):
            onFolderCreated(created)
            return created
        }
    }

    /// What the card says when its folder can't be made: the reason, not a silent no-op.
    struct FolderFailure: Error, Equatable { let text: String }

    /// Makes `name` in `parent` on disk: its path, or the sentence the card shows instead.
    nonisolated static func makeFolder(named name: String, in parent: String,
                                       parentName: String) -> Result<String, FolderFailure> {
        let created = (parent as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: created), withIntermediateDirectories: false
            )
        } catch {
            Logger.shared.warning("Could not create “\(name)” in \(parent): \(error.localizedDescription)")
            return .failure(FolderFailure(text: "Couldn’t make “\(name)” in “\(parentName)”: \(error.localizedDescription)"))
        }
        Logger.shared.info("Created “\(name)” from the destination picker")
        return .success(created)
    }

    // MARK: - Helpers

    /// A folder's name as the picker shows it. A root reads as its source ("iCloud", never the
    /// container's "com~apple~CloudDocs"), as in the breadcrumbs.
    private func displayName(of path: String) -> String {
        let normalized = PaneBrowsePath.normalized(path)
        if normalized.isEmpty { return "" }
        if normalized == browseRoot { return browseRootName }
        if normalized == requestRoot { return request.providerName }
        return (normalized as NSString).lastPathComponent
    }

    /// The column stack that shows `path`, given the root it is under; anything outside rests at
    /// the root. Inside means `PathBoundary`'s inside, links included: an iCloud item at
    /// `~/Documents/…` is reached through iCloud Drive's `Documents` link, which a plain prefix test
    /// would call outside.
    static func browsePath(for path: String, under root: String,
                           links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> PaneBrowsePath {
        let normalizedRoot = PaneBrowsePath.normalized(root)
        let normalized = PaneBrowsePath.normalized(path)
        guard let relative = PathBoundary.relativize(normalized, under: normalizedRoot, links: links),
              !relative.isEmpty else { return PaneBrowsePath() }
        return PaneBrowsePath(relativePath: relative)
    }
}

// MARK: - Column

/// One column of folders, a separate view so the picker's body stays inside the type checker's
/// budget. Not `private`, and its three states are a value (`state`) rather than conditions in the
/// body, so `DestinationColumnStateTests` can assert what it draws without driving the view.
struct DestinationColumn: View {
    /// What the column has to show: loading, a message, or rows.
    enum State: Equatable {
        /// Nothing read yet: a spinner, never a claim about the folder.
        case loading
        /// Nothing to list, and the reason, in the words the column shows.
        case message(String)
        /// Rows to draw.
        case rows
    }

    /// `nil` until the listing lands, which is what the spinner distinguishes from an empty folder.
    let listing: DestinationFolderListing?
    let highlighted: String
    /// Name of the folder drilled through at this depth, marked as the trail.
    let onPathAt: String?
    let accent: Color
    /// A heading over the rows: "Now Here" on the item's own folder.
    var caption: String? = nil
    /// The items being moved, by path. Drawn in place but dimmed and not clickable: a folder is
    /// never a destination for itself, and seeing it among its neighbours is the point.
    var moving: Set<String> = []
    /// The verb those rows wear: "Moving", or "Copying" for a copy.
    var movingLabel = "Moving"
    /// A suggested folder not made yet, drawn dashed where it will sort.
    var ghost: DestinationSuggestion? = nil
    var onPickGhost: (DestinationSuggestion) -> Void = { _ in }
    let onOpen: (DestinationFolder) -> Void


    /// The wording comes from `DestinationFolderListing.emptyMessage`, which tells an empty folder
    /// from an unreadable one; the column must not decide that no rows means "Empty".
    var state: State {
        guard let listing else { return .loading }
        if let message = listing.emptyMessage { return .message(message) }
        return .rows
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .message(let text):
                Text(text)
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .rows:
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Self.entries(listing?.folders ?? [], ghost: ghost)) { entry in
                            switch entry {
                            case .folder(let folder):
                                if moving.contains(folder.path) { movingRow(folder) } else { row(folder) }
                            case .ghost(let suggestion):
                                ghostRow(suggestion)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let caption {
                Text(caption.uppercased())
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(caption == nil ? Color.clear : accent.opacity(0.05))
    }

    /// One row of a column.
    enum Entry: Identifiable, Equatable {
        case folder(DestinationFolder)
        case ghost(DestinationSuggestion)
        var id: String {
            switch self {
            case .folder(let folder): return folder.path
            case .ghost(let suggestion): return "new:" + suggestion.path
            }
        }
    }

    /// The listing with a not-yet-made suggestion sorted in, as the folder will sort once made.
    nonisolated static func entries(_ folders: [DestinationFolder], ghost: DestinationSuggestion?) -> [Entry] {
        var entries = folders.map(Entry.folder)
        guard let ghost, !folders.contains(where: { $0.path == ghost.path }) else { return entries }
        let at = folders.firstIndex { $0.name.localizedStandardCompare(ghost.name) == .orderedDescending } ?? folders.count
        entries.insert(.ghost(ghost), at: at)
        return entries
    }

    private func movingRow(_ folder: DestinationFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(folder.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(movingLabel.uppercased()).scaledFont(.system(size: 9, weight: .semibold))
        }
        .scaledFont(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DestinationRowShape.outline.stroke(Color.secondary.opacity(0.5),
                                                       style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), \(movingLabel.lowercased())")
    }

    private func ghostRow(_ suggestion: DestinationSuggestion) -> some View {
        let isChosen = suggestion.path == highlighted
        return Button { onPickGhost(suggestion) } label: {
            // Words in `.primary` over the accent wash, for contrast; the accent is the icon and the
            // outline.
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus").foregroundStyle(accent)
                Text(suggestion.name).lineLimit(1)
                Spacer(minLength: 4)
                Text("NEW").scaledFont(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .scaledFont(.system(size: 12))
            .foregroundStyle(.primary)
            .fontWeight(isChosen ? .medium : .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    if isChosen { DestinationRowShape.outline.fill(accent.opacity(PaneSelectionWash.active)) }
                    DestinationRowShape.outline.stroke(accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(DestinationRowShape.outline)
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: DestinationRowShape.kind))
        .padding(.horizontal, 8)
        .help(suggestion.reason)
        .accessibilityLabel("New folder \(suggestion.name)")
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private func row(_ folder: DestinationFolder) -> some View {
        let isChosen = folder.path == highlighted
        let isTrail = folder.name == onPathAt && !isChosen
        // One click both chooses and opens, so there is no separate "open" gesture to discover. A
        // Button rather than a tap gesture, so hover goes through `HoverAffordanceStyle`, the app's
        // one hover choke point.
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
            .contentShape(DestinationRowShape.outline)
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: DestinationRowShape.kind))
        .padding(.horizontal, 8)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func rowBackground(isChosen: Bool, isTrail: Bool) -> some View {
        if isChosen {
            // The panes' own selection strength, so a chosen row reads as a selected row in the
            // rail behind the card.
            DestinationRowShape.outline.fill(accent.opacity(PaneSelectionWash.active))
        } else if isTrail {
            // Quieter than a selection: this row is the trail, not the target, as in
            // `PaneColumnsView`.
            DestinationRowShape.outline.fill(accent.opacity(PaneSelectionWash.inactive * 0.6))
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
                        .foregroundStyle(isHighlighted ? onAccent : Color.primary)
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
                    DestinationRowShape.outline.fill(accentFill)
                }
            }
            .contentShape(DestinationRowShape.outline)
        }
        .buttonStyle(.hoverAffordance(isHighlighted ? .filled : .segment,
                                      tint: isHighlighted ? onAccent : accent,
                                      shape: DestinationRowShape.kind))
        .padding(.horizontal, 12)
    }
}
