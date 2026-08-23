import Events
import Foundation
import SwiftUI
import Sync

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

    private let userDefaults: UserDefaults
    /// Name of the persistent defaults domain that owns the override keys, when known.
    /// See `overridesByProviderId` — reading the named domain alone keeps global-domain keys
    /// from being honored as overrides. Nil falls back to the merged search list.
    private let overridesDomainName: String?
    private let listCloudStorageFolders: CloudStorageLister
    /// The account folders the last READABLE pass found.
    ///
    /// A pass that could not read the root learned nothing about which accounts are mounted, so it
    /// re-maps from this instead of from the empty list it actually got. That keeps the failure
    /// confined to the one thing the listing is evidence about: iCloud, folder sources, and every
    /// path/name override still come from the fresh pass and still publish, while the cloud
    /// accounts hold at their last good reading.
    ///
    /// This replaces a `providers.count < availableProviders.count` refusal, which was the wrong
    /// instrument on two counts: `availableProviders` also contains FOLDER SOURCES, so adding one
    /// while the root was unreadable made the counts match and let the truncated list through —
    /// and `addFolderSource` calls `discoverProviders()` directly, so that is a routine sequence,
    /// not a contrived one. In the other direction, REMOVING a folder source shrinks the list
    /// legitimately and was refused.
    private let validatePath: PathValidator

    /// Monotonic token for `discoverProviders()` passes: each pass claims the next value at
    /// entry, then publishes only if no newer pass has published yet (see
    /// `lastPublishedDiscoveryGeneration`). Discovery runs concurrently from init, the Settings
    /// Refresh button, and every setPath/resetPath/setCustomName — without the token, whichever
    /// off-main pass finished *last* would win and could republish stale provider paths that
    /// `path(for:)` then serves to file operations. Same shape as
    /// `FileSyncManager.applyFilters`' filterGeneration.
    private var lastKnownAccountFolders: [URL] = []
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
        Task {
            await discoverProviders()
        }
    }

    // MARK: Reading persisted values

    /// Reads one persisted setting so that a stored value this build cannot read is **kept**
    /// rather than quietly becoming the default.
    ///
    /// Every `@Published` setting above shares one shape: a tolerant read (`?? default`) at init,
    /// and a `didSet` that writes the live value back on the next edit. The tolerance is right —
    /// the app must start whatever is on disk — but alone it destroys data, and invisibly: a
    /// foreign-typed value, or a raw value only a newer build recognizes, reads as the default,
    /// and the user's next edit of that setting persists the default-derived value over the
    /// original. Five disabled providers silently become one; a newer build's sort choice is gone
    /// the first time the setting is touched after a downgrade, with nothing in the log to say why.
    ///
    /// This is the shape `FileSyncManager.readPersistedStore` was built for — a sibling module,
    /// `internal`, so the behaviour is restated here rather than shared: preserve the original
    /// under a `.unreadable` sibling key, say so at `.error`, and carry on with the default so the
    /// app still starts. Absent stays absent: a first launch has no value and must not log.
    ///
    /// - Returns: The decoded value, or nil for both "absent" and "unreadable" — the caller's
    ///   `?? default` supplies the fallback either way; only the unreadable case leaves a backup.
    static func readSetting<T>(_ key: String, from defaults: UserDefaults,
                               describing what: String,
                               as read: (UserDefaults) -> T?) -> T? {
        if let value = read(defaults) { return value }
        guard let original = defaults.object(forKey: key) else { return nil }
        let backupKey = key + ".unreadable"
        // Read-and-compare rather than an unconditional write: after this line the value is under
        // the backup key however it got there, and a re-launch on a still-unreadable value must
        // not rewrite the same payload every time.
        if (defaults.object(forKey: backupKey) as? NSObject)?.isEqual(original) != true {
            defaults.set(original, forKey: backupKey)
        }
        Logger.shared.error(
            "The saved \(what) could not be read and is being treated as the default — the "
            + "unreadable copy was kept under \"\(backupKey)\". Your choice is not lost; it is "
            + "in that value.")
        return nil
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
        self.ignorePatterns = Self.readSetting(Self.ignorePatternsKey, from: userDefaults,
                                               describing: "ignore-pattern list") {
            $0.stringArray(forKey: Self.ignorePatternsKey)
        } ?? []
        // The same decode `ConflictPolicy.persisted(from:)` performs; inlined so an unreadable
        // value takes the salvage path above. The app's per-collision re-reads keep using
        // `persisted`, which only reads — the destroying write is this manager's `didSet`.
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
    ///   - pathOverride: Returns the user's custom path for a provider id, or nil for the default.
    ///   - nameOverride: Returns the user's custom display name for a provider id, or nil for
    ///     the discovered default (e.g. "Google Drive (someone@gmail.com)").
    /// - Returns: The providers sorted iCloud → OneDrive → Google Drive → Dropbox, then by
    ///   display name within each type; unrecognized folders are ignored.
    nonisolated static func mapProviders(
        cloudStorageFolders: [URL],
        iCloudDefaultPath: String,
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

        return sorted
    }

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
        // The whole pass — listing, mapping, and validity stats — runs off the main
        // actor: validating a root stats network-backed CloudStorage mounts, which can
        // block for seconds and would beachball the Settings window if done here.
        let lastKnown = lastKnownAccountFolders
        let (accounts, providers, validity) = await Task.detached(priority: .userInitiated) {
            let accounts = lister()
            // An unreadable root is not evidence that the accounts are gone — see
            // `lastKnownAccountFolders`. Everything else in this pass is still fresh.
            let folders = accounts.rootWasReadable ? accounts.folders : lastKnown
            let providers = Self.mapProviders(
                cloudStorageFolders: folders,
                iCloudDefaultPath: iCloudPath,
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
        if accounts.rootWasReadable {
            lastKnownAccountFolders = accounts.folders
        } else {
            Logger.shared.warning(
                "Provider discovery could not read the CloudStorage folder, so it learned nothing "
                + "about which accounts are mounted — the \(lastKnown.count) found by the last "
                + "readable pass are being kept. Cloud accounts have NOT been removed; check that "
                + "~/Library/CloudStorage is readable.")
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
    /// - Parameters:
    ///   - path: The new folder target path.
    ///   - providerId: The targeted provider ID.
    public func setPath(_ path: String, for providerId: String) {
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
