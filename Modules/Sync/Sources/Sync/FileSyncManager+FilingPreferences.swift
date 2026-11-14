import Events
import Foundation

/// Whether a statement naming several accounts is copied into each or filed once (decision 11), at
/// a scope: one account, one bank, every statement, everything. The narrowest that applies wins,
/// so "copy for ••4657" beats "file once for Fidelity".
public struct FilingPreference: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: Codable, Equatable, Hashable, Sendable {
        case account(institution: String, ending: String)
        case institution(String)
        case statements
        case all

        /// Narrower first.
        var rank: Int {
            switch self {
            case .account: return 0
            case .institution: return 1
            case .statements: return 2
            case .all: return 3
            }
        }
    }

    public var id: UUID
    public var scope: Scope
    /// true: copy into every account the statement names. false: file once, into the first.
    public var copies: Bool
    /// What the scope names, for Automations: "Fidelity ••4657", "Fidelity", "statements".
    public var label: String
    public var createdAt: Date

    public init(id: UUID = UUID(), scope: Scope, copies: Bool, label: String, createdAt: Date = Date()) {
        self.id = id; self.scope = scope; self.copies = copies; self.label = label; self.createdAt = createdAt
    }

    /// Whether a statement is copied into `account` (a copy target), by the narrowest preference
    /// that applies; true with none.
    public static func copies(into account: FilingAccount, kind: DocumentFacts.Kind,
                              preferences: [FilingPreference]) -> Bool {
        let applying = preferences.filter { p in
            switch p.scope {
            case .account(let institution, let ending): return institution == account.institution && ending == account.ending
            case .institution(let institution): return institution == account.institution
            case .statements: return kind == .statement
            case .all: return true
            }
        }
        return applying.min { ($0.scope.rank, $1.createdAt) < ($1.scope.rank, $0.createdAt) }?.copies ?? true
    }
}

extension FileSyncManager {

    public nonisolated static let filingPreferencesDefaultsKey = "filingPreferences"

    public var filingPreferences: [FilingPreference] {
        get {
            FileSyncManager.decodePersistedStore([FilingPreference].self, from: filingRuleDefaults,
                                                 key: Self.filingPreferencesDefaultsKey,
                                                 describing: "filing preferences") ?? []
        }
        set {
            objectWillChange.send()
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.filingPreferencesDefaultsKey,
                                                describing: "filing preferences")
        }
    }

    /// Records a preference, replacing one at the same scope.
    public func setFilingPreference(_ preference: FilingPreference) {
        var all = filingPreferences.filter { $0.scope != preference.scope }
        all.append(preference)
        filingPreferences = all
        Logger.shared.info("Filing: \(preference.copies ? "copy" : "file once") for \(preference.label)")
    }

    public func removeFilingPreference(id: UUID) {
        filingPreferences.removeAll { $0.id == id }
    }
}
