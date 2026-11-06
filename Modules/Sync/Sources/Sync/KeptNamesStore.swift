import Foundation
import Events

/// The names the user has said they meant, cloud-hostile on purpose, and not to be reported again.
/// Durable because the row badge shows every time the file is on screen; Organize's per-scan
/// dismissal (``FileSyncManager/dismissRiskyName(_:)``) would leave a mark the user can't answer.
///
/// Keyed on the name, not the path: the risk is a property of the name, so moving or copying the
/// file must not ask again. Keeping one `Q3: final.pdf` keeps every file with that name.
///
/// Not scoped per provider. The verdict is per provider, but two panes often show the same folder
/// on two providers, and a per-provider keep would leave the badge on one side only.
///
/// Keeping hides the badge and the Organize row; it never touches the file, and "Stop Allowing
/// This Name" on the same row menu reverses it.
@MainActor
public final class KeptNamesStore: ObservableObject {
    /// The kept names, exactly as on disk. Published so badges and lenses re-render on each change.
    @Published public private(set) var names: Set<String> = []

    private let userDefaults: UserDefaults

    /// Versioned so a future key shape (say, per provider) can tell an old set from a new one.
    nonisolated static let defaultsKey = "keptRiskyNames_v1"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        names = Set(userDefaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Whether `name` has been deliberately kept. Uses Swift's canonical `==`, as
    /// ``NameNormalizer/evaluate(name:relativePath:absolutePath:isDirectory:provider:)`` does, so NFC
    /// and NFD spellings are the same kept name, as they are to APFS.
    public func isKept(_ name: String) -> Bool { names.contains(name) }

    public func keep(_ name: String) {
        guard !name.isEmpty, !names.contains(name) else { return }
        names.insert(name)
        save()
        Logger.shared.info("Kept risky name “\(name)” — it will no longer be reported")
    }

    public func stopKeeping(_ name: String) {
        guard names.contains(name) else { return }
        names.remove(name)
        save()
        Logger.shared.info("Stopped keeping risky name “\(name)” — it will be reported again")
    }

    /// Withdraws every keep at once, for Settings' "Clear All". One mutation, not a loop over
    /// `stopKeeping`: each publish makes ``FileSyncManager/keptNamesStore`` re-filter `riskyNames`,
    /// so a loop would re-filter and log once per name.
    public func stopKeepingAll() {
        guard !names.isEmpty else { return }
        let count = names.count
        names.removeAll()
        save()
        Logger.shared.info("Stopped keeping all \(count) risky \(count == 1 ? "name" : "names") — they will be reported again")
    }

    /// Stable ordering for any list that presents them.
    public var sortedNames: [String] { names.sorted() }

    private func save() {
        if names.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else {
            userDefaults.set(names.sorted(), forKey: Self.defaultsKey)
        }
    }
}
