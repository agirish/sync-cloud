import Events
import Foundation
import SwiftUI
import Sync

/// What `SettingsManager.setPath` did with a Location edit.
///
/// Exists so a refusal is something the caller can *see*. The Location field commits on Return and
/// on focus-loss, so a `setPath` that quietly declined would leave the rejected text sitting in the
/// field looking accepted — the user's next read of that row would be wrong, and nothing on screen
/// would say why.
public enum PathChangeOutcome: Equatable, Sendable {
    /// The new path was stored.
    case changed
    /// Nothing to do: that is already this provider's path, or the edit was empty.
    case unchanged
    /// Refused, because `existingId` already names that folder and one folder gets one row.
    /// Only a folder source is ever refused — see `setPath` for why an account is not.
    case refusedDuplicate(existingId: String)
}

/// What one pass over the CloudStorage root found, and whether it could read the root at all.
///
/// Two values rather than a bare `[URL]`, because the empty array had to carry two opposite
/// meanings: "no cloud accounts are mounted" — ordinary, and the right answer on any Mac using
/// only iCloud — and "the root is there and could not be listed", where the pass learned nothing.
/// Discovery *publishes over* the provider list, so serving the second as the first deletes every
/// account the user actually has.
public struct CloudStorageAccounts: Sendable, Equatable {
    /// The account folders directly under the root.
    public let folders: [URL]
    /// False only when the root exists and could not be listed.
    ///
    /// **An ABSENT root is `true` with no folders**, and that distinction is measured rather than
    /// assumed: `FileManager.enumerator(at:)` returns non-nil and yields nothing for an empty
    /// directory, an unreadable one AND a missing one alike, and its `errorHandler` fires for the
    /// last two both (`NSFileReadNoPermissionError` 257 and `NSFileNoSuchFileError` 260). So the
    /// error handler alone would report every Mac that has never mounted a cloud account as a
    /// failure; a stat on the root is what separates "nothing to find" from "could not look".
    public let rootWasReadable: Bool

    /// The root was read. The folders are the whole truth, empty included.
    public static func read(_ folders: [URL]) -> CloudStorageAccounts {
        CloudStorageAccounts(folders: folders, rootWasReadable: true)
    }

    /// The root is there and could not be listed. Carries no folders and no claim that there are none.
    public static let unreadableRoot = CloudStorageAccounts(folders: [], rootWasReadable: false)

    public init(folders: [URL], rootWasReadable: Bool) {
        self.folders = folders
        self.rootWasReadable = rootWasReadable
    }
}

/// Manages the discovery and customization of Cloud Providers available to the application.
/// Interfaces with `UserDefaults` to persist custom path overwrites per provider.
@MainActor
public class SettingsManager: ObservableObject {
    /// Lists the account folders mounted under the CloudStorage root (one URL per provider account).
    public typealias CloudStorageLister = @Sendable () -> CloudStorageAccounts

    /// Reports whether a provider's root path currently exists as a directory.
    public typealias PathValidator = @Sendable (String) -> Bool

    /// A sorted array of natively detected and custom-configured providers (e.g., iCloud, OneDrive).
    @Published public var availableProviders: [CloudProvider] = []

    /// Whether each provider's root path exists as a directory, keyed by provider id.
    /// Recomputed on every `discoverProviders()` pass — including ones that change no
    /// provider — so the validity badge re-checks the disk on the user's explicit refresh
    /// gesture and after path edits, without views stat-ing the filesystem per render.
    @Published public private(set) var pathValidity: [String: Bool] = [:]

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

    /// The cloud ground the discovered sources cover, for the *Where it lives* inspector row and
    /// the `⌂ on this Mac only` row badge — see `FileLocation`.
    ///
    /// **Built from `availableProviders`, deliberately, and never from `enabledProviders`.** A
    /// provider the user switched off still has its folder on disk, so a file inside it still has
    /// a second copy; asking coverage of the *enabled* list would report a file as having only one
    /// copy because of a checkbox, which is the "manufactures risk that is not there" failure
    /// ROADMAP names. The disabled set is handed to `FileLocation.coverage` all the same, so the
    /// rule is stated where it can be tested rather than resting on which property is read here.
    ///
    /// Recomputed on each access rather than cached: it is a compactMap over a handful of
    /// providers — an order of magnitude below the per-render answers that earned their own memos
    /// (`RiskyNameBadgeCache`'s live check is 0.5–3 ms per pane pass) — and it is read once per
    /// pane render, not once per row. The per-ROW answer is the one that is memoized, in
    /// `HomeOnlyBadgeCache`, keyed on this value.
    public var cloudCoverage: FileLocation.Coverage {
        FileLocation.coverage(of: availableProviders, disabledProviderIds: disabledProviderIds)
    }

    private let userDefaults: UserDefaults
    /// Name of the persistent defaults domain that owns the override keys, when known.
    /// See `overridesByProviderId` — reading the named domain alone keeps global-domain keys
    /// from being honored as overrides. Nil falls back to the merged search list.
    private let overridesDomainName: String?
    private let listCloudStorageFolders: CloudStorageLister
    private let validatePath: PathValidator

    /// Monotonic token for `discoverProviders()` passes: each pass claims the next value at
    /// entry, then publishes only if no newer pass has published yet (see
    /// `lastPublishedDiscoveryGeneration`). Discovery runs concurrently from init, the Settings
    /// Refresh button, and every setPath/resetPath/setCustomName — without the token, whichever
    /// off-main pass finished *last* would win and could republish stale provider paths that
    /// `path(for:)` then serves to file operations. Same shape as
    /// `FileSyncManager.applyFilters`' filterGeneration.
    private var discoveryGeneration = 0
    /// Generation of the most recent discovery pass that published its results.
    private var lastPublishedDiscoveryGeneration = 0
    private static let overrideKeyPrefix = "path_override_"
    private static let nameOverrideKeyPrefix = "name_override_"
    private static let ignoreGoogleDriveNewerDateOnlyKey = "ignoreGoogleDriveNewerDateOnly"
    private static let disabledProviderIdsKey = "disabledProviderIds"
    private static let dateToleranceSecondsKey = "dateToleranceSeconds"
    private static let defaultSortOptionKey = "defaultSortOption"
    private static let autoVerifySameSizeDuringScanKey = "autoVerifySameSizeDuringScan"
    private static let rememberIgnoredItemsKey = "rememberIgnoredItems"
    private static let ignorePatternsKey = "ignorePatterns"
    private static let folderSourcesKey = "folderSources"
    private static let folderNameRuleKey = "folderNameRuleProvider"

    /// The UserDefaults domain the app persists settings to — its bundle identifier, which is what
    /// `.standard` resolves to inside the bundled app. Un-bundled processes (the `synccloud` CLI)
    /// must pass `UserDefaults(suiteName: SettingsManager.appSuiteName)` explicitly: their own
    /// `.standard` resolves to a per-process-name domain that never sees the app's path overrides.
    public static let appSuiteName = "com.abhishekgirish.SyncCloud"

    static var iCloudDefaultPath: String {
        (NSString(string: "~/Documents")).expandingTildeInPath
    }

    /// When true, the Differences pane hides "right is newer" items when right is Google Drive and sizes match (avoids noise from Drive overwriting file dates).
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

    /// Sort order the panes start with — and remember: ContentView mirrors the pane sort
    /// menu back here, so the last-used order survives relaunches instead of resetting to
    /// Name. Mirrored into `FileSyncManager.sortOption` by the app.
    @Published public var defaultSortOption: SortOption {
        didSet {
            userDefaults.set(defaultSortOption.rawValue, forKey: Self.defaultSortOptionKey)
        }
    }

    /// Standing answer to the file-collision prompt; `.ask` preserves the always-prompt
    /// behavior and folder collisions always prompt regardless (see `ConflictPolicy`).
    /// The app's alert closures re-read the persisted value per collision, so no mirror
    /// into `FileSyncManager` is needed.
    @Published public var conflictPolicy: ConflictPolicy {
        didSet {
            userDefaults.set(conflictPolicy.rawValue, forKey: ConflictPolicy.defaultsKey)
        }
    }

    /// The plain folders the user added as sources, in the order they were added. Merged into
    /// `availableProviders` by every discovery pass, after the discovered cloud accounts.
    ///
    /// Persisted as JSON under one key rather than as a defaults array of dictionaries: the list is
    /// read and written whole, and a `Codable` round-trip keeps `FolderSource`'s shape in one place
    /// instead of spreading key strings through the manager.
    @Published public private(set) var folderSources: [FolderSource] {
        didSet {
            guard folderSources != oldValue else { return }
            userDefaults.set(try? JSONEncoder().encode(folderSources), forKey: Self.folderSourcesKey)
        }
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
    /// Falls back to OneDrive — the strictest — when the id resolves to no provider, so an
    /// unresolved source over-reports rather than going quiet. That fallback predates folder
    /// sources and is preserved exactly; the folder substitution is layered on top of it.
    public func nameRuleType(for providerId: String) -> CloudProvider.ProviderType {
        let type = availableProviders.first(where: { $0.id == providerId })?.type ?? .oneDrive
        return CloudProvider.nameRuleType(for: type, folderRule: folderNameRule)
    }

    /// Adds `path` as a folder source and returns the id to select.
    ///
    /// Adding a path that is already a source **selects** it rather than creating a second row:
    /// nested and overlapping sources are legitimate (`~` and `~/Projects` both make sense, and so
    /// does a folder inside a cloud root), but two rows for one folder are just a duplicate the
    /// user then has to tell apart by name. The existing source's own id comes back, so the caller
    /// that wanted a pane pointed at that folder still gets what it asked for.
    ///
    /// A path that is already a *discovered* provider's root is also returned rather than added,
    /// for the same reason and a stronger one: the cloud account knows things about that folder
    /// (its name rules, its date behaviour) that a folder source would throw away.
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

    /// The id of the source that already names `path`, or nil when nothing does — the one place
    /// the "one folder gets one row" invariant is decided.
    ///
    /// **Both doors onto a folder source's path go through this**, which is the point of it
    /// existing: `addFolderSource` answers what it finds by *selecting* it, and `setPath` answers
    /// by *refusing the move*. They disagreed once — `setPath` shipped with no check at all, so
    /// editing a Location could mint the second row for one folder that `addFolderSource` is
    /// careful never to mint, or point a plain folder at a cloud account's own root and throw away
    /// the name rules and date behaviour that account carries. Prose in two places did not keep
    /// them in step; one function does.
    ///
    /// Order is load-bearing. `folderSources` is consulted FIRST, and not `availableProviders`
    /// alone: discovery is async and stats network-backed CloudStorage mounts, so the published
    /// list lags this one by however long that takes. Consulting only what has been published
    /// would mint a second row for one folder in exactly that window — two adds in a row with no
    /// wait between them, which is what a double-click on Add Folder… is.
    ///
    /// - Parameter ignoring: A source id to skip. `setPath` passes the source being moved, which
    ///   necessarily names its own current folder and would otherwise refuse every edit. It has to
    ///   be skipped in **both** lists, not just the first: `mapProviders` appends the folder
    ///   sources to `availableProviders`, so a source appears in both.
    private func existingSource(naming path: String, ignoring ignoredId: String? = nil) -> String? {
        if let existing = folderSources.first(where: {
            $0.id != ignoredId && FolderSource.sameFolder($0.path, path)
        }) {
            return existing.id
        }
        // Then the discovered accounts, which is the other thing a chosen path can already be.
        if let existing = availableProviders.first(where: {
            $0.id != ignoredId && FolderSource.sameFolder($0.path, path)
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
        userDefaults.removeObject(forKey: "\(Self.nameOverrideKeyPrefix)\(id)")
        if disabledProviderIds.remove(id) != nil {
            userDefaults.set(disabledProviderIds.sorted(), forKey: Self.disabledProviderIdsKey)
        }
        Task {
            await discoverProviders()
        }
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

    /// Wipes the app's persisted defaults domain — appearance, General/Sync/Advanced flags,
    /// provider path/name overrides and enablement, ignored items — and republishes this
    /// manager's own settings at their defaults. `@AppStorage`-backed values elsewhere pick
    /// the removal up automatically. Files on disk are untouched.
    public func resetAllSettings() {
        Logger.shared.info("User reset all settings to defaults")
        userDefaults.removePersistentDomain(forName: overridesDomainName ?? Self.appSuiteName)
        // Re-seed the LIVE log level from the (now-cleared) persisted value, exactly as launch does.
        // removePersistentDomain drops the persisted `logMinimumLevel`, but the running Logger keeps
        // whatever the user had set, so a raised threshold would keep hiding entries until relaunch.
        Logger.shared.minimumLevel = Logger.persistedMinimumLevel()
        ignoreGoogleDriveNewerDateOnly = false
        dateToleranceSeconds = 1
        autoVerifySameSizeDuringScan = false
        rememberIgnoredItems = true
        ignorePatterns = []
        conflictPolicy = .ask
        defaultSortOption = .name
        disabledProviderIds = []
        // The curated folder list goes with the domain. `removePersistentDomain` has already taken
        // it; this republishes the emptiness so the UI and `availableProviders` agree without
        // waiting for a relaunch. The confirmation names it — "files on disk are untouched" is true
        // and was the whole of what it said, which read as reassurance while the list disappeared.
        folderSources = []
        folderNameRule = .oneDrive
        Task {
            await discoverProviders()
        }
    }

    /// - Parameters:
    ///   - autoDiscover: When true (the app's case), kicks off provider discovery in the
    ///     background so the UI populates on launch. Callers that discover explicitly (e.g. the CLI,
    ///     which `await`s `discoverProviders()`) should pass false to avoid a redundant scan.
    ///   - userDefaults: Backing store for path overrides and flags. Tests inject a
    ///     `UserDefaults(suiteName:)` instance to stay isolated from the user's real settings.
    ///   - overridesDomainName: The persistent-domain name backing `userDefaults` (the app
    ///     and CLI pass `SettingsManager.appSuiteName`; tests pass their fresh suite name).
    ///     When set, override keys are read from that domain alone, so keys living elsewhere
    ///     in the defaults search list (e.g. NSGlobalDomain) are never honored as overrides.
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
        self.rememberIgnoredItems = (userDefaults.object(forKey: Self.rememberIgnoredItemsKey) as? Bool) ?? true
        self.ignorePatterns = userDefaults.stringArray(forKey: Self.ignorePatternsKey) ?? []
        self.conflictPolicy = ConflictPolicy.persisted(from: userDefaults)
        self.defaultSortOption = userDefaults.string(forKey: Self.defaultSortOptionKey).flatMap(SortOption.init(rawValue:)) ?? .name
        self.disabledProviderIds = Set(userDefaults.stringArray(forKey: Self.disabledProviderIdsKey) ?? [])
        self.folderSources = userDefaults.data(forKey: Self.folderSourcesKey)
            .flatMap { try? JSONDecoder().decode([FolderSource].self, from: $0) } ?? []
        self.folderNameRule = userDefaults.string(forKey: Self.folderNameRuleKey)
            .flatMap(CloudProvider.ProviderType.init(rawValue:)) ?? .oneDrive
        // Seed with the always-present iCloud provider so the app can start immediately,
        // before the first (off-main) discovery publishes. The seed goes through the same
        // mapping as discovery — persisted path/name overrides included, validity computed
        // against the *effective* path — so anything rendered pre-discovery agrees with the
        // first publish instead of flashing the default path and a wrong badge.
        let pathOverrides = overridesByProviderId(keyPrefix: Self.overrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        self.availableProviders = Self.mapProviders(
            cloudStorageFolders: [],
            iCloudDefaultPath: Self.iCloudDefaultPath,
            folderSources: self.folderSources,
            pathOverride: { pathOverrides[$0] },
            nameOverride: { nameOverrides[$0] }
        )
        self.pathValidity = Self.validity(of: self.availableProviders, using: self.validatePath)

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

    /// The account *folders* directly under the given CloudStorage root. Plain files are
    /// skipped: a stray file named e.g. "Dropbox" would otherwise surface as a selectable
    /// provider whose path can never be a valid root.
    ///
    /// The `if let enumerator = …` this replaces had an else-branch the filesystem never reaches:
    /// the enumerator is non-nil for a directory it cannot read, so an unlistable root produced an
    /// empty array that discovery then published over the user's provider list — every mounted
    /// Dropbox / Google Drive / OneDrive account disappearing from the app with nothing said.
    /// `DirectoryListing` is the seam that tells that apart from a root with nothing in it.
    ///
    /// The root is stat'ed FIRST because the listing cannot separate the two failures on its own:
    /// a missing root fires the same error handler as an unreadable one, and a Mac that has never
    /// mounted a cloud account has no `~/Library/CloudStorage` at all. Absent is an honest empty.
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
            // A partial answer is still an answer here: this listing does not descend, so an
            // account folder that cannot be opened is still *named*, which is all discovery needs.
            return .read(listing.urls.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            })
        }
    }

    /// Maps the mounted CloudStorage account folders to the providers they represent — the pure
    /// core of discovery: prefix parsing, account-suffix extraction, default document paths,
    /// type-order sorting, and user path-override application.
    ///
    /// - Parameters:
    ///   - cloudStorageFolders: Account folder URLs found under the CloudStorage root.
    ///   - iCloudDefaultPath: Path used for the always-present iCloud provider absent an override.
    ///   - folderSources: The plain folders the user added, in the order they were added.
    ///   - pathOverride: Returns the user's custom path for a provider id, or nil for the default.
    ///   - nameOverride: Returns the user's custom display name for a provider id, or nil for
    ///     the discovered default (e.g. "Google Drive (someone@gmail.com)").
    /// - Returns: The providers sorted iCloud → OneDrive → Google Drive → Dropbox → folder sources,
    ///   then by display name within each type; unrecognized folders are ignored.
    nonisolated static func mapProviders(
        cloudStorageFolders: [URL],
        iCloudDefaultPath: String,
        folderSources: [FolderSource] = [],
        pathOverride: (String) -> String?,
        nameOverride: (String) -> String? = { _ in nil }
    ) -> [CloudProvider] {
        var found: [CloudProvider] = []

        // A rename replaces the whole discovered name; empty means "no override".
        func displayName(_ defaultName: String, id: String) -> String {
            nameOverride(id).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
        }

        // 1. iCloud is always available
        found.append(CloudProvider(
            id: "iCloud",
            displayName: displayName("iCloud", id: "iCloud"),
            imageName: "icloud",
            path: iCloudDefaultPath,
            type: .iCloud
        ))

        // 2. Map the local Cloud Storage folders
        for fileURL in cloudStorageFolders {
            let folderName = fileURL.lastPathComponent

            if folderName.hasPrefix("OneDrive-") {
                let suffix = folderName.dropFirst("OneDrive-".count)
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("OneDrive (\(suffix))", id: id),
                    imageName: "onedrive",
                    path: fileURL.appendingPathComponent("Documents").path,
                    type: .oneDrive
                ))
            } else if folderName.hasPrefix("GoogleDrive-") {
                let suffix = folderName.dropFirst("GoogleDrive-".count)
                let id = folderName
                let defaultPath = fileURL.appendingPathComponent("My Drive").appendingPathComponent("Documents").path
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("Google Drive (\(suffix))", id: id),
                    imageName: "googledrive",
                    path: defaultPath,
                    type: .googleDrive
                ))
            } else if folderName == "Dropbox" {
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: displayName("Dropbox", id: id),
                    imageName: "dropbox",
                    path: fileURL.appendingPathComponent("Documents").path,
                    type: .dropBox
                ))
            }
        }

        // Sort so related providers are together: iCloud, then OneDrive, then Google Drive, then Dropbox; within each group by displayName.
        let typeOrder: [CloudProvider.ProviderType] = [.iCloud, .oneDrive, .googleDrive, .dropBox]
        var sorted = found.sorted { a, b in
            let aIndex = typeOrder.firstIndex(of: a.type) ?? typeOrder.count
            let bIndex = typeOrder.firstIndex(of: b.type) ?? typeOrder.count
            if aIndex != bIndex { return aIndex < bIndex }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }

        // Apply user path overrides
        for i in 0..<sorted.count {
            if let override = pathOverride(sorted[i].id) {
                sorted[i].path = override
            }
        }

        // 3. The user's folder sources, appended AFTER the sort so they land last as a block and
        //    keep the order the user added them in. Deliberately not folded into the sort: sorting
        //    them by display name would reshuffle the list every time one is renamed, and the whole
        //    point of putting them last is that the existing picker is visually untouched above.
        //
        //    Path overrides are not applied here — `setPath` writes a folder source's new path
        //    straight into `folderSources`, so this path is already the effective one. A folder
        //    source has no discovered default for an override to sit on top of.
        sorted.append(contentsOf: folderSources.map { source in
            CloudProvider(
                id: source.id,
                displayName: displayName(source.defaultDisplayName, id: source.id),
                imageName: folderImageName,
                path: source.path,
                type: .localFolder
            )
        })

        return sorted
    }

    /// The mark a folder source wears in place of a brand logo. An SF Symbol name, not an asset:
    /// `ProviderLogo` falls back to `Image(systemName:)` when no asset by that name is bundled,
    /// which is what lets one `imageName` field carry both kinds of mark.
    nonisolated static let folderImageName = "folder.fill"

    /// Scans the local filesystem's CloudStorage mounting point to detect configured provider accounts.
    /// Re-evaluates custom user overwrites and updates the `availableProviders` sequence.
    /// Always recomputes `pathValidity`, even when discovery changes no provider: a refresh
    /// often leaves a provider's identity and path unchanged while its folder on disk was
    /// created or deleted externally.
    public func discoverProviders() async {
        Logger.shared.debug("Discovering cloud providers...")

        // Claimed synchronously at entry (no suspension point above), so generations order
        // by call order even when passes overlap.
        discoveryGeneration += 1
        let generation = discoveryGeneration

        let lister = listCloudStorageFolders
        let validator = validatePath
        let overrides = overridesByProviderId(keyPrefix: Self.overrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        let iCloudPath = Self.iCloudDefaultPath
        let sources = folderSources
        // The whole pass — listing, mapping, and validity stats — runs off the main
        // actor: validating a root stats network-backed CloudStorage mounts, which can
        // block for seconds and would beachball the Settings window if done here.
        let (accounts, providers, validity) = await Task.detached(priority: .userInitiated) {
            let accounts = lister()
            let providers = Self.mapProviders(
                cloudStorageFolders: accounts.folders,
                iCloudDefaultPath: iCloudPath,
                folderSources: sources,
                pathOverride: { overrides[$0] },
                nameOverride: { nameOverrides[$0] }
            )
            return (accounts, providers, Self.validity(of: providers, using: validator))
        }.value

        // A newer pass published while this one ran off-main: its defaults/disk snapshot is
        // fresher, so drop this result instead of letting last-to-finish win.
        guard generation > lastPublishedDiscoveryGeneration else {
            Logger.shared.debug("Discarding stale provider discovery pass")
            return
        }
        lastPublishedDiscoveryGeneration = generation

        // A pass that could not READ the CloudStorage root learned nothing about which accounts
        // are mounted, and this line publishes OVER the provider list — so serving that failure as
        // "no accounts" would delete every Dropbox / Google Drive / OneDrive the user has, leaving
        // the always-present iCloud entry behind to make the list look plausible. Refuse the
        // shrink, the way `FilingProfileStore.indexForAmending` refuses to amend what it could not
        // read. Only a SHRINK is refused: an unreadable root that would change nothing, or that
        // carries a fresh path/name override, still publishes.
        if !accounts.rootWasReadable, providers.count < availableProviders.count {
            Logger.shared.warning(
                "Provider discovery could not read the CloudStorage folder, so it found "
                + "\(providers.count) provider(s) where \(availableProviders.count) are already "
                + "known — keeping the known ones rather than replacing them. Cloud accounts have "
                + "NOT been removed; check that ~/Library/CloudStorage is readable.")
            return
        }

        // Skip no-op publishes so unrelated saves don't re-render every observer.
        if availableProviders != providers {
            availableProviders = providers
        }
        if pathValidity != validity {
            pathValidity = validity
        }
    }

    /// All persisted overrides under the given key prefix (path or label), keyed by provider id —
    /// snapshotted on the main actor so the discovery pass can run detached without capturing
    /// the (non-Sendable) defaults.
    private func overridesByProviderId(keyPrefix: String) -> [String: String] {
        // dictionaryRepresentation() merges the entire defaults search list — NSGlobalDomain
        // included — so a stray global-domain key starting with the prefix would be honored as
        // an override. Read the owning domain alone when its name is known. A nil persistent
        // domain there just means nothing was ever persisted to the suite (a fresh install):
        // that is "no overrides", not license to fall back to the merged list — the fallback
        // would honor exactly the stray keys this scoping exists to exclude, precisely when
        // the app owns no keys to outweigh them. Only a caller without a domain name (the
        // pre-existing bare-suite injection contract) reads the merged list.
        let entries: [String: Any]
        if let domainName = overridesDomainName {
            entries = userDefaults.persistentDomain(forName: domainName) ?? [:]
        } else {
            entries = userDefaults.dictionaryRepresentation()
        }
        return entries.reduce(into: [:]) { result, entry in
            guard entry.key.hasPrefix(keyPrefix),
                  let value = entry.value as? String else { return }
            result[String(entry.key.dropFirst(keyPrefix.count))] = value
        }
    }

    /// Whether the provider's root path existed as a directory at the last validity check
    /// (init, or any discovery pass). Unknown provider ids are invalid.
    public func isPathValid(for providerId: String) -> Bool {
        pathValidity[providerId] ?? false
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

    private nonisolated static func validity(
        of providers: [CloudProvider],
        using validate: PathValidator
    ) -> [String: Bool] {
        Dictionary(providers.map { ($0.id, validate($0.path)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Returns the active root path (either default or user-overridden) for a specific provider.
    /// - Parameter providerId: The unique identifier.
    /// - Returns: The absolute directory path as a string.
    public func path(for providerId: String) -> String {
        return availableProviders.first(where: { $0.id == providerId })?.path ?? ""
    }

    /// Persists a custom absolute path mapping for a specific provider ID, dropping the system default.
    ///
    /// Moving a **folder source** onto a folder some other source already names is refused rather
    /// than written, because one folder gets one row — see `existingSource(naming:ignoring:)`,
    /// which is where that is decided for this and for `addFolderSource` alike. The caller is told
    /// so it can put the field back; a silent no-op would read as the edit having been lost.
    ///
    /// Re-pointing a **discovered account** is deliberately unrestricted, exactly as before. The
    /// invariant is about folder sources, which exist only because the user said so; an account's
    /// Location is a mapping onto machinery that already owns that folder's identity, and refusing
    /// to let someone aim Dropbox at a folder they had also added as a source would be a new rule,
    /// not this fix.
    ///
    /// - Parameters:
    ///   - path: The new folder target path.
    ///   - providerId: The targeted provider ID.
    /// - Returns: What happened, so a caller holding an editable field can reflect it.
    @discardableResult
    public func setPath(_ path: String, for providerId: String) -> PathChangeOutcome {
        // A folder source has no discovered default, so there is nothing for an override to sit on
        // top of: its stored path IS its path. Writing an override here instead would leave the
        // list holding the old path and the provider the new one — two truths, and Remove would
        // clear only one of them.
        if let index = folderSources.firstIndex(where: { $0.id == providerId }) {
            let normalized = FolderSource.abbreviated(path)
            guard !path.isEmpty, normalized != folderSources[index].path else { return .unchanged }
            // `ignoring:` is this source itself — it names its own folder, and without the skip
            // every edit would refuse itself.
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
            Logger.shared.info("User cleared custom path mapping for provider: \(providerId)")
            userDefaults.removeObject(forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        } else {
            Logger.shared.info("User mapped custom path \(path) for provider: \(providerId)")
            userDefaults.set(path, forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        }
        Task {
            await discoverProviders()
        }
        return .changed
    }

    /// Persists a custom display name for a provider (e.g. renaming "Google Drive
    /// (someone@gmail.com)" to "Google Drive (Personal)"). An empty or whitespace-only
    /// name clears the override, restoring the discovered default. Interior control
    /// characters (including newlines) each become a space: the name is echoed into
    /// single-line log records, where an embedded \n could forge extra log lines.
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

    /// Clears any user-defined override from UserDefaults and restores the System-discovered path.
    /// - Parameter providerId: The targeted provider ID.
    public func resetPath(for providerId: String) {
        Logger.shared.info("User reset path mapping to default system root for provider: \(providerId)")
        userDefaults.removeObject(forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
    }
}
