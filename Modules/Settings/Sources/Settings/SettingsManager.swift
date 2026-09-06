import Events
import Foundation
import SwiftUI
import Sync

/// What `SettingsManager.setPath` or `setOpenAt` did with a folder the user picked.
///
/// Exists so a refusal is something the caller can *see*. The Location field commits on Return and
/// on focus-loss, so a `setPath` that quietly declined would leave the rejected text sitting in the
/// field looking accepted — the user's next read of that row would be wrong, and nothing on screen
/// would say why. The same holds for the "Open at" picker, whose panel closes either way.
///
/// **The two refusals are separate cases and must stay separate.** They were briefly one: the
/// out-of-root refusal borrowed `refusedDuplicate(existingId:)` and passed the asking provider's
/// own id, so the payload named neither a duplicate nor another source. It rendered correctly only
/// because the one call site switched on the case and ignored the payload — and the next consumer
/// to copy `commitPath`'s handling would have told the user their folder "is already **this very
/// source's** folder."
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

    /// Whether each provider's **landing** folder (`rootPath` + `openAt`) exists as a directory.
    ///
    /// A second question from `pathValidity`, because the two have different consequences. A
    /// missing ROOT is a broken source — nothing about it works, and the row's badge says so. A
    /// missing landing folder is a stale preference: the source is fine, and a pane simply opens at
    /// the root instead (`openAtIfReachable`). Reporting the second as the first would put an
    /// invalid badge on a perfectly working account because a folder the user once chose was
    /// renamed.
    ///
    /// Computed in the same off-main pass as `pathValidity`, against the same injected validator,
    /// so the pair is always one consistent reading of the disk.
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

    /// Records the order a drag produced, and republishes the list in it.
    ///
    /// The whole sequence is written rather than a delta, so what is stored is always a complete
    /// answer for what was on screen.
    public func setSourceOrder(_ ids: [String]) {
        guard ids != sourceOrder else { return }
        sourceOrder = ids
        userDefaults.set(ids, forKey: Self.sourceOrderKey)
        availableProviders = Self.inUserOrder(availableProviders, order: ids)
    }

    /// **Providers in the user's order**, with anything the order does not name kept in discovery
    /// order behind those it does.
    ///
    /// The same shape `FolderJumpStore.orderedFavorites` uses, and for the same reason: it needs no
    /// migration and no seed. An install that has never dragged has an empty order and gets exactly
    /// the discovery order it had before; a newly connected account appends rather than jumping to
    /// the front, which is where a rank-defaulting sort would have put it.
    ///
    /// A stable partition rather than one `sorted(by:)` over an optional rank, because Swift's sort
    /// is not stable — the unnamed tail would otherwise be free to shuffle between launches.
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
    /// The account folders the last successful discovery saw — the answer to "is an unreadable
    /// CloudStorage root evidence that the accounts are gone?", which it is not.
    ///
    /// **Persisted, and it was not before.** In memory only, this started every launch EMPTY, which
    /// broke both of the things it is for:
    ///
    /// - The unreadable-root fallback below could not fall back to anything on the FIRST pass after
    ///   launch — precisely the pass most likely to meet a CloudStorage root that has not mounted
    ///   yet — so the shrink it exists to refuse would have been published.
    /// - And the constructor's seed had no cloud accounts to offer, so a pane restored onto a cloud
    ///   source found `enabledProviders` without it and skipped its launch refresh, warning every
    ///   time. That was a guaranteed miss rather than a race lost: the seed passed
    ///   `cloudStorageFolders: []` by construction, so discovery's speed never came into it. iCloud
    ///   never tripped it because iCloud is a constant the seed always adds.
    private var lastKnownAccountFolders: [URL] = []
    private var discoveryGeneration = 0
    /// Generation of the most recent discovery pass that published its results.
    private var lastPublishedDiscoveryGeneration = 0
    /// **Legacy.** The pre-roots "Location" override: one absolute path that was simultaneously the
    /// pane root, the breadcrumb ceiling and the scan scope.
    ///
    /// Read by `RootsMigration` exactly once, to work out where this install used to sit, and never
    /// written or removed after — the v3.x and v2.x maintenance lines share this defaults domain
    /// and still read this key as their Location. Rewriting it would reach backwards into a build
    /// the user may return to; removing it would delete their setting there outright.
    nonisolated static let legacyPathOverrideKeyPrefix = "path_override_"
    /// The root a source covers, when it is not the discovered one. Written only by
    /// `RootsMigration`, for the install whose legacy Location pointed somewhere OUTSIDE the
    /// account folder — there is no discovered root that contains such a path, so the path itself
    /// becomes the root. Settings offers no editor for it: one account has one true root.
    nonisolated static let rootOverrideKeyPrefix = "root_override_"
    /// The user's chosen landing folder, **relative to the root**, when it is not the discovered
    /// default. Empty string is a real value here (the root itself) and is stored as one; absent
    /// means "use the default".
    nonisolated static let openAtOverrideKeyPrefix = "openAt_override_"
    private static let nameOverrideKeyPrefix = "name_override_"
    private static let ignoreGoogleDriveNewerDateOnlyKey = "ignoreGoogleDriveNewerDateOnly"
    private static let disabledProviderIdsKey = "disabledProviderIds"
    private static let dateToleranceSecondsKey = "dateToleranceSeconds"
    private static let defaultSortOptionKey = "defaultSortOption"
    private static let autoVerifySameSizeDuringScanKey = "autoVerifySameSizeDuringScan"
    private static let rememberIgnoredItemsKey = "rememberIgnoredItems"
    private static let ignorePatternsKey = "ignorePatterns"
    private static let folderSourcesKey = "folderSources"
    /// The user's own order for the source list, as provider ids.
    ///
    /// **One order, read by everything.** It arrived for the Browse sidebar's Sources section, where
    /// the rows can be dragged — but a sidebar-only order would put the sidebar and the pane
    /// header's dropdown in different sequences for the same list, which is exactly the drift that
    /// makes a user distrust both. So it lives here and `availableProviders` is published in it.
    private static let sourceOrderKey = "sourceOrder"
    /// The account folders the last successful discovery found, as absolute paths.
    ///
    /// **Persisted so `lastKnownAccountFolders` survives a quit**, which is what makes both of its
    /// jobs work at launch rather than only mid-session. See there.
    private static let lastKnownAccountFoldersKey = "lastKnownAccountFolders"
    private static let folderNameRuleKey = "folderNameRuleProvider"

    /// The UserDefaults domain the app persists settings to — its bundle identifier, which is what
    /// `.standard` resolves to inside the bundled app. Un-bundled processes (the `synccloud` CLI)
    /// must pass `UserDefaults(suiteName: SettingsManager.appSuiteName)` explicitly: their own
    /// `.standard` resolves to a per-process-name domain that never sees the app's path overrides.
    ///
    /// `nonisolated` so `RootsMigration` — which runs before any actor is available and takes this
    /// as a default argument — can name it rather than keeping a second copy of a bundle
    /// identifier in the same package.
    nonisolated public static let appSuiteName = "com.abhishekgirish.SyncCloud"

    /// iCloud's discovered root: the iCloud Drive container, what Finder shows as "iCloud Drive".
    /// See `CloudProvider.rootPath` for why it was `~/Documents` until v5.3, and
    /// `PathBoundary.LinkedFolders` for how `Documents` under it still reaches `~/Documents`.
    nonisolated public static var iCloudDefaultPath: String {
        PathBoundary.iCloudDriveContainer
    }

    /// Where iCloud was rooted before v5.3. `RootsMigration` maps the pre-split world against
    /// this — a migration is a statement about what was on disk at its version, and moving the
    /// discovered default under it would have it plan iCloud as a source that moved when, for
    /// the positions it rebases, it had not — and `moveICloudRoot` moves stored positions from
    /// here to the container.
    nonisolated public static var legacyICloudRoot: String {
        (NSString(string: "~/Documents")).expandingTildeInPath
    }

    /// iCloud's discovered landing folder: `Documents` when the container has one — the link
    /// Desktop & Documents syncing leaves, or a real folder — and the root itself otherwise.
    /// Measured rather than assumed so a Mac with the syncing off, where `Documents` is simply
    /// not in iCloud Drive, opens at what it does have rather than at a folder that is not there.
    nonisolated static func iCloudDefaultOpenAt(rootPath: String, validator: PathValidator) -> String {
        validator(PathBoundary.join(root: rootPath, relative: "Documents")) ? "Documents" : ""
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
            // Not `set(try? …)`: passing an encode failure's nil to `set` REMOVES the key, which
            // destroys the stored list the read side goes to such lengths to salvage. On a failed
            // encode the disk keeps the previous value — stale beats gone — and the log says so.
            guard let data = try? JSONEncoder().encode(folderSources) else {
                Logger.shared.error("The folder-source list could not be encoded for saving — the previously stored list is left in place")
                return
            }
            userDefaults.set(data, forKey: Self.folderSourcesKey)
        }
    }

    /// The curated source list, read so that a payload this build cannot decode is **kept** rather
    /// than quietly becoming an empty list.
    ///
    /// **The loss was invisible twice over.** `init` assigns the property directly, so the `didSet`
    /// that persists it does not fire — nothing is written at launch, and Settings simply looks
    /// like a fresh install. Then the first add, remove or path edit fires it and writes the
    /// empty-based list over the bytes that were still on disk, so the only copy of a
    /// hand-curated list is gone at the moment the user touches the panel to ask where it went.
    /// `try? … ?? []` said nothing at either step.
    ///
    /// This is the shape `FileSyncManager.readPersistedStore` was built for and applies to the
    /// filing rules — a sibling module, `internal`, so the behaviour is restated here rather than
    /// shared: preserve the bytes under a `.unreadable` sibling key, say so at `.error`, and carry
    /// on with an empty list so the app still starts. Absent stays absent: a first launch has no
    /// bytes and must not log anything.
    static func readFolderSources(from defaults: UserDefaults) -> [FolderSource] {
        guard let data = defaults.data(forKey: folderSourcesKey) else { return [] }
        if let decoded = try? JSONDecoder().decode([FolderSource].self, from: data) { return decoded }
        let backupKey = folderSourcesKey + ".unreadable"
        // Read-and-compare rather than an unconditional write: after this line the bytes are under
        // the backup key however they got there, and a re-launch on a still-corrupt store must not
        // rewrite the same payload every time.
        if defaults.data(forKey: backupKey) != data {
            defaults.set(data, forKey: backupKey)
        }
        Logger.shared.error(
            "The saved folder-source list could not be read (\(data.count) bytes) and is being "
            + "treated as empty — the unreadable copy was kept under \"\(backupKey)\". Your "
            + "added folders are not lost; they are in that value.")
        return []
    }

    /// `readFolderSources`' salvage, for the sibling settings that share its
    /// read-tolerantly-then-write-unconditionally shape.
    ///
    /// Every `@Published` setting here pairs a tolerant read (`?? default`) at init with a `didSet`
    /// that writes the live value back on the next edit. The tolerance is right — the app must
    /// start whatever is on disk — but alone it destroys data, and invisibly: a foreign-typed
    /// value, or a raw value only a newer build recognizes, reads as the default, and the user's
    /// next edit of that setting persists the default-derived value over the original. Five
    /// disabled providers silently become one; a newer build's sort choice is gone the first time
    /// the setting is touched after a downgrade, with nothing in the log to say why. The lesson
    /// stopped at `folderSources`; this carries it to the rest: preserve the original under a
    /// `.unreadable` sibling key, say so at `.error`, and carry on with the default. Absent stays
    /// absent — a first launch has no value and must not log.
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
        // Matched against the ROOT: that is the folder the account owns, and since roots widened to
        // the account folder this now also catches someone adding `.../OneDrive-X` itself, which
        // used to look like an unclaimed folder because the account's path sat one level below it.
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

    /// **The per-id keys a removed source takes with it**, for one source or for several.
    ///
    /// Split out of ``removeFolderSource(id:)`` so ``removeFolderSources(onVolume:)`` can drop a
    /// whole card's worth in one pass. The `disabledProviderIds` write is hoisted out of the loop
    /// and made conditional on something actually having been removed, which is the same rule the
    /// single-source path always had — a set that did not change must not be re-written to
    /// defaults.
    private func forgetKeys(ofRemovedSources ids: [String]) {
        for id in ids {
            userDefaults.removeObject(forKey: "\(Self.nameOverrideKeyPrefix)\(id)")
        }
        var droppedADisabledId = false
        for id in ids where disabledProviderIds.remove(id) != nil {
            droppedADisabledId = true
        }
        if droppedADisabledId {
            userDefaults.set(disabledProviderIds.sorted(), forKey: Self.disabledProviderIdsKey)
        }
    }

    /// **Follows a volume rename**, so a source rooted on a card that was renamed in Finder moves
    /// with it instead of being left naming a mount point that will never come back.
    ///
    /// Renaming a card moves its mount point: `/Volumes/NO NAME` becomes `/Volumes/Camera SD`, and
    /// the source stays where it was. What that produces is not a source that is asleep — the rule
    /// the sidebar's dimming means — but a permanently dead row, beside a second source for the
    /// same card as soon as the user clicks it. Both happened on 2026-08-29.
    ///
    /// **Driven by `NSWorkspace.didRenameVolumeNotification`, which carries both URLs**, so the
    /// move is a fact rather than a guess. That is the whole reason this is safe to do silently:
    /// nothing here infers a rename from a source having gone missing, and an unplugged card is
    /// untouched — it is asleep, and "a source that is asleep has not gone" is the rule the whole
    /// column is built on. A rename that happens while SyncCloud is quit is therefore NOT followed;
    /// the sidebar's Remove Source is the way out of that one.
    ///
    /// - Returns: the ids that moved, for a caller that wants to say so.
    @discardableResult
    public func followVolumeRename(from oldVolume: String, to newVolume: String) -> [String] {
        let plan = FolderSource.following(volumeRenameFrom: oldVolume, to: newVolume,
                                          in: folderSources)
        guard !plan.moved.isEmpty || !plan.absorbed.isEmpty else { return [] }
        for id in plan.absorbed {
            Logger.shared.info("Volume renamed to \(newVolume): dropped folder source \(id), whose folder is already another source's")
            // The per-id keys `removeFolderSource` clears, cleared here for the same reason — the
            // source is gone, and an override left behind would attach itself to nothing.
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

    /// **Forgets the sources on a volume that has been unmounted.**
    ///
    /// The counterpart to ``followVolumeRename(from:to:)``, and safe for the same reason: an
    /// unmount is an EVENT the app is told about, not an inference from a source having gone quiet.
    /// Ejecting a card in Finder is the user saying they are done with it, so the row goes rather
    /// than dimming — which is what a source that is merely asleep does, and the two used to look
    /// identical.
    ///
    /// **The caller decides whether the volume was detachable; this does not.** That fact cannot be
    /// read once the volume has gone, so it comes from ``MountedVolumeMemory``, which recorded it
    /// while the volume was mounted. Calling this for a network share that dropped would delete
    /// sources that are coming back.
    ///
    /// Sources are removed the same way Settings removes one, so the name override and the enabled
    /// flag go with them rather than being left keyed to an id nothing holds. **The pinned and
    /// recent folders under that root are deliberately kept**: they are keyed by path, so plugging
    /// the card back in and adding it again finds them exactly where they were, and nothing is
    /// gained by throwing them away.
    ///
    /// - Returns: the display names of what was removed, in list order, so a caller can say so.
    @discardableResult
    public func removeFolderSources(onVolume volume: String) -> [String] {
        let ids = FolderSource.idsOnVolume(volume, in: folderSources)
        guard !ids.isEmpty else { return [] }
        // **Names read BEFORE the removal**, from the published provider list — that is where a
        // source's *effective* name lives, override applied, and `removeFolderSource` is about to
        // clear both the entry and the override key. Falling back to the folder's own name keeps
        // the message honest for a source that discovery has not published yet.
        let names = ids.map { id in
            availableProviders.first { $0.id == id }?.displayName
                ?? folderSources.first { $0.id == id }?.defaultDisplayName
                ?? id
        }
        Logger.shared.info("Volume \(volume) was unmounted — removing \(ids.count) source(s) on it: \(names.joined(separator: ", "))")
        // **Removed as a batch: one array write, one defaults write, ONE discovery.**
        //
        // This called `removeFolderSource(id:)` per id, and each of those spawns
        // `Task { await discoverProviders() }` — a pass that lists the CloudStorage mounting point
        // and then `stat`s every provider root to recompute `pathValidity`, on network-backed
        // mounts that can block for seconds. A card holding four sources therefore started four
        // full discoveries at the moment a volume disappeared, and `discoveryGeneration` only
        // decides which one gets to *publish*: the other three do all of the work and are thrown
        // away. Each removal also re-encoded `folderSources` and wrote it to defaults, through the
        // `didSet`.
        //
        // The end state is identical — the same ids gone, the same per-id keys cleared, the same
        // single published provider list — because a discovery reads `folderSources` when it runs,
        // not when it was requested, and it runs after this returns.
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
        self.folderSources = Self.readFolderSources(from: userDefaults)
        self.folderNameRule = Self.readSetting(Self.folderNameRuleKey, from: userDefaults,
                                               describing: "folder name-rule choice") {
            $0.string(forKey: Self.folderNameRuleKey).flatMap(CloudProvider.ProviderType.init(rawValue:))
        } ?? .oneDrive
        // Seed with the always-present iCloud provider so the app can start immediately,
        // before the first (off-main) discovery publishes. The seed goes through the same
        // mapping as discovery — persisted path/name overrides included, validity computed
        // against the *effective* path — so anything rendered pre-discovery agrees with the
        // first publish instead of flashing the default path and a wrong badge.
        let rootOverrides = overridesByProviderId(keyPrefix: Self.rootOverrideKeyPrefix)
        let openAtOverrides = overridesByProviderId(keyPrefix: Self.openAtOverrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        // Read before the seed is ordered by it. Never seeded and never written on load: an empty
        // order means "the user has not dragged anything", and `inUserOrder` falls through to
        // discovery order for every id it does not name.
        self.sourceOrder = userDefaults.stringArray(forKey: Self.sourceOrderKey) ?? []
        // Restored before the seed, so the seed has the accounts to offer — see
        // `lastKnownAccountFolders`. Paths rather than URLs on disk: a defaults array of strings
        // reads back identically on every OS, and these are always plain file paths.
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
    /// **Pure, and stays pure.** Nothing here touches the filesystem: whether a discovered root or
    /// a chosen landing folder actually exists is a *validity* question, answered by
    /// `validity(of:using:)` against an injected validator on the same pass. Folding an existence
    /// check in here would make the provider list depend on disk state at map time, which is
    /// exactly what makes a mapping untestable without a fixture tree.
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
        //    `Documents` — which, with Desktop & Documents syncing on, is `~/Documents` reached
        //    through the link macOS leaves in the container (`PathBoundary.LinkedFolders`).
        found.append(CloudProvider(
            id: "iCloud",
            displayName: displayName("iCloud", id: "iCloud"),
            imageName: "icloud",
            rootPath: iCloudDefaultPath,
            openAt: iCloudDefaultOpenAt,
            type: .iCloud
        ))

        // 2. Map the local Cloud Storage folders. The account folder is the ROOT; the folder that
        //    used to be the whole of a source's Location becomes its default landing folder.
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
                    // Two components, so the trail shows `My Drive` on the way down — the level a
                    // Drive account actually branches at (My Drive beside every Shared drive), and
                    // one the old single-path root hid completely.
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

        // Sort so related providers are together: iCloud, then OneDrive, then Google Drive, then Dropbox; within each group by displayName.
        let typeOrder: [CloudProvider.ProviderType] = [.iCloud, .oneDrive, .googleDrive, .dropBox]
        var sorted = found.sorted { a, b in
            let aIndex = typeOrder.firstIndex(of: a.type) ?? typeOrder.count
            let bIndex = typeOrder.firstIndex(of: b.type) ?? typeOrder.count
            if aIndex != bIndex { return aIndex < bIndex }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }

        // Apply the stored overrides. Root first, then landing: an `openAt` is meaningful only
        // against the root it was measured from, and a migrated root override replaces exactly the
        // root that its companion `openAt` was relativized against.
        for i in 0..<sorted.count {
            if let override = rootOverride(sorted[i].id) {
                sorted[i].rootPath = override
            }
            // Note the deliberate absence of an `isEmpty` filter: "" is the root, a landing folder
            // the user can legitimately choose and one they cannot otherwise express. Only an
            // ABSENT key means "use the discovered default".
            if let override = openAtOverride(sorted[i].id) {
                sorted[i].openAt = override
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
        //
        //    A folder source is its own root and lands at it. The root/landing split exists to
        //    reach *above* a cloud account's document folder; a folder the user picked by hand has
        //    nothing above it that they did not already choose, so it keeps one path and one row.
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
        let rootOverrides = overridesByProviderId(keyPrefix: Self.rootOverrideKeyPrefix)
        let openAtOverrides = overridesByProviderId(keyPrefix: Self.openAtOverrideKeyPrefix)
        let nameOverrides = overridesByProviderId(keyPrefix: Self.nameOverrideKeyPrefix)
        let iCloudPath = Self.iCloudDefaultPath
        let sources = folderSources
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
                iCloudDefaultOpenAt: Self.iCloudDefaultOpenAt(rootPath: iCloudPath, validator: validator),
                folderSources: sources,
                rootOverride: { rootOverrides[$0] },
                openAtOverride: { openAtOverrides[$0] },
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
            // Written on every readable pass, including one that changes nothing: what has to
            // survive the quit is "what did we last actually see", and a change-guard would skip
            // exactly the unchanged pass that is the only one a quiet session ever runs.
            userDefaults.set(accounts.folders.map(\.path), forKey: Self.lastKnownAccountFoldersKey)
        } else {
            Logger.shared.warning(
                "Provider discovery could not read the CloudStorage folder, so it learned nothing "
                + "about which accounts are mounted — the \(lastKnown.count) found by the last "
                + "readable pass are being kept. Cloud accounts have NOT been removed; check that "
                + "~/Library/CloudStorage is readable.")
        }

        // **Ordered before the comparison**, not after: comparing the discovery order against a
        // published list already in the user's order would differ every time and re-render every
        // observer on every save.
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

    /// All persisted overrides under the given key prefix (path or label), keyed by provider id —
    /// snapshotted on the main actor so the discovery pass can run detached without capturing
    /// the (non-Sendable) defaults.
    private func overridesByProviderId(keyPrefix: String) -> [String: String] {
        Self.overridesByProviderId(in: userDefaults, domainName: overridesDomainName, keyPrefix: keyPrefix)
    }

    /// The scoped read behind `overridesByProviderId`, and behind `RootsMigration`'s harvest of the
    /// legacy `path_override_` keys — **one implementation, because the scoping rule is the whole
    /// point of it and a second copy drifted off it immediately.**
    ///
    /// `dictionaryRepresentation()` merges the entire defaults search list — NSGlobalDomain
    /// included — so a stray global-domain key starting with the prefix would be honored as an
    /// override. Read the owning domain alone when its name is known.
    ///
    /// **A nil persistent domain is `[:]`, never a fallback to the merged list.** Nil there means
    /// nothing was ever persisted to the suite (a fresh install); falling back would honor exactly
    /// the stray keys this scoping exists to exclude, precisely when the app owns no keys of its
    /// own to outweigh them. Only a caller that passes no domain name at all (the pre-existing
    /// bare-suite injection contract) reads the merged list.
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

    /// One value read with the same domain scoping `overridesByProviderId` uses, for the migration's
    /// stamp and its record of which sources it has already settled. Both are written with
    /// `defaults.set`, which lands in the app's own domain — reading them through the merged search
    /// list would let a stray NSGlobalDomain key of the same name suppress the migration outright.
    nonisolated static func scopedValue(
        forKey key: String,
        in defaults: UserDefaults,
        domainName: String?
    ) -> Any? {
        guard let domainName else { return defaults.object(forKey: key) }
        return defaults.persistentDomain(forName: domainName)?[key]
    }

    /// The names of every key under `prefix`, scoped the same way. For a store whose keys carry
    /// their own identity — `IgnoredItemsStore`'s pair keys — where the migration has to find the
    /// keys before it can read them.
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
    ///
    /// **Hoisted because that switch is drawn twice** — the Settings source row and the setup
    /// sheet's source row — and until now each held its own copy of both sentences. They drifted
    /// exactly the way two copies do: both spent months promising to "Show <name> in the pane
    /// sidebar", a window column `7293d946` deleted on 2026-07-14, and repairing the one a reader
    /// happened to open would have left the other still saying it. Nothing catches that, because
    /// nothing in the app ever reads a help string back.
    ///
    /// Living in `Settings` rather than in `MacApp` is what makes it reachable from both: the
    /// setup sheet already imports this module for `SettingsManager` itself.
    public enum ProviderToggleHelp {
        /// Why the switch is disabled: this is the last enabled source, and `canDisable` refuses.
        public static let lastRemaining = "At least one source must remain enabled."

        /// What switching it on does. Phrased from `enabledProviders`, which is the list every
        /// source picker is handed — each pane header's source menu (`ProviderMenu` in
        /// `DashboardViews`), the lens source bar, and the command palette's source rows — rather
        /// than from any one of those surfaces, so removing or adding a picker cannot falsify it
        /// the way naming the sidebar did.
        public static func offer(_ displayName: String) -> String {
            "Offer \(displayName) in the pane header's source menu, and anywhere else a source is picked."
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
    /// Returned as a pair rather than computed by two functions so the two dictionaries can never
    /// be read from different moments — the landing answer is only meaningful beside the root
    /// answer it was measured with.
    private nonisolated static func validity(
        of providers: [CloudProvider],
        using validate: PathValidator
    ) -> (root: [String: Bool], landing: [String: Bool]) {
        var root: [String: Bool] = [:]
        var landing: [String: Bool] = [:]
        for provider in providers where root[provider.id] == nil {
            let rootExists = validate(provider.rootPath)
            root[provider.id] = rootExists
            // A landing folder AT the root is the root, already stat'ed — and a landing under a
            // root that does not exist cannot exist either. Neither needs a second syscall.
            landing[provider.id] = provider.openAt.isEmpty || !rootExists
                ? rootExists
                : validate(provider.landingPath)
        }
        return (root, landing)
    }

    /// The **root** of a source: the top of what it covers, and the base every root-relative path
    /// in the app is measured from. Empty for an unknown id.
    ///
    /// This is what a pane's tree is rooted at, what a breadcrumb's first crumb names, and what
    /// scanning, coverage and containment are bounded by. Callers that want the folder a pane
    /// *opens* at want `landingPath(for:)` — the two were one value until the roots split, and
    /// picking the wrong one composes a path that is silently wrong rather than obviously so.
    public func rootPath(for providerId: String) -> String {
        availableProviders.first(where: { $0.id == providerId })?.rootPath ?? ""
    }

    /// The source's landing folder relative to its root; `""` for the root itself and for an
    /// unknown id.
    public func openAt(for providerId: String) -> String {
        availableProviders.first(where: { $0.id == providerId })?.openAt ?? ""
    }

    /// The landing folder a pane on this source **should actually open at**: `openAt`, or the root
    /// when that folder is not there.
    ///
    /// The degrade is the point. A landing folder is a stored preference pointing at a folder the
    /// user can rename or delete at any time, from outside this app; seeding a pane to a path that
    /// is no longer a directory would open every new tab on that source into an empty tree with no
    /// explanation. The root always exists when the source is valid at all, so it is the one
    /// fallback that cannot fail in turn.
    /// The degrade is only as fresh as the last discovery pass, which is what refreshes
    /// `landingValidity` — renaming the landing folder mid-session does not re-seed panes until
    /// something rediscovers. That is the same staleness `isPathValid` has always carried, and the
    /// same one the Settings row reads, so the two never disagree with each other.
    /// **`== false`, not `!isLandingValid(for:)`, and the asymmetry is the point.** An id with no
    /// entry is not evidence of a missing folder — it is a source published a moment before the
    /// validity pass that measured it, which is an ordinary launch state. Degrading there would
    /// seed panes at the account root for the window between the two, i.e. exactly at launch, which
    /// is where a wrong landing folder is most visible and most likely to be saved back.
    ///
    /// `isLandingValid` defaults the other way because it answers a different question — "do we
    /// have positive evidence this folder is there?" — for a row that only warns when it also has
    /// positive evidence about the root (`isPathValid`), so an unknown id says nothing there either.
    public func openAtIfReachable(for providerId: String) -> String {
        let openAt = openAt(for: providerId)
        guard !openAt.isEmpty, landingValidity[providerId] == false else { return openAt }
        return ""
    }

    /// Whether this source's root is a stored override rather than the discovered one.
    ///
    /// Only `RootsMigration` writes that key, for the install whose legacy Location pointed outside
    /// its account entirely — so this is false for every source on a normal install, and the one
    /// control it gates does not appear. It has to exist at all because a root the user cannot see
    /// the provenance of and cannot clear is a trap: the row presents it as the account's one true
    /// root while it is in fact a value carried forward from a setting they made years ago.
    public func hasRootOverride(for providerId: String) -> Bool {
        hasStoredOverride(prefix: Self.rootOverrideKeyPrefix, for: providerId)
    }

    /// The absolute folder a pane on this source opens at — `rootPath` with `openAt` applied,
    /// degrading to the root when the landing folder is missing.
    public func landingPath(for providerId: String) -> String {
        PathBoundary.join(root: rootPath(for: providerId),
                          relative: openAtIfReachable(for: providerId))
    }

    /// Persists a custom absolute path mapping for a specific provider ID, dropping the system default.
    ///
    /// Moving a **folder source** onto a folder some other source already names is refused rather
    /// than written, because one folder gets one row — see `existingSource(naming:ignoring:)`,
    /// which is where that is decided for this and for `addFolderSource` alike. The caller is told
    /// so it can put the field back; a silent no-op would read as the edit having been lost.
    ///
    /// **The account branch below has no editor and is not meant to grow one.** An account has one
    /// root — the folder `~/Library/CloudStorage` mounts it at — so a field there would be a way to
    /// be wrong about a fact rather than a preference to express, and Settings shows it read-only.
    /// What survives is the *clearing* half, reached from the Root row's Reset, which appears only
    /// for the install `RootsMigration` pinned to a root carried forward from a legacy Location
    /// (see `hasRootOverride`). Passing a non-empty path here still writes an override, and only
    /// the migration does that.
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
    /// The chosen folder must be inside the source's root, and that is not a formality: `openAt` is
    /// *stored* relative to the root, so a folder outside it has no representation here at all —
    /// the containment test and the conversion are the same operation, which is why
    /// `PathBoundary.relativize` performs both and a nil is the refusal.
    ///
    /// Symlinks are resolved on both sides before the test, and only for the test. A folder reached
    /// through a link is genuinely inside the root it resolves into, but the *stored* value stays
    /// the spelling the user navigated, so what Settings shows them is the path they chose.
    @discardableResult
    public func setOpenAt(_ absolutePath: String, for providerId: String) -> PathChangeOutcome {
        let root = rootPath(for: providerId)
        // Its own refusal, not `.unchanged`. A source can leave the discovered list while its row is
        // still on screen (or not have entered it yet), and `.unchanged` is what the picker reads as
        // success — so the user chose a folder, the panel closed, nothing happened, and nothing said
        // so anywhere, log included.
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
        // Lexical first, so a path the user navigated through a link keeps its own spelling; the
        // resolved comparison is the fallback for a choice that arrived already resolved (which is
        // what NSOpenPanel hands back on a machine using firmlinked home directories).
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
    /// Says which of the two it did. The first draft logged the same line either way, so an audit
    /// read "reset the landing folder" for a source that had no landing folder to reset — and the
    /// button is enabled in both states (`hasOpenAtOverride` gates only what the row *says*, not
    /// whether the click is allowed).
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

    /// Whether the landing folder is the user's choice rather than the discovered default. What
    /// separates "Open at: The source root" *chosen* from the same words *inherited* — which for
    /// iCloud, whose discovered default IS the root, is otherwise the identical row.
    public func hasOpenAtOverride(for providerId: String) -> Bool {
        hasStoredOverride(prefix: Self.openAtOverrideKeyPrefix, for: providerId)
    }

    /// Whether one prefixed override key is stored **for this install**, scoped exactly as
    /// `overridesByProviderId` scopes the reads that actually apply the value.
    ///
    /// Not `userDefaults.string(forKey:)`, which both of these used to be: that reads the merged
    /// search list, so a stray `NSGlobalDomain` key of the same name answers true here while
    /// `mapProviders` — which reads the owning domain alone — never sees it. The row would then
    /// offer a Reset for a choice it does not have, and taking it would log "reset the landing
    /// folder to the discovered default" over a key that was never this install's. Two readers of
    /// one key with two scoping rules is the exact defect `overridesByProviderId`'s doc says a
    /// second copy introduced immediately; these were that second copy.
    private func hasStoredOverride(prefix: String, for providerId: String) -> Bool {
        Self.scopedValue(forKey: prefix + providerId,
                         in: userDefaults, domainName: overridesDomainName) as? String != nil
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
