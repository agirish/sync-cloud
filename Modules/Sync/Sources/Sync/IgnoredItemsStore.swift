import Foundation
import Events

/// Persists the paths the user ignored from the Differences list (and pane context menus) across
/// rescans, navigation and relaunches. `FileSyncManager.ignoredPaths` is the session layer
/// (focus-relative, cleared on navigation); this store holds the durable set, pane-root-relative,
/// keyed per provider pair so one comparison's ignores never bleed into another.
///
/// The pair key is unordered, so a pane swap keeps the same set. **Entries are relative to the
/// source whose id sorts first**, not to whichever is on the left: the same item can be `Family/x`
/// from one source's root and `Documents/Family/x` from another's. Callers enforce this
/// (`FileSyncManager.ignoreAnchorIsLeft`, `RootsMigration.rebaseIgnoredItems`).
@MainActor
public final class IgnoredItemsStore: ObservableObject {
    /// Root-relative paths ignored for the currently active provider pair. Published so the
    /// Settings list and the manager's filter pass both react to edits.
    @Published public private(set) var rootRelativePaths: Set<String> = []

    private let userDefaults: UserDefaults
    /// The pair whose ignores `rootRelativePaths` holds. Public so a control that asks before
    /// clearing can tell whether the pair changed while it asked.
    public private(set) var activeKey: String?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Defaults key for one provider pair, order-independent.
    public nonisolated static func pairKey(_ providerIdA: String, _ providerIdB: String) -> String {
        "ignoredItems_v1_" + [providerIdA, providerIdB].sorted().joined(separator: "|")
    }

    /// Loads the persisted set for the given pair key; a no-op when the key is already active, so
    /// provider-id onChange churn during launch or swap never clobbers unsaved edits.
    public func activate(pairKey: String) {
        guard pairKey != activeKey else { return }
        activeKey = pairKey
        let stored = Set(userDefaults.stringArray(forKey: pairKey) ?? [])
        if rootRelativePaths != stored {
            rootRelativePaths = stored
        }
    }

    public func add(_ paths: Set<String>) {
        guard !paths.isEmpty, !paths.subtracting(rootRelativePaths).isEmpty else { return }
        rootRelativePaths.formUnion(paths)
        save()
    }

    public func remove(_ paths: Set<String>) {
        guard !paths.isEmpty, !paths.intersection(rootRelativePaths).isEmpty else { return }
        rootRelativePaths.subtract(paths)
        save()
    }

    public func removeAll() {
        guard !rootRelativePaths.isEmpty else { return }
        rootRelativePaths = []
        save()
    }

    /// Stable ordering for the Settings list.
    public var sortedPaths: [String] {
        rootRelativePaths.sorted()
    }

    private func save() {
        guard let activeKey else {
            // No pair is active yet, so there is nowhere to write, though the UI already shows the
            // edit: an ignore made before `activate()` would look saved and vanish on relaunch.
            // Logged so that is explainable. No count: `rootRelativePaths` is the whole
            // post-mutation set, not this edit.
            Logger.shared.error("Ignored items: this change was not persisted — no provider pair is active yet, so it is session-only and will be gone on relaunch")
            return
        }
        if rootRelativePaths.isEmpty {
            userDefaults.removeObject(forKey: activeKey)
        } else {
            userDefaults.set(rootRelativePaths.sorted(), forKey: activeKey)
        }
    }
}
