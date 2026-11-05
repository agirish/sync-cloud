import AppKit
import Foundation
import SwiftUI
import Testing
import Sync
@testable import Settings

/// Folder sources in Settings: the curated list of plain folders, merged into `availableProviders`
/// so every downstream surface (panes, the lens workspaces, the diff engine, the CLI) gets them
/// for free, plus the edges most likely to bite: duplicates, removal, moves and name rules.
@Suite struct FolderSourcesTests {

    @MainActor
    private func manager(_ defaults: TestDefaults,
                         cloudStorage: [URL] = [],
                         valid: @escaping @Sendable (String) -> Bool = { _ in true }) -> SettingsManager {
        SettingsManager(autoDiscover: false,
                        userDefaults: defaults.defaults,
                        overridesDomainName: defaults.suiteName,
                        cloudStorageLister: { .read(cloudStorage) },
                        pathValidator: valid)
    }

    private let dropboxAccount = URL(fileURLWithPath: "/Users/u/Library/CloudStorage/Dropbox")

    // MARK: mapProviders — the merge

    /// Folder sources land after every cloud account, as a block, in the order added, so no
    /// account row moves because a folder was added.
    @Test func folderSourcesSortAfterEveryCloudAccount() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [dropboxAccount],
            iCloudDefaultPath: "/Users/u/Documents",
            folderSources: [FolderSource(id: "folder:b", path: "~/Projects"),
                            FolderSource(id: "folder:a", path: "/Volumes/Backup")],
            rootOverride: { _ in nil }
        )
        #expect(providers.map(\.type) == [.iCloud, .dropBox, .localFolder, .localFolder])
        // Added-order, not alphabetical: sorting them by name would reshuffle the whole block
        // every time one is renamed.
        #expect(providers.suffix(2).map(\.id) == ["folder:b", "folder:a"])
    }

    @Test func aFolderSourceBecomesAProviderNamedForItsFolder() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [],
            iCloudDefaultPath: "/Users/u/Documents",
            folderSources: [FolderSource(id: "folder:a", path: "~/Projects")],
            rootOverride: { _ in nil }
        )
        let folder = try! #require(providers.last)
        #expect(folder.id == "folder:a")
        #expect(folder.displayName == "Projects")
        #expect(folder.rootPath == "~/Projects")
        #expect(folder.type == .localFolder)
        #expect(folder.isLocalFolder)
        // An SF Symbol, not an asset — `ProviderLogo` renders whichever it is handed.
        #expect(folder.imageName == "folder.fill")
    }

    /// Renaming a folder source works as on a cloud account: same override key prefix, same
    /// clearing rule. Clearing the override brings back the folder's own name.
    @Test func aFolderSourceHonorsANameOverride() {
        func mapped(_ override: String?) -> CloudProvider {
            SettingsManager.mapProviders(
                cloudStorageFolders: [],
                iCloudDefaultPath: "/Users/u/Documents",
                folderSources: [FolderSource(id: "folder:a", path: "~/Projects")],
                rootOverride: { _ in nil },
                nameOverride: { $0 == "folder:a" ? override : nil }
            ).last!
        }
        #expect(mapped("Work").displayName == "Work")
        #expect(mapped(nil).displayName == "Projects")
        #expect(mapped("").displayName == "Projects", "an emptied name restores the folder's own")
    }

    // MARK: Adding

    @MainActor
    @Test func addingAFolderPublishesItAsASelectableSource() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)

        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        #expect(settings.folderSources.map(\.id) == [id])
        #expect(settings.availableProviders.contains { $0.id == id && $0.type == .localFolder })
        #expect(settings.enabledProviders.contains { $0.id == id },
                "a folder is enabled the moment it is added — nobody adds one to leave it off")
    }

    /// The curated list is the thing the user built; it has to survive a relaunch.
    @MainActor
    @Test func theFolderListSurvivesARelaunch() async {
        let defaults = TestDefaults()
        let first = manager(defaults)
        let id = first.addFolderSource(path: "/Users/u/Projects")
        await first.discoverProviders()

        let reopened = manager(defaults)
        #expect(reopened.folderSources.map(\.id) == [id])
        // Seeded before discovery runs, like iCloud, so no first frame lacks the user's folders.
        #expect(reopened.availableProviders.contains { $0.id == id })
    }

    /// Nested sources are fine, but two rows for one folder are a duplicate. Adding an existing
    /// path selects it, and the returned id lets "Choose Folder…" still point the pane at it.
    @MainActor
    @Test func addingAFolderThatIsAlreadyASourceSelectsItInsteadOfDuplicating() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)

        let first = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        let second = settings.addFolderSource(path: "/Users/u/Projects/")
        let third = settings.addFolderSource(path: "/users/u/projects")

        #expect(second == first)
        #expect(third == first, "the volume is case-insensitive; these are one folder")
        #expect(settings.folderSources.count == 1)
    }

    /// The duplicate check holds with no discovery in between. `discoverProviders` is async and
    /// stats network mounts, so `availableProviders` can lag `folderSources`; a check against only
    /// the published list would mint a second row in that window.
    @MainActor
    @Test func addingTwiceWithoutWaitingForDiscoveryStillSelects() {
        let defaults = TestDefaults()
        let settings = manager(defaults)

        let first = settings.addFolderSource(path: "/Users/u/Projects")
        let second = settings.addFolderSource(path: "/Users/u/Projects")

        #expect(second == first)
        #expect(settings.folderSources.count == 1)
    }

    /// Nesting is allowed: `~` and `~/Projects` are both reasonable sources, and `inferredType`
    /// resolves the overlap. Only an exact repeat is refused.
    @MainActor
    @Test func nestedFoldersAreStillTwoSources() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)

        let parent = settings.addFolderSource(path: "/Users/u")
        await settings.discoverProviders()
        let child = settings.addFolderSource(path: "/Users/u/Projects")

        #expect(parent != child)
        #expect(settings.folderSources.count == 2)
    }

    /// A discovered account knows things a folder source would throw away, such as its name rules
    /// and date behaviour, so adding its root selects the account.
    @MainActor
    @Test func addingACloudProvidersOwnRootSelectsThatProvider() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        await settings.discoverProviders()

        // The account folder, which is Dropbox's root. (Its `Documents` is an ordinary folder
        // within the source, and adding it as its own row is a legitimate nested source.)
        let id = settings.addFolderSource(path: "/Users/u/Library/CloudStorage/Dropbox")

        #expect(id == "Dropbox")
        #expect(settings.folderSources.isEmpty)
    }

    // MARK: Removing

    @MainActor
    @Test func removingAFolderTakesItsNameAndItsDisabledStateWithIt() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        settings.setCustomName("Work", for: id)
        settings.setEnabled(false, for: id)
        await settings.discoverProviders()

        settings.removeFolderSource(id: id)
        await settings.discoverProviders()

        #expect(settings.folderSources.isEmpty)
        #expect(settings.availableProviders.contains { $0.id == id } == false)
        // Re-adding mints a new id, so a leftover name override can't attach, but a leftover
        // disabled entry would sit in the persisted set forever, and `canDisable` counts that set.
        #expect(settings.disabledProviderIds.contains(id) == false)
        #expect(defaults.defaults.string(forKey: "name_override_\(id)") == nil)
    }

    @MainActor
    @Test func removingIgnoresIdsThatAreNotFolderSources() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        await settings.discoverProviders()

        settings.removeFolderSource(id: "Dropbox")
        await settings.discoverProviders()

        #expect(settings.availableProviders.contains { $0.id == "Dropbox" },
                "a discovered account is not removable")
    }

    // MARK: Moving one

    /// A folder source's stored path is its path; there's no discovered default for an override
    /// to sit on. An override would leave two paths, and Remove would clear only one.
    @MainActor
    @Test func movingAFolderSourceRewritesTheListRatherThanAddingAnOverride() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        settings.setPath("/Users/u/Archive", for: id)
        await settings.discoverProviders()

        #expect(settings.folderSources.first?.path == "/Users/u/Archive")
        #expect(settings.rootPath(for: id) == "/Users/u/Archive")
        #expect(defaults.defaults.string(forKey: "path_override_\(id)") == nil,
                "an override here would be a second, stale copy of the path")
        // And it is the moved path that persists.
        #expect(manager(defaults).folderSources.first?.path == "/Users/u/Archive")
    }

    // MARK: Moving one onto a folder that is already taken

    /// The other door onto "one folder gets one row": `addFolderSource` selects the existing row,
    /// and `setPath` must refuse, or editing a Location makes the duplicate the add door prevents.
    @MainActor
    @Test func movingAFolderSourceOntoAnotherSourcesFolderIsRefused() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let projects = settings.addFolderSource(path: "/Users/u/Projects")
        let archive = settings.addFolderSource(path: "/Users/u/Archive")
        await settings.discoverProviders()

        let outcome = settings.setPath("/Users/u/Projects", for: archive)

        #expect(outcome == .refusedDuplicate(existingId: projects))
        #expect(settings.folderSources.count == 2, "still two sources, not two rows for one folder")
        #expect(settings.rootPath(for: archive) == "/Users/u/Archive", "and the refused one did not move")
        // Nothing was written, so the refusal survives a relaunch. No tildes: `/Users/u` is
        // nobody's real home, so `FolderSource.abbreviated` has nothing to fold.
        #expect(manager(defaults).folderSources.map(\.path)
                == ["/Users/u/Projects", "/Users/u/Archive"])
    }

    /// Case-insensitive here too: on the default macOS volume these are one folder.
    @MainActor
    @Test func movingOntoAnotherSourcesFolderIsRefusedCaseInsensitively() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let projects = settings.addFolderSource(path: "/Users/u/Projects")
        let archive = settings.addFolderSource(path: "/Users/u/Archive")
        await settings.discoverProviders()

        #expect(settings.setPath("/users/u/projects/", for: archive)
                == .refusedDuplicate(existingId: projects))
        #expect(settings.rootPath(for: archive) == "/Users/u/Archive")
    }

    /// `addFolderSource` refuses to shadow a cloud account, and so must this: a `.localFolder` row
    /// over a real account would silently swap its ruleset for the folder default.
    @MainActor
    @Test func movingAFolderSourceOntoACloudAccountsRootIsRefused() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        let archive = settings.addFolderSource(path: "/Users/u/Archive")
        await settings.discoverProviders()
        let dropboxPath = settings.rootPath(for: "Dropbox")

        let outcome = settings.setPath(dropboxPath, for: archive)

        #expect(outcome == .refusedDuplicate(existingId: "Dropbox"))
        #expect(settings.rootPath(for: archive) == "/Users/u/Archive")
        #expect(settings.nameRuleType(for: "Dropbox") == .dropBox,
                "the account keeps its own ruleset — the shadowing row is what would have taken it")
    }

    /// A source names its own folder, so without `ignoring:` every edit would refuse itself.
    /// Re-spelling a path in place still lands.
    @MainActor
    @Test func respellingASourcesOwnPathIsNotRefusedAsADuplicateOfItself() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        #expect(settings.setPath("/users/u/projects", for: id) == .changed)
        #expect(settings.folderSources.first?.path == "/users/u/projects")
    }

    /// Nesting is allowed on this door too; only an exact repeat is refused, as on the add door.
    @MainActor
    @Test func movingAFolderSourceUnderAnotherSourceIsStillAllowed() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let parent = settings.addFolderSource(path: "/Users/u")
        let other = settings.addFolderSource(path: "/Users/u/Archive")
        await settings.discoverProviders()

        #expect(settings.setPath("/Users/u/Projects", for: other) == .changed)
        #expect(settings.rootPath(for: parent) == "/Users/u", "the parent is untouched")
        #expect(settings.folderSources.count == 2)
    }

    /// Re-pointing a discovered account is deliberately unrestricted: the invariant is about folder
    /// sources, and `setPath` says so.
    @MainActor
    @Test func repointingACloudAccountOntoAFolderSourceIsStillAllowed() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        #expect(settings.setPath("/Users/u/Projects", for: "Dropbox") == .changed)
    }

    /// A no-op edit reports itself as one rather than as an acceptance, so the field's refusal
    /// message is cleared by a blur that committed nothing.
    @MainActor
    @Test func recommittingTheSamePathIsUnchanged() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        // The same folder spelled with a trailing slash: `abbreviated` standardizes it back to the
        // stored value, so there is nothing to write.
        #expect(settings.setPath("/Users/u/Projects/", for: id) == .unchanged)
        #expect(settings.setPath("", for: id) == .unchanged)
    }

    // MARK: The name ruleset a folder borrows

    @MainActor
    @Test func namesUnderAFolderAreCheckedAgainstTheChosenRuleset() async {
        let defaults = TestDefaults()
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        #expect(settings.folderNameRule == .oneDrive, "the strictest, by default")
        #expect(settings.nameRuleType(for: id) == .oneDrive)
        #expect(settings.nameRuleType(for: "Dropbox") == .dropBox,
                "a cloud account keeps its own rules")

        settings.folderNameRule = .dropBox
        #expect(settings.nameRuleType(for: id) == .dropBox)

        settings.folderNameRule = .localFolder
        #expect(settings.nameRuleType(for: id) == .localFolder, "\"don't check\"")
        #expect(settings.nameRuleType(for: "Dropbox") == .dropBox,
                "turning the folder check off must not disarm the cloud accounts")
    }

    /// An id that resolves to nothing is checked against OneDrive, so a name that would break a
    /// sync never passes unflagged.
    @MainActor
    @Test func anUnresolvableSourceStillOverReports() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        #expect(settings.nameRuleType(for: "nothing-by-this-name") == .oneDrive)
    }

    @MainActor
    @Test func theChosenRulesetSurvivesARelaunch() {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.folderNameRule = .dropBox
        #expect(manager(defaults).folderNameRule == .dropBox)
    }

    /// Every option the picker offers has to be one `nameRuleType` can actually return, and the
    /// list must stay free of the two spellings of "don't check" that look like they mean
    /// something (iCloud and Google Drive report no violations either).
    @Test func thePickerOffersOnlyRulesetsThatMeanSomething() {
        #expect(FolderNameRuleOption.all.map(\.value) == [.oneDrive, .dropBox, .localFolder])
        #expect(FolderNameRuleOption.all.allSatisfy { !$0.label.isEmpty })
    }

    // MARK: Reset All Settings

    /// `resetAllSettings` clears the defaults domain except what `SettingsResetKeeps` names, so the
    /// folder list goes too, as the confirmation says. The in-memory list must go with it, or the
    /// next write resurrects the folders and the next launch loses them.
    @MainActor
    @Test func resetAllSettingsClearsTheFolderListAndSaysSo() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        settings.addFolderSource(path: "/Users/u/Projects")
        settings.folderNameRule = .dropBox
        await settings.discoverProviders()

        settings.resetAllSettings()
        await settings.discoverProviders()

        #expect(settings.folderSources.isEmpty)
        #expect(settings.folderNameRule == .oneDrive)
        #expect(settings.availableProviders.allSatisfy { !$0.isLocalFolder })
        #expect(manager(defaults).folderSources.isEmpty)
    }

    // MARK: Findability

    /// The tab is "Sources", with sections "Cloud providers" and "Local folders"; someone
    /// searching in other words must still land here.
    @Test func addingAFolderIsFindableByTheWordsSomeoneWouldType() {
        for query in ["add folder", "local", "folder", "providers", "sources", "home folder"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.tab == .providers },
                    "'\(query)' should surface something on the Sources tab")
        }
    }

    @Test func theNameCheckSettingIsFindableByTheProblemItSolves() {
        for query in ["risky names", "check names", "name rules"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Check folder names against" },
                    "'\(query)' should surface the folder name-rule picker")
        }
    }

    @Test func theTabIsCalledSources() {
        #expect(SettingsView.SettingsTab.providers.displayName == "Sources")
        // The raw value is the persisted `settingsSelectedTab` format and every deep link's target.
        #expect(SettingsView.SettingsTab.providers.rawValue == "providers")
    }

    // MARK: The tab as laid out

    /// Lays the tab out for real, so a broken `body` can't pass on the method tests above. A
    /// populated tab must be taller than an empty one, the cheapest proof the rows are drawn.
    @MainActor
    @Test func theTabLaysOutTheFolderRowsItIsGiven() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        await settings.discoverProviders()

        let empty = laidOutHeight(ProvidersSettingsTab().environmentObject(settings))
        #expect(empty > 0, "the tab did not lay out at all")

        for path in ["/Users/u/Projects", "/Users/u/Archive", "/Volumes/Backup"] {
            settings.addFolderSource(path: path)
        }
        await settings.discoverProviders()
        let populated = laidOutHeight(ProvidersSettingsTab().environmentObject(settings))

        #expect(populated > empty,
                "three folder rows added \(populated - empty)pt — they are not being rendered")
    }

    /// Rows are collapsed by default because the tab grows with every account and folder, and an
    /// expanded row carries a Location field and three buttons. Expanding one must add that height.
    @MainActor
    @Test func expandingARowRevealsItsLocationControls() async {
        let defaults = TestDefaults()
        let settings = manager(defaults)
        await settings.discoverProviders()
        let provider = try! #require(settings.availableProviders.first)

        let collapsed = laidOutHeight(
            ProviderSettingsSection(provider: provider, isExpanded: .constant(false))
                .environmentObject(settings))
        let expanded = laidOutHeight(
            ProviderSettingsSection(provider: provider, isExpanded: .constant(true))
                .environmentObject(settings))

        #expect(collapsed > 0, "the collapsed row must still draw its identity line")
        #expect(expanded > collapsed,
                "expanding added \(expanded - collapsed)pt — the Location controls are not appearing")
    }

    /// Text scale pinned, as in `SettingsLayoutTests`: `scaledFont` reads it from the environment,
    /// so unpinned it measures this machine's text size.
    @MainActor
    private func laidOutHeight(_ view: some View,
                               width: CGFloat = SettingsSheetMetrics.contentWidth(textScale: 1)) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
