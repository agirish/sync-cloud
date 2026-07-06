import Events
import Foundation
import SwiftUI
import Sync

/// Manages the discovery and customization of Cloud Providers available to the application.
/// Interfaces with `UserDefaults` to persist custom path overwrites per provider.
@MainActor
public class SettingsManager: ObservableObject {
    /// Lists the account folders mounted under the CloudStorage root (one URL per provider account).
    public typealias CloudStorageLister = @Sendable () -> [URL]

    /// Reports whether a provider's root path currently exists as a directory.
    public typealias PathValidator = @Sendable (String) -> Bool

    /// A sorted array of natively detected and custom-configured providers (e.g., iCloud, OneDrive).
    @Published public var availableProviders: [CloudProvider] = []

    /// Whether each provider's root path exists as a directory, keyed by provider id.
    /// Recomputed on every `discoverProviders()` pass — including ones that change no
    /// provider — so the validity badge re-checks the disk on the user's explicit refresh
    /// gesture and after path edits, without views stat-ing the filesystem per render.
    @Published public private(set) var pathValidity: [String: Bool] = [:]

    private let userDefaults: UserDefaults
    private let listCloudStorageFolders: CloudStorageLister
    private let validatePath: PathValidator
    private static let overrideKeyPrefix = "path_override_"
    private static let ignoreGoogleDriveNewerDateOnlyKey = "ignoreGoogleDriveNewerDateOnly"

    /// The UserDefaults domain the app persists settings to — its bundle identifier, which is what
    /// `.standard` resolves to inside the bundled app. Un-bundled processes (the `synccloud` CLI)
    /// must pass `UserDefaults(suiteName: SettingsManager.appSuiteName)` explicitly: their own
    /// `.standard` resolves to a per-process-name domain that never sees the app's path overrides.
    public static let appSuiteName = "com.abhishekgirish.SyncCloud"

    static var iCloudDefaultPath: String {
        (NSString(string: "~/Documents")).expandingTildeInPath
    }

    /// When true, the Differences pane hides "right is newer" items when right is Google Drive and sizes match (avoids noise from Drive overwriting file dates).
    @Published public var ignoreGoogleDriveNewerDateOnly: Bool {
        didSet {
            userDefaults.set(ignoreGoogleDriveNewerDateOnly, forKey: Self.ignoreGoogleDriveNewerDateOnlyKey)
        }
    }

    /// - Parameters:
    ///   - autoDiscover: When true (the app's case), kicks off provider discovery in the
    ///     background so the UI populates on launch. Callers that discover explicitly (e.g. the CLI,
    ///     which `await`s `discoverProviders()`) should pass false to avoid a redundant scan.
    ///   - userDefaults: Backing store for path overrides and flags. Tests inject a
    ///     `UserDefaults(suiteName:)` instance to stay isolated from the user's real settings.
    ///   - cloudStorageLister: Source of the mounted provider account folders. Defaults to
    ///     enumerating the real `~/Library/CloudStorage`; tests inject a canned list.
    ///   - pathValidator: Directory-existence check backing `pathValidity`. Defaults to
    ///     stat-ing the real filesystem; tests inject a canned predicate.
    public init(
        autoDiscover: Bool = true,
        userDefaults: UserDefaults = .standard,
        cloudStorageLister: CloudStorageLister? = nil,
        pathValidator: PathValidator? = nil
    ) {
        self.userDefaults = userDefaults
        self.listCloudStorageFolders = cloudStorageLister ?? Self.defaultCloudStorageLister
        self.validatePath = pathValidator ?? Self.defaultPathValidator
        self.ignoreGoogleDriveNewerDateOnly = userDefaults.bool(forKey: Self.ignoreGoogleDriveNewerDateOnlyKey)
        // Initialize with default iCloud provider to allow app to start immediately
        self.availableProviders = [
            CloudProvider(
                id: "iCloud",
                displayName: "iCloud",
                imageName: "icloud",
                path: Self.iCloudDefaultPath,
                type: .iCloud
            )
        ]
        self.pathValidity = Self.validity(of: self.availableProviders, using: self.validatePath)

        if autoDiscover {
            Task {
                await discoverProviders()
            }
        }
    }

    /// Stats the real filesystem: true when the (tilde-expanded) path is an existing directory.
    private static let defaultPathValidator: PathValidator = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Enumerates the local filesystem's CloudStorage mounting point.
    private static let defaultCloudStorageLister: CloudStorageLister = {
        let cloudStoragePath = (NSString(string: "~/Library/CloudStorage")).expandingTildeInPath
        let cloudStorageURL = URL(fileURLWithPath: cloudStoragePath)
        var folders: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: cloudStorageURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                folders.append(fileURL)
            }
        }
        return folders
    }

    /// Maps the mounted CloudStorage account folders to the providers they represent — the pure
    /// core of discovery: prefix parsing, account-suffix extraction, default document paths,
    /// type-order sorting, and user path-override application.
    ///
    /// - Parameters:
    ///   - cloudStorageFolders: Account folder URLs found under the CloudStorage root.
    ///   - iCloudDefaultPath: Path used for the always-present iCloud provider absent an override.
    ///   - pathOverride: Returns the user's custom path for a provider id, or nil for the default.
    /// - Returns: The providers sorted iCloud → OneDrive → Google Drive → Dropbox, then by
    ///   display name within each type; unrecognized folders are ignored.
    nonisolated static func mapProviders(
        cloudStorageFolders: [URL],
        iCloudDefaultPath: String,
        pathOverride: (String) -> String?
    ) -> [CloudProvider] {
        var found: [CloudProvider] = []

        // 1. iCloud is always available
        found.append(CloudProvider(
            id: "iCloud",
            displayName: "iCloud",
            imageName: "icloud",
            path: iCloudDefaultPath,
            type: .iCloud
        ))

        // 2. Map the local Cloud Storage folders
        for fileURL in cloudStorageFolders {
            let folderName = fileURL.lastPathComponent

            if folderName.hasPrefix("OneDrive-") {
                let suffix = folderName.dropFirst("OneDrive-".count)
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: "OneDrive (\(suffix))",
                    imageName: "onedrive",
                    path: fileURL.appendingPathComponent("Documents").path,
                    type: .oneDrive
                ))
            } else if folderName.hasPrefix("GoogleDrive-") {
                let suffix = folderName.dropFirst("GoogleDrive-".count)
                let id = folderName
                let defaultPath = fileURL.appendingPathComponent("My Drive").appendingPathComponent("Documents").path
                found.append(CloudProvider(
                    id: id,
                    displayName: "Google Drive (\(suffix))",
                    imageName: "googledrive",
                    path: defaultPath,
                    type: .googleDrive
                ))
            } else if folderName == "Dropbox" {
                let id = folderName
                found.append(CloudProvider(
                    id: id,
                    displayName: "Dropbox",
                    imageName: "dropbox",
                    path: fileURL.appendingPathComponent("Documents").path,
                    type: .dropBox
                ))
            }
        }

        // Sort so related providers are together: iCloud, then OneDrive, then Google Drive, then Dropbox; within each group by displayName.
        let typeOrder: [CloudProvider.ProviderType] = [.iCloud, .oneDrive, .googleDrive, .dropBox]
        var sorted = found.sorted { a, b in
            let aIndex = typeOrder.firstIndex(of: a.type) ?? typeOrder.count
            let bIndex = typeOrder.firstIndex(of: b.type) ?? typeOrder.count
            if aIndex != bIndex { return aIndex < bIndex }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }

        // Apply user path overrides
        for i in 0..<sorted.count {
            if let override = pathOverride(sorted[i].id) {
                sorted[i].path = override
            }
        }

        return sorted
    }

    /// Scans the local filesystem's CloudStorage mounting point to detect configured provider accounts.
    /// Re-evaluates custom user overwrites and updates the `availableProviders` sequence.
    /// Always recomputes `pathValidity`, even when discovery changes no provider: a refresh
    /// often leaves a provider's identity and path unchanged while its folder on disk was
    /// created or deleted externally.
    public func discoverProviders() async {
        Logger.shared.debug("Discovering cloud providers...")

        let lister = listCloudStorageFolders
        let folders = await Task.detached(priority: .userInitiated) { lister() }.value

        self.availableProviders = Self.mapProviders(
            cloudStorageFolders: folders,
            iCloudDefaultPath: Self.iCloudDefaultPath,
            pathOverride: { userDefaults.string(forKey: "\(Self.overrideKeyPrefix)\($0)") }
        )
        pathValidity = Self.validity(of: availableProviders, using: validatePath)
    }

    /// Whether the provider's root path existed as a directory at the last validity check
    /// (init, or any discovery pass). Unknown provider ids are invalid.
    public func isPathValid(for providerId: String) -> Bool {
        pathValidity[providerId] ?? false
    }

    private nonisolated static func validity(
        of providers: [CloudProvider],
        using validate: PathValidator
    ) -> [String: Bool] {
        Dictionary(providers.map { ($0.id, validate($0.path)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Returns the active root path (either default or user-overridden) for a specific provider.
    /// - Parameter providerId: The unique identifier.
    /// - Returns: The absolute directory path as a string.
    public func path(for providerId: String) -> String {
        return availableProviders.first(where: { $0.id == providerId })?.path ?? ""
    }

    /// Persists a custom absolute path mapping for a specific provider ID, dropping the system default.
    /// - Parameters:
    ///   - path: The new folder target path.
    ///   - providerId: The targeted provider ID.
    public func setPath(_ path: String, for providerId: String) {
        if path.isEmpty {
            Logger.shared.info("User cleared custom path mapping for provider: \(providerId)")
            userDefaults.removeObject(forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        } else {
            Logger.shared.info("User mapped custom path \(path) for provider: \(providerId)")
            userDefaults.set(path, forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        }
        Task {
            await discoverProviders()
        }
    }

    /// Clears any user-defined override from UserDefaults and restores the System-discovered path.
    /// - Parameter providerId: The targeted provider ID.
    public func resetPath(for providerId: String) {
        Logger.shared.info("User reset path mapping to default system root for provider: \(providerId)")
        userDefaults.removeObject(forKey: "\(Self.overrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
    }
}
