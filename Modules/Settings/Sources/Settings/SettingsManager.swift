import Events
import Foundation
import SwiftUI
import Sync

/// What `SettingsManager.setPath` or `setOpenAt` did with a folder the user picked.
///
/// Exists so a refusal is visible. The Location field commits on Return and on focus loss, so a
/// quiet refusal would leave the rejected text in the field looking accepted; the "Open at"
/// picker's panel closes either way. Keep each refusal its own case: a shared case would carry a
/// payload that is wrong for one of them.
public enum PathChangeOutcome: Equatable, Sendable {
    /// The new path was stored.
    case changed
    /// Nothing to do: that is already this provider's path, or the edit was empty.
    case unchanged
    /// Refused, because `existingId` already names that folder and one folder gets one row.
    /// Only a folder source is ever refused this way — see `setPath` for why an account is not.
    case refusedDuplicate(existingId: String)
    /// Refused, because the chosen landing folder is not inside the source's root. No payload: the
    /// caller knows which source it asked about, and the root is on screen beside the picker.
    case refusedOutsideRoot
    /// Refused, because the source is not in the discovered list — it was dropped or is still being
    /// discovered while its row is on screen. Nothing was written.
    case refusedUnknownSource
}

/// What one pass over the CloudStorage root found, and whether it could read the root at all.
///
/// Not a bare `[URL]`, because an empty array would mean both "no cloud accounts are mounted"
/// (ordinary on an iCloud-only Mac) and "the root could not be listed". Discovery publishes over
/// the provider list, so reading the second as the first would delete every account the user has.
public struct CloudStorageAccounts: Sendable, Equatable {
    /// The account folders directly under the root.
    public let folders: [URL]
    /// False only when the root exists and could not be listed. An absent root is `true` with no
    /// folders. `FileManager.enumerator(at:)` yields nothing for an empty, an unreadable and a
    /// missing directory alike, and its `errorHandler` fires for the last two, so only a stat on
    /// the root separates "nothing to find" from "could not look".
    public let rootWasReadable: Bool

    /// The root was read. The folders are the whole truth, empty included.
    public static func read(_ folders: [URL]) -> CloudStorageAccounts {
        CloudStorageAccounts(folders: folders, rootWasReadable: true)
    }

    /// The root is there and could not be listed: no folders, and no claim that there are none.
    public static let unreadableRoot = CloudStorageAccounts(folders: [], rootWasReadable: false)

    public init(folders: [URL], rootWasReadable: Bool) {
        self.folders = folders
        self.rootWasReadable = rootWasReadable
    }
}

/// Discovers the cloud providers and folder sources the app can show, and persists the user's
/// per-provider overrides and app-wide settings in `UserDefaults`.
@MainActor
public class SettingsManager: ObservableObject {
    /// Lists the account folders mounted under the CloudStorage root (one URL per provider account).
    public typealias CloudStorageLister = @Sendable () -> CloudStorageAccounts

    /// Reports whether a provider's root path currently exists as a directory.
    public typealias PathValidator = @Sendable (String) -> Bool

    /// The discovered providers and folder sources, sorted by type and then put in the user's
    /// order (`inUserOrder`).
    @Published public var availableProviders: [CloudProvider] = []

    /// Whether each provider's root path exists as a directory, keyed by provider id. Recomputed on
    /// every `discoverProviders()` pass, even one that changes no provider, so the validity badge
    /// re-checks the disk on refresh and after path edits without views stat-ing per render.
    @Published public private(set) var pathValidity: [String: Bool] = [:]

    /// Whether each provider's landing folder (`rootPath` + `openAt`) exists as a directory.
    ///
    /// Separate from `pathValidity` because the consequences differ: a missing root is a broken
    /// source, while a missing landing folder is a stale preference and a pane opens at the root
    /// instead (`openAtIfReachable`). Computed in the same pass with the same validator, so the
    /// pair is one consistent reading of the disk.
    @Published public private(set) var landingValidity: [String: Bool] = [:]

    /// Provider ids the user switched off in Settings. Stored as the disabled set (not the
    /// enabled one) so newly discovered accounts default to enabled. Ids of providers that
    /// later disappear from disk are kept: if the account is re-mounted it stays disabled.
    @Published public private(set) var disabledProviderIds: Set<String>

    /// The discovered providers the rest of the app may offer as pane roots — everything the
    /// user hasn't disabled. Settings itself lists `availableProviders` so disabled entries
    /// remain visible and re-enableable.
    public var enabledProviders: [CloudProvider] {
        availableProviders.filter { !disabledProviderIds.contains($0.id) }
    }

    /// The user's dragged source order, empty until they drag one.
    @Published public private(set) var sourceOrder: [String] = []

    /// Records the order a drag produced, and republishes the list in it. Stores the whole
    /// sequence, not a delta, so the stored order always matches what was on screen.
    public func setSourceOrder(_ ids: [String]) {
        guard ids != sourceOrder else { return }
        sourceOrder = ids
        userDefaults.set(ids, forKey: Self.sourceOrderKey)
        availableProviders = Self.inUserOrder(availableProviders, order: ids)
    }

    /// Providers in the user's order, with anything the order does not name kept in discovery
    /// order behind those it does.
    ///
    /// Same shape as `FolderJumpStore.orderedFavorites`: no migration or seed needed. An empty
    /// order gives discovery order, and a newly connected account appends rather than jumping to
    /// the front. A stable partition, not one `sorted(by:)`, because Swift's sort is not stable and
    /// the unnamed tail could shuffle between launches.
    nonisolated static func inUserOrder(_ providers: [CloudProvider], order: [String]) -> [CloudProvider] {
        guard !order.isEmpty else { return providers }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var ranked: [(CloudProvider, Int)] = []
        var unranked: [CloudProvider] = []
        for provider in providers {
            if let index = rank[provider.id] { ranked.append((provider, index)) } else { unranked.append(provider) }
        }
        ranked.sort { $0.1 < $1.1 }
        return ranked.map(\.0) + unranked
    }

    /// The cloud ground the discovered sources cover, for the *Where it lives* inspector row — see
    /// `FileLocation`.
    ///
    /// Built from `availableProviders`, never `enabledProviders`: a switched-off provider's folder
    /// is still on disk, so its files still have a second copy, and a checkbox must not report risk
    /// that is not there. The disabled set goes to `FileLocation.coverage` so that rule is tested
    /// there. Not cached: it is a compactMap over a handful of providers, read once per inspector
    /// render.
    public var cloudCoverage: FileLocation.Coverage {
        FileLocation.coverage(of: availableProviders, disabledProviderIds: disabledProviderIds)
    }

    private let userDefaults: UserDefaults
    /// The persistent defaults domain that owns the override keys, when known. Reading it alone
    /// keeps global-domain keys from being honored as overrides (`overridesByProviderId`). Nil
    /// reads the merged search list.
    private let overridesDomainName: String?
    private let listCloudStorageFolders: CloudStorageLister
    /// Directory-existence check behind `pathValidity` and `landingValidity`.
    private let validatePath: PathValidator

    /// The account folders the last readable discovery pass found.
    ///
    /// A pass that cannot read the CloudStorage root learned nothing about which accounts are
    /// mounted, so it maps these instead; iCloud, folder sources and every override still come
    /// from the fresh pass. A count comparison can't do this job, because folder sources are in
    /// `availableProviders` too.
    ///
    /// Persisted (`lastKnownAccountFoldersKey`), because both jobs matter most at launch: the first
    /// pass is the one most likely to meet an unmounted root, and the init seed needs the cloud
    /// accounts so a pane restored onto one finds it in `enabledProviders`.
    private var lastKnownAccountFolders: [URL] = []
    /// Monotonic token for `discoverProviders()` passes: each claims the next value at entry and
    /// publishes only if no newer pass has published (`lastPublishedDiscoveryGeneration`). Passes
    /// overlap — init, Refresh, every path or name edit — and without it the last to finish would
    /// win and could republish stale paths. Same shape as `FileSyncManager.applyFilters`'
    /// filterGeneration.
    private var discoveryGeneration = 0
    /// Generation of the most recent discovery pass that published its results.
    private var lastPublishedDiscoveryGeneration = 0
    /// The legacy "Location" override: one absolute path that was the pane root, breadcrumb ceiling
    /// and scan scope at once.
    ///
    /// Read once by `RootsMigration` and **never written or removed**: older builds share this
    /// defaults domain and still read it as their Location, so changing it would break the setting
    /// in a build the user may return to.
    nonisolated static let legacyPathOverrideKeyPrefix = "path_override_"
    /// The root a source covers, when it is not the discovered one. Written only by
    /// `RootsMigration`, for an install whose legacy Location was outside the account folder: no
    /// discovered root contains it, so the path becomes the root. Settings has no editor for it.
    nonisolated static let rootOverrideKeyPrefix = "root_override_"
    /// The user's chosen landing folder, relative to the root. Empty string is a real value (the
    /// root itself); absent means "use the discovered default".
    nonisolated static let openAtOverrideKeyPrefix = "openAt_override_"
    private static let nameOverrideKeyPrefix = "name_override_"
    private static let ignoreGoogleDriveNewerDateOnlyKey = "ignoreGoogleDriveNewerDateOnly"
    private static let disabledProviderIdsKey = "disabledProviderIds"
    private static let dateToleranceSecondsKey = "dateToleranceSeconds"
    private static let defaultSortOptionKey = "defaultSortOption"
    private static let autoVerifySameSizeDuringScanKey = "autoVerifySameSizeDuringScan"
    private static let rescanWhenFilesChangeKey = "rescanWhenFilesChange"
    private static let rememberIgnoredItemsKey = "rememberIgnoredItems"
    private static let ignorePatternsKey = "ignorePatterns"
    private static let folderSourcesKey = "folderSources"
    /// The user's own order for the source list, as provider ids. Dragged in the Browse sidebar,
    /// but kept here so `availableProviders` is published in it and every source list agrees.
    private static let sourceOrderKey = "sourceOrder"
    /// The account folders the last readable discovery found, as absolute paths. Persists
    /// `lastKnownAccountFolders` across a quit; see there.
    private static let lastKnownAccountFoldersKey = "lastKnownAccountFolders"
    private static let folderNameRuleKey = "folderNameRuleProvider"

    /// The defaults domain the app persists to: its bundle identifier, which `.standard` resolves
    /// to inside the app. Un-bundled processes (the `synccloud` CLI) must pass
    /// `UserDefaults(suiteName: SettingsManager.appSuiteName)`: their `.standard` is a
    /// per-process domain that never sees the app's overrides. `nonisolated` so `RootsMigration`
    /// can use it as a default argument.
    nonisolated public static let appSuiteName = "com.abhishekgirish.SyncCloud"

    /// iCloud's discovered root: the iCloud Drive container, what Finder shows as "iCloud Drive".
    /// `PathBoundary.LinkedFolders` covers how `Documents` under it reaches `~/Documents`.
    nonisolated public static var iCloudDefaultPath: String {
        PathBoundary.iCloudDriveContainer
    }

    /// iCloud's root in older builds, `~/Documents`. `RootsMigration` maps old settings against
    /// this rather than the current default, since a migration describes what was on disk then.
    nonisolated public static var legacyICloudRoot: String {
        (NSString(string: "~/Documents")).expandingTildeInPath
    }

    /// iCloud's discovered landing folder: `Documents` when the container has one (the link
    /// Desktop & Documents syncing leaves, or a real folder), otherwise the root. Checked on disk
    /// so a Mac with that syncing off doesn't open at a folder that isn't there.
    nonisolated static func iCloudDefaultOpenAt(rootPath: String, validator: PathValidator) -> String {
        validator(PathBoundary.join(root: rootPath, relative: "Documents")) ? "Documents" : ""
    }

    /// When true, the Differences pane hides "right is newer" items when right is Google Drive and
    /// sizes match, since Drive rewrites file dates.
    @Published public var ignoreGoogleDriveNewerDateOnly: Bool {
        didSet {
            userDefaults.set(ignoreGoogleDriveNewerDateOnly, forKey: Self.ignoreGoogleDriveNewerDateOnlyKey)
        }
    }

    /// Modification dates within this many seconds compare as equal during scans (0 = exact).
    /// Mirrored into `FileSyncManager.dateToleranceSeconds` by the app.
    @Published public var dateToleranceSeconds: Double {
        didSet {
            userDefaults.set(dateToleranceSeconds, forKey: Self.dateToleranceSecondsKey)
        }
    }

    /// When true, scans finish with a checksum pass that hides same-size pairs whose content
    /// is identical. Mirrored into `FileSyncManager.autoVerifySameSizeDuringScan` by the app.
    @Published public var autoVerifySameSizeDuringScan: Bool {
        didSet {
            userDefaults.set(autoVerifySameSizeDuringScan, forKey: Self.autoVerifySameSizeDuringScanKey)
        }
    }

    /// When true, a change on disk under either pane rescans it by itself. Off by default: the
    /// panes then only say their folder changed, so nothing moves under someone reviewing a list.
    /// Read by the app each time the watcher reports.
    @Published public var rescanWhenFilesChange: Bool {
        didSet {
            userDefaults.set(rescanWhenFilesChange, forKey: Self.rescanWhenFilesChangeKey)
        }
    }

    /// When true (the default), ignored items persist across rescans, navigation, and
    /// relaunches. Mirrored into `FileSyncManager.rememberIgnoredItems` by the app.
    @Published public var rememberIgnoredItems: Bool {
        didSet {
            userDefaults.set(rememberIgnoredItems, forKey: Self.rememberIgnoredItemsKey)
        }
    }

    /// Name patterns hidden from the Differences list on every scan (see `IgnoreRules`).
    /// Mirrored into `FileSyncManager.ignorePatterns` by the app.
    @Published public var ignorePatterns: [String] {
        didSet {
            userDefaults.set(ignorePatterns, forKey: Self.ignorePatternsKey)
        }
    }

    /// Sort order the panes start with. ContentView mirrors the pane sort menu back here, so the
    /// last-used order survives relaunch. Mirrored into `FileSyncManager.sortOption` by the app.
    @Published public var defaultSortOption: SortOption {
        didSet {
            userDefaults.set(defaultSortOption.rawValue, forKey: Self.defaultSortOptionKey)
        }
    }

    /// Standing answer to the file-collision prompt; `.ask` always prompts, and folder collisions
    /// prompt regardless (see `ConflictPolicy`). The app re-reads the persisted value per
    /// collision, so nothing mirrors it into `FileSyncManager`.
    @Published public var conflictPolicy: ConflictPolicy {
        didSet {
            userDefaults.set(conflictPolicy.rawValue, forKey: ConflictPolicy.defaultsKey)
        }
    }

    /// The plain folders the user added as sources, in the order added. Every discovery pass
    /// appends them to `availableProviders` after the cloud accounts. Stored as JSON under one key,
    /// so `FolderSource`'s `Codable` shape is the only definition of the format.
    @Published public private(set) var folderSources: [FolderSource] {
        didSet {
            guard folderSources != oldValue else { return }
            // Not `set(try? …)`: a nil passed to `set` removes the key and destroys the stored
            // list. On a failed encode the disk keeps the previous value — stale beats gone.
            guard let data = try? JSONEncoder().encode(folderSources) else {
                Logger.shared.error("The folder-source list could not be encoded for saving — the previously stored list is left in place")
                return
            }
            userDefaults.set(data, forKey: Self.folderSourcesKey)
        }
    }

    /// The curated source list, read so that a payload this build cannot decode is kept rather
    /// than becoming an empty list.
    ///
    /// The trap: `init` assigns the property directly, so nothing is written at launch, but the
    /// first add, remove or path edit fires `didSet` and writes the empty-based list over the bytes
    /// still on disk. So the bytes go under a `.unreadable` sibling key, the log says so at
    /// `.error`, and the app starts with an empty list — the shape of
    /// `FileSyncManager.decodePersistedStore`, restated because that is `internal` to another
    /// module.
    /// Absent stays absent: a first launch must not log.
    static func readFolderSources(from defaults: UserDefaults) -> [FolderSource] {
        guard let data = defaults.data(forKey: folderSourcesKey) else { return [] }
        if let decoded = try? JSONDecoder().decode([FolderSource].self, from: data) { return decoded }
        let backupKey = folderSourcesKey + ".unreadable"
        // Compare before writing, so a relaunch on a still-corrupt store doesn't rewrite the same
        // backup every time.
        if defaults.data(forKey: backupKey) != data {
            defaults.set(data, forKey: backupKey)
        }
        Logger.shared.error(
            "The saved folder-source list could not be read (\(data.count) bytes) and is being "
            + "treated as empty — the unreadable copy was kept under \"\(backupKey)\". Your "
            + "added folders are not lost; they are in that value.")
        return []
    }

    /// `readFolderSources`' salvage, for the other settings read tolerantly at init and written
    /// back by `didSet`.
    ///
    /// A foreign-typed value, or a raw value only a newer build knows, reads as the default, and
    /// the next edit would write the default-derived value over the original with nothing logged.
    /// So the original goes under a `.unreadable` sibling key, the log says so at `.error`, and the
    /// default is used. Absent stays absent: a first launch must not log.
    ///
    /// - Returns: The decoded value, or nil for both "absent" and "unreadable"; the caller's
    ///   `?? default` supplies the fallback, and only the unreadable case leaves a backup.
    static func readSetting<T>(_ key: String, from defaults: UserDefaults,
                               describing what: String,
                               as read: (UserDefaults) -> T?) -> T? {
        if let value = read(defaults) { return value }
        guard let original = defaults.object(forKey: key) else { return nil }
        let backupKey = key + ".unreadable"
        // Compare before writing, so a relaunch on a still-unreadable value doesn't rewrite the
        // same backup every time.
        if (defaults.object(forKey: backupKey) as? NSObject)?.isEqual(original) != true {
            defaults.set(original, forKey: backupKey)
        }
        Logger.shared.error(
            "The saved \(what) could not be read and is being treated as the default — the "
            + "unreadable copy was kept under \"\(backupKey)\". Your choice is not lost; it is "
            + "in that value.")
        return nil
    }

    /// The ruleset names under a *folder* source are checked against — the standing answer to
    /// "would this folder survive being put somewhere that has rules?". Defaults to `.oneDrive`,
    /// the strictest; `.localFolder` means "don't check". See `CloudProvider.nameRuleType`.
    @Published public var folderNameRule: CloudProvider.ProviderType {
        didSet {
            userDefaults.set(folderNameRule.rawValue, forKey: Self.folderNameRuleKey)
        }
    }

    /// The ruleset a name found under `providerId` should be judged against: the source's own type,
    /// except for a folder source, which has none of its own and borrows `folderNameRule`.
    ///
    /// Falls back to OneDrive, the strictest, when the id resolves to no provider, so an unresolved
    /// source over-reports rather than going quiet.
    public func nameRuleType(for providerId: String) -> CloudProvider.ProviderType {
        let type = availableProviders.first(where: { $0.id == providerId })?.type ?? .oneDrive
        return CloudProvider.nameRuleType(for: type, folderRule: folderNameRule)
    }

    /// Adds `path` as a folder source and returns the id to select.
    ///
    /// A path that is already a source is selected, not added again: nested and overlapping
    /// sources are fine (`~` and `~/Projects`), but two rows for one folder are a duplicate. The
    /// same goes for a discovered provider's root, whose account carries name rules and date
    /// behaviour a folder source would lose. The existing id comes back either way.
    @discardableResult
    public func addFolderSource(path: String) -> String {
        let normalized = FolderSource.abbreviated(path)
        if let existing = existingSource(naming: normalized) {
            if FolderSource.isFolderSourceId(existing) {
                Logger.shared.info("Folder source already exists for \(normalized): selecting \(existing)")
            } else {
                Logger.shared.info("\(normalized) is already \(existing)'s root: selecting it")
            }
            return existing
        }
        let source = FolderSource.new(path: normalized)
        Logger.shared.info("User added folder source \(source.path) (\(source.id))")
        folderSources.append(source)
        Task {
            await discoverProviders()
        }
        return source.id
    }

    /// The id of the source that already names `path`, or nil — the one place the "one folder gets
    /// one row" rule is decided. `addFolderSource` selects what this finds; `setPath` refuses the
    /// move.
    ///
    /// Order matters: `folderSources` first, because discovery is async and the published
    /// `availableProviders` lags it. Checking only the published list would let a double-click on
    /// Add Folder… mint two rows for one folder.
    ///
    /// - Parameter ignoring: A source id to skip. `setPath` passes the source being moved, which
    ///   names its own folder and would otherwise refuse every edit. Skipped in both lists, since
    ///   `mapProviders` appends folder sources to `availableProviders`.
    private func existingSource(naming path: String, ignoring ignoredId: String? = nil) -> String? {
        if let existing = folderSources.first(where: {
            $0.id != ignoredId && FolderSource.sameFolder($0.path, path)
        }) {
            return existing.id
        }
        // Then the discovered accounts, matched by root: the folder the account owns, so adding
        // `.../OneDrive-X` itself is caught too.
        if let existing = availableProviders.first(where: {
            $0.id != ignoredId && FolderSource.sameFolder($0.rootPath, path)
        }) {
            return existing.id
        }
        return nil
    }

    /// Removes a folder source and everything keyed to it — its name override, its enabled state.
    /// Discovered providers are not removable and are ignored here.
    public func removeFolderSource(id: String) {
        guard folderSources.contains(where: { $0.id == id }) else { return }
        Logger.shared.info("User removed folder source: \(id)")
        folderSources.removeAll { $0.id == id }
        forgetKeys(ofRemovedSources: [id])
        Task {
            await discoverProviders()
        }
    }

    /// The per-id keys a removed source takes with it, for one source or several, so
    /// ``removeFolderSources(onVolume:)`` can drop a whole card's worth in one pass.
    /// `disabledProviderIds` is written once, and only if it changed.
    private func forgetKeys(ofRemovedSources ids: [String]) {
        for id in ids {
            userDefaults.removeObject(forKey: "\(Self.nameOverrideKeyPrefix)\(id)")
            // Where it opens goes too: the Remove question says so, and nothing will use the id
            // again.
            userDefaults.removeObject(forKey: "\(Self.openAtOverrideKeyPrefix)\(id)")
        }
        var droppedADisabledId = false
        for id in ids where disabledProviderIds.remove(id) != nil {
            droppedADisabledId = true
        }
        if droppedADisabledId {
            userDefaults.set(disabledProviderIds.sorted(), forKey: Self.disabledProviderIdsKey)
        }
    }

    /// Follows a volume rename, so a source on a card renamed in Finder moves with it instead of
    /// naming a mount point that will never come back (`/Volumes/NO NAME` → `/Volumes/Camera SD`).
    ///
    /// Driven by `NSWorkspace.didRenameVolumeNotification`, which carries both URLs, so the move is
    /// a fact, not a guess, and safe to do silently. Nothing infers a rename from a missing source:
    /// an unplugged card is asleep, not gone. A rename while SyncCloud is quit is not followed;
    /// the sidebar's Remove Source handles that.
    ///
    /// - Returns: the ids that moved, for a caller that wants to say so.
    @discardableResult
    public func followVolumeRename(from oldVolume: String, to newVolume: String) -> [String] {
        let plan = FolderSource.following(volumeRenameFrom: oldVolume, to: newVolume,
                                          in: folderSources)
        guard !plan.moved.isEmpty || !plan.absorbed.isEmpty else { return [] }
        for id in plan.absorbed {
            Logger.shared.info("Volume renamed to \(newVolume): dropped folder source \(id), whose folder is already another source's")
            // The per-id keys `removeFolderSource` clears: the source is gone, and an override
            // left behind would attach to nothing.
            userDefaults.removeObject(forKey: "\(Self.nameOverrideKeyPrefix)\(id)")
            if disabledProviderIds.remove(id) != nil {
                userDefaults.set(disabledProviderIds.sorted(), forKey: Self.disabledProviderIdsKey)
            }
        }
        for id in plan.moved {
            Logger.shared.info("Volume renamed: moved folder source \(id) from \(oldVolume) to \(newVolume)")
        }
        folderSources = plan.sources
        Task {
            await discoverProviders()
        }
        return plan.moved
    }

    /// Forgets the sources on a volume that has been unmounted.
    ///
    /// The counterpart to ``followVolumeRename(from:to:)``, safe for the same reason: an unmount is
    /// an event the app is told about. Ejecting a card is the user saying they are done with it, so
    /// the row goes rather than dimming like a source that is merely asleep.
    ///
    /// **The caller decides whether the volume was detachable**, from ``MountedVolumeMemory``,
    /// since that can't be read once it has gone. Calling this for a dropped network share would
    /// delete sources that are coming back.
    ///
    /// The name override and enabled flag go with each source; pinned and recent folders under the
    /// root are kept, keyed by path, so re-adding the card finds them.
    ///
    /// - Returns: the display names of what was removed, in list order, so a caller can say so.
    @discardableResult
    public func removeFolderSources(onVolume volume: String) -> [String] {
        let ids = FolderSource.idsOnVolume(volume, in: folderSources)
        guard !ids.isEmpty else { return [] }
        // Names are read before the removal clears them, from the published list where the
        // override is applied; the folder's own name covers a source not published yet.
        let names = ids.map { id in
            availableProviders.first { $0.id == id }?.displayName
                ?? folderSources.first { $0.id == id }?.defaultDisplayName
                ?? id
        }
        Logger.shared.info("Volume \(volume) was unmounted — removing \(ids.count) source(s) on it: \(names.joined(separator: ", "))")
        // Removed as a batch: one array write, one defaults write, one discovery. Removing per id
        // would start a full discovery each, stat-ing network-backed mounts, with all but one
        // thrown away by `discoveryGeneration`. The end state is the same, because discovery reads
        // `folderSources` when it runs.
        let dropped = Set(ids)
        folderSources.removeAll { dropped.contains($0.id) }
        forgetKeys(ofRemovedSources: ids)
        Task {
            await discoverProviders()
        }
        return names
    }

    /// Adds a normalized ignore pattern; whitespace-only input and duplicates are dropped.
    /// - Returns: True when the pattern was added.
    @discardableResult
    public func addIgnorePattern(_ raw: String) -> Bool {
        guard let pattern = IgnoreRules.normalized(raw), !ignorePatterns.contains(pattern) else { return false }
        Logger.shared.info("User added ignore pattern: \(pattern)")
        ignorePatterns.append(pattern)
        return true
    }

    public func removeIgnorePattern(_ pattern: String) {
        guard ignorePatterns.contains(pattern) else { return }
        Logger.shared.info("User removed ignore pattern: \(pattern)")
        ignorePatterns.removeAll { $0 == pattern }
    }

    /// Clears the app's persisted defaults — appearance, General/Sync/Advanced flags, provider
    /// overrides and enablement, ignored items — except what `SettingsResetKeeps` names (the Never
    /// show Claude list, spending limits and records, what he made by hand, migration marks), and
    /// republishes this manager's settings at their defaults. `@AppStorage` values elsewhere pick
    /// the removal up. Touches no file; the app's full reset
    /// (`ContentView.applyFullSettingsReset`) also deletes setup's draft.
    ///
    /// **Key by key**, not `removePersistentDomain` and writing the kept keys back: in between, the
    /// hidden list would be absent, and a reader on another thread would show Claude every folder
    /// in it.
    public func resetAllSettings() {
        // Listed from the store the keys are removed from. With no domain name that is every key
        // the store answers for; removing an inherited one (global domain, registered defaults)
        // is a harmless no-op.
        let stored = overridesDomainName.map { userDefaults.persistentDomain(forName: $0) ?? [:] }
            ?? userDefaults.dictionaryRepresentation()
        let kept = stored.keys.filter(SettingsResetKeeps.keeps).sorted()
        Logger.shared.info("User reset all settings to defaults, keeping \(kept.isEmpty ? "nothing" : kept.joined(separator: ", "))")
        for key in stored.keys where !SettingsResetKeeps.keeps(key) {
            userDefaults.removeObject(forKey: key)
        }
        // What may reach Claude changed (`askClaudeSharedFolders` is reset), so post the notice and
        // no cache of it is left stale. The store is the sender so a test can tell this reset's
        // notice from another's.
        NotificationCenter.default.post(name: AskClaudePrivacy.didChange, object: userDefaults)
        // Re-seed the live log level from the now-cleared persisted value (Info), as launch does,
        // or a raised threshold would keep hiding entries until relaunch. Through the picker's own
        // path, so the change is one line in the log. Ends a trace switch's Debug for this launch
        // too: Reset All is an explicit choice, like the picker.
        LogLevelSetting.applyRunning(Logger.persistedMinimumLevel(), because: "Reset All")
        ignoreGoogleDriveNewerDateOnly = false
        dateToleranceSeconds = 1
        autoVerifySameSizeDuringScan = false
        rescanWhenFilesChange = false
        rememberIgnoredItems = true
        ignorePatterns = []
        conflictPolicy = .ask
        defaultSortOption = .name
        disabledProviderIds = []
        // Its key is gone; republish so the dragged order doesn't linger in memory until relaunch.
        sourceOrder = []
        // The folder list's key is already gone; republish the emptiness so the UI and
        // `availableProviders` agree without a relaunch. The reset confirmation names this list.
        folderSources = []
        folderNameRule = .oneDrive
        Task {
            await discoverProviders()
        }
    }

    /// - Parameters:
    ///   - autoDiscover: When true (the app's case), starts discovery in the background so the UI
    ///     populates on launch. Callers that `await discoverProviders()` themselves (the CLI) pass
    ///     false to avoid a redundant scan.
    ///   - userDefaults: Backing store for overrides and flags. Tests inject a
    ///     `UserDefaults(suiteName:)` to stay isolated from the user's real settings.
    ///   - overridesDomainName: The persistent domain backing `userDefaults` (the app and CLI pass
    ///     `SettingsManager.appSuiteName`; tests their suite name). When set, override keys are
    ///     read from that domain alone, so NSGlobalDomain keys are never honored as overrides.
    ///   - cloudStorageLister: Source of the mounted provider account folders. Defaults to
    ///     enumerating the real `~/Library/CloudStorage`; tests inject a canned list.
    ///   - pathValidator: Directory-existence check backing `pathValidity`. Defaults to
    ///     stat-ing the real filesystem; tests inject a canned predicate.
    public init(
        autoDiscover: Bool = true,
        userDefaults: UserDefaults = .standard,
        overridesDomainName: String? = nil,
        cloudStorageLister: CloudStorageLister? = nil,
        pathValidator: PathValidator? = nil
    ) {
        self.userDefaults = userDefaults
        self.overridesDomainName = overridesDomainName
        self.listCloudStorageFolders = cloudStorageLister ?? Self.defaultCloudStorageLister
        self.validatePath = pathValidator ?? Self.defaultPathValidator
        self.ignoreGoogleDriveNewerDateOnly = userDefaults.bool(forKey: Self.ignoreGoogleDriveNewerDateOnlyKey)
        self.dateToleranceSeconds = (userDefaults.object(forKey: Self.dateToleranceSecondsKey) as? Double) ?? 1
        self.autoVerifySameSizeDuringScan = userDefaults.bool(forKey: Self.autoVerifySameSizeDuringScanKey)
        self.rescanWhenFilesChange = userDefaults.bool(forKey: Self.rescanWhenFilesChangeKey)
        self.rememberIgnoredItems = (userDefaults.object(forKey: Self.rememberIgnoredItemsKey) as? Bool) ?? true
        self.ignorePatterns = Self.readSetting(Self.ignorePatternsKey, from: userDefaults,
                                               describing: "ignore-pattern list") {
            $0.stringArray(forKey: Self.ignorePatternsKey)
        } ?? []
        // The decode `ConflictPolicy.persisted(from:)` performs, inlined so an unreadable value
        // gets salvaged. The app's per-collision re-reads use `persisted`, which only reads.
        self.conflictPolicy = Self.readSetting(ConflictPolicy.defaultsKey, from: userDefaults,
                                               describing: "collision answer") {
            $0.string(forKey: ConflictPolicy.defaultsKey).flatMap(ConflictPolicy.init(rawValue:))
        } ?? .ask
        self.defaultSortOption = Self.readSetting(Self.defaultSortOptionKey, from: userDefaults,
                                                  describing: "default sort order") {
            $0.string(forKey: Self.defaultSortOptionKey).flatMap(SortOption.init(rawValue:))
        } ?? .name
        self.disabledProviderIds = Self.readSetting(Self.disabledProviderIdsKey, from: userDefaults,
                                                    describing: "disabled-provider list") {
            $0.stringArray(forKey: Self.disabledProviderIdsKey).map(Set.init)
        } ?? []
        self.folderSources = Self.readFolderSources(from: userDefaults)
        self.folderNameRule = Self.readSetting(Self.folderNameRuleKey, from: userDefaults,
                                               describing: "folder name-rule choice") {
            $0.string(forKey: Self.folderNameRuleKey).flatMap(CloudProvider.ProviderType.init(rawValue:))
        } ?? .oneDrive
        // Seed the provider list so the app can start before the first off-main discovery
        // publishes. It goes through the same mapping, overrides and validity included, so what
        // renders first agrees with that publish instead of flashing a default path or wrong badge.
        let rootOverrides = overridesByProviderId(keyPrefix: Self.rootOverrideKeyPrefix)
        let openAtOverrides = overridesByProviderId(keyPrefix: Self.openAtOverrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        // Read before the seed is ordered by it, and never written on load: empty means "never
        // dragged", and `inUserOrder` keeps discovery order for every id it doesn't name.
        self.sourceOrder = userDefaults.stringArray(forKey: Self.sourceOrderKey) ?? []
        // Restored before the seed, so the seed has the accounts to offer — see
        // `lastKnownAccountFolders`. Stored as plain path strings.
        self.lastKnownAccountFolders = (userDefaults.stringArray(forKey: Self.lastKnownAccountFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        self.availableProviders = Self.inUserOrder(Self.mapProviders(
            cloudStorageFolders: self.lastKnownAccountFolders,
            iCloudDefaultPath: Self.iCloudDefaultPath,
            iCloudDefaultOpenAt: Self.iCloudDefaultOpenAt(rootPath: Self.iCloudDefaultPath,
                                                          validator: self.validatePath),
            folderSources: self.folderSources,
            rootOverride: { rootOverrides[$0] },
            openAtOverride: { openAtOverrides[$0] },
            nameOverride: { nameOverrides[$0] }
        ), order: self.sourceOrder)
        let seedValidity = Self.validity(of: self.availableProviders, using: self.validatePath)
        self.pathValidity = seedValidity.root
        self.landingValidity = seedValidity.landing

        if autoDiscover {
            Task {
                await discoverProviders()
            }
        }
    }

    /// Stats the real filesystem: true when the (tilde-expanded) path is an existing directory.
    private static let defaultPathValidator: PathValidator = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Enumerates the local filesystem's CloudStorage mounting point.
    private static let defaultCloudStorageLister: CloudStorageLister = {
        let cloudStoragePath = (NSString(string: "~/Library/CloudStorage")).expandingTildeInPath
        return cloudStorageFolders(at: URL(fileURLWithPath: cloudStoragePath))
    }

    /// The account folders directly under the given CloudStorage root. Plain files are skipped, so
    /// a stray file named "Dropbox" can't become a provider with an invalid root.
    ///
    /// The enumerator is non-nil even for a directory it cannot read, so `DirectoryListing`
    /// reports an unreadable root rather than an empty one that discovery would publish over every
    /// account. The root is stat'ed first because a missing root fires the same error as an
    /// unreadable one, and a Mac that never mounted a cloud account has no
    /// `~/Library/CloudStorage`. Absent is an honest empty.
    nonisolated static func cloudStorageFolders(at rootURL: URL) -> CloudStorageAccounts {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Never mounted a cloud account: genuinely nothing to find, and nothing to report.
            return .read([])
        }
        let listing = FileManager.default.listing(
            of: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        switch listing.outcome {
        case .unreadable:
            return .unreadableRoot
        case .listed, .listedWithUnreadableDescendants:
            // A partial answer is enough: this listing doesn't descend, so an account folder that
            // can't be opened is still named, which is all discovery needs.
            return .read(listing.urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            })
        }
    }

    /// Maps the mounted CloudStorage account folders to the providers they represent — the pure
    /// core of discovery: prefix parsing, account suffixes, default landing folders, type-order
    /// sorting, and the user's overrides.
    ///
    /// - Parameters:
    ///   - cloudStorageFolders: Account folder URLs found under the CloudStorage root.
    ///   - iCloudDefaultPath: Root used for the always-present iCloud provider absent an override.
    ///   - iCloudDefaultOpenAt: iCloud's landing folder absent an override — `Documents` on a Mac
    ///     whose iCloud Drive has one (`iCloudDefaultOpenAt(rootPath:validator:)`), `""` otherwise.
    ///   - folderSources: The plain folders the user added, in the order they were added.
    ///   - rootOverride: Returns a migrated root for a provider id, or nil for the discovered one.
    ///   - openAtOverride: Returns the user's chosen landing folder (root-relative) for a provider
    ///     id, or nil for the discovered default. An empty string is a real answer — the root.
    ///   - nameOverride: Returns the user's custom display name for a provider id, or nil for
    ///     the discovered default (e.g. "Google Drive (someone@gmail.com)").
    /// - Returns: The providers sorted iCloud → OneDrive → Google Drive → Dropbox → folder sources,
    ///   then by display name within each type; unrecognized folders are ignored.
    ///
    /// Pure: nothing here touches the filesystem. Whether a root or landing folder exists is
    /// answered by `validity(of:using:)` on the same pass, so this stays testable without a fixture
    /// tree.
    nonisolated static func mapProviders(
        cloudStorageFolders: [URL],
        iCloudDefaultPath: String,
        iCloudDefaultOpenAt: String = "Documents",
        folderSources: [FolderSource] = [],
        rootOverride: (String) -> String? = { _ in nil },
        openAtOverride: (String) -> String? = { _ in nil },
        nameOverride: (String) -> String? = { _ in nil }
    ) -> [CloudProvider] {
        var found: [CloudProvider] = []

        // A rename replaces the whole discovered name; empty means "no override".
        func displayName(_ defaultName: String, id: String) -> String {
            nameOverride(id).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
        }

        // 1. iCloud is always available. Its root is the iCloud Drive container and it lands at
        //    `Documents`, which with Desktop & Documents syncing on is `~/Documents` reached
        //    through the link macOS leaves in the container (`PathBoundary.LinkedFolders`).
        found.append(CloudProvider(
            id: "iCloud",
            displayName: displayName("iCloud", id: "iCloud"),
            imageName: "icloud",
            rootPath: iCloudDefaultPath,
            openAt: iCloudDefaultOpenAt,
            type: .iCloud
        ))

        // 2. Map the local Cloud Storage folders. The account folder is the root; its documents
        //    folder is the default landing folder.
        for fileURL in cloudStorageFolders {
            let folderName = fileURL.lastPathComponent

            if folderName.hasPrefix("OneDrive-") {
                let suffix = folderName.dropFirst("OneDrive-".count)
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("OneDrive (\(suffix))", id: id),
                    imageName: "onedrive",
                    rootPath: fileURL.path,
                    openAt: "Documents",
                    type: .oneDrive
                ))
            } else if folderName.hasPrefix("GoogleDrive-") {
                let suffix = folderName.dropFirst("GoogleDrive-".count)
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("Google Drive (\(suffix))", id: id),
                    imageName: "googledrive",
                    rootPath: fileURL.path,
                    // Two components, so the trail shows `My Drive`, the level a Drive account
                    // branches at (beside every Shared drive).
                    openAt: "My Drive/Documents",
                    type: .googleDrive
                ))
            } else if folderName == "Dropbox" {
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("Dropbox", id: id),
                    imageName: "dropbox",
                    rootPath: fileURL.path,
                    openAt: "Documents",
                    type: .dropBox
                ))
            }
        }

        // Group by type — iCloud, OneDrive, Google Drive, Dropbox — then by displayName.
        let typeOrder: [CloudProvider.ProviderType] = [.iCloud, .oneDrive, .googleDrive, .dropBox]
        var sorted = found.sorted { a, b in
            let aIndex = typeOrder.firstIndex(of: a.type) ?? typeOrder.count
            let bIndex = typeOrder.firstIndex(of: b.type) ?? typeOrder.count
            if aIndex != bIndex { return aIndex < bIndex }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }

        // Apply the stored overrides, root first: an `openAt` is relative to the root it was
        // measured from, which a migrated root override replaces.
        for i in 0..<sorted.count {
            if let override = rootOverride(sorted[i].id) {
                sorted[i].rootPath = override
            }
            // No `isEmpty` filter: "" is the root, a landing folder the user can choose. Only an
            // absent key means "use the discovered default".
            if let override = openAtOverride(sorted[i].id) {
                sorted[i].openAt = override
            }
        }

        // 3. The user's folder sources, appended after the sort so they stay last in the order
        //    added; sorting by name would reshuffle them on every rename. No path override applies:
        //    `setPath` writes a folder source's path straight into `folderSources`. A folder
        //    source is its own root and lands at it: the root/landing split only exists to reach
        //    above a cloud account's documents folder.
        sorted.append(contentsOf: folderSources.map { source in
            CloudProvider(
                id: source.id,
                displayName: displayName(source.defaultDisplayName, id: source.id),
                imageName: folderImageName,
                rootPath: source.path,
                openAt: "",
                type: .localFolder
            )
        })

        return sorted
    }

    /// The mark a folder source wears in place of a brand logo. An SF Symbol name: `ProviderLogo`
    /// falls back to `Image(systemName:)` when no asset has that name.
    nonisolated static let folderImageName = "folder.fill"

    /// Scans the CloudStorage mounting point for provider accounts, applies the user's overrides,
    /// and publishes `availableProviders`. Always recomputes `pathValidity` and `landingValidity`,
    /// since a folder can be created or deleted on disk while the provider list stays the same.
    public func discoverProviders() async {
        Logger.shared.debug("Discovering cloud providers...")

        // Claimed synchronously at entry (no suspension point above), so generations order
        // by call order even when passes overlap.
        discoveryGeneration += 1
        let generation = discoveryGeneration

        let lister = listCloudStorageFolders
        let validator = validatePath
        let rootOverrides = overridesByProviderId(keyPrefix: Self.rootOverrideKeyPrefix)
        let openAtOverrides = overridesByProviderId(keyPrefix: Self.openAtOverrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        let iCloudPath = Self.iCloudDefaultPath
        let sources = folderSources
        // The whole pass runs off the main actor: validity stats on network-backed CloudStorage
        // mounts can block for seconds and would beachball the Settings window.
        let lastKnown = lastKnownAccountFolders
        let (accounts, providers, validity) = await Task.detached(priority: .userInitiated) {
            let accounts = lister()
            // An unreadable root is not evidence that the accounts are gone — see
            // `lastKnownAccountFolders`. Everything else in this pass is still fresh.
            let folders = accounts.rootWasReadable ? accounts.folders : lastKnown
            let providers = Self.mapProviders(
                cloudStorageFolders: folders,
                iCloudDefaultPath: iCloudPath,
                iCloudDefaultOpenAt: Self.iCloudDefaultOpenAt(rootPath: iCloudPath, validator: validator),
                folderSources: sources,
                rootOverride: { rootOverrides[$0] },
                openAtOverride: { openAtOverrides[$0] },
                nameOverride: { nameOverrides[$0] }
            )
            return (accounts, providers, Self.validity(of: providers, using: validator))
        }.value

        // A newer pass published while this one ran off-main, with a fresher snapshot: drop this
        // result rather than let last-to-finish win.
        guard generation > lastPublishedDiscoveryGeneration else {
            Logger.shared.debug("Discarding stale provider discovery pass")
            return
        }
        lastPublishedDiscoveryGeneration = generation

        // Only a readable pass updates `lastKnownAccountFolders`. An unreadable one mapped the last
        // known folders above instead, since publishing "no accounts" over the list would delete
        // every cloud account the user has; its fresh overrides and folder sources still publish.
        if accounts.rootWasReadable {
            lastKnownAccountFolders = accounts.folders
            // Written on every readable pass, unchanged ones included, so what survives a quit is
            // always what was last actually seen.
            userDefaults.set(accounts.folders.map(\.path), forKey: Self.lastKnownAccountFoldersKey)
        } else {
            Logger.shared.warning(
                "Provider discovery could not read the CloudStorage folder, so it learned nothing "
                + "about which accounts are mounted — the \(lastKnown.count) found by the last "
                + "readable pass are being kept. Cloud accounts have NOT been removed; check that "
                + "~/Library/CloudStorage is readable.")
        }

        // Ordered before the comparison: discovery order would never equal the published list
        // in the user's order, and every save would re-render every observer.
        let ordered = Self.inUserOrder(providers, order: sourceOrder)
        // Skip no-op publishes so unrelated saves don't re-render every observer.
        if availableProviders != ordered {
            availableProviders = ordered
        }
        if pathValidity != validity.root {
            pathValidity = validity.root
        }
        if landingValidity != validity.landing {
            landingValidity = validity.landing
        }
    }

    /// All persisted overrides under the given key prefix (root, landing or name), keyed by
    /// provider id — snapshotted on the main actor so discovery can run detached without capturing
    /// the non-Sendable defaults.
    private func overridesByProviderId(keyPrefix: String) -> [String: String] {
        Self.overridesByProviderId(in: userDefaults, domainName: overridesDomainName, keyPrefix: keyPrefix)
    }

    /// The scoped read behind `overridesByProviderId` and `RootsMigration`'s harvest of the legacy
    /// `path_override_` keys. One implementation, because the scoping rule is the point of it.
    ///
    /// `dictionaryRepresentation()` merges the whole search list, NSGlobalDomain included, so a
    /// stray global key with the prefix would be honored. Read the owning domain alone when its
    /// name is known. **A nil persistent domain is `[:]`, never the merged list**: nil means a
    /// fresh install, exactly when stray keys have nothing to outweigh them. Only a caller passing
    /// no domain name reads the merged list.
    nonisolated static func overridesByProviderId(
        in defaults: UserDefaults,
        domainName: String?,
        keyPrefix: String
    ) -> [String: String] {
        let entries: [String: Any]
        if let domainName {
            entries = defaults.persistentDomain(forName: domainName) ?? [:]
        } else {
            entries = defaults.dictionaryRepresentation()
        }
        return entries.reduce(into: [:]) { result, entry in
            guard entry.key.hasPrefix(keyPrefix),
                  let value = entry.value as? String else { return }
            result[String(entry.key.dropFirst(keyPrefix.count))] = value
        }
    }

    /// One value read with `overridesByProviderId`'s domain scoping, for the migration's stamp and
    /// its record of settled sources. Read through the merged list, a stray NSGlobalDomain key of
    /// the same name could suppress the migration.
    nonisolated static func scopedValue(
        forKey key: String,
        in defaults: UserDefaults,
        domainName: String?
    ) -> Any? {
        guard let domainName else { return defaults.object(forKey: key) }
        return defaults.persistentDomain(forName: domainName)?[key]
    }

    /// The names of every key under `prefix`, scoped the same way, for a store whose keys carry
    /// their own identity (`IgnoredItemsStore`'s pair keys) that the migration must find first.
    nonisolated static func keys(
        in defaults: UserDefaults,
        domainName: String?,
        havingPrefix prefix: String
    ) -> [String] {
        let entries: [String: Any]
        if let domainName {
            entries = defaults.persistentDomain(forName: domainName) ?? [:]
        } else {
            entries = defaults.dictionaryRepresentation()
        }
        return entries.keys.filter { $0.hasPrefix(prefix) }
    }

    /// Whether the provider's root path existed as a directory at the last validity check
    /// (init, or any discovery pass). Unknown provider ids are invalid.
    public func isPathValid(for providerId: String) -> Bool {
        pathValidity[providerId] ?? false
    }

    /// Whether the provider's landing folder existed at the last validity check. False for an
    /// unknown id, and true whenever the source lands at its own (valid) root.
    public func isLandingValid(for providerId: String) -> Bool {
        landingValidity[providerId] ?? false
    }

    /// Whether the provider participates in pane selection. Ids never disabled — including
    /// ones not discovered yet — report enabled, matching the default for new accounts.
    public func isEnabled(_ providerId: String) -> Bool {
        !disabledProviderIds.contains(providerId)
    }

    /// Whether the Settings toggle for this provider may be switched off: disabling is refused
    /// when it would leave the app without any enabled provider to show in the panes.
    public func canDisable(_ providerId: String) -> Bool {
        !isEnabled(providerId) || enabledProviders.count > 1
    }

    /// The enable/disable switch's tooltip, in the two states ``canDisable(_:)`` picks between.
    /// One copy for both places the switch is drawn, the Settings and setup sheet source rows, so
    /// they can't drift; it lives in `Settings` because both already import it.
    public enum ProviderToggleHelp {
        /// Why the switch is disabled: this is the last enabled source, and `canDisable` refuses.
        public static let lastRemaining = "At least one source must remain enabled."

        /// What switching it on does. Phrased from `enabledProviders`, the list every source picker
        /// is handed (`ProviderMenu`, the lens source bar, the command palette), not from one
        /// surface, so adding or removing a picker can't make it false.
        public static func offer(_ displayName: String) -> String {
            "Offer \(displayName) in the pane header’s source menu, and anywhere else a source is picked."
        }
    }

    /// Switches a discovered provider on or off for pane selection, persisting the choice.
    /// Disabling the last enabled provider is ignored (see `canDisable`).
    public func setEnabled(_ enabled: Bool, for providerId: String) {
        if enabled {
            guard disabledProviderIds.contains(providerId) else { return }
            Logger.shared.info("User enabled provider: \(providerId)")
            disabledProviderIds.remove(providerId)
        } else {
            guard isEnabled(providerId), canDisable(providerId) else { return }
            Logger.shared.info("User disabled provider: \(providerId)")
            disabledProviderIds.insert(providerId)
        }
        userDefaults.set(disabledProviderIds.sorted(), forKey: Self.disabledProviderIdsKey)
    }

    /// Root existence and landing existence for every provider, from one pass over the disk.
    ///
    /// One function, so the two can never come from different moments: the landing answer means
    /// something only beside the root answer it was measured with.
    private nonisolated static func validity(
        of providers: [CloudProvider],
        using validate: PathValidator
    ) -> (root: [String: Bool], landing: [String: Bool]) {
        var root: [String: Bool] = [:]
        var landing: [String: Bool] = [:]
        for provider in providers where root[provider.id] == nil {
            let rootExists = validate(provider.rootPath)
            root[provider.id] = rootExists
            // A landing at the root is the root, already stat'ed, and one under a missing root
            // can't exist. Neither needs a second stat.
            landing[provider.id] = provider.openAt.isEmpty || !rootExists
                ? rootExists
                : validate(provider.landingPath)
        }
        return (root, landing)
    }

    /// The root of a source: the top of what it covers and the base of every root-relative path.
    /// Empty for an unknown id. A pane's tree, the first breadcrumb, and scanning, coverage and
    /// containment are all bounded by it. The folder a pane opens at is `landingPath(for:)`;
    /// mixing them up composes a path that is silently wrong.
    public func rootPath(for providerId: String) -> String {
        availableProviders.first(where: { $0.id == providerId })?.rootPath ?? ""
    }

    /// The source's landing folder relative to its root; `""` for the root itself and for an
    /// unknown id.
    public func openAt(for providerId: String) -> String {
        availableProviders.first(where: { $0.id == providerId })?.openAt ?? ""
    }

    /// The landing folder a pane on this source should actually open at: `openAt`, or the root
    /// when that folder is not there.
    ///
    /// The user can rename or delete a landing folder from outside the app, and a pane seeded to
    /// it would open into an empty tree; the root exists whenever the source is valid. As fresh as
    /// the last discovery pass, the same staleness the Settings row has.
    ///
    /// **`== false`, not `!isLandingValid(for:)`.** An id with no entry is a source published just
    /// before the validity pass, an ordinary launch state; degrading there would seed panes at the
    /// root at launch, where a wrong landing folder is most visible and most likely saved back.
    public func openAtIfReachable(for providerId: String) -> String {
        let openAt = openAt(for: providerId)
        guard !openAt.isEmpty, landingValidity[providerId] == false else { return openAt }
        return ""
    }

    /// Whether this source's root is a stored override rather than the discovered one.
    ///
    /// Only `RootsMigration` writes that key, so this is false on a normal install and the Reset
    /// it gates stays hidden. It exists so a root carried forward from an old setting can be seen
    /// and cleared rather than passing as the account's own.
    public func hasRootOverride(for providerId: String) -> Bool {
        hasStoredOverride(prefix: Self.rootOverrideKeyPrefix, for: providerId)
    }

    /// The absolute folder a pane on this source opens at — `rootPath` with `openAt` applied,
    /// degrading to the root when the landing folder is missing.
    public func landingPath(for providerId: String) -> String {
        PathBoundary.join(root: rootPath(for: providerId),
                          relative: openAtIfReachable(for: providerId))
    }

    /// Moves a folder source to `path`, or writes (non-empty) or clears (empty) an account's root
    /// override.
    ///
    /// Moving a folder source onto a folder another source names is refused, because one folder
    /// gets one row (`existingSource(naming:ignoring:)`); the caller is told so it can put the
    /// field back.
    ///
    /// An account has no root editor and shouldn't grow one: its root is where
    /// `~/Library/CloudStorage` mounts it. Only the migration writes an account override; the Root
    /// row's Reset clears it (see `hasRootOverride`).
    ///
    /// - Parameters:
    ///   - path: The new folder path.
    ///   - providerId: The targeted provider ID.
    /// - Returns: What happened, so a caller holding an editable field can reflect it.
    @discardableResult
    public func setPath(_ path: String, for providerId: String) -> PathChangeOutcome {
        // A folder source's stored path is its path, with no default for an override to sit on.
        // An override here would leave two truths, and Remove would clear only one.
        if let index = folderSources.firstIndex(where: { $0.id == providerId }) {
            let normalized = FolderSource.abbreviated(path)
            guard !path.isEmpty, normalized != folderSources[index].path else { return .unchanged }
            // Skip this source itself, or every edit would refuse itself.
            if let existing = existingSource(naming: normalized, ignoring: providerId) {
                Logger.shared.info(
                    "Refused to move folder source \(providerId) to \(normalized): already \(existing)'s folder")
                return .refusedDuplicate(existingId: existing)
            }
            Logger.shared.info("User moved folder source \(providerId) to \(normalized)")
            folderSources[index].path = normalized
            Task {
                await discoverProviders()
            }
            return .changed
        }
        if path.isEmpty {
            Logger.shared.info("Cleared the root override for provider: \(providerId)")
            userDefaults.removeObject(forKey: "\(Self.rootOverrideKeyPrefix)\(providerId)")
        } else {
            Logger.shared.info("Set root \(path) for provider: \(providerId)")
            userDefaults.set(path, forKey: "\(Self.rootOverrideKeyPrefix)\(providerId)")
        }
        Task {
            await discoverProviders()
        }
        return .changed
    }

    /// Records the folder panes on this source should open at, given as an absolute path the user
    /// picked, and returns what happened so a picker can report a refusal.
    ///
    /// The folder must be inside the source's root: `openAt` is stored relative to it, so
    /// `PathBoundary.relativize` both tests and converts, and nil is the refusal. Symlinks are
    /// resolved only for the test; the stored value keeps the spelling the user navigated.
    @discardableResult
    public func setOpenAt(_ absolutePath: String, for providerId: String) -> PathChangeOutcome {
        let root = rootPath(for: providerId)
        // Its own refusal, not `.unchanged`, which the picker reads as success: a source can be
        // missing from the discovered list while its row is still on screen.
        guard !root.isEmpty else {
            Logger.shared.info(
                "Refused to open \(providerId) at \(absolutePath): that source has no root right now")
            return .refusedUnknownSource
        }

        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        let expandedRoot = (root as NSString).expandingTildeInPath
        let expandedChoice = (absolutePath as NSString).expandingTildeInPath
        // Lexical first, so a path navigated through a link keeps its spelling; resolved is the
        // fallback for a choice that arrives already resolved, as NSOpenPanel's can with firmlinks.
        let relative = PathBoundary.relativize(expandedChoice, under: expandedRoot)
            ?? PathBoundary.relativize(resolved(expandedChoice), under: resolved(expandedRoot))
        guard let relative else {
            Logger.shared.info(
                "Refused to open \(providerId) at \(absolutePath): it is outside that source's root (\(root))")
            return .refusedOutsideRoot
        }
        return setOpenAtRelative(relative, for: providerId)
    }

    /// `setOpenAt` for a value that is already root-relative — the form the migration produces and
    /// the form on disk. `""` is the root, a legitimate choice, and is stored rather than cleared.
    @discardableResult
    public func setOpenAtRelative(_ relative: String, for providerId: String) -> PathChangeOutcome {
        guard relative != openAt(for: providerId) else { return .unchanged }
        Logger.shared.info("Provider \(providerId) now opens at \(relative.isEmpty ? "its root" : relative)")
        userDefaults.set(relative, forKey: "\(Self.openAtOverrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
        return .changed
    }

    /// Drops the chosen landing folder, restoring the discovered default (`Documents`, or
    /// `My Drive/Documents` for Google Drive, or the root for iCloud and folder sources).
    ///
    /// Logs which of the two it did: the button is enabled either way, since `hasOpenAtOverride`
    /// gates only what the row says.
    public func resetOpenAt(for providerId: String) {
        guard hasOpenAtOverride(for: providerId) else {
            Logger.shared.info(
                "Reset the landing folder for provider \(providerId): no override was set, so nothing changed")
            return
        }
        Logger.shared.info("Reset the landing folder to the discovered default for provider: \(providerId)")
        userDefaults.removeObject(forKey: "\(Self.openAtOverrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
    }

    /// Whether the landing folder is the user's choice rather than the discovered default — what
    /// tells "Open at: The source root" chosen from the same words inherited.
    public func hasOpenAtOverride(for providerId: String) -> Bool {
        hasStoredOverride(prefix: Self.openAtOverrideKeyPrefix, for: providerId)
    }

    /// Whether one prefixed override key is stored for this install, scoped as
    /// `overridesByProviderId` scopes the reads that apply it. Not `userDefaults.string(forKey:)`:
    /// the merged list would see a stray `NSGlobalDomain` key that `mapProviders` never applies,
    /// and the row would offer a Reset for a choice it doesn't have.
    private func hasStoredOverride(prefix: String, for providerId: String) -> Bool {
        Self.scopedValue(forKey: prefix + providerId,
                         in: userDefaults, domainName: overridesDomainName) as? String != nil
    }

    /// Persists a custom display name for a provider, such as "Google Drive (Personal)". An empty
    /// or whitespace-only name restores the discovered default. Each control character becomes a
    /// space: the name goes into single-line log records, where a \n could forge extra lines.
    public func setCustomName(_ name: String, for providerId: String) {
        let sanitized = name.components(separatedBy: .controlCharacters).joined(separator: " ")
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Logger.shared.info("User cleared custom name for provider: \(providerId)")
            userDefaults.removeObject(forKey: "\(Self.nameOverrideKeyPrefix)\(providerId)")
        } else {
            Logger.shared.info("User renamed provider \(providerId) to \(trimmed)")
            userDefaults.set(trimmed, forKey: "\(Self.nameOverrideKeyPrefix)\(providerId)")
        }
        Task {
            await discoverProviders()
        }
    }

    /// Clears any stored root override and restores the discovered root.
    /// - Parameter providerId: The targeted provider ID.
    public func resetPath(for providerId: String) {
        Logger.shared.info("User reset the root to the discovered one for provider: \(providerId)")
        userDefaults.removeObject(forKey: "\(Self.rootOverrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
    }
}
