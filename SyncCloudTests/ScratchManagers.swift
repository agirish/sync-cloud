import Foundation
import Settings
import Sync

// The test host is SyncCloud.app, so `.standard` here is the user's live domain. These build the
// two managers on a scratch suite instead; `LiveSettingsScanTests` keeps every test on them.

extension FileSyncManager {
    /// A manager whose Keep separate and Filing stores are a scratch suite, not `.standard`.
    static func scratch(fileManager: FileManaging = FileManager.default,
                        _ function: String = #function) -> FileSyncManager {
        FileSyncManager(fileManager: fileManager,
                        defaults: ScratchDefaults("SyncCloudTests-\(function.prefix { $0 != "(" })"))
    }
}

extension SettingsManager {
    /// A manager on a scratch suite that discovers nothing: a bare `SettingsManager()` reads
    /// `.standard` and lists the real `~/Library/CloudStorage` in the background.
    static func scratch(_ function: String = #function) -> SettingsManager {
        SettingsManager(autoDiscover: false,
                        userDefaults: ScratchDefaults("SyncCloudTests-\(function.prefix { $0 != "(" })"),
                        cloudStorageLister: { .read([]) })
    }
}
