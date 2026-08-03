import AppKit
import Foundation
import SwiftUI
import Testing
import Sync
@testable import Settings

/// Folder sources in Settings (roadmap 1a): the curated list of plain folders, merged into
/// `availableProviders` so every downstream surface — panes, Tidy, the diff engine, the CLI — gets
/// one for free, and the four things the roadmap flagged as likely to bite.
@Suite struct FolderSourcesTests {

    @MainActor
    private func manager(_ defaults: TestDefaults,
                         cloudStorage: [URL] = [],
                         valid: @escaping @Sendable (String) -> Bool = { _ in true }) -> SettingsManager {
        SettingsManager(autoDiscover: false,
                        userDefaults: defaults.defaults,
                        overridesDomainName: defaults.suiteName,
                        cloudStorageLister: { cloudStorage },
                        pathValidator: valid)
    }

    private let dropboxAccount = URL(fileURLWithPath: "/Users/u/Library/CloudStorage/Dropbox")

    // MARK: mapProviders — the merge

    /// Folder sources land AFTER every cloud account, as a block, in the order they were added.
    /// That ordering is what keeps the existing picker visually untouched: nobody's iCloud row
    /// moves because they added a folder.
    @Test func folderSourcesSortAfterEveryCloudAccount() {
        let providers = SettingsManager.mapProviders(
            cloudStorageFolders: [dropboxAccount],
            iCloudDefaultPath: "/Users/u/Documents",
            folderSources: [FolderSource(id: "folder:b", path: "~/Projects"),
                            FolderSource(id: "folder:a", path: "/Volumes/Backup")],
            pathOverride: { _ in nil }
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
            pathOverride: { _ in nil }
        )
        let folder = try! #require(providers.last)
        #expect(folder.id == "folder:a")
        #expect(folder.displayName == "Projects")
        #expect(folder.path == "~/Projects")
        #expect(folder.type == .localFolder)
        #expect(folder.isLocalFolder)
        // An SF Symbol, not an asset — `ProviderLogo` renders whichever it is handed.
        #expect(folder.imageName == "folder.fill")
    }

    /// Renaming works on a folder source exactly as it does on a cloud account: same override key
    /// prefix, same clearing rule. It is the ONE place the two kinds share machinery, so it is
    /// worth pinning that the folder's default name is what comes back when the override clears.
    @Test func aFolderSourceHonorsANameOverride() {
        func mapped(_ override: String?) -> CloudProvider {
            SettingsManager.mapProviders(
                cloudStorageFolders: [],
                iCloudDefaultPath: "/Users/u/Documents",
                folderSources: [FolderSource(id: "folder:a", path: "~/Projects")],
                pathOverride: { _ in nil },
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let first = manager(defaults)
        let id = first.addFolderSource(path: "/Users/u/Projects")
        await first.discoverProviders()

        let reopened = manager(defaults)
        #expect(reopened.folderSources.map(\.id) == [id])
        // Seeded before discovery even runs, like the iCloud provider is — so nothing renders a
        // list that is missing the user's folders for the first frame.
        #expect(reopened.availableProviders.contains { $0.id == id })
    }

    /// Nested and overlapping sources are legitimate, but two rows for ONE folder are just a
    /// duplicate the user then has to tell apart by name. Adding an existing path SELECTS it —
    /// and the id coming back is what lets "Choose Folder…" still point the pane at it.
    @MainActor
    @Test func addingAFolderThatIsAlreadyASourceSelectsItInsteadOfDuplicating() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)

        let first = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()
        let second = settings.addFolderSource(path: "/Users/u/Projects/")
        let third = settings.addFolderSource(path: "/users/u/projects")

        #expect(second == first)
        #expect(third == first, "the volume is case-insensitive; these are one folder")
        #expect(settings.folderSources.count == 1)
    }

    /// The duplicate check must hold on the SECOND add too, with no discovery in between.
    /// `discoverProviders` is async and stats network-backed mounts, so `availableProviders` can
    /// lag `folderSources` by however long that takes — and a check that consults only the
    /// published list would mint a second row for one folder in exactly that window.
    @MainActor
    @Test func addingTwiceWithoutWaitingForDiscoveryStillSelects() {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)

        let first = settings.addFolderSource(path: "/Users/u/Projects")
        let second = settings.addFolderSource(path: "/Users/u/Projects")

        #expect(second == first)
        #expect(settings.folderSources.count == 1)
    }

    /// Nesting is still allowed — `~` and `~/Projects` are both reasonable sources, and
    /// `inferredType` resolves the overlap. Only an EXACT repeat is refused.
    @MainActor
    @Test func nestedFoldersAreStillTwoSources() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)

        let parent = settings.addFolderSource(path: "/Users/u")
        await settings.discoverProviders()
        let child = settings.addFolderSource(path: "/Users/u/Projects")

        #expect(parent != child)
        #expect(settings.folderSources.count == 2)
    }

    /// A discovered account already knows things about its folder that a folder source would
    /// throw away — its name rules, its date behaviour. Adding its root selects the account.
    @MainActor
    @Test func addingACloudProvidersOwnRootSelectsThatProvider() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        await settings.discoverProviders()

        let id = settings.addFolderSource(path: "/Users/u/Library/CloudStorage/Dropbox/Documents")

        #expect(id == "Dropbox")
        #expect(settings.folderSources.isEmpty)
    }

    // MARK: Removing

    @MainActor
    @Test func removingAFolderTakesItsNameAndItsDisabledStateWithIt() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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
        // Re-adding the same folder mints a new id, so a leftover name override could not attach
        // to it — but a leftover DISABLED entry keyed to the old id would sit in the persisted set
        // forever, and the set is what `canDisable` counts against.
        #expect(settings.disabledProviderIds.contains(id) == false)
        #expect(defaults.defaults.string(forKey: "name_override_\(id)") == nil)
    }

    @MainActor
    @Test func removingIgnoresIdsThatAreNotFolderSources() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults, cloudStorage: [dropboxAccount])
        await settings.discoverProviders()

        settings.removeFolderSource(id: "Dropbox")
        await settings.discoverProviders()

        #expect(settings.availableProviders.contains { $0.id == "Dropbox" },
                "a discovered account is not removable")
    }

    // MARK: Moving one

    /// A folder source's stored path IS its path — there is no discovered default for an override
    /// to sit on top of. Writing one would leave the list holding the old path and the provider
    /// the new one, and Remove would clear only one of them.
    @MainActor
    @Test func movingAFolderSourceRewritesTheListRatherThanAddingAnOverride() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)
        let id = settings.addFolderSource(path: "/Users/u/Projects")
        await settings.discoverProviders()

        settings.setPath("/Users/u/Archive", for: id)
        await settings.discoverProviders()

        #expect(settings.folderSources.first?.path == "/Users/u/Archive")
        #expect(settings.path(for: id) == "/Users/u/Archive")
        #expect(defaults.defaults.string(forKey: "path_override_\(id)") == nil,
                "an override here would be a second, stale copy of the path")
        // And it is the moved path that persists.
        #expect(manager(defaults).folderSources.first?.path == "/Users/u/Archive")
    }

    // MARK: The name ruleset a folder borrows

    @MainActor
    @Test func namesUnderAFolderAreCheckedAgainstTheChosenRuleset() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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

    /// The pre-existing over-report fallback, preserved: an id that resolves to nothing is checked
    /// against OneDrive, so a name that would break a sync never passes unflagged.
    @MainActor
    @Test func anUnresolvableSourceStillOverReports() {
        let defaults = TestDefaults(); defer { defaults.wipe() }
        let settings = manager(defaults)
        #expect(settings.nameRuleType(for: "nothing-by-this-name") == .oneDrive)
    }

    @MainActor
    @Test func theChosenRulesetSurvivesARelaunch() {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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

    /// `resetAllSettings` removes the whole defaults domain, which takes the curated folder list
    /// with it. That is defensible, and the confirmation now says so — what must not happen is the
    /// list surviving in memory while its persistence is gone, which would resurrect the folders
    /// on the next write and lose them on the next launch.
    @MainActor
    @Test func resetAllSettingsClearsTheFolderListAndSaysSo() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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

    /// The tab is titled "Sources" now and the section headings are "Cloud providers" / "Local
    /// folders", so someone who thinks in the old vocabulary — or in none of it — still has to
    /// land here.
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

    /// Every assertion above calls a method; none of them build the view. This one lays the tab
    /// out for real, so the folder rows, the Add Folder button and the ruleset picker are actually
    /// constructed — a broken `body` would otherwise ship green.
    ///
    /// Height rather than a constant: a populated tab must be taller than an empty one, which is
    /// the cheapest statement that the rows reached the screen rather than being built and dropped.
    @MainActor
    @Test func theTabLaysOutTheFolderRowsItIsGiven() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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

    /// Rows are collapsed by default and that is the point: this tab grows with every account the
    /// Mac has plus every folder added, and an expanded row carries a Location field and three
    /// buttons. Expanding one must actually add that height.
    @MainActor
    @Test func expandingARowRevealsItsLocationControls() async {
        let defaults = TestDefaults(); defer { defaults.wipe() }
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

    /// Text scale pinned, as `SettingsLayoutTests` does: `scaledFont` reads it from the
    /// environment, so an unpinned measurement reports whatever text size this machine has set.
    @MainActor
    private func laidOutHeight(_ view: some View,
                               width: CGFloat = SettingsSheetMetrics.contentWidth(textScale: 1)) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
