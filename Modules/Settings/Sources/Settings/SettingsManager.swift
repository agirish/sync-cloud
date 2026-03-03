import Events
import Foundation
import SwiftUI
import Sync

/// Manages the discovery and customization of Cloud Providers available to the application.
/// Interfaces with `UserDefaults` to persist custom path overwrites per provider.
@MainActor
public class SettingsManager: ObservableObject {
    /// A sorted array of natively detected and custom-configured providers (e.g., iCloud, OneDrive).
    @Published public var availableProviders: [CloudProvider] = []
    
    private let userDefaults = UserDefaults.standard
    private let overrideKeyPrefix = "path_override_"
    
    public init() {
        // Initialize with default iCloud provider to allow app to start immediately
        let iCloudDefaultPath = (NSString(string: "~/Documents")).expandingTildeInPath
        self.availableProviders = [
            CloudProvider(
                id: "iCloud",
                displayName: "iCloud",
                imageName: "icloud",
                path: iCloudDefaultPath,
                type: .iCloud
            )
        ]
        
        Task {
            await discoverProviders()
        }
    }
    
    /// Scans the local filesystem's CloudStorage mounting point to detect configured provider accounts.
    /// Re-evaluates custom user overwrites and updates the `availableProviders` sequence.
    public func discoverProviders() async {
        Logger.shared.info("Discovering cloud providers...")
        
        let iCloudOverride = userDefaults.string(forKey: "\(overrideKeyPrefix)iCloud")
        let cloudStoragePath = (NSString(string: "~/Library/CloudStorage")).expandingTildeInPath
        let cloudStorageURL = URL(fileURLWithPath: cloudStoragePath)
        
        let providers = await Task.detached(priority: .userInitiated) { () -> [CloudProvider] in
            var found: [CloudProvider] = []
            
            // 1. iCloud is always available
            let iCloudDefaultPath = (NSString(string: "~/Documents")).expandingTildeInPath
            found.append(CloudProvider(
                id: "iCloud",
                displayName: "iCloud",
                imageName: "icloud",
                path: iCloudOverride ?? iCloudDefaultPath,
                type: .iCloud
            ))
            
            // 2. Discover local Cloud Storage mapping
            if let enumerator = FileManager.default.enumerator(at: cloudStorageURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let folderName = fileURL.lastPathComponent
                    
                    if folderName.hasPrefix("OneDrive-") {
                        let suffix = folderName.dropFirst("OneDrive-".count)
                        let id = folderName
                        // We can't access userDefaults here easily as it's not Sendable, 
                        // but we can pass the override map if needed. 
                        // For now, let's keep it simple and just find the folders.
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
            }
            return found
        }.value
        
        // Apply overrides back on the Main Actor
        var finalProviders = providers
        for i in 0..<finalProviders.count {
            if let override = userDefaults.string(forKey: "\(overrideKeyPrefix)\(finalProviders[i].id)") {
                finalProviders[i].path = override
            }
        }
        
        self.availableProviders = finalProviders
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
            userDefaults.removeObject(forKey: "\(overrideKeyPrefix)\(providerId)")
        } else {
            userDefaults.set(path, forKey: "\(overrideKeyPrefix)\(providerId)")
        }
        Task {
            await discoverProviders()
        }
    }
    
    /// Clears any user-defined override from UserDefaults and restores the System-discovered path.
    /// - Parameter providerId: The targeted provider ID.
    public func resetPath(for providerId: String) {
        userDefaults.removeObject(forKey: "\(overrideKeyPrefix)\(providerId)")
        Task {
            await discoverProviders()
        }
    }
}
