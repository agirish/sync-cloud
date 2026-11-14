import SwiftUI
import Sync
import Combine
import UniformTypeIdentifiers
import AppKit
import Design
import FileExplorer

/// The Info inspector's contents: a picture of the selected item over its name, its actions and
/// its details, for the current selection or, with nothing selected, the focused folder.
public struct DetailsSidebar: View {
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @ObservedObject public var syncManager: FileSyncManager

    /// Current root path for the left pane (used when no item is selected).
    public let leftPath: String
    /// Current root path for the right pane (used when no item is selected).
    public let rightPath: String
    /// An explicit path to inspect, overriding the pane selection — set by "Get Info" on a
    /// differences-table row, whose file has no pane selection to derive from. nil = follow selection.
    public let overridePath: String?
    /// True when the inspector is showing the single-source rail (which is the left pane). The
    /// right pane is hidden there, so its (possibly stale) selection from a prior Compare session must
    /// not drive the inspector — otherwise the panel would describe a file in the wrong provider.
    public let singleSource: Bool
    /// The cloud ground the *Where it lives* rows are resolved against; see `FileLocation`.
    ///
    /// nil means "the coverage is not known here" and draws no verdict at all. That is the safe
    /// default rather than `.none`: an empty coverage claims no cloud folder contains anything, so
    /// a caller who forgot to pass this would have every iCloud file reported as *This Mac only*.
    public let cloudCoverage: FileLocation.Coverage?
    /// How this host opens a file in Edit, or nil where it has no editor; see ``EditorHandOff``.
    /// Defaults to nil on both initializers, which is a correct answer: the inspector then draws
    /// its action row without Open in Edit.
    public let editorHandOff: EditorHandOff?
    /// The picture's share of the height, which the host persists and the bar under the picture
    /// sets.
    public let previewFraction: Binding<Double>
    /// The host's preview of `previewPath`, drawn as the picture. nil for anything the host does not
    /// preview — a folder, several items — which then shows its icon in the same frame.
    public let preview: AnyView?
    /// The file `preview` shows. The picture is drawn only while the details below describe that
    /// same file: the preview follows the selection as it is now, the details the last stat, which
    /// lags it (for seconds on a slow provider). Until the stat catches up, the picture is the
    /// described item's icon, so a new file's picture never sits over the previous file's name.
    public let previewPath: String?
    /// Whether the right pane's selection comes first: the host's answer to "which pane is the user
    /// working in", so a click in the right pane isn't described as the left pane's selection. A
    /// right pane with nothing selected falls through to the left; with nothing selected anywhere,
    /// the focused folder is the right pane's.
    public let followsRight: Bool
    /// Describes only the pane `followsRight` names, never the other one. A pane's own Info is this:
    /// in Compare the unfocused pane would otherwise be described by the other pane's selection, or
    /// by none. With nothing selected the pane's own folder is shown.
    public let ownPaneOnly: Bool

    /// The picture's share of the inspector's height until the user drags it: most of it, since the
    /// page is what the panel is opened to read.
    public static let defaultPreviewFraction: Double = 0.7

    @State private var computedDirectorySizeKey: DirectorySizeTaskID? = nil
    @State private var computedDirectorySize: String? = nil
    /// Mirror of `cache.generation` (the cache is a plain class in @State, so mutating it can't
    /// re-trigger rendering); updated in the same onReceive closures that invalidate the cache,
    /// so the size task's id changes and it recomputes.
    @State private var sizeGeneration = 0

    /// Memoization and invalidation rules live in DetailsMetadataCache; the view only
    /// forwards lookups and the refresh/scan events to it.
    @State private var cache = DetailsMetadataCache()
    /// The stat result the card renders, filled by the loader task. See `LoadedDetails`.
    @State private var loaded: LoadedDetails?
    /// The materialization answer behind the *Where it lives* rows, filled by its own task — see
    /// `LoadedLocation`.
    @State private var loadedLocation: LoadedLocation?

    /// Item previewed via the metadata card's "Quick Look" action. Presented by this view's own
    /// `.quickLookPreview`, like `FileTreeView`: the sidebar has no host presenter to delegate to,
    /// and the shared QL panel shows one preview at a time anyway.
    @State private var quickLookItem: URL?

    /// Shared formatter for created/modified dates. Reused instead of reallocated on every access
    /// of `metadata` (DateFormatter is expensive to construct).
    ///
    /// `nonisolated` so the stat that reads it can run off the main actor (see
    /// `loadMetadata(for:fileManager:)`). That is why it is a `ZoneRefreshedFormatter`, not a bare
    /// `DateFormatter` with a zone check: re-checking the zone mutates the formatter, so from more
    /// than one thread the check and the format must be taken together under that type's lock.
    nonisolated private static let dateFormatter = ZoneRefreshedFormatter.localized(date: .medium,
                                                                                    time: .medium)
    
    public init(syncManager: FileSyncManager, leftPath: String, rightPath: String, overridePath: String? = nil, singleSource: Bool = false, cloudCoverage: FileLocation.Coverage? = nil, editorHandOff: EditorHandOff? = nil, previewFraction: Binding<Double> = .constant(DetailsSidebar.defaultPreviewFraction), preview: AnyView? = nil, previewPath: String? = nil, followsRight: Bool = false, ownPaneOnly: Bool = false) {
        self.init(syncManager: syncManager, leftPath: leftPath, rightPath: rightPath,
                  overridePath: overridePath, singleSource: singleSource,
                  cloudCoverage: cloudCoverage, editorHandOff: editorHandOff,
                  cache: DetailsMetadataCache(), previewFraction: previewFraction, preview: preview,
                  previewPath: previewPath, followsRight: followsRight, ownPaneOnly: ownPaneOnly)
    }

    /// Test seam: hands in the metadata cache instead of letting `@State` mint one, so a test can
    /// hold the loader back and prove the first frame still paints. `DetailsMetadataCache` is
    /// internal, so this initializer can't be the public one.
    init(syncManager: FileSyncManager, leftPath: String, rightPath: String,
         overridePath: String?, singleSource: Bool, cloudCoverage: FileLocation.Coverage? = nil,
         editorHandOff: EditorHandOff? = nil, cache: DetailsMetadataCache,
         previewFraction: Binding<Double> = .constant(DetailsSidebar.defaultPreviewFraction),
         preview: AnyView? = nil, previewPath: String? = nil, followsRight: Bool = false,
         ownPaneOnly: Bool = false) {
        self.syncManager = syncManager
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.overridePath = overridePath
        self.singleSource = singleSource
        self.cloudCoverage = cloudCoverage
        self.editorHandOff = editorHandOff
        self.previewFraction = previewFraction
        self.preview = preview
        self.previewPath = previewPath
        self.followsRight = followsRight
        self.ownPaneOnly = ownPaneOnly
        _cache = State(initialValue: cache)
    }
    
    // Internal struct to hold parsed metadata logic cleanly.
    //
    // `Sendable` (and plain values throughout) because it is produced off the main actor by
    // `loadMetadata(for:fileManager:)` and handed back to it — see `DetailsMetadataCache.load(for:)`.
    struct FileMetadata: Sendable {
        let name: String
        let path: String
        let kind: String
        let size: String
        let creationDate: String
        let modificationDate: String
        let permissions: String
        let isDirectory: Bool
    }

    /// What one stat produced: the metadata, plus the reason it failed when the item exists but
    /// could not be read.
    ///
    /// The reason is returned rather than logged by the loader: the loader runs off the main actor,
    /// where a `@MainActor` logging sink can't be reached, and only the caller,
    /// `DetailsMetadataCache`, knows a re-stat of the same path is not news (its `warnedPaths`).
    struct MetadataLoad: Sendable {
        let metadata: FileMetadata?
        /// Non-nil only for the "exists but unreadable" case. A path that is simply not there is
        /// the common, unremarkable case (the selection cleared, the item moved) and reports nothing.
        let failure: String?
    }
    
    /// The right pane's selection, treated as empty in single-source mode: the right pane is hidden
    /// on the single-source rail, so its lingering selection must not leak into what the inspector shows.
    private var rightSelectionPaths: Set<String> {
        singleSource ? [] : syncManager.selectedRightPaths
    }

    /// The selection of the one pane an own-pane Info describes.
    private var ownSelectionPaths: Set<String> {
        followsRight ? rightSelectionPaths : syncManager.selectedLeftPaths
    }

    /// The path to display metadata for: first selected path in either pane, or the focused folder path.
    internal var activePath: String {
        // A "Get Info" target wins over the pane selection (a differences-table row has no pane
        // selection of its own).
        if let overridePath, !overridePath.isEmpty { return overridePath }
        if ownPaneOnly {
            if let own = ownSelectionPaths.min() { return own }
            return followsRight ? rightPath : leftPath
        }
        if followsRight, let right = rightSelectionPaths.min() { return right }
        // The shared resolver, so the inspector and Space (`PaneLogic.primarySelectionPath`)
        // always agree on which file is current.
        if let selected = CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: singleSource
        ) {
            return selected
        }

        // Fallback to navigated folders: the pane the user is in, as everything above follows it.
        if followsRight, !rightPath.isEmpty { return rightPath }
        return leftPath.isEmpty ? rightPath : leftPath
    }

    /// True when `activePath` fell back to the focused folder rather than a user-chosen item.
    /// Drives the "— focused folder" caption so the metadata card doesn't read as a selection the
    /// user made.
    ///
    /// Mirrors `activePath`'s branches in the same order, override first and the shared resolver
    /// second. Otherwise "Get Info" on a differences row, which sets the override when no pane
    /// holds a selection, would caption a chosen file "— focused folder".
    internal var isShowingFocusedFolderFallback: Bool {
        if let overridePath, !overridePath.isEmpty { return false }
        if ownPaneOnly { return ownSelectionPaths.isEmpty }
        if followsRight, !rightSelectionPaths.isEmpty { return false }
        return CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: singleSource
        ) == nil
    }

    /// Non-nil when 2+ items are selected: the sidebar shows the Finder-style summary instead of
    /// single-item metadata, which would describe only the alphabetically-first path. Answers for
    /// the pane `activePath` reads (the right one when `followsRight` and it holds something, the
    /// left otherwise), and never over a Get Info target, which `activePath` puts first, or Get
    /// Info on a differences row would show "3 items" and seem to do nothing.
    ///
    /// Resolved through the manager's cached path→node index, not `leftTree.findNodes`: this is
    /// read from `body`, where a walk costs milliseconds per render. See
    /// `DetailsSelectionSummary.make(selectedPaths:resolving:)`.
    internal var selectionSummary: DetailsSelectionSummary? {
        if let overridePath, !overridePath.isEmpty { return nil }
        if ownPaneOnly {
            return DetailsSelectionSummary.make(selectedPaths: ownSelectionPaths) {
                followsRight ? syncManager.rightNodes(for: $0) : syncManager.leftNodes(for: $0)
            }
        }
        if followsRight, !rightSelectionPaths.isEmpty {
            return DetailsSelectionSummary.make(selectedPaths: rightSelectionPaths) {
                syncManager.rightNodes(for: $0)
            }
        }
        if !syncManager.selectedLeftPaths.isEmpty {
            return DetailsSelectionSummary.make(selectedPaths: syncManager.selectedLeftPaths) {
                syncManager.leftNodes(for: $0)
            }
        }
        return DetailsSelectionSummary.make(selectedPaths: rightSelectionPaths) {
            syncManager.rightNodes(for: $0)
        }
    }

    /// `.task(id:)` key for the directory-size walk. Includes the multi-selection flag so the
    /// task re-fires when the selection collapses back to one item with the same `activePath`
    /// (the size was cleared while multi-selected and must recompute), and the cache generation
    /// so a refresh/scan-end drops the stale total and recomputes it.
    private struct DirectorySizeTaskID: Equatable {
        let path: String
        let isMultiSelection: Bool
        let generation: Int
    }

    /// What the metadata card renders, once the stat behind it has actually run.
    ///
    /// Held in `@State` and filled by a task, never resolved inside `body`: the resolve is four
    /// blocking filesystem calls (`fileExists`, `attributesOfItem`, a `typeIdentifier` fetch, and
    /// `NSWorkspace.icon(forFile:)`), and the memo is dropped on every file operation, scan end and
    /// click, so each click would hold the pane's re-render behind four stats on a cloud path. This
    /// way the click paints first and the card fills a beat later.
    ///
    /// Not on the main actor either: a `View`'s `.task` inherits its `@MainActor` isolation, so
    /// a wedged `getxattr` there would freeze the app. The stats run on
    /// `DetailsMetadataCache.ioQueue`; see `loadMetadata(for:fileManager:)`.
    private struct LoadedDetails: Equatable {
        let key: DirectorySizeTaskID
        let metadata: FileMetadata?
        let icon: NSImage?

        static func == (lhs: LoadedDetails, rhs: LoadedDetails) -> Bool { lhs.key == rhs.key }
    }

    /// Whether this file's content is on this Mac, for the item the card is describing.
    ///
    /// Its own task and state, not folded into `DetailsMetadataCache.load(for:)`: that memo's
    /// invalidation is tuned for metadata, and a separate task lets the name, size and dates paint
    /// as soon as they land instead of waiting on the slowest stat against a cloud path.
    ///
    /// The `lstat` runs off the main actor. `MaterializationStatus.isCloudOnlyIfKnown` is a
    /// single `lstat`, cheap until a file provider wedges, and a `View`'s `.task` inherits the
    /// view's `@MainActor` isolation. `Task.detached` gets it off the main thread, the same shape
    /// `CloudOnlyBadgeCache` uses for the row badge's copy of this stat.
    ///
    /// `isCloudOnly` keeps its Optional: nil is "the stat could not answer", a different fact from
    /// "the content is here", and draws nothing rather than a guess.
    private struct LoadedLocation: Equatable {
        let key: DirectorySizeTaskID
        let isCloudOnly: Bool?
    }

    /// `.task(id:)` key for the folder-size walk: the base key plus the resolved directory the
    /// walk would run over, which is `nil` until the stat has landed and said the item is a
    /// directory. That second half is what re-fires the walk when the metadata arrives.
    private struct DirectorySizeWalkID: Equatable {
        let base: DirectorySizeTaskID
        let directoryPath: String?
    }

    private func sizeWalkKey(base: DirectorySizeTaskID) -> DirectorySizeWalkID {
        guard let settled = loaded, settled.key == base,
              let metadata = settled.metadata, metadata.isDirectory
        else { return DirectorySizeWalkID(base: base, directoryPath: nil) }
        return DirectorySizeWalkID(base: base, directoryPath: metadata.path)
    }

    /// Stats `activePath` for the metadata card, or an empty result when there is nothing to show.
    ///
    /// A path that isn't there and one the app may not read both render the same empty inspector,
    /// so the second carries its reason back in `MetadataLoad.failure`; otherwise a permissions or
    /// IO failure on a cloud provider would look like "nothing selected", with nothing logged.
    ///
    /// This reports every failed stat; the once-per-path limit belongs to `DetailsMetadataCache`
    /// (its `warnedPaths`), which knows a re-stat is a re-stat.
    ///
    /// ## Why this is `nonisolated`
    ///
    /// **Every call below can block indefinitely.** `attributesOfItem(atPath:)` reaches
    /// `getxattr`, which does not return on a wedged file provider (bird/fileproviderd), even
    /// while a plain `stat` of the same path answers at once. A `View`'s `.task` is
    /// `@MainActor`-isolated, so run from there the syscall would freeze the app, at launch with
    /// zero windows and an empty log.
    ///
    /// Being `nonisolated` lets `DetailsMetadataCache` run it on a private queue, so it must stay
    /// free of main-actor state: the failure comes back in the return value, and `dateFormatter`
    /// is `nonisolated`.
    ///
    /// `fileManager` is injected (defaulting to the real one) so the failure path is testable,
    /// following `FolderJump.siblings`.
    nonisolated static func loadMetadata(
        for activePath: String,
        fileManager: FileManager = .default
    ) -> MetadataLoad {
        let url = URL(fileURLWithPath: activePath)
        let fm = fileManager
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: activePath, isDirectory: &isDir) else {
            return MetadataLoad(metadata: nil, failure: nil)
        }

        do {
            let attrs = try fm.attributesOfItem(atPath: activePath)
            
            // Name
            let name = url.lastPathComponent
            
            // Dates
            let creation = attrs[.creationDate] as? Date ?? Date.distantPast
            let modification = attrs[.modificationDate] as? Date ?? Date.distantPast

            let dateFormatter = Self.dateFormatter

            // Size
            let sizeInt = attrs[.size] as? Int64 ?? 0
            let sizeStr = isDir.boolValue ? "" : ByteCountFormatter.string(fromByteCount: sizeInt, countStyle: .file)
            
            // Permissions
            let perms = attrs[.posixPermissions] as? NSNumber
            let permStr = symbolicPermissions(mode: perms?.intValue ?? 0, isDirectory: isDir.boolValue)
            
            // Kind
            var fileKind = isDir.boolValue ? "Folder" : "Document"
            if let typeID = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
                if let localized = UTType(typeID)?.localizedDescription {
                    fileKind = localized
                }
            }
            
            return MetadataLoad(
                metadata: FileMetadata(
                    name: name,
                    path: activePath,
                    kind: fileKind,
                    size: sizeStr,
                    creationDate: dateFormatter.string(from: creation),
                    modificationDate: dateFormatter.string(from: modification),
                    permissions: permStr,
                    isDirectory: isDir.boolValue
                ),
                failure: nil
            )
        } catch {
            // The item exists but its attributes could not be read: a permissions failure, or a
            // cloud placeholder that won't materialize. Say so; the inspector can only fall silent.
            return MetadataLoad(
                metadata: nil,
                failure: "Details: couldn't read attributes of \(activePath): \(error.localizedDescription)")
        }
    }

    /// Renders a POSIX mode as an `ls`-style symbolic string followed by the octal in
    /// parentheses, e.g. mode `0o755` on a directory → `"drwxr-xr-x (755)"`.
    ///
    /// The leading char is `d` for a directory and `-` for a file, followed by the
    /// owner/group/other `rwx` triads. Special bits are honoured: setuid/setgid show
    /// `s` in the owner/group execute slot (`S` when the execute bit is unset), and the
    /// sticky bit shows `t` in the other-execute slot (`T` when unset). The mode is
    /// masked with `0o7777`, so the parenthesised octal includes any special bits
    /// (e.g. `0o4755` → `"-rwsr-xr-x (4755)"`). Pure formatting; no I/O.
    nonisolated static func symbolicPermissions(mode: Int, isDirectory: Bool) -> String {
        let m = mode & 0o7777
        let octal = String(format: "%03o", m)

        // Builds one rwx triad. `specialBit` is the setuid/setgid/sticky mask for this
        // triad and `specialChar` its lowercase glyph (`s` or `t`); it renders in the
        // execute slot, uppercased when the underlying execute bit is unset.
        func triad(shift: Int, specialBit: Int, specialChar: Character) -> String {
            let bits = (m >> shift) & 0o7
            let r = (bits & 0o4) != 0 ? "r" : "-"
            let w = (bits & 0o2) != 0 ? "w" : "-"
            let executable = (bits & 0o1) != 0
            let x: String
            if (m & specialBit) != 0 {
                x = executable ? String(specialChar) : specialChar.uppercased()
            } else {
                x = executable ? "x" : "-"
            }
            return r + w + x
        }

        let type = isDirectory ? "d" : "-"
        let owner = triad(shift: 6, specialBit: 0o4000, specialChar: "s")
        let group = triad(shift: 3, specialBit: 0o2000, specialChar: "s")
        let other = triad(shift: 0, specialBit: 0o1000, specialChar: "t")

        return "\(type)\(owner)\(group)\(other) (\(octal))"
    }

    /// `key` matches on generation too, so an invalidated total shows "Calculating…" while the
    /// re-keyed task recomputes it instead of serving the pre-operation value.
    private func displaySize(for data: FileMetadata, key: DirectorySizeTaskID) -> String {
        if !data.isDirectory { return data.size }

        if computedDirectorySizeKey == key, let computedDirectorySize {
            return computedDirectorySize
        }
        return "Calculating…"
    }

    public var body: some View {
        let summary = selectionSummary
        let sizeKey = DirectorySizeTaskID(path: activePath, isMultiSelection: summary != nil, generation: sizeGeneration)
        // Read out of state, never resolved here: the lookup hits the filesystem, and `body` must
        // never run it. See `LoadedDetails`.
        //
        // Stale-while-revalidate, as the pane trees do: dropping the previous answer until the new
        // stat lands would flash "No item selected". Icon and name are held together, so a stale
        // card is consistent, only a beat behind. It must not offer to act, though: the action row
        // is withheld while stale, or Reveal and Quick Look would target the previous file.
        let shown = loaded
        let isStale = shown?.key != sizeKey
        // The picture stays through a re-read of the same file: every file operation and scan
        // bumps the generation, and tearing the preview down for it would lose a PDF's page or a
        // playing video. The file's own changes reach it through its identity.
        let pictureStale = shown?.key.path != sizeKey.path || shown?.key.isMultiSelection != sizeKey.isMultiSelection
        let (data, icon): (FileMetadata?, NSImage?) = (shown?.metadata, shown?.icon)
        return inspectorLayout(summary: summary, data: data, icon: icon, isStale: isStale,
                               pictureStale: pictureStale, key: shown?.key ?? sizeKey)
        .frame(minHeight: 0)
        // Allow the sidebar to shrink slightly but wrap text elements to avoid clipping
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .quickLookPreview($quickLookItem)
        .onReceive(syncManager.refreshSubject) { _ in
            cache.refreshOccurred()
            sizeGeneration = cache.generation
        }
        .onReceive(syncManager.$isScanning) { scanning in
            cache.scanningChanged(scanning)
            sizeGeneration = cache.generation
        }
        // The stat, off the render path. A multi-selection renders the summary instead, so the
        // single-item lookup is skipped entirely rather than computed and discarded.
        .task(id: sizeKey) {
            guard !sizeKey.isMultiSelection, !sizeKey.path.isEmpty else {
                loaded = LoadedDetails(key: sizeKey, metadata: nil, icon: nil)
                return
            }
            // `DetailsMetadataCache` owns the per-path memo and the once-per-path warning.
            // `load(for:)` serves a hit without suspending, so an already-loaded path paints in one
            // pass and needs no separate `cached(for:)` branch. A miss suspends while the syscalls
            // run on the cache's private queue, and `body` renders the previous card meanwhile. If
            // they never land, this task stays suspended; the window is already on screen.
            let entry = await cache.load(for: sizeKey.path)
            guard !Task.isCancelled else { return }
            loaded = LoadedDetails(key: sizeKey, metadata: entry.metadata, icon: entry.icon)
        }
        // The materialization half of *Where it lives*, off the main actor and off the metadata
        // card's critical path; see `LoadedLocation`.
        .task(id: sizeKey) {
            guard !sizeKey.isMultiSelection, !sizeKey.path.isEmpty else {
                loadedLocation = LoadedLocation(key: sizeKey, isCloudOnly: nil)
                return
            }
            let path = sizeKey.path
            let answer = await Task.detached {
                MaterializationStatus.isCloudOnlyIfKnown(atPath: path)
            }.value
            // `Task.detached` does not inherit cancellation and `.value` on `Task<Bool?, Never>`
            // does not throw, so this can resume with a stale answer after the selection moved
            // on. `FileRowView.resolveBadge` closes the same window for the row badge.
            guard !Task.isCancelled else { return }
            loadedLocation = LoadedLocation(key: sizeKey, isCloudOnly: answer)
        }
        // Keyed on the walk id, not the base key: the metadata arrives asynchronously, so a task
        // keyed on the base alone would run before the stat landed, bail, and never re-fire,
        // leaving every folder at "Calculating…".
        .task(id: sizeWalkKey(base: sizeKey)) {
            // No directory walk while multi-selected: the summary never shows a computed
            // folder size (it stays metadata-only). Nor before the stat says it's a directory.
            guard let directoryPath = sizeWalkKey(base: sizeKey).directoryPath else {
                computedDirectorySizeKey = nil
                computedDirectorySize = nil
                return
            }

            // Avoid re-computing if we already have a cached value for this key (same path,
            // same generation, single-selection).
            if computedDirectorySizeKey == sizeKey, computedDirectorySize != nil {
                return
            }

            computedDirectorySizeKey = sizeKey
            computedDirectorySize = nil

            let result = await Self.computeDirectorySizeString(path: directoryPath)

            guard !Task.isCancelled else { return }
            if computedDirectorySizeKey == sizeKey {
                computedDirectorySize = result ?? "--"
            }
        }
    }

    /// The folder total, or nil when there is no honest number to show (the caller renders "--").
    ///
    /// Not `private`, so `DetailsSidebarSizeTests` can drive it against a real locked directory;
    /// the sidebar itself is a SwiftUI view no unit test can drive.
    ///
    /// A folder whose contents are not on this Mac is asked for, never walked into. The
    /// enumerator reads a dataless folder's contents by asking its cloud app, which never answers
    /// if the app isn't running, leaving the size at "Calculating…" and a thread stuck for good.
    /// OneDrive accounts can hold a dataless `.Trash`. Each such folder is skipped and asked
    /// through `waitForContents`, which holds no thread while it waits; answered, it is walked like
    /// any other, and unanswered, the total becomes a floor ("+"), or "--" for the folder itself.
    nonisolated static func computeDirectorySizeString(path: String,
                                                       fileManager: FileManaging = FileManager.default) async -> String? {
        let url = URL(fileURLWithPath: path)
        let fm = fileManager

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        // Built once, not per entry: a walk near the root visits tens of thousands of entries,
        // and the values are already prefetched through `includingPropertiesForKeys`.
        let keySet = Set(keys)

        /// One streaming pass. nil means the task was cancelled; otherwise what the walk saw,
        /// handed to `classify` by the caller.
        ///
        /// A function so it can run twice (see the symlink retry below). A stream rather than
        /// `FileManaging.listing(of:)`, which collects every entry into an array; this walks tens
        /// of thousands while polling for cancellation.
        func walk(_ root: URL) async -> (total: Int64, entries: Int, failures: [URL])? {
            // Asked first, suspending, if its contents are not on this Mac (see the doc above).
            // Unanswered, nothing below it was read: a failure of the root, as a locked one is.
            guard await fm.waitForContents(of: root) else {
                return Task.isCancelled ? nil : (0, 0, [root])
            }
            // The enumerator is non-nil even for a folder that can't be listed (it yields
            // nothing), so without the error handler a locked folder would read "Zero KB".
            // `DirectoryListingSupport.classify` turns what it saw into the same verdict
            // `FileManaging.listing(of:)` reaches.
            //
            // A box rather than a captured `var`: the handler is an escaping closure and this
            // function suspends (`Task.yield`) while the walk runs.
            final class Failures: @unchecked Sendable { var urls: [URL] = [] }
            let failures = Failures()

            // Descend into package bundles (.app, .rtfd, .photoslibrary…) so their contents count
            // toward the folder total, matching Finder's Get Info. `.skipsPackageDescendants` would
            // treat each bundle as 0 bytes and understate the size.
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [],
                // Returning true keeps going: one locked subfolder must not abandon the whole total.
                errorHandler: { failed, _ in failures.urls.append(failed); return true }
            ) else {
                // Documented as unreachable on a real filesystem; reported as the root itself
                // having failed.
                return (0, 0, [root])
            }

            var total: Int64 = 0
            var count = 0
            while let fileURL = enumerator.nextObject() as? URL {
                // Check for cancellation periodically to avoid orphaned background work
                if count % 100 == 0 {
                    if Task.isCancelled { return nil }
                    await Task.yield()
                }
                count += 1

                // Not walked into: asked, and walked by a walk of its own (see the doc above).
                if fileURL.hasDirectoryPath, fm.isDataless(at: fileURL) {
                    enumerator.skipDescendants()
                    guard let below = await walk(fileURL) else { return nil }
                    total += below.total
                    count += below.entries
                    failures.urls.append(contentsOf: below.failures)
                    continue
                }

                autoreleasepool {
                    guard let values = try? fileURL.resourceValues(forKeys: keySet),
                          values.isRegularFile == true,
                          let size = values.fileSize
                    else {
                        return
                    }
                    total += Int64(size)
                }
            }

            if Task.isCancelled { return nil }
            return (total, count, failures.urls)
        }

        guard var walked = await walk(url) else { return nil }
        var verdictRoot = url

        // A symlinked directory is not an unreadable one, but the walk alone can't tell them
        // apart: `enumerator(at:)` won't traverse a symlinked directory, yielding zero entries and
        // an error for the link's own URL, which `classify` calls `.unreadable` ("--").
        //
        // Same retry as `DirectoryListing.childCount`, through the same public
        // `traversableTarget`. A link to a locked directory, a broken link and a self-referential
        // link still report "--" through the `classify` below on the retried walk.
        // `aLinkToALockedFolderIsStillUnreadable` and `aBrokenOrSelfReferentialLinkHasNoSize` pin
        // that. No re-spelling as in `listing(of:)`: the number is the target's either way, so
        // `.producesRelativePathURLs` isn't needed.
        if DirectoryListingSupport.classify(
            entryCount: walked.entries, failures: walked.failures, root: verdictRoot).outcome == .unreadable,
           let target = DirectoryListingSupport.traversableTarget(of: url, using: fm) {
            guard let retried = await walk(target) else { return nil }
            walked = retried
            verdictRoot = target
        }

        let total = walked.total
        let formatted = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        switch DirectoryListingSupport.classify(
            entryCount: walked.entries, failures: walked.failures, root: verdictRoot).outcome {
        case .listed:
            return formatted
        case .listedWithUnreadableDescendants:
            // Part of the tree was withheld, so `total` is a floor: "+", the idiom of the review
            // card's "1000+ items". Except at zero, where "Zero KB+" would read as a size and state
            // nothing; a partial walk can total zero bytes, and a floor of zero is "--", no honest
            // number.
            return total == 0 ? nil : formatted + "+"
        case .unreadable:
            // Nothing was read: nil, which the caller renders as "--", not a size of zero.
            return nil
        }
    }
    
    // MARK: The Info inspector's layout (TE318 B)

    /// Picture, bar, then name, actions and grouped details. The file is named once, under its
    /// picture, and Kind and Size sit in the line under the name, where Finder's preview pane keeps
    /// them.
    @ViewBuilder
    private func inspectorLayout(summary: DetailsSelectionSummary?, data: FileMetadata?, icon: NSImage?,
                                 isStale: Bool, pictureStale: Bool, key: DirectorySizeTaskID) -> some View {
        if summary == nil, data == nil {
            // Nothing to draw yet is not "nothing selected": while the first stat is out, the panel
            // stays blank rather than contradict the click that brought it here.
            if isStale {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isShowingFocusedFolderFallback {
                EmptyStateView(
                    icon: "info.circle",
                    title: "No item selected",
                    message: "Select a file or folder to see its details here.",
                    layout: .compact
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A selected item the stat found nothing for: deleted since the last scan, moved,
                // or unreadable. "No item selected" over a selection would be wrong.
                EmptyStateView(
                    icon: "questionmark.folder",
                    title: "Can’t show this item",
                    message: "It is no longer here, or SyncCloud can’t read it.",
                    layout: .compact
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            InspectorSplit(fraction: previewFraction, defaultFraction: Self.defaultPreviewFraction) {
                inspectorPicture(summary: summary, data: data, icon: icon, isStale: pictureStale)
            } lower: {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 14) {
                        inspectorCaption(summary: summary, data: data, key: key)
                        // Hidden while the card is a beat behind the selection: an action must act
                        // on the item the name above it says.
                        if summary == nil, let data, !isStale {
                            inspectorActions(for: data)
                        }
                        if summary == nil, let data {
                            Divider()
                            inspectorGroups(for: data, key: key)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    /// The host's preview for one file; otherwise the item's icon, in the same frame, so going from
    /// a file to a folder moves nothing below it. The preview only while the details describe the
    /// file it shows; see `previewPath`.
    @ViewBuilder
    private func inspectorPicture(summary: DetailsSelectionSummary?, data: FileMetadata?, icon: NSImage?,
                                  isStale: Bool) -> some View {
        Group {
            if summary == nil, !isStale, let preview, let data, data.path == previewPath {
                preview
            } else if summary != nil {
                Image(systemName: "square.fill.on.square.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.secondary)
            } else if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 128, maxHeight: 128)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspectorCaption(summary: DetailsSelectionSummary?, data: FileMetadata?,
                                  key: DirectorySizeTaskID) -> some View {
        let title = summary?.title ?? data?.name ?? ""
        let subtitle: String = {
            if let summary { return "\(summary.kindDescription) · \(summary.sizeDescription)" }
            guard let data else { return "" }
            let facts = "\(data.kind) · \(displaySize(for: data, key: key))"
            return isShowingFocusedFolderFallback ? "Focused folder · " + facts : facts
        }()
        return VStack(spacing: 3) {
            Text(title)
                .scaledFont(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(subtitle)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// One of the verbs in the row under the name.
    enum InspectorAction: CaseIterable, Hashable {
        case openInEdit, quickLook, revealInFinder, copyPath

        var title: String {
            switch self {
            case .openInEdit: return "Open in Edit"
            case .quickLook: return "Quick Look"
            case .revealInFinder: return "Reveal in Finder"
            case .copyPath: return "Copy Path"
            }
        }

        var symbol: String {
            switch self {
            case .openInEdit: return "square.and.pencil"
            case .quickLook: return "doc.viewfinder"
            case .revealInFinder: return RevealGlyph.inFinder
            case .copyPath: return "doc.on.clipboard"
            }
        }

        var help: String {
            self == .openInEdit ? "Open this file in Edit, SyncCloud’s own editor" : title
        }
    }

    /// The row, in order: Open in Edit first where the file opens there (`offersEditor`), as the
    /// row menu leads with it, then the three every item gets. Pure, so a test can read the order:
    /// the buttons are icons of one width, and a rendered row can't tell them apart.
    static func inspectorActionRow(offersEditor: Bool) -> [InspectorAction] {
        InspectorAction.allCases.filter { $0 != .openInEdit || offersEditor }
    }

    /// The verbs as one row of icons, always directly under the name, so they don't move with
    /// however many facts there are.
    private func inspectorActions(for data: FileMetadata) -> some View {
        let offers = Self.offersEditor(handOff: editorHandOff, data: data)
        return HStack(spacing: 8) {
            ForEach(Self.inspectorActionRow(offersEditor: offers), id: \.self) { action in
                Button { perform(action, on: data) } label: {
                    Label(action.title, systemImage: action.symbol)
                        .labelStyle(.iconOnly)
                }
                .chromeHover()
                .help(action.help)
                .accessibilityLabel(action.title)
            }
        }
        .chromeButtonStyle(glassLevel)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func perform(_ action: InspectorAction, on data: FileMetadata) {
        switch action {
        case .openInEdit:
            editorHandOff?.open(data.path)
        case .quickLook:
            quickLookItem = URL(fileURLWithPath: data.path)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: data.path)])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(data.path, forType: .string)
        }
    }

    /// The remaining facts in three short groups instead of one long list.
    private func inspectorGroups(for data: FileMetadata, key: DirectorySizeTaskID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            inspectorGroup("Location", lines: [.fact("Where:", data.path)]
                                              + whereItLivesLines(for: data, key: key))
            Divider()
            inspectorGroup("Dates", lines: [.fact("Created:", data.creationDate),
                                            .fact("Modified:", data.modificationDate)])
            Divider()
            inspectorGroup("Access", lines: [.fact("Permissions:", data.permissions)])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorGroup(_ title: String, lines: [DetailsMetadataLine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .scaledFont(.caption)
                .fontWeight(.semibold)
                .tracking(0.4)
                .foregroundStyle(.secondary)
            DetailsMetadataGrid(lines: lines)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the inspector offers to open its file in Edit.
    ///
    /// Pure and static, so tests can call the rule rather than mount it. Three terms: no hand-off
    /// means the host has no editor; a directory never offers it, because this card renders for
    /// focused folders too and `kind` is a localized UTI description that can't be asked; and the
    /// host answers per path, because the closure is fixed when this view is built and the
    /// selection is not.
    static func offersEditor(handOff: EditorHandOff?, data: FileMetadata) -> Bool {
        guard let handOff, !data.isDirectory else { return false }
        return handOff.isOffered(data.path)
    }

    // MARK: Where it lives

    /// What the *On this Mac* row says for one materialization answer, or nil when there is
    /// nothing honest to put there.
    ///
    /// Static and pure so the wording is pinned without mounting anything: the three states and the
    /// one non-state are all this row can say.
    ///
    /// nil for a directory: a folder has no content of its own to be downloaded, and its children
    /// can each answer differently, so calling it "downloaded" would over-claim. *Where it lives*
    /// says where a folder is instead; see `FileLocation.folderLabel`.
    static func onThisMacText(isDirectory: Bool, isCloudOnly: Bool?, hasAnswer: Bool) -> String? {
        guard !isDirectory else { return nil }
        guard hasAnswer else { return "Checking…" }
        guard let isCloudOnly else { return nil }
        return isCloudOnly ? "No — placeholder only" : "Yes — downloaded"
    }

    /// What the *Where it lives* row says, or nil for no row; static and pure, like
    /// `onThisMacText`.
    ///
    /// A file gets the verdict: containment crossed with its materialization answer, so none until
    /// that answer is in. A folder gets containment alone (`FileLocation.folderLabel`), which needs
    /// no stat; this row is the only place the app says it. Neither without a coverage answer to
    /// judge against.
    static func whereItLivesText(path: String, isDirectory: Bool, coverage: FileLocation.Coverage?,
                                 isCloudOnly: Bool?, hasAnswer: Bool) -> String? {
        guard let coverage else { return nil }
        if isDirectory { return FileLocation.folderLabel(forPath: path, in: coverage) }
        guard hasAnswer else { return nil }
        return FileLocation.verdict(forPath: path, in: coverage, isCloudOnly: isCloudOnly)?.label
    }

    /// The supporting *On this Mac* row and the *Where it lives* verdict beneath it.
    ///
    /// Both are withheld when there is nothing provable to say: an unresolvable stat, an unknown
    /// coverage, or a dataless file outside every discovered provider root. An "Unknown" row would
    /// suggest SyncCloud looked and found nothing, when it did not look.
    private func whereItLivesLines(for data: FileMetadata, key: DirectorySizeTaskID) -> [DetailsMetadataLine] {
        // Keyed on the stat this card came from, like Size, so a card a beat behind the selection
        // says "Checking…" rather than crediting the previous file's answer to the current one.
        let settled = loadedLocation.flatMap { $0.key == key ? $0 : nil }
        var lines: [DetailsMetadataLine] = []
        if let text = Self.onThisMacText(isDirectory: data.isDirectory,
                                         isCloudOnly: settled?.isCloudOnly,
                                         hasAnswer: settled != nil) {
            lines.append(.fact("On this Mac:", text))
        }
        if let text = Self.whereItLivesText(path: data.path, isDirectory: data.isDirectory,
                                            coverage: cloudCoverage,
                                            isCloudOnly: settled?.isCloudOnly, hasAnswer: settled != nil) {
            lines.append(.fact("Where it lives:", text))
        }
        return lines
    }
}

/// One line of the Info card's metadata table: a labelled fact, or a rule between two groups.
enum DetailsMetadataLine: Equatable {
    case fact(String, String)
    case divider
}

/// The Info card's label/value table, as a `Grid` whose label column takes its widest label at
/// every text size; a fixed column would wrap "Where it lives:" even at the default size.
///
/// The labels never wrap (`fixedSize`); the values take the rest and wrap. Both follow the app's
/// text size, like the card's title above them.
///
/// When the labels leave the values too little room (large text in a narrow inspector), each label
/// goes above its value. The side-by-side grid is offered only when its value column can be at
/// least ``minimumValueWidth`` wide (`ViewThatFits`, reading the grid's ideal width as the widest
/// label plus that); otherwise the facts stack.
struct DetailsMetadataGrid: View {
    let lines: [DetailsMetadataLine]
    @Environment(\.appFontScale) private var scale

    /// The narrowest value column worth drawing beside its label.
    static let minimumValueWidth: CGFloat = 64
    static let columnSpacing: CGFloat = 8

    /// The width the side-by-side grid needs: its widest label, the gap, and a usable value column.
    static func columnsWidth(labels: [String], scale: CGFloat) -> CGFloat {
        let widest = labels.map { LabelMetrics.width(of: $0, font: .body, scale: scale) }.max() ?? 0
        return widest + columnSpacing + minimumValueWidth
    }

    private var labels: [String] {
        lines.compactMap { if case let .fact(label, _) = $0 { label } else { nil } }
    }

    var body: some View {
        let needed = Self.columnsWidth(labels: labels, scale: scale)
        ViewThatFits(in: .horizontal) {
            columns.frame(minWidth: needed, idealWidth: needed, maxWidth: .infinity, alignment: .leading)
            stacked
        }
    }

    /// Each label above its value, for a column too narrow to hold both side by side.
    var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .divider:
                    Divider()
                case let .fact(label, value):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .scaledFont(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(value)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The labels in a trailing-aligned column beside their values.
    var columns: some View {
        Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .divider:
                    Divider()
                case let .fact(label, value):
                    GridRow(alignment: .top) {
                        Text(label)
                            .scaledFont(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                        Text(value)
                            .scaledFont(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// How a host opens one of its files in the Edit workspace, handed to ``DetailsSidebar``.
///
/// Two closures, and neither is optional per file: a closure is fixed when the view is built while
/// the selection changes underneath it, so a nil chosen at construction would answer for whichever
/// file was selected then. `isOffered` is asked per path, on every render, and must be cheap and
/// I/O-free (in the app it is `EditableText.opensInEdit`, which reads a path extension).
///
/// One value rather than two parameters, as with `PaneRowVerbs`: a host can't wire one and forget
/// the other, leaving a button that looks live and does nothing.
///
/// The whole value is optional: nil means this host has no editor, and the row offers no Open in
/// Edit. The Dashboard package learns nothing about what a text file is; the app passes it down.
public struct EditorHandOff {
    /// Whether the editor opens the file at this path. Asked per render, per path.
    public let isOffered: (String) -> Bool
    /// Hands the file at this path to the editor.
    public let open: (String) -> Void

    public init(isOffered: @escaping (String) -> Bool, open: @escaping (String) -> Void) {
        self.isOffered = isOffered
        self.open = open
    }
}
