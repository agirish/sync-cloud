import Events
import Foundation
import Sync

/// Moves an install's stored positions from the old single-path world to the root/landing one.
///
/// ## What actually changed, and what did not
///
/// A source's root widened from its documents folder to the account folder, and its `openAt` was
/// seeded to exactly the folder the root used to be. So `root + openAt` names the same directory
/// the old root did, and **everything stored as an absolute path is already correct** — an
/// automation's destination, an Organize scope, every filing profile, every cache, the storage-lens
/// snapshots. That is not luck; it is why the `openAt` defaults were chosen that way.
///
/// What is left is the state stored *relative to* a source's root, or *keyed by* it. Those six
/// stores are this migration's whole subject:
///
/// | Key | Shape | What moves |
/// |---|---|---|
/// | `lastLeftFocusPath` / `lastRightFocusPath` | root-relative string | gains the prefix |
/// | `browseTabs` / `browseTabsRight` | JSON, `relativePath` per entry | gains the prefix |
/// | `folderJumpPinnedByRoot` / `folderJumpRecentsByRoot` | JSON, root-keyed, root-relative values | re-keyed, values gain the prefix |
/// | `folderJumpFavoriteOrder` | `root\0relative` strings | both halves |
/// | `destinationRecentsByProvider` | root-keyed, ABSOLUTE values | re-keyed only |
/// | `ignoredItems_v1_<idA>\|<idB>` | pane-root-relative strings | gain the LEFT source's prefix |
///
/// The ignore sets are the one that reads as safe and is not. `IgnoredItemsStore` holds them in
/// **pane-root-relative** coordinates (its own doc says so) — `FileSyncManager.rootRelativePath`
/// composes them from the pane's focus, which IS measured from the root. So a widened root
/// reinterprets every stored entry: `Archive/big.zip` stops matching the file it was written for
/// and starts matching a different file one level up. Un-ignoring by accident is the bad direction
/// here — Sync All then acts on a file the user deliberately excluded — which is why this store is
/// migrated rather than left to degrade.
///
/// ## Additive, because the user can go back
///
/// The `v3.x` and `v2.x` maintenance lines share this defaults domain and still read
/// `path_override_<id>` as their Location. Nothing here rewrites or removes a legacy key: the
/// migration only *reads* the old override and writes new ones beside it. An install that tries
/// this build and reinstalls the last release finds its settings exactly as it left them.
///
/// Tab positions are the one thing that can be genuinely lost, and only in the direction of going
/// *back*: a tab moved to `Documents/Family` here restores as a missing folder on an older build,
/// which re-roots it. That is the existing graceful degrade for a folder that disappeared, and it
/// is why this is worth doing once, correctly, rather than lazily per read.
///
/// ## Per source, not once for the machine
///
/// **A source that is not mounted at the moment this runs cannot be planned**, because its root is
/// unknown — and a signed-out OneDrive is an ordinary state, not an exotic one. The first draft
/// stamped anyway, which made that source's tabs, pins and last-open folder permanently wrong the
/// week the account came back. So the record is a SET OF PROVIDER IDS, not a single flag: each
/// launch settles whichever sources it can see and leaves the rest for a launch that can see them.
/// The one-shot stamp is kept purely as the fast exit — it is written only once every source the
/// stored state actually mentions has been settled, so the common install pays for one listing at
/// the first launch of this build and nothing afterwards.
public enum RootsMigration {

    /// The fast exit: set only when nothing is outstanding (see `handledProviderIdsKey`). An absent
    /// key reads as 0, and 0 < 1 is what makes a fresh install skip the work while an existing one
    /// does it.
    ///
    /// **Do not bump this to re-run the migration.** Every rebase here PREPENDS a prefix, so a
    /// second pass over already-migrated data produces `Documents/Documents/…`. `PaneBarMigration`
    /// is safe to bump because it is idempotent by content; this is not. A future change of shape
    /// needs its own key and its own record of what it has already touched.
    public static let stampKey = "rootsModelStamp"
    static let currentStamp = 1

    /// The provider ids whose stored positions have already been moved — the real idempotence
    /// guard, and the thing that lets an unmounted source be picked up on a later launch. A source
    /// listed here is never planned again, so nothing can gain a prefix twice.
    public static let handledProviderIdsKey = "rootsModelHandledProviderIds"

    // MARK: Foreign keys, deliberately re-spelled
    //
    // These strings belong to `GeneralSettings`, `PaneTabsStore`, `FolderJumpStore`,
    // `DestinationRecents` and `IgnoredItemsStore` — most of them in modules this one does not
    // import. Naming them here rather than reaching for the constants is the right call for a
    // migration specifically: it is a statement about what was on disk *at this version*, and it
    // must keep working if one of those stores renames its key later. A migration that follows a
    // rename stops finding the data it exists to move.
    static let leftFocusKey = "lastLeftFocusPath"
    static let rightFocusKey = "lastRightFocusPath"
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
        /// Nothing left to do — either the stamp was already current, or this pass found no source
        /// it had not already settled. The common case, every launch after the first.
        case alreadyDone
        /// The CloudStorage root could not be listed, so the account roots are unknown and a plan
        /// built now would be a plan about the wrong providers. Nothing was written and nothing was
        /// stamped — the next launch tries again.
        case deferred
        /// Migrated. Carries the prefix applied per source, how many stored positions actually
        /// moved, the sources still waiting for a launch that can see them, and any store that was
        /// present but unreadable.
        case migrated(prefixes: [String: String],
                      moved: Int,
                      outstanding: [String],
                      unreadable: [String])

        /// The line the app writes at launch, or nil when there is nothing worth saying.
        ///
        /// **It says what moved, not what was planned.** The first draft described the plan, so a
        /// fresh install with no stored state at all announced that its "stored folder positions
        /// were moved down into (Dropbox → Documents, …)" — naming folders it had never had a
        /// position in. A count the reader can check against their own tabs is the point of the
        /// line; a restatement of the discovery table is not.
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
        /// Provider id → the relative path every stored position of that source gains. **Only
        /// sources that actually move appear here**, so `prefixes.isEmpty` means "nothing to do"
        /// rather than "nothing was looked at" — `handled` is what answers the second question.
        var prefixes: [String: String] = [:]
        /// Every provider id this plan settled, moved or not. Recorded so a later launch does not
        /// plan them a second time, which would prepend a second prefix.
        var handled: Set<String> = []
        /// Old normalized root → new normalized root, for the two root-keyed stores.
        var rootRemap: [String: String] = [:]
        /// Landing folders to persist, for sources whose legacy Location was not the new default.
        var openAtOverrides: [String: String] = [:]
        /// Roots to persist, for the legacy Location that pointed outside its account entirely.
        var rootOverrides: [String: String] = [:]
    }

    /// Works out, per source, where its stored positions have to move.
    ///
    /// - Parameters:
    ///   - discovered: Providers mapped with their DISCOVERED defaults and **no `openAt` override
    ///     applied**, so `landingPath` is exactly the path this source had before the split.
    ///   - legacyOverrides: The `path_override_<id>` values, by provider id.
    ///
    /// Four cases, and the last two are the ones worth naming:
    /// - the legacy root is inside the new root — the prefix is what separates them, and it becomes
    ///   the landing folder when it differs from the discovered default;
    /// - the legacy root IS the new root and the user never set a Location — iCloud, whose root did
    ///   not move at all. Nothing to write, nothing to move;
    /// - the legacy root IS the new root **and the user typed it** — they deliberately sat at the
    ///   account folder, which is the very thing the old ceiling made awkward. `openAt` must be
    ///   written as `""`, or discovery seeds `Documents` and their panes silently move a level down
    ///   from where they left them. (The same intent spelled with a trailing slash took the first
    ///   branch and got this right, which is how the gap showed up.)
    /// - the legacy root is somewhere else entirely, which a hand-typed Location could always be.
    ///   There is no discovered root that contains it, so the path itself becomes the root and the
    ///   source lands at it. That keeps such an install working exactly as it did, at the cost of a
    ///   source with nothing above it — which is what it had before, too.
    static func plan(discovered: [CloudProvider], legacyOverrides: [String: String]) -> Plan {
        var plan = Plan()
        // Sorted, so two sources that collide on one legacy root resolve the same way on every run
        // rather than by dictionary iteration order.
        for provider in discovered.sorted(by: { $0.id < $1.id }) {
            // A folder source is its own root and always was. It has no discovered default for an
            // override to sit on, and `setPath` writes its path straight into the stored list, so
            // there is no legacy override to adopt and nothing to re-base.
            guard !provider.isLocalFolder else { continue }
            plan.handled.insert(provider.id)

            let newRoot = normalizedRoot(provider.rootPath)
            let legacyOverride = legacyOverrides[provider.id]
            // Normalized, not merely tilde-expanded: a hand-typed Location ending in `/` would
            // otherwise relativize to `Documents/`, and that trailing slash rides into the stored
            // `openAt`, out through `openAtIfReachable` into the pane's focus, and makes
            // `Documents/` and `Documents` two different tabs for one folder.
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
            // **No two sources can collide on one `rootRemap` key**, so this is an assignment and
            // not a merge. Reaching this line at all means `legacyRoot` relativized under THIS
            // source's account folder, and account folders are siblings — a path inside one is
            // outside every other, and iCloud's `~/Documents` contains none of them. A Location
            // aimed at another account's folder therefore takes the branch above (no containing
            // root, so it becomes a root override) rather than claiming that account's key.
            plan.rootRemap[legacyRoot] = newRoot
            // Only when it differs from what discovery would produce anyway: an install with no
            // Location override must not come out of this looking customized, or Reset would have
            // nothing to reset and the row would claim a choice the user never made.
            if prefix != provider.openAt {
                plan.openAtOverrides[provider.id] = prefix
            }
        }
        return plan
    }

    /// Runs the migration. Safe to call repeatedly: the stamp short-circuits the settled case, and
    /// `handledProviderIdsKey` makes even a pass that does run skip every source it has already
    /// moved — which is what keeps a prefix from being applied twice.
    @discardableResult
    public static func apply(
        defaults: UserDefaults,
        domainName: String? = nil,
        accounts: CloudStorageAccounts,
        discovered: [CloudProvider],
        legacyOverrides: [String: String]
    ) -> Outcome {
        guard stamp(in: defaults, domainName: domainName) < currentStamp else { return .alreadyDone }
        // An unreadable root means the account folders are unknown, and a plan is a statement about
        // which sources exist. Stamping now would make a wrong plan permanent; deferring costs one
        // more listing next launch. Same refusal `discoverProviders` makes for the same evidence.
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
        moved += rebaseFocus(defaults: defaults, plan: plan)
        moved += rebaseTabs(defaults: defaults, plan: plan, unreadable: &unreadable)
        moved += rebaseJumpFolders(defaults: defaults, plan: plan, unreadable: &unreadable)
        moved += rebaseFavoriteOrder(defaults: defaults, plan: plan)
        moved += rebaseDestinationRecents(defaults: defaults, plan: plan)
        moved += rebaseIgnoredItems(defaults: defaults, domainName: domainName, plan: plan)

        let handled = alreadyHandled.union(plan.handled)
        defaults.set(handled.sorted(), forKey: handledProviderIdsKey)

        // Outstanding is derived from what the STORED STATE mentions, not from the override list:
        // a source with no Location override still has tabs and a last-open folder measured from
        // its old root, so an unmounted Dropbox is just as much a reason to keep looking as an
        // unmounted account that was re-pointed.
        let outstanding = referencedProviderIds(defaults: defaults, legacyOverrides: legacyOverrides)
            .subtracting(handled)
        if outstanding.isEmpty {
            defaults.set(currentStamp, forKey: stampKey)
        }
        // Nothing new settled and nothing moved: this pass is only here because a source the stored
        // state names is still absent. Say nothing rather than repeating the same line every launch.
        guard !plan.handled.isEmpty || moved > 0 else { return .alreadyDone }
        return .migrated(prefixes: plan.prefixes, moved: moved,
                         outstanding: Array(outstanding), unreadable: unreadable)
    }

    // MARK: - The six stores

    /// The last-open folder of each pane. Not keyed by provider — the pane's provider is, so the
    /// prefix comes from whichever source that pane was on.
    private static func rebaseFocus(defaults: UserDefaults, plan: Plan) -> Int {
        var moved = 0
        for (focusKey, providerKey) in [(leftFocusKey, leftProviderKey), (rightFocusKey, rightProviderKey)] {
            guard let stored = defaults.string(forKey: focusKey), !stored.isEmpty,
                  let providerId = defaults.string(forKey: providerKey),
                  let prefix = plan.prefixes[providerId] else { continue }
            defaults.set(rebased(stored, under: prefix), forKey: focusKey)
            moved += 1
        }
        return moved
    }

    /// Both tab strips. Re-serialized through `JSONSerialization` rather than a `Codable` round
    /// trip **so unknown keys survive**: the maintenance lines write these same strips, and a
    /// decode-to-known-fields would quietly drop any field a newer or older build added.
    private static func rebaseTabs(defaults: UserDefaults, plan: Plan, unreadable: inout [String]) -> Int {
        var moved = 0
        for key in [leftTabsKey, rightTabsKey] {
            guard let raw = defaults.string(forKey: key) else { continue }
            guard let data = raw.data(using: .utf8),
                  var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                // Present and unreadable is not the same as absent, and it is the case that loses
                // data in silence: the strip stays measured from the old root and nothing says so.
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
    /// from it, so both halves move together.
    ///
    /// A root the plan does not name is carried across untouched — a folder source's pins, an
    /// account whose root did not move, or one already migrated by an earlier pass.
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
            // Sorted, so a merge onto a root that already exists produces the same order every run
            // — `FolderJumpStore.init` sorts its keys for exactly this reason.
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

    /// The Favorites drag order, whose entries are `root\0relativePath` — so a rewrite has to take
    /// both halves apart and put them back. An entry naming a root that did not move is kept as-is
    /// rather than dropped: this list is the *sequence*, and a hole in it reorders the section.
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

    /// Filing destinations. The values are absolute and stay exactly as they are — only the key
    /// they are filed under moves, which is why this one cannot be skipped even though nothing
    /// inside it is wrong.
    ///
    /// Trimmed to `DestinationRecents.limit` on the way out: a merge onto a key that already exists
    /// can otherwise leave more entries than the store's own writer would ever produce, and
    /// `DestinationRecents.load` does not trim on read.
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
    /// **The left source's prefix, for every entry.** `FileSyncManager.rootRelativePath` documents
    /// the left pane's focus as the coordinate system the identity is written in, and the pair key
    /// sorts its two ids rather than recording which was left — so "left" cannot be recovered from
    /// the key. Both sides are tried and the FIRST that yields a prefix wins, in sorted-id order,
    /// which is the same order the key itself is built in: for the overwhelmingly common pair
    /// (two sources whose roots both widened by `Documents`) the two answers are identical, and
    /// for a mixed pair it picks the one the key names first, deterministically.
    ///
    /// A pair with no prefix on either side — iCloud⇄a folder source, neither of which moved — is
    /// left alone, which is correct rather than merely safe: its entries were never mismeasured.
    private static func rebaseIgnoredItems(defaults: UserDefaults, domainName: String?, plan: Plan) -> Int {
        let keys = SettingsManager.keys(in: defaults, domainName: domainName,
                                        havingPrefix: ignoredItemsKeyPrefix)
        var moved = 0
        for key in keys.sorted() {
            let ids = key.dropFirst(ignoredItemsKeyPrefix.count).components(separatedBy: "|")
            guard let prefix = ids.compactMap({ plan.prefixes[$0] }).first, !prefix.isEmpty,
                  let stored = defaults.stringArray(forKey: key), !stored.isEmpty else { continue }
            defaults.set(stored.map { rebased($0, under: prefix) }, forKey: key)
            moved += stored.count
        }
        return moved
    }

    // MARK: - Helpers

    /// The prefix belonging to whichever provider owned this root, found by the root the plan
    /// remapped rather than by id — the two root-keyed stores hold no provider ids at all.
    private static func prefix(forRoot root: String, plan: Plan) -> String? {
        guard let newRoot = plan.rootRemap[root] else { return nil }
        // `relativize` rather than a lookup by id: it re-derives the prefix from the very pair the
        // remap is made of. Both sides of that pair are `normalizedRoot`ed and so is the value in
        // `prefixes`, which is what makes the two answers the same string rather than merely two
        // spellings that happen to canonicalize alike downstream.
        return PathBoundary.relativize(root, under: newRoot)
    }

    /// A stored relative path with `prefix` in front of it, canonicalized through `PaneBrowsePath`.
    ///
    /// The canonicalization is the guard, not decoration. `PathBoundary.join` returns the bare root
    /// for anything starting with `/`, so a rebased path that picked up a leading or doubled
    /// separator would not fail loudly — every affected pane and tab would simply open at the top
    /// of the account, which reads as data loss rather than as a bug. `PaneBrowsePath` splits on
    /// `/` and rejoins, so no such spelling can survive this function.
    static func rebased(_ relative: String, under prefix: String) -> String {
        PaneBrowsePath(relativePath: PathBoundary.joinRelative(prefix, relative)).relativePath
    }

    /// The spelling the root-keyed stores file under: tilde-expanded, trailing slashes trimmed.
    ///
    /// `FolderJumpStore.key(forRoot:)` is this exact rule and delegates to the same helper.
    /// `DestinationRecents` uses `PaneBrowsePath.normalized`, which trims but does NOT expand a
    /// tilde — a difference that cannot bite here, because every root this migration remaps is a
    /// discovered CloudStorage account path, which is absolute and has no tilde to expand. (A
    /// hand-typed `~/…` Location reaches `rootOverrides`, which is not a remap and not a key.)
    private static func normalizedRoot(_ root: String) -> String {
        PathBoundary.normalizedRoot(root)
    }

    /// Every provider id the stored state actually mentions, which is the set that has to be
    /// settled before the fast-exit stamp may be written.
    ///
    /// The two root-keyed stores are deliberately not consulted: they hold roots, not ids, and a
    /// root cannot be attributed to a source that is not mounted. They are covered by the sources
    /// the tab strips and the pane selections name, which is where an unmounted account shows up.
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
        return ids
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

    /// Gathers the inputs off disk and runs the migration — the app's one entry point, and the
    /// CLI's.
    ///
    /// **Synchronous, and it does its own CloudStorage listing rather than waiting for
    /// `SettingsManager`'s.** Discovery is `async` and publishes from a detached task, while this
    /// has to finish before anything reads a stored position: the launch focus restore and both tab
    /// strips are read in the bootstrap task, and `@AppStorage` values bind even earlier. One
    /// directory listing at launch, and only until the stamp is set, buys an ordering that does not
    /// depend on which task wins.
    ///
    /// Every read of the app's own keys — the legacy overrides, the stamp, the handled set — goes
    /// through `SettingsManager`'s domain scoping rather than the merged search list, which is what
    /// keeps a stray NSGlobalDomain key from either masquerading as this install's Location or
    /// suppressing the migration outright.
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
        // Mapped with the DISCOVERED defaults and no `openAt` override: `landingPath` then names
        // exactly the folder this source pointed at before the split, which is what a legacy
        // position was measured from. Folder sources are left out of the mapping entirely — they
        // are their own roots and this migration has nothing to say about them.
        let discovered = SettingsManager.mapProviders(
            cloudStorageFolders: accounts.folders,
            iCloudDefaultPath: SettingsManager.iCloudDefaultPath
        )
        return apply(defaults: defaults, domainName: domainName, accounts: accounts,
                     discovered: discovered, legacyOverrides: legacyOverrides)
    }
}
