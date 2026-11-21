import Foundation

/// What a read of the documents looks at.
///
/// Reading does two jobs. Keeping the IDs the Vault has up to date needs only the documents they
/// came from (Refresh); finding IDs it does not have yet needs the folders (Discover More).
public enum VaultReadScope: Equatable, Sendable {
    /// Discover More: new and changed files under the read folders.
    case discover
    /// Read Everything Again: every file the read plan picks, as if for the first time.
    case everything
    /// Refresh: only documents an ID was already read from. It opens no other file, so it is
    /// quick and safe to run unasked. With an id, that ID's documents alone, read whether or not
    /// they changed.
    case refresh(only: UUID? = nil)

    public var isRefresh: Bool {
        if case .refresh = self { return true }
        return false
    }
}

/// One thing a refresh changed about an ID: a date or a detail its document now reads
/// differently, or reads for the first time.
public struct VaultChange: Equatable, Sendable {
    public var label: String
    /// What it read before; nil when the detail is new.
    public var was: VaultDetail.Value?
    public var now: VaultDetail.Value

    public init(label: String, was: VaultDetail.Value?, now: VaultDetail.Value) {
        self.label = label
        self.was = was
        self.now = now
    }
}

public enum VaultRefresh {
    /// Whether Refresh runs by itself as the Vault opens (Settings ▸ Vault). On unless turned off.
    public static let automaticKey = "vaultRefreshesByItself"

    public static func isAutomatic(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticKey) as? Bool ?? true
    }

    /// What differs between an ID's details before a refresh and after: each detail that reads
    /// differently now, and each read for the first time. A detail no longer read is not listed:
    /// the row simply stops showing it, and nothing was changed to something else.
    public static func changes(from old: VaultReadFacts?, to new: VaultReadFacts?) -> [VaultChange] {
        guard let new else { return [] }
        let before = Dictionary((old?.details ?? []).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        return new.details.compactMap { detail in
            guard before[detail.label] != detail.value else { return nil }
            // With nothing read before, there is nothing it changed from: a first read is not news.
            guard old != nil else { return nil }
            return VaultChange(label: detail.label, was: before[detail.label], now: detail.value)
        }
    }
}

extension VaultDetail.Value {
    /// How a change's side is drawn: a date spelled out, a number with only its ending unless shown.
    public func drawn(shown: Bool) -> String {
        VaultDetail("", self).drawn(shown: shown)
    }
}
