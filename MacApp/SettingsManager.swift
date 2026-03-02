import Foundation
import SwiftUI

@MainActor
class SettingsManager: ObservableObject {
    @Published var availableProviders: [CloudProvider] = []
    
    private let userDefaults = UserDefaults.standard
    private let overrideKeyPrefix = "path_override_"
    
    init() {
        discoverProviders()
    }
    
    func discoverProviders() {
        var providers: [CloudProvider] = []
        
        // 1. iCloud is always available
        let iCloudDefaultPath = (NSString(string: "~/Documents")).expandingTildeInPath
        let iCloudOverride = userDefaults.string(forKey: "\(overrideKeyPrefix)iCloud")
        providers.append(CloudProvider(
            id: "iCloud",
            displayName: "iCloud",
            imageName: "icloud_logo",
            path: iCloudOverride ?? iCloudDefaultPath,
            type: .iCloud
        ))
        
        // 2. Discover local Cloud Storage mapping
        let cloudStorageURL = URL(fileURLWithPath: (NSString(string: "~/Library/CloudStorage")).expandingTildeInPath)
        
        if let enumerator = FileManager.default.enumerator(at: cloudStorageURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let folderName = fileURL.lastPathComponent
                
                if folderName.hasPrefix("OneDrive-") {
                    let suffix = folderName.dropFirst("OneDrive-".count)
                    let id = folderName
                    let override = userDefaults.string(forKey: "\(overrideKeyPrefix)\(id)")
                    providers.append(CloudProvider(
                        id: id,
                        displayName: "OneDrive (\(suffix))",
                        imageName: "onedrive_logo",
                        path: override ?? fileURL.path,
                        type: .oneDrive
                    ))
                } else if folderName.hasPrefix("GoogleDrive-") {
                    let suffix = folderName.dropFirst("GoogleDrive-".count)
                    let id = folderName
                    let override = userDefaults.string(forKey: "\(overrideKeyPrefix)\(id)")
                    let defaultPath = fileURL.appendingPathComponent("My Drive").path
                    providers.append(CloudProvider(
                        id: id,
                        displayName: "Google Drive (\(suffix))",
                        imageName: "googledrive_logo",
                        path: override ?? defaultPath,
                        type: .googleDrive
                    ))
                } else if folderName == "Dropbox" {
                    let id = folderName
                    let override = userDefaults.string(forKey: "\(overrideKeyPrefix)\(id)")
                    providers.append(CloudProvider(
                        id: id,
                        displayName: "Dropbox",
                        imageName: "dropbox_logo",
                        path: override ?? fileURL.path,
                        type: .dropBox
                    ))
                }
            }
        }
        
        self.availableProviders = providers
    }
    
    func path(for providerId: String) -> String {
        return availableProviders.first(where: { $0.id == providerId })?.path ?? ""
    }
    
    func setPath(_ path: String, for providerId: String) {
        userDefaults.set(path, forKey: "\(overrideKeyPrefix)\(providerId)")
        if let index = availableProviders.firstIndex(where: { $0.id == providerId }) {
            availableProviders[index].path = path
        }
    }
}
