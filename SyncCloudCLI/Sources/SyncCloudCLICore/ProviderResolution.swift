import Foundation
import Sync

/// A `-L`/`-R` value that is neither a known provider nor an existing path.
public struct ProviderResolutionError: Error, Equatable, Sendable {
    public let message: String
}

/// Expands a leading tilde in a user-supplied path.
public func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Resolves a `-L`/`-R` argument to a provider: first by id or display name among the
/// discovered providers, else as a filesystem path (tilde-expanded) wrapped in an ad-hoc
/// provider. Throws `ProviderResolutionError` when neither matches.
public func resolveProviderOrPath(
    value: String,
    label: String,
    providers: [CloudProvider],
    fileManager: FileManaging = FileManager.default
) throws -> CloudProvider {
    if let provider = providers.first(where: { $0.id == value || $0.displayName == value }) {
        return provider
    }
    let expanded = expandPath(value)
    guard fileManager.fileExists(atPath: expanded) else {
        throw ProviderResolutionError(message: "Path or provider '\(value)' for \(label) could not be found.")
    }
    return CloudProvider(
        id: expanded,
        displayName: label,
        imageName: "folder",
        path: expanded,
        type: .iCloud
    )
}
