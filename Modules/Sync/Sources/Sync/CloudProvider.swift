import Foundation

public struct CloudProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let imageName: String
    public var path: String
    public let type: ProviderType

    public init(id: String, displayName: String, imageName: String, path: String, type: ProviderType) {
        self.id = id
        self.displayName = displayName
        self.imageName = imageName
        self.path = path
        self.type = type
    }

    public enum ProviderType: String, Sendable {
        case iCloud = "iCloud"
        case oneDrive = "OneDrive"
        case dropBox = "Dropbox"
        case googleDrive = "Google Drive"
    }

    /// The provider type governing a bare filesystem path, inferred from the discovered providers
    /// whose roots contain it — nil when no provider claims it.
    ///
    /// The CLI accepts a `-L`/`-R` value as either a provider id or a plain path, and a path
    /// carries no provider identity of its own. But the destination guards that matter most are
    /// type-gated: `ProviderNameRules.violation(inRelativePath:for:)` refuses to write names the
    /// target provider cannot store, and the Google Drive date-noise filter keys off
    /// `.googleDrive`. Typing every path-addressed root as one fixed provider silently disables
    /// both for exactly the folders that need them — the same OneDrive folder would skip `CON.txt`
    /// when addressed by id and copy it when addressed by path.
    ///
    /// A provider claims the path when the path is its root or inside it, or inside the
    /// CloudStorage account folder its root sits under: `~/Library/CloudStorage/OneDrive-X/Photos`
    /// belongs to the same OneDrive account as the discovered `.../OneDrive-X/Documents` root even
    /// though it is a sibling of it, not a descendant. The longest matching root wins, so a
    /// provider nested inside another resolves to the more specific one.
    ///
    /// Matching folds case: on the default case-insensitive macOS volume the two spellings name
    /// one folder, and claiming is the safe direction — a wrong claim costs a skipped file the
    /// user is told about, a missed one costs an unsyncable file they are not.
    public static func inferredType(forPath path: String, among providers: [CloudProvider]) -> ProviderType? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        var best: (rootLength: Int, type: ProviderType)?
        for provider in providers {
            for root in claimRoots(of: provider) {
                let base = URL(fileURLWithPath: root).standardizedFileURL.path.lowercased()
                guard PathBoundary.contains(target, under: base) else { continue }
                if base.count > (best?.rootLength ?? -1) {
                    best = (base.count, provider.type)
                }
            }
        }
        return best?.type
    }

    /// The roots a provider claims: its own (possibly user-overridden) root, plus the CloudStorage
    /// account folder that root sits under, when it has one. A provider whose path was overridden
    /// to somewhere outside CloudStorage contributes only its own root, which is the whole of what
    /// is known about it.
    private static func claimRoots(of provider: CloudProvider) -> [String] {
        let components = URL(fileURLWithPath: provider.path).standardizedFileURL.pathComponents
        // A provider's Location is user-settable to ANY folder, and a claim is not a harmless label:
        // it decides whether a path-addressed CLI root inherits that provider's name rules, which
        // decides whether files are silently skipped. Someone who points a provider at their home
        // folder must not thereby give every local folder OneDrive's reserved-name rules — so a root
        // that is too shallow to be a real provider folder claims nothing beyond itself. Three
        // components is `/Users/<me>`; a genuine provider root is always deeper.
        guard components.count > 3 else { return [] }
        var roots = [provider.path]
        // Widen to the CloudStorage ACCOUNT folder, so a sibling of the discovered root
        // (`.../OneDrive-X/Photos` next to `.../OneDrive-X/Documents`) resolves to the same account.
        // Anchored on `Library/CloudStorage` specifically, and on the LAST such pair: matching a
        // bare "CloudStorage" component anywhere claimed unrelated trees for anyone who happens to
        // keep a folder by that name.
        for index in components.indices.dropLast().reversed()
        where components[index] == "Library" && components[index + 1] == "CloudStorage" {
            let accountIndex = index + 2
            guard accountIndex < components.count else { break }
            roots.append(NSString.path(withComponents: Array(components[0...accountIndex])))
            break
        }
        return roots
    }
}
