import SwiftUI
import Sync
import Events
import Combine
import UniformTypeIdentifiers
import AppKit
import Design

/// Sidebar that shows file/folder metadata (size, dates, permissions) for the current selection or focused folder.
/// Shown in the bottom tabbed area of the main view when the “Details” tab is selected.
public struct DetailsSidebar: View {
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @ObservedObject public var syncManager: FileSyncManager

    /// Current root path for the left pane (used when no item is selected).
    public let leftPath: String
    /// Current root path for the right pane (used when no item is selected).
    public let rightPath: String
    /// Lays the icon above the metadata (vertical) instead of beside it (horizontal), for the narrow
    /// Compare Info inspector where a side-by-side icon column would starve the values of width.
    public let compact: Bool
    /// An explicit path to inspect, overriding the pane selection — set by "Get Info" on a
    /// differences-table row, whose file has no pane selection to derive from. nil = follow selection.
    public let overridePath: String?
    /// True when the inspector is showing the single-source rail (which is the left pane). The
    /// right pane is hidden there, so its (possibly stale) selection from a prior Compare session must
    /// not drive the inspector — otherwise the panel would describe a file in the wrong provider.
    public let singleSource: Bool
    /// The cloud ground the *Where it lives* rows are resolved against — see `FileLocation`.
    ///
    /// **nil means "the coverage is not known here", and draws no verdict at all.** That is the
    /// safe default rather than `.none`: an empty coverage is a positive claim that no cloud
    /// folder contains anything, so a caller who forgot to pass this would have every file in
    /// iCloud reported as *This Mac only* — the exact false statement this feature exists not to
    /// make. Absent is absent.
    public let cloudCoverage: FileLocation.Coverage?

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
    /// `.quickLookPreview`, mirroring `FileTreeView` — the sidebar has no host presenter to
    /// delegate to and the shared QL panel only shows one preview at a time anyway.
    @State private var quickLookItem: URL?

    /// Shared formatter for created/modified dates. Reused instead of reallocated on every access
    /// of `metadata` (DateFormatter is expensive to construct).
    ///
    /// `nonisolated` so the stat that reads it can run off the main actor — see
    /// `loadMetadata(for:fileManager:)`. Safe: it is fully configured here and never mutated
    /// afterwards, and `DateFormatter` is documented thread-safe for formatting on macOS 10.9+
    /// (which is why Foundation marks it `Sendable`).
    nonisolated private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
    
    public init(syncManager: FileSyncManager, leftPath: String, rightPath: String, compact: Bool = false, overridePath: String? = nil, singleSource: Bool = false, cloudCoverage: FileLocation.Coverage? = nil) {
        self.init(syncManager: syncManager, leftPath: leftPath, rightPath: rightPath,
                  compact: compact, overridePath: overridePath, singleSource: singleSource,
                  cloudCoverage: cloudCoverage, cache: DetailsMetadataCache())
    }

    /// Test seam: hands in the metadata cache instead of letting `@State` mint one, so a test can
    /// control the loader behind it — specifically, hold it hostage and prove the first frame still
    /// paints. `DetailsMetadataCache` is internal, which is why this initializer cannot be the
    /// public one.
    init(syncManager: FileSyncManager, leftPath: String, rightPath: String, compact: Bool,
         overridePath: String?, singleSource: Bool, cloudCoverage: FileLocation.Coverage? = nil,
         cache: DetailsMetadataCache) {
        self.syncManager = syncManager
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.compact = compact
        self.overridePath = overridePath
        self.singleSource = singleSource
        self.cloudCoverage = cloudCoverage
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
    /// The reason is *returned* rather than logged from inside the loader for two reasons. The
    /// loader now runs off the main actor, where a `@MainActor` logging sink cannot be reached
    /// at all; and the caller — `DetailsMetadataCache` — is the only party that knows a re-stat
    /// of the same path is not news, which is what its `warnedPaths` rate limit is for.
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

    /// The path to display metadata for: first selected path in either pane, or the focused folder path.
    internal var activePath: String {
        // A "Get Info" target wins over the pane selection (a differences-table row has no pane
        // selection of its own).
        if let overridePath, !overridePath.isEmpty { return overridePath }
        // Was a hand-written copy of the left-first `min()` rule, under a comment claiming it
        // matched `PaneLogic.primarySelectionPath` — it re-derived it instead, which is how the
        // inspector and Space came to disagree about which file was current. Both now call this.
        if let selected = CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: singleSource
        ) {
            return selected
        }

        // Fallback to navigated folders
        return leftPath.isEmpty ? rightPath : leftPath
    }

    /// True when `activePath` fell back to the focused folder rather than a user-chosen item.
    /// Drives the "— focused folder" caption so the metadata card doesn't read as a selection the
    /// user made.
    ///
    /// It has to answer for the SAME branches `activePath` takes, and it used to answer for only
    /// one of them: it re-derived "no pane selection" by hand and ignored `overridePath` entirely.
    /// So "Get Info" on a differences row — which sets the override precisely when no pane holds a
    /// selection — showed that file's metadata captioned "— focused folder", which is wrong twice
    /// over: it is not the focused folder, and it IS an item the user chose. Now it mirrors
    /// `activePath`'s own order, override first and the shared resolver second.
    internal var isShowingFocusedFolderFallback: Bool {
        if let overridePath, !overridePath.isEmpty { return false }
        return CurrentSelection.primaryPanePath(
            left: syncManager.selectedLeftPaths,
            right: syncManager.selectedRightPaths,
            singleSource: singleSource
        ) == nil
    }

    /// Non-nil when 2+ items are selected: the sidebar shows the Finder-style summary instead
    /// of single-item metadata (which would silently describe only the alphabetically-first
    /// path). Left pane wins when both have selections — the same rule as `activePath`.
    ///
    /// Resolved through the manager's cached path→node index, NOT `leftTree.findNodes` — this is
    /// read from `body`, and the walk costs 8–11ms per render whenever the selection sits deep in
    /// the tree or holds a path a rescan has removed. See `DetailsSelectionSummary.make(selectedPaths:resolving:)`.
    internal var selectionSummary: DetailsSelectionSummary? {
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
    /// Held in `@State` and filled by a task rather than resolved inline, because resolving it
    /// inline meant resolving it *inside `body`* — and the resolve is four blocking filesystem
    /// calls (`fileExists`, `attributesOfItem`, a `typeIdentifier` fetch, and
    /// `NSWorkspace.icon(forFile:)`, which looks for a custom icon resource). The memo in
    /// `DetailsMetadataCache` bounded how OFTEN they ran but not WHERE: it is dropped after every
    /// file operation and at the end of every scan, and `activePath` changes on every click, so in
    /// practice each click on a file serialized the pane's own re-render behind four stats against
    /// a cloud path.
    ///
    /// Landing them in state instead means the click paints first and the card fills a beat later.
    ///
    /// That reordering alone was **not** enough, and the note that used to sit here saying the
    /// stats "still run on the main actor … the next step if it measures" understated it: a
    /// `View`'s `.task` inherits the view's `@MainActor` isolation, so the syscalls were still on
    /// the main thread and a wedged `getxattr` still froze the app at launch. They now run on
    /// `DetailsMetadataCache.ioQueue`; see `loadMetadata(for:fileManager:)`.
    private struct LoadedDetails: Equatable {
        let key: DirectorySizeTaskID
        let metadata: FileMetadata?
        let icon: NSImage?

        static func == (lhs: LoadedDetails, rhs: LoadedDetails) -> Bool { lhs.key == rhs.key }
    }

    /// Whether this file's content is on this Mac, for the item the card is describing.
    ///
    /// **Its own task, and its own state, deliberately.** The obvious alternative was to fold the
    /// `lstat` into `DetailsMetadataCache.load(for:)` alongside the other four syscalls. That
    /// couples one more answer to a memo whose invalidation rules are tuned for metadata, and —
    /// more to the point — the metadata card is what the user is waiting for on every click. A
    /// separate task lets the name, size and dates paint the moment they land while this row is
    /// still resolving, instead of holding all of them behind the slowest stat against a cloud
    /// path.
    ///
    /// **The `lstat` runs off the main actor.** `MaterializationStatus.isCloudOnlyIfKnown` is a
    /// single `lstat`, which is cheap right up until it is not: this sidebar is the surface that
    /// froze the app at launch on a wedged `getxattr` (2026-07-30, with zero windows and an empty
    /// log), and a `View`'s `.task` inherits the view's `@MainActor` isolation. `Task.detached` is
    /// what actually gets it off the main thread — the same shape `CloudOnlyBadgeCache` uses for
    /// the row badge's copy of this stat.
    ///
    /// `isCloudOnly` keeps its Optional: nil is "the stat could not answer", which is a different
    /// fact from "the content is here" and draws nothing at all rather than a guess.
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
    /// An empty result is genuinely ambiguous to the caller — a path that isn't there and a path
    /// the app is not allowed to read both render the same empty inspector — so the second case
    /// carries a breadcrumb back in `MetadataLoad.failure`. Without it a permissions or IO failure
    /// on a cloud provider was indistinguishable from "nothing selected", with nothing recorded
    /// anywhere to say otherwise.
    ///
    /// This function reports EVERY failed stat — the once-per-path limit belongs to the caller that
    /// knows a re-stat is a re-stat, `DetailsMetadataCache` (see its `warnedPaths`). The claim used
    /// to be made here and rest on that cache's memo, which is wrong: the memo is dropped after
    /// every file operation, so a bulk run of N operations over an unreadable selection wrote N
    /// identical warnings.
    ///
    /// ## Why this is `nonisolated`
    ///
    /// **Every call below can block indefinitely.** `attributesOfItem(atPath:)` reaches
    /// `getxattr`, which on a wedged file provider (bird/fileproviderd) does not return — measured
    /// 2026-07-30: `xattr -l ~/Documents` blocked >8s with no SyncCloud process running at all,
    /// while a plain `stat` of the same path answered in 6ms. `f77bdc3` moved this call out of the
    /// render pass and into a `.task`, which is the right shape but not sufficient: a `View`'s
    /// `.task` closure is `@MainActor`-isolated, so the syscall still ran on the main thread and
    /// still froze the app — with zero windows and an empty log when it happened during launch.
    ///
    /// Being `nonisolated` is what lets `DetailsMetadataCache` run it on a private queue. It must
    /// therefore stay free of main-actor state: `logError` is gone (the failure comes back in the
    /// return value) and `dateFormatter` is `nonisolated`.
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
            // The item exists (the guard above passed) but its attributes could not be read —
            // a permissions failure, or a cloud provider's placeholder that won't materialize.
            // Say so; the inspector itself can only fall silent.
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
        // Read out of state, never resolved here: the lookup hits the filesystem, and `body` is the
        // one place it must not run from. See `LoadedDetails`.
        //
        // Stale-while-revalidate, the same rule the pane trees follow. Withholding the previous
        // answer until the new stat lands would drop the card into its "No item selected" branch
        // for the turn in between — a flash saying the opposite of what the user just did. The
        // pair is held together in one value, so a stale card is internally consistent (this
        // file's icon, this file's name); it is only a beat behind. What it must NOT do is offer
        // to act, which is why `metadataActions` is withheld while stale — Reveal and Quick Look
        // would otherwise target the previous file.
        let shown = loaded
        let isStale = shown?.key != sizeKey
        let (data, icon): (FileMetadata?, NSImage?) = (shown?.metadata, shown?.icon)
        // Compact (narrow inspector): stack the icon above the metadata so values get the full width.
        // Wide (bottom pane): the icon sits in a column beside the metadata.
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .center, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top))
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                layout {
                    if let summary {
                        // Stack-of-documents header mirroring the single-item icon column.
                        VStack {
                            Image(systemName: "square.fill.on.square.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 56, height: 56)
                                .foregroundStyle(.secondary)
                                .padding(.top, 28)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 120)

                        VStack(alignment: .leading, spacing: 12) {
                            Text(summary.title)
                                .scaledFont(.title2)
                                .fontWeight(.semibold)
                                .padding(.top, 10)

                            Divider()

                            metadataRow(label: "Items:", value: summary.kindDescription)
                            metadataRow(label: "Size:", value: summary.sizeDescription)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 20)

                        Spacer(minLength: 0)
                    // The cache loads the icon whenever the metadata stat succeeds, so `icon`
                    // is non-nil exactly when `data` is — one binding, no fallback icon path.
                    } else if let data, let icon {
                        // Icon Header
                        VStack {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .padding(.top, 16)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 120)
                        
                        // Metadata Table
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(data.name)
                                    .scaledFont(.title2)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                // Nothing is selected — clarify this is the focused folder,
                                // not an item the user chose.
                                if isShowingFocusedFolderFallback {
                                    Text("— focused folder")
                                        .scaledFont(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                            .padding(.top, 10)

                            Divider()

                            metadataRow(label: "Kind:", value: data.kind)
                            // Keyed on the stat this card came from, not on the live key: a folder
                            // total belongs to the item it was walked for, so a stale card reads
                            // "Calculating…" rather than crediting the previous folder's size to
                            // the one now selected.
                            metadataRow(label: "Size:", value: displaySize(for: data, key: shown?.key ?? sizeKey))
                            metadataRow(label: "Where:", value: data.path)

                            // The supporting facts, then the verdict — in that order, and directly
                            // under the path they are drawn from. "Where it lives" names a
                            // provider because the path above is inside that provider's folder,
                            // and says the content is here because the row above says so. Put the
                            // verdict first and it reads as an oracle; put the facts first and the
                            // row explains itself.
                            whereItLivesRows(for: data, key: shown?.key ?? sizeKey)

                            Divider()

                            metadataRow(label: "Created:", value: data.creationDate)
                            metadataRow(label: "Modified:", value: data.modificationDate)

                            Divider()

                            metadataRow(label: "Permissions:", value: data.permissions)

                            // Withheld while the card is a beat behind the selection — see the
                            // stale-while-revalidate note in `body`. Reveal / Copy Path / Quick
                            // Look all name `data.path`, and for the turn between the click and
                            // the stat landing that is still the PREVIOUS file.
                            if !isStale {
                                Divider()

                                metadataActions(for: data)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 20)
                        
                        Spacer(minLength: 0)
                    } else {
                        EmptyStateView(
                            icon: "info.circle",
                            title: "No item selected",
                            message: "Select a file or folder in either pane to see its details here.",
                            layout: .compact
                        )
                        .frame(minHeight: 120)
                    }
                }
            }
            .padding(20)
        }
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
            // Still the memoized lookup — `DetailsMetadataCache` keeps owning the per-path memo
            // and the once-per-path warning. What changed is where a miss runs.
            //
            // `load(for:)` serves a memo hit without ever suspending, so a re-render of an
            // already-loaded path still paints its card in one pass; there is deliberately no
            // separate `cached(for:)` branch here, which would only duplicate that check. A miss
            // suspends and the syscalls run on the cache's private queue; until they land, `body`
            // renders the previous card (see the stale-while-revalidate note there). If they
            // never land, this task simply stays suspended — the window is already on screen.
            let entry = await cache.load(for: sizeKey.path)
            guard !Task.isCancelled else { return }
            loaded = LoadedDetails(key: sizeKey, metadata: entry.metadata, icon: entry.icon)
        }
        // The materialization half of *Where it lives*, off the main actor and off the metadata
        // card's critical path — see `LoadedLocation`.
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
            // does not throw, so this resumes carrying a stale answer after the selection has
            // moved on — the same window `FileRowView.resolveBadge` closes for the row badge.
            guard !Task.isCancelled else { return }
            loadedLocation = LoadedLocation(key: sizeKey, isCloudOnly: answer)
        }
        // Keyed on the walk id, not the base key: the metadata this depends on now arrives
        // asynchronously, so a task keyed on the base alone would run once — before the stat
        // landed — see a nil `data`, bail, and never re-fire, leaving every folder reading
        // "Calculating…" forever.
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

    nonisolated private static func computeDirectorySizeString(path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        // Descend into package bundles (.app, .rtfd, .photoslibrary…) so their contents count
        // toward the folder total, matching Finder's Get Info. `.skipsPackageDescendants` would
        // treat each bundle as 0 bytes and understate the size.
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return nil
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
            
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let size = values.fileSize
                else {
                    return
                }
                total += Int64(size)
            }
        }

        if Task.isCancelled { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    /// Inline actions for the metadata card so the Details tab isn't a read-only dead end.
    /// Mirrors the file-row context menu (Reveal / Copy Path / Quick Look). Bordered + small to
    /// match the app's other inline action rows. Shown for both single-item and focused-folder
    /// renders — wherever `data` is non-nil.
    private func metadataActions(for data: FileMetadata) -> some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: data.path)])
            } label: {
                Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)
            }
            .chromeHover()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(data.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            .chromeHover()
            Button {
                quickLookItem = URL(fileURLWithPath: data.path)
            } label: {
                Label("Quick Look", systemImage: "doc.viewfinder")
            }
            .chromeHover()
        }
        // The inspector card takes the glass level verbatim, so at Clear these buttons frost
        // individually — a plain bordered fill has nothing to read against on see-through glass.
        .chromeButtonStyle(glassLevel)
        .controlSize(.small)
    }

    // MARK: Where it lives

    /// What the *On this Mac* row says for one materialization answer, or nil when there is
    /// nothing honest to put there.
    ///
    /// A static pure function so the wording is pinned without mounting anything — the three
    /// states and the one non-state are the whole of what this row can say.
    ///
    /// nil for a DIRECTORY: a folder has no content of its own to be downloaded or not, and its
    /// children can each answer differently. Claiming a folder is "downloaded" because its
    /// directory entry is on disk would be the one kind of over-claim this feature must not make.
    /// (The ⌂ row badge still marks folders, because that is a containment claim — where the
    /// folder *is* — which is sound for one.)
    static func onThisMacText(isDirectory: Bool, isCloudOnly: Bool?, hasAnswer: Bool) -> String? {
        guard !isDirectory else { return nil }
        guard hasAnswer else { return "Checking…" }
        guard let isCloudOnly else { return nil }
        return isCloudOnly ? "No — placeholder only" : "Yes — downloaded"
    }

    /// The supporting *On this Mac* row and the *Where it lives* verdict beneath it.
    ///
    /// Both are withheld entirely when there is nothing provable to say — an unresolvable stat, an
    /// unknown coverage, or a dataless file outside every discovered provider root. A row that
    /// said "Unknown" would be worse than no row: it invites the reading that SyncCloud looked and
    /// found nothing, when it did not look.
    @ViewBuilder
    private func whereItLivesRows(for data: FileMetadata, key: DirectorySizeTaskID) -> some View {
        // Keyed on the stat this card came from, exactly like Size: a location answer belongs to
        // the item it was measured for, so a card that is a beat behind the selection says
        // "Checking…" rather than crediting the previous file's answer to the current one.
        let settled = loadedLocation.flatMap { $0.key == key ? $0 : nil }
        if let text = Self.onThisMacText(isDirectory: data.isDirectory,
                                         isCloudOnly: settled?.isCloudOnly,
                                         hasAnswer: settled != nil) {
            metadataRow(label: "On this Mac:", value: text)
        }
        if !data.isDirectory, let settled, let coverage = cloudCoverage,
           let verdict = FileLocation.verdict(forPath: data.path, in: coverage,
                                             isCloudOnly: settled.isCloudOnly) {
            metadataRow(label: "Where it lives:", value: verdict.label)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            // Allow text to wrap across multiple lines
            Text(value)
                .textSelection(.enabled) 
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
