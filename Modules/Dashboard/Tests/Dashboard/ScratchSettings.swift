import Settings
import Foundation
import Sync
@testable import Dashboard

/// Settings with no discovery pass, on a scratch suite. A bare `SettingsManager()` discovers the
/// real `~/Library/CloudStorage` and writes it to `lastKnownAccountFolders` in the standard domain,
/// which under `swift test` is a plist every test process on the machine shares.
///
/// Given `providers`, the list is exactly those: nothing listed from CloudStorage, every path valid.
/// Without, the seed is iCloud and nothing else.
@MainActor
func scratchSettings(providers: [CloudProvider]? = nil) -> SettingsManager {
    let defaults = ScratchDefaults("ScratchSettings")
    guard let providers else { return SettingsManager(autoDiscover: false, userDefaults: defaults) }
    let settings = SettingsManager(autoDiscover: false, userDefaults: defaults,
                                   cloudStorageLister: { .read([]) }, pathValidator: { _ in true })
    settings.availableProviders = providers
    return settings
}

/// A `FileActionHandler` on scratch settings, defaults and pasteboard. Prompts answer "cancel"
/// unless a test supplies one, so none can reach a real modal.
@MainActor
func scratchHandler(_ manager: FileSyncManager, settings: SettingsManager? = nil, defaults: UserDefaults? = nil,
                    label: String = #function, fileID: String = #fileID,
                    renamePrompter: @escaping (String, (String) -> String?) -> String? = { _, _ in nil },
                    newFolderPrompter: @escaping ((String) -> String?) -> String? = { _ in nil },
                    deleteConfirmer: @escaping ([String], Int) -> Bool = { _, _ in false }) -> FileActionHandler {
    FileActionHandler(syncManager: manager, settings: settings ?? scratchSettings(providers: []),
                      defaults: defaults ?? ScratchDefaults("FileActionHandler"),
                      pasteboard: scratchPasteboard(label, fileID: fileID),
                      renamePrompter: renamePrompter, newFolderPrompter: newFolderPrompter,
                      deleteConfirmer: deleteConfirmer)
}
