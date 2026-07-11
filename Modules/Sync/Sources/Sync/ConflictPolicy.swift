import Foundation

/// The user's standing answer to the file-collision prompt (Settings → Sync → Conflicts).
/// `.ask` — the default — preserves the historical always-prompt behavior; the other cases
/// resolve FILE collisions without a prompt. Folder collisions always prompt regardless:
/// replacing a folder trashes its entire contents (including items that exist only in the
/// destination), which is never a decision to automate away.
///
/// Lives in Sync because it answers with Sync's `CollisionResolution`; the app's alert layer
/// consults `autoResolution(isDirectory:)` before showing its prompt.
public enum ConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask
    case keepBoth
    case replace
    case skip

    public var id: String { rawValue }

    /// Defaults key holding the persisted policy (a raw value). Settings writes it; the
    /// app's collision-prompt closures re-read it per collision so changes apply immediately.
    public static let defaultsKey = "conflictDefaultPolicy"

    /// The persisted policy, falling back to `.ask` when unset or unrecognized.
    public static func persisted(from defaults: UserDefaults = .standard) -> ConflictPolicy {
        defaults.string(forKey: defaultsKey).flatMap(ConflictPolicy.init(rawValue:)) ?? .ask
    }

    /// The resolution to apply WITHOUT prompting, or nil when the prompt must run
    /// (policy is `.ask`, or the colliding destination item is a directory).
    public func autoResolution(isDirectory: Bool) -> CollisionResolution? {
        guard !isDirectory else { return nil }
        switch self {
        case .ask: return nil
        case .keepBoth: return .keepBoth
        case .replace: return .replace
        case .skip: return .skip
        }
    }

    public var displayName: String {
        switch self {
        case .ask: return "Ask every time"
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        case .skip: return "Skip"
        }
    }
}
