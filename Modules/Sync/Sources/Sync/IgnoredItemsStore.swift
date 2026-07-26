import Foundation
import Events

/// Persists the paths the user ignored from the Differences list (and pane context menus)
/// so they survive rescans, navigation, and app relaunches. `FileSyncManager.ignoredPaths`
/// remains the session layer (focus-relative, cleared on navigation); this store holds the
/// durable set in *pane-root-relative* coordinates, keyed per provider pair so ignores for
/// one comparison never bleed into another.
///
/// The pair key is unordered: in the dominant workflow both panes navigate together, so an
/// item's root-relative path reads the same from either side, and a pane swap keeps the same
/// stored set.
@MainActor
public final class IgnoredItemsStore: ObservableObject {
    /// Root-relative paths ignored for the currently active provider pair. Published so the
    /// Settings list and the manager's filter pass both react to edits.
    @Published public private(set) var rootRelativePaths: Set<String> = []

    private let userDefaults: UserDefaults
    private(set) var activeKey: String?

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Defaults key for one provider pair, order-independent.
    public nonisolated static func pairKey(_ providerIdA: String, _ providerIdB: String) -> String {
        "ignoredItems_v1_" + [providerIdA, providerIdB].sorted().joined(separator: "|")
    }

    /// Loads the persisted set for the given pair key; no-op when the key is already active
    /// (so provider-id onChange churn during launch/swap never clobbers unsaved edits).
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
            // No pair is active yet, so there is nowhere to write. The edit already landed in the
            // published set, which is what the UI shows — so an ignore added before `activate()`
            // (a context-menu Ignore during launch, before the provider-id onChange has fired)
            // looked durable and silently vanished on relaunch. Nothing else reports this: the
            // caller gets no return value and no error, and the visible state is indistinguishable
            // from a successful save. Say so in the log so the disappearance is explainable.
            Logger.shared.warning("Ignored items: \(rootRelativePaths.count) ignore(s) were not persisted — no provider pair is active yet, so this edit is session-only")
            return
        }
        if rootRelativePaths.isEmpty {
            userDefaults.removeObject(forKey: activeKey)
        } else {
            userDefaults.set(rootRelativePaths.sorted(), forKey: activeKey)
        }
    }
}
