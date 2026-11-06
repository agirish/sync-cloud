import Foundation
import Testing
import Sync

/// The door table: where each vendor's own settings are, and which vendors have none reachable
/// (see ``CloudProvider/SettingsDoor``). Each value was verified on a live machine, so the literals
/// are pinned against a well-meant swap for a plausible but unverified door.
@Suite struct ProviderSettingsDoorTests {

    private func provider(id: String = "X", type: CloudProvider.ProviderType) -> CloudProvider {
        CloudProvider(id: id, displayName: "X", imageName: "x", rootPath: "/tmp/x", type: type)
    }

    /// Door and title travel together: a door without a label cannot be offered, and a label
    /// without a door promises what cannot happen.
    @Test func doorAndTitleComeTogetherOrNotAtAll() {
        for type in [CloudProvider.ProviderType.iCloud, .oneDrive, .dropBox, .googleDrive, .localFolder] {
            let p = provider(type: type)
            #expect((p.settingsDoor == nil) == (p.settingsDoorTitle == nil),
                    "\(type) has a door without a title, or a title without a door")
        }
    }

    /// iCloud is the one vendor with a native settings pane, opened by the documented System
    /// Settings deep link.
    @Test func iCloudOpensTheSystemSettingsPane() {
        #expect(provider(type: .iCloud).settingsDoor == .systemSettings(
            URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud")!))
    }

    /// Google Drive is the one vendor whose app verifiably opens a window on activation, so its
    /// door is the app.
    @Test func googleDriveOpensItsApp() {
        #expect(provider(type: .googleDrive).settingsDoor
                == .application(bundleIdentifier: "com.google.drivefs"))
    }

    /// OneDrive and Dropbox have no door, by his choice: native preferences or nothing. Activation
    /// shows no window, `odopen://settings`, `preferences` and `account` open only error windows,
    /// and `dropbox-client://` is inert. A door needs a verified route to the vendor's own
    /// preferences window, not a web page.
    @Test func oneDriveAndDropboxOfferNothing() {
        #expect(provider(id: "OneDrive-Personal", type: .oneDrive).settingsDoor == nil)
        #expect(provider(id: "OneDrive-AcmeCorporationWorldwide", type: .oneDrive).settingsDoor == nil)
        #expect(provider(type: .dropBox).settingsDoor == nil)
    }

    @Test func aFolderSourceOffersNothing() {
        #expect(provider(type: .localFolder).settingsDoor == nil)
        #expect(provider(type: .localFolder).settingsDoorTitle == nil)
    }

    /// Each title names its own vendor: the menu lists up to eleven sources, and a bare "Open
    /// Settings" wouldn't say whose.
    @Test func everyTitleNamesItsVendor() throws {
        let expectations: [(CloudProvider.ProviderType, String)] = [
            (.iCloud, "iCloud"), (.googleDrive, "Google Drive"),
        ]
        for (type, vendor) in expectations {
            let title = try #require(provider(type: type).settingsDoorTitle)
            #expect(title.contains(vendor), "\(type)'s title \"\(title)\" does not name \(vendor)")
        }
    }
}
