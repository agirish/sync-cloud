import Events
import Foundation
import Sync

/// Moves an install's stored positions from the old single-path world to the root/landing one.
///
/// ## What moves, and what does not
///
/// A source's root widened from its documents folder to the account folder, and its `openAt` is
/// seeded to exactly the old root. So `root + openAt` names the same directory the old root did,
/// and **everything stored as an absolute path is already correct**: automation destinations,
/// Organize scopes, filing profiles, caches, storage-lens snapshots. That is why the `openAt`
/// defaults are what they are.
///
/// What is left is state stored *relative to* a source's root, or *keyed by* it, in five stores.
/// The per-pane `lastLeftFocusPath` / `lastRightFocusPath` are not among them: nothing reads them.
///
/// | Key | Shape | What moves |
/// |---|---|---|
/// | `browseTabs` / `browseTabsRight` | JSON, `relativePath` per entry | gains the prefix |
/// | `folderJumpPinnedByRoot` / `folderJumpRecentsByRoot` | JSON, root-keyed, root-relative values | re-keyed, values gain the prefix |
/// | `folderJumpFavoriteOrder` | `root\0relative` strings | both halves |
/// | `destinationRecentsByProvider` | root-keyed, ABSOLUTE values | re-keyed only |
/// | `ignoredItems_v1_<idA>\|<idB>` | pane-root-relative strings | gain the first id's prefix |
///
/// **The ignore sets look safe and are not.** `IgnoredItemsStore` holds them pane-root-relative
/// (`FileSyncManager.rootRelativePath` composes them from the pane's focus), so a widened root
/// would make `Archive/big.zip` match a different file one level up. An accidental un-ignore lets
/// Sync All act on a file the user excluded, so this store is migrated, not left to degrade.
///
/// ## Additive, because the user can go back
///
/// Older releases share this defaults domain and still read `path_override_<id>` as their
/// Location. **Never rewrite or remove a legacy key**: the migration only reads the old override
/// and writes new ones beside it, so reinstalling an older release finds its settings as it left
/// them. Only tab positions can be lost going back: a tab moved to `Documents/Family` opens as a
/// missing folder on an older build, which re-roots it, the usual degrade for a vanished folder.
///
/// ## Per source, not once for the machine
///
/// A source not mounted when this runs can't be planned, because its root is unknown, and a
/// signed-out OneDrive is ordinary. Stamping anyway would leave its tabs and pins wrong for good
/// once it came back. So the record is a set of provider ids, not a flag: each launch settles the
/// sources it can see and leaves the rest. The stamp is only the fast exit, written once every
/// source the stored state mentions is settled, so a typical install pays for one listing.
public enum RootsMigration {

    /// The fast exit: set only when nothing is outstanding (see `handledProviderIdsKey`). An absent
    /// key reads as 0, below `currentStamp`.
    ///
    /// **Do not bump this to re-run the migration.** Every rebase prepends a prefix, so a second
    /// pass produces `Documents/Documents/…`. Unlike `PaneBarMigration`, this isn't idempotent by
    /// content; a future change of shape needs its own key and its own record of what it touched.
    public static let stampKey = "rootsModelStamp"
    static let currentStamp = 1

    /// The provider ids whose stored positions have already been moved: the real idempotence guard,
    /// and what lets an unmounted source be picked up later. A source listed here is never planned
    /// again, so nothing gains a prefix twice.
    public static let handledProviderIdsKey = "rootsModelHandledProviderIds"

    // MARK: Foreign keys, deliberately re-spelled
    //
    // These strings belong to `GeneralSettings`, `PaneTabsStore`, `FolderJumpStore`,
    // `DestinationRecents` and `IgnoredItemsStore`, mostly in modules this one doesn't import.
    // Spelled out rather than referenced because a migration describes what was on disk at its
    // version: if a store renames its key, this must still find the old data.
    static let leftProviderKey = "selectedLeftProviderId"
    static let rightProviderKey = "selectedRightProviderId"
    static let leftTabsKey = "browseTabs"
    static let rightTabsKey = "browseTabsRight"
    static let pinnedByRootKey = "folderJumpPinnedByRoot"
    static let recentsByRootKey = "folderJumpRecentsByRoot"
    static let favoriteOrderKey = "folderJumpFavoriteOrder"
    static let destinationRecentsKey = "destinationRecentsByProvider"
    static let ignoredItemsKeyPrefix = "ignoredItems_v1_"

    /// What one pass did, in the form the launch log line is built from.
    public enum Outcome: Equatable, Sendable {
        /// Nothing left to do: the stamp was current, or this pass found no unsettled source. The
        /// common case.
        case alreadyDone
        /// The CloudStorage root couldn't be listed, so the account roots are unknown and a plan
        /// would be about the wrong providers. Nothing written or stamped; the next launch retries.
        case deferred
        /// Migrated. Carries the prefix applied per source, how many stored positions actually
        /// moved, the sources still waiting for a launch that can see them, and any store that was
        /// present but unreadable.
        case migrated(prefixes: [String: String],
                      moved: Int,
                      outstanding: [String],
                      unreadable: [String])

        /// The line the app writes at launch, or nil when there is nothing worth saying. It says
        /// what moved, not what was planned, so a fresh install with nothing stored doesn't claim
        /// positions were moved; a count the reader can check against their tabs is the point.
        public var logLine: String? {
            switch self {
            case .alreadyDone:
                return nil
            case .deferred:
                return "Source roots: could not read ~/Library/CloudStorage, so the one-time move "
                    + "of stored folder positions is deferred to the next launch. Nothing was changed."
            case .migrated(let prefixes, let moved, let outstanding, let unreadable):
                var line: String
                let described = prefixes.filter { !$0.value.isEmpty }
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) → \($0.value)" }
                    .joined(separator: ", ")
                if moved == 0 {
                    line = described.isEmpty
                        ? "Source roots: nothing to move — every source already sat at its root."
                        : "Source roots: sources now start at their account folder (\(described)). "
                            + "There were no stored folder positions to move."
                } else {
                    line = "Source roots: sources now start at their account folder, and \(moved) "
                        + "stored folder position\(moved == 1 ? "" : "s") moved down into "
                        + "(\(described)). Tabs, pins, recents, ignored items and the last-open "
                        + "folder all point at the same folders as before."
                }
                if !outstanding.isEmpty {
                    line += " Still waiting on \(outstanding.sorted().joined(separator: ", ")) — "
                        + "not mounted right now, so their stored positions will move on a launch "
                        + "that can see them."
                }
                if !unreadable.isEmpty {
                    line += " NOT moved, because the stored value could not be read: "
                        + "\(unreadable.sorted().joined(separator: ", "))."
                }
                return line
            }
        }
    }

    /// The per-provider rewrite, worked out before anything is written.
    struct Plan: Equatable {
        /// Provider id → the relative path every stored position of that source gains. Only
        /// sources that move appear, so `prefixes.isEmpty` means "nothing to do"; `handled` says
        /// what was looked at.
        var prefixes: [String: String] = [:]
        /// Every provider id this plan settled, moved or not, so a later launch doesn't plan them
        /// again and prepend a second prefix.
        var handled: Set<String> = []
        /// Old normalized root → new normalized root, for the two root-keyed stores.
        var rootRemap: [String: String] = [:]
        /// Old normalized root → the prefix its positions gain, for the same two stores: the values
        /// of `prefixes`, keyed the way those stores are. Recorded, not re-derived, because the
        /// iCloud move's prefix comes from a folder linked into the new root
        /// (`PathBoundary.LinkedFolders`), which no string arithmetic can recover;
        /// `prefix(forRoot:plan:)` reads this first.
        var prefixByRoot: [String: String] = [:]
        /// Landing folders to persist, for sources whose legacy Location was not the new default.
        var openAtOverrides: [String: String] = [:]
        /// Roots to persist, for the legacy Location that pointed outside its account entirely.
        var rootOverrides: [String: String] = [:]
    }

    /// Works out, per source, where its stored positions have to move.
    ///
    /// - Parameters:
    ///   - discovered: Providers mapped with their discovered defaults and **no `openAt` override
    ///     applied**, so `landingPath` is exactly the path this source had before the split.
    ///   - legacyOverrides: The `path_override_<id>` values, by provider id.
    ///
    /// Four cases:
    /// - the legacy root is inside the new root: the prefix between them becomes the landing folder
    ///   when it differs from the discovered default;
    /// - the legacy root is the new root and no Location was set (iCloud): nothing to do;
    /// - the legacy root is the new root **and the user typed it**: `openAt` must be written as
    ///   `""`, or discovery seeds `Documents` and their panes silently open a level down;
    /// - the legacy root is somewhere else entirely (a hand-typed Location): no discovered root
    ///   contains it, so the path itself becomes the root and the source lands at it, as before.
    static func plan(discovered: [CloudProvider], legacyOverrides: [String: String]) -> Plan {
        var plan = Plan()
        // Sorted, so two sources colliding on one legacy root resolve the same way on every run.
        for provider in discovered.sorted(by: { $0.id < $1.id }) {
            // A folder source is its own root and always was: `setPath` writes its path straight
            // into the stored list, so there is no legacy override to adopt and nothing to rebase.
            guard !provider.isLocalFolder else { continue }
            plan.handled.insert(provider.id)

            let newRoot = normalizedRoot(provider.rootPath)
            // An empty stored override is no override. `overridesByProviderId` can't filter
            // empties, because `openAt_override_` uses `""` as a real value; an empty
            // `path_override_` would otherwise become a `root_override_` of `""`, a source with no
            // root at all. Old builds cleared the key instead, so this guards a shape that shouldn't
            // exist, which a one-shot migration is the wrong place to discover.
            let legacyOverride = legacyOverrides[provider.id].flatMap { $0.isEmpty ? nil : $0 }
            // Normalized, not merely tilde-expanded: a Location ending in `/` would relativize to
            // `Documents/`, and the slash would ride into `openAt` and the pane's focus, making
            // `Documents/` and `Documents` two tabs for one folder.
            let legacyRoot = normalizedRoot(legacyOverride ?? provider.landingPath)
            guard legacyRoot != newRoot else {
                if legacyOverride != nil, !provider.openAt.isEmpty {
                    plan.openAtOverrides[provider.id] = ""
                }
                continue
            }

            guard let prefix = PathBoundary.relativize(legacyRoot, under: newRoot) else {
                plan.rootOverrides[provider.id] = legacyRoot
                plan.openAtOverrides[provider.id] = ""
                continue
            }
            plan.prefixes[provider.id] = prefix
            plan.prefixByRoot[legacyRoot] = prefix
            // An assignment, not a merge: no two sources can collide on one `rootRemap` key. Here
            // `legacyRoot` is inside this source's account folder, and account folders are siblings
            // that iCloud's `~/Documents` doesn't contain; a Location aimed at another account's
            // folder takes the root-override branch above instead.
            plan.rootRemap[legacyRoot] = newRoot
            // Only when it differs from what discovery would produce: an install with no Location
            // override must not come out looking customized, claiming a choice never made.
            if prefix != provider.openAt {
                plan.openAtOverrides[provider.id] = prefix
            }
        }
        return plan
    }

    /// Runs the migration. Safe to call repeatedly: the stamp short-circuits the settled case, and
    /// `handledProviderIdsKey` makes a pass skip every source already moved, so no prefix is
    /// applied twice.
    @discardableResult
    public static func apply(
        defaults: UserDefaults,
        domainName: String? = nil,
        accounts: CloudStorageAccounts,
        discovered: [CloudProvider],
        legacyOverrides: [String: String]
    ) -> Outcome {
        guard stamp(in: defaults, domainName: domainName) < currentStamp else { return .alreadyDone }
        // An unreadable root means the account folders are unknown. Stamping now would make a
        // wrong plan permanent; deferring costs one listing next launch. `discoverProviders`
        // refuses on the same evidence.
        guard accounts.rootWasReadable else { return .deferred }

        let alreadyHandled = handledProviderIds(in: defaults, domainName: domainName)
        let plan = plan(discovered: discovered.filter { !alreadyHandled.contains($0.id) },
                        legacyOverrides: legacyOverrides)

        for (id, root) in plan.rootOverrides {
            defaults.set(root, forKey: SettingsManager.rootOverrideKeyPrefix + id)
        }
        for (id, openAt) in plan.openAtOverrides {
            defaults.set(openAt, forKey: SettingsManager.openAtOverrideKeyPrefix + id)
        }

        var moved = 0
        var unreadable: [String] = []
        moved += rebaseTabs(defaults: defaults, plan: plan, unreadable: &unreadable)
        moved += rebaseJumpFolders(defaults: defaults, plan: plan, unreadable: &unreadable)
        moved += rebaseFavoriteOrder(defaults: defaults, plan: plan)
        moved += rebaseDestinationRecents(defaults: defaults, plan: plan)
        moved += rebaseIgnoredItems(defaults: defaults, domainName: domainName, plan: plan)

        let handled = alreadyHandled.union(plan.handled)
        defaults.set(handled.sorted(), forKey: handledProviderIdsKey)

        // Outstanding comes from what the stored state mentions, not the override list: a source
        // with no Location override still has tabs measured from its old root, so an unmounted
        // Dropbox is as much a reason to keep looking as a re-pointed account.
        let outstanding = referencedProviderIds(defaults: defaults, legacyOverrides: legacyOverrides)
            .subtracting(handled)
        if outstanding.isEmpty {
            defaults.set(currentStamp, forKey: stampKey)
        }
        // Nothing new settled and nothing moved: a source the stored state names is still absent.
        // Say nothing rather than repeat the same line every launch.
        guard !plan.handled.isEmpty || moved > 0 else { return .alreadyDone }
        return .migrated(prefixes: plan.prefixes, moved: moved,
                         outstanding: Array(outstanding), unreadable: unreadable)
    }

    // MARK: - The five stores

    /// Both tab strips. Re-serialized through `JSONSerialization`, not a `Codable` round trip, **so
    /// unknown keys survive**: other releases write these strips, and decoding to known fields
    /// would drop any field another build added.
    private static func rebaseTabs(defaults: UserDefaults, plan: Plan, unreadable: inout [String]) -> Int {
        var moved = 0
        for key in [leftTabsKey, rightTabsKey] {
            guard let raw = defaults.string(forKey: key) else {
                // `string(forKey:)` is nil both when absent and when stored as another type. Only
                // the second is worth reporting, since this one-shot migration never comes back for
                // a strip it passes over, so ask whether anything is stored at all.
                if defaults.object(forKey: key) != nil { unreadable.append(key) }
                continue
            }
            guard let data = raw.data(using: .utf8),
                  var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                // Present and unreadable isn't absent: the strip stays measured from the old root,
                // so say so.
                unreadable.append(key)
                continue
            }
            var changed = false
            for index in entries.indices {
                guard let providerId = entries[index]["providerId"] as? String,
                      let prefix = plan.prefixes[providerId] else { continue }
                let relative = entries[index]["relativePath"] as? String ?? ""
                entries[index]["relativePath"] = rebased(relative, under: prefix)
                changed = true
                moved += 1
            }
            guard changed,
                  let out = try? JSONSerialization.data(withJSONObject: entries),
                  let text = String(data: out, encoding: .utf8) else { continue }
            defaults.set(text, forKey: key)
        }
        return moved
    }

    /// Pins and recents: the dictionary key is a root and every entry's `relativePath` is measured
    /// from it, so both halves move together. A root the plan doesn't name is carried across
    /// untouched: a folder source's, one that didn't move, or one an earlier pass migrated.
    private static func rebaseJumpFolders(defaults: UserDefaults, plan: Plan, unreadable: inout [String]) -> Int {
        var moved = 0
        for key in [pinnedByRootKey, recentsByRootKey] {
            guard let data = defaults.data(forKey: key) else { continue }
            guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]]
            else {
                unreadable.append(key)
                continue
            }
            var out: [String: [[String: Any]]] = [:]
            var changed = false
            // Sorted, so a merge onto an existing root produces the same order every run, as
            // `FolderJumpStore.init` does.
            for (root, entries) in stored.sorted(by: { $0.key < $1.key }) {
                guard let newRoot = plan.rootRemap[root],
                      let prefix = prefix(forRoot: root, plan: plan), !prefix.isEmpty else {
                    // Merge rather than assign: a remapped root could collide with one already
                    // spelled the new way, and dropping either list would lose pins.
                    out[root, default: []].append(contentsOf: entries)
                    continue
                }
                changed = true
                let relocated = entries.map { entry -> [String: Any] in
                    var entry = entry
                    entry["relativePath"] = rebased(entry["relativePath"] as? String ?? "", under: prefix)
                    return entry
                }
                moved += relocated.count
                out[newRoot, default: []].append(contentsOf: relocated)
            }
            guard changed, let encoded = try? JSONSerialization.data(withJSONObject: out) else { continue }
            defaults.set(encoded, forKey: key)
        }
        return moved
    }

    /// The Favorites drag order, whose entries are `root\0relativePath`, so both halves are
    /// rewritten. An entry whose root didn't move is kept, not dropped: this list is the sequence,
    /// and a hole would reorder the section.
    private static func rebaseFavoriteOrder(defaults: UserDefaults, plan: Plan) -> Int {
        guard let stored = defaults.stringArray(forKey: favoriteOrderKey), !stored.isEmpty else { return 0 }
        var moved = 0
        let rewritten = stored.map { entry -> String in
            let halves = entry.components(separatedBy: "\u{0}")
            guard halves.count == 2,
                  let newRoot = plan.rootRemap[halves[0]],
                  let prefix = prefix(forRoot: halves[0], plan: plan), !prefix.isEmpty else { return entry }
            moved += 1
            return "\(newRoot)\u{0}\(rebased(halves[1], under: prefix))"
        }
        guard moved > 0 else { return 0 }
        defaults.set(rewritten, forKey: favoriteOrderKey)
        return moved
    }

    /// Filing destinations. The values are absolute and stay as they are; only the key they are
    /// filed under moves. Trimmed to `DestinationRecents.limit`, because a merge onto an existing
    /// key can exceed it and `DestinationRecents.load` doesn't trim on read.
    private static func rebaseDestinationRecents(defaults: UserDefaults, plan: Plan) -> Int {
        guard let stored = defaults.dictionary(forKey: destinationRecentsKey) as? [String: [String]],
              !stored.isEmpty else { return 0 }
        var out: [String: [String]] = [:]
        var moved = 0
        for (root, destinations) in stored.sorted(by: { $0.key < $1.key }) {
            guard let newRoot = plan.rootRemap[root] else {
                out[root, default: []].append(contentsOf: destinations)
                continue
            }
            moved += destinations.count
            out[newRoot, default: []].append(contentsOf: destinations)
        }
        guard moved > 0 else { return 0 }
        defaults.set(out.mapValues { Array($0.prefix(DestinationRecents.limit)) }, forKey: destinationRecentsKey)
        return moved
    }

    /// The durable ignore sets, one key per provider PAIR (`ignoredItems_v1_<idA>|<idB>`, ids
    /// sorted). Values are pane-root-relative.
    ///
    /// The first id's prefix, and only the first id's: `IgnoredItemsStore` measures entries
    /// from the source whose id sorts first, the id this key names first
    /// (`FileSyncManager.ignoreAnchorIsLeft`), so the entries must move into exactly those
    /// coordinates. Deliberately not "the first id that has a prefix": when the leading source
    /// didn't move (iCloud, or a folder source sorting first), its entries are already right.
    private static func rebaseIgnoredItems(defaults: UserDefaults, domainName: String?, plan: Plan) -> Int {
        let keys = SettingsManager.keys(in: defaults, domainName: domainName,
                                        havingPrefix: ignoredItemsKeyPrefix)
        var moved = 0
        for key in keys.sorted() {
            let ids = key.dropFirst(ignoredItemsKeyPrefix.count).components(separatedBy: "|")
            guard let anchorId = ids.first, let prefix = plan.prefixes[anchorId], !prefix.isEmpty,
                  let stored = defaults.stringArray(forKey: key), !stored.isEmpty else { continue }
            defaults.set(stored.map { rebased($0, under: prefix) }, forKey: key)
            moved += stored.count
        }
        return moved
    }

    // MARK: - Helpers

    /// The prefix of whichever provider owned this root, found by root, not id: the two root-keyed
    /// stores hold no provider ids.
    private static func prefix(forRoot root: String, plan: Plan) -> String? {
        guard let newRoot = plan.rootRemap[root] else { return nil }
        if let recorded = plan.prefixByRoot[root] { return recorded }
        // Re-derived from the remap's own pair. Both sides are `normalizedRoot`ed, as is the value
        // in `prefixes`, so the two answers are the same string, not two spellings.
        return PathBoundary.relativize(root, under: newRoot)
    }

    /// A stored relative path with `prefix` in front of it, canonicalized through `PaneBrowsePath`.
    ///
    /// The canonicalization is the guard. `PathBoundary.join` returns the bare root for anything
    /// starting with `/`, so a leading or doubled separator would silently open every affected pane
    /// at the top of the account, which reads as data loss. `PaneBrowsePath` splits on `/` and
    /// rejoins, so no such spelling survives.
    static func rebased(_ relative: String, under prefix: String) -> String {
        PaneBrowsePath(relativePath: PathBoundary.joinRelative(prefix, relative)).relativePath
    }

    /// The spelling the root-keyed stores file under: tilde-expanded, trailing slashes trimmed.
    ///
    /// `FolderJumpStore.key(forRoot:)` delegates to the same helper. `DestinationRecents` uses
    /// `PaneBrowsePath.normalized`, which doesn't expand a tilde; harmless here, because every
    /// remapped root is an absolute discovered account path. (A hand-typed `~/…` Location goes to
    /// `rootOverrides`, which is not a key.)
    private static func normalizedRoot(_ root: String) -> String {
        PathBoundary.normalizedRoot(root)
    }

    /// Every provider id the stored state mentions: the set that must be settled before the
    /// fast-exit stamp is written. The two root-keyed stores aren't consulted, since a root can't
    /// be attributed to an unmounted source; the tab strips and pane selections name those sources.
    ///
    /// **Folder sources must be excluded**, or the wait becomes a deadlock. A signed-out account
    /// will be discovered on a later launch; a folder source never is, because `applyAtLaunch` maps
    /// only the CloudStorage accounts and iCloud. Counted, its id would stay outstanding for good:
    /// every launch would pay for a CloudStorage listing, and with a legacy Location the CLI would
    /// refuse permanently. Recognised by `FolderSource.isFolderSourceId`, a documented property of
    /// the id, not by reading the stored list, which can itself be unreadable.
    private static func referencedProviderIds(
        defaults: UserDefaults,
        legacyOverrides: [String: String]
    ) -> Set<String> {
        var ids = Set(legacyOverrides.keys)
        for key in [leftProviderKey, rightProviderKey] {
            if let id = defaults.string(forKey: key), !id.isEmpty { ids.insert(id) }
        }
        for key in [leftTabsKey, rightTabsKey] {
            guard let raw = defaults.string(forKey: key),
                  let data = raw.data(using: .utf8),
                  let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { continue }
            for entry in entries {
                if let id = entry["providerId"] as? String, !id.isEmpty { ids.insert(id) }
            }
        }
        return ids.filter { !FolderSource.isFolderSourceId($0) }
    }

    private static func stamp(in defaults: UserDefaults, domainName: String?) -> Int {
        (SettingsManager.scopedValue(forKey: stampKey, in: defaults, domainName: domainName) as? Int) ?? 0
    }

    private static func handledProviderIds(in defaults: UserDefaults, domainName: String?) -> Set<String> {
        let value = SettingsManager.scopedValue(forKey: handledProviderIdsKey,
                                                in: defaults, domainName: domainName)
        return Set(value as? [String] ?? [])
    }
}

extension RootsMigration {

    /// Stored state from the old layout this migration hasn't moved yet, keyed by source id; empty
    /// once the stamp is set, and on a fresh install.
    ///
    /// A read that writes nothing, for the CLI. It shares the app's defaults domain, and read
    /// under the new meaning a legacy Location would make `sync`, a mass copy, quietly scan the
    /// discovered root instead. Migrating from the CLI would rewrite tabs and pins from a terminal,
    /// possibly under the running app, and stamp on different evidence. So the CLI asks and
    /// refuses; the app migrates. Narrower than "is the stamp missing", so a fresh install with
    /// nothing to move isn't refused.
    public static func legacyStateAwaitingMigration(
        defaults: UserDefaults = .standard,
        domainName: String? = SettingsManager.appSuiteName
    ) -> [String: String] {
        guard stamp(in: defaults, domainName: domainName) < currentStamp else { return [:] }
        return SettingsManager.overridesByProviderId(
            in: defaults, domainName: domainName,
            keyPrefix: SettingsManager.legacyPathOverrideKeyPrefix)
    }

    /// Gathers the inputs off disk and runs the migration: the app's one entry point. **The CLI
    /// must not run this**; it calls `legacyStateAwaitingMigration` and refuses instead.
    ///
    /// Synchronous, with its own CloudStorage listing, because it must finish before anything
    /// reads a stored position (the bootstrap task's focus restore and tab strips, and `@AppStorage`
    /// earlier still), while `SettingsManager`'s discovery publishes asynchronously. One listing per
    /// launch until the stamp is set buys an ordering that doesn't depend on which task wins.
    ///
    /// The app's own keys are read through `SettingsManager`'s domain scoping, not the merged
    /// search list, so a stray NSGlobalDomain key can't pose as this install's Location or suppress
    /// the migration.
    @discardableResult
    public static func applyAtLaunch(
        defaults: UserDefaults = .standard,
        domainName: String? = SettingsManager.appSuiteName,
        lister: (() -> CloudStorageAccounts)? = nil
    ) -> Outcome {
        guard stamp(in: defaults, domainName: domainName) < currentStamp else { return .alreadyDone }

        let accounts = lister?() ?? SettingsManager.cloudStorageFolders(
            at: URL(fileURLWithPath: NSString(string: "~/Library/CloudStorage").expandingTildeInPath))
        let legacyOverrides = SettingsManager.overridesByProviderId(
            in: defaults, domainName: domainName,
            keyPrefix: SettingsManager.legacyPathOverrideKeyPrefix)
        // Mapped with the discovered defaults and no `openAt` override, so `landingPath` names
        // the folder a legacy position was measured from. Folder sources are their own roots and
        // aren't mapped.
        //
        // **iCloud is mapped as this migration first saw it: rooted at `~/Documents`, landing on
        // itself.** Builds 5.3 through 7.0 then moved it to the container, under their own
        // `iCloudRootMoveStamp`; mapped with today's default, this plan would rebase positions
        // never measured from where it now points.
        let discovered = SettingsManager.mapProviders(
            cloudStorageFolders: accounts.folders,
            iCloudDefaultPath: SettingsManager.legacyICloudRoot,
            iCloudDefaultOpenAt: ""
        )
        return apply(defaults: defaults, domainName: domainName, accounts: accounts,
                     discovered: discovered, legacyOverrides: legacyOverrides)
    }
}
