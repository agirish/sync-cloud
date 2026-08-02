import Foundation
import Events

/// The names the user has said they *meant* — cloud-hostile, deliberately, and not to be reported
/// again.
///
/// **Why this has to be durable, and why it did not exist before.** Organize's list can already
/// dismiss a row (``FileSyncManager/dismissRiskyName(_:)``), but that dismissal lasts as long as the
/// results do: the next scan re-finds the name and you skip it again. That was survivable while the
/// only way to meet a risky name was to go looking for one. The row badge changes the arithmetic —
/// it is rendered every time the file is on screen, forever — so without somewhere to record "I
/// meant that name", a name you deliberately chose becomes a permanent amber mark you cannot answer.
///
/// **Keyed on the NAME, not the path.** The offence is entirely a property of the name: two files
/// called `Q3: final.pdf` are risky for exactly the same reason, and moving one of them changes
/// nothing about why it was flagged. Keying on the path would re-nag the moment the file moved or
/// was copied — re-asking a question the user already answered, which is the specific failure this
/// type exists to prevent. The cost of the choice is that keeping one `Q3: final.pdf` also keeps a
/// different file with the identical name; that is the same decision about the same string, so it is
/// the answer the user gave.
///
/// **Not scoped per provider, deliberately.** The *verdict* is per (name, provider) — a name iCloud
/// accepts and OneDrive rejects is risky only on OneDrive — but the *decision* is not. The app's
/// dominant workflow is two panes over two providers showing the same folder, so a per-provider keep
/// would silence the badge on one side and leave it standing on the other, for the same file, on
/// screen at the same time. That is the nagging, wearing a scope.
///
/// **What keeping does NOT do.** It suppresses the badge and drops the row from Organize's list; it
/// does not touch the file, and it is reversible from the same row menu that set it ("Stop Allowing
/// This Name"). It is a statement about the name, not a repair of it.
@MainActor
public final class KeptNamesStore: ObservableObject {
    /// The kept names, exactly as they are on disk. Published so a badge and a lens both re-render
    /// the instant one is added or withdrawn.
    @Published public private(set) var names: Set<String> = []

    private let userDefaults: UserDefaults

    /// Versioned so a future change of key shape (should keeping ever become provider-scoped) can
    /// tell an old set from a new one instead of silently reinterpreting it.
    static let defaultsKey = "keptRiskyNames_v1"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        names = Set(userDefaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Whether `name` has been deliberately kept.
    ///
    /// Compares with Swift's canonical `==` (through `Set<String>`), the same equality
    /// ``NameNormalizer/evaluate(name:relativePath:absolutePath:isDirectory:provider:)`` gates on —
    /// so a name stored NFC and met NFD is the same kept name, which is what APFS re-normalizing on
    /// write makes it anyway.
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
