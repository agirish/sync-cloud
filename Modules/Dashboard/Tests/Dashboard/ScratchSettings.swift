import Settings
import Sync

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
