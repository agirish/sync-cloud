import Design
import Foundation
import Sync
import Testing
@testable import Settings

/// TE332 step 2's rows for settings the app kept but Settings never showed: One-Way Sync's
/// notifications, Differences' Group by folder, Show Again for every group kept separate, Add… for
/// the folders shared without asking, Customize Pane Bar… and the saved signatures.
///
/// The two that change what is kept or what Claude may see go through gates tested here over real
/// stores; the wiring test at the end holds each control to its gate, since a SwiftUI button's
/// action can't be reached from a test.
@MainActor
@Suite struct NewSettingsRowsTests {

    // MARK: Ask Claude ▸ Privacy ▸ Shared without asking ▸ Add…

    @Test func aFolderNeitherHiddenNorSharedIsSharedWithoutAQuestion() {
        let defaults = ScratchDefaults("NewRows-share-plain")
        AskClaudePrivacy.hide("/Users/u/Taxes", in: defaults)
        var asked = 0

        let shared = IntelligenceSettingsTab.shareIfConfirmed("/Users/u/Recipes", in: defaults) { _ in asked += 1; return true }

        #expect(shared)
        #expect(asked == 0, "sharing a folder nothing hides asked")
        #expect(AskClaudePrivacy.sharedFolders(in: defaults) == ["/Users/u/Recipes"])
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Taxes"], "an unrelated hidden folder was shown")
    }

    @Test func decliningKeepsAHiddenFolderHiddenAndUnshared() {
        let defaults = ScratchDefaults("NewRows-share-decline")
        AskClaudePrivacy.hide("/Users/u/Private", in: defaults)
        var asked = 0

        let shared = IntelligenceSettingsTab.shareIfConfirmed("/Users/u/Private", in: defaults) { _ in asked += 1; return false }

        #expect(!shared)
        #expect(asked == 1, "sharing a hidden folder didn't ask")
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Private"], "a declined share showed it to Claude")
        #expect(AskClaudePrivacy.sharedFolders(in: defaults).isEmpty, "a declined share shared it")
    }

    /// Hidden wins over shared: a folder inside a hidden one is shared only by taking the hidden
    /// one off, and the question names it, because that shows Claude more than what was picked.
    /// Only the entries that hide it come off.
    @Test func sharingAFolderInsideAHiddenOneAsksNamingItThenTakesItOff() throws {
        let defaults = ScratchDefaults("NewRows-share-above")
        AskClaudePrivacy.hide("/Users/u/Private", in: defaults)
        AskClaudePrivacy.hide("/Users/u/Taxes", in: defaults)
        var question: RemovalPrompt?
        var hiddenWhenAsked: [String] = []

        let shared = IntelligenceSettingsTab.shareIfConfirmed("/Users/u/Private/Recipes", in: defaults) {
            question = $0
            hiddenWhenAsked = AskClaudePrivacy.hiddenFolders(in: defaults)
            return true
        }

        #expect(shared)
        let asked = try #require(question, "sharing a folder inside a hidden one didn't ask")
        #expect(asked.messageText == "Share “Recipes” without asking?")
        #expect(asked.informativeText.contains("inside “Private”"), "\(asked.informativeText)")
        #expect(asked.informativeText.contains("hidden wins over shared"))
        #expect(hiddenWhenAsked.contains("/Users/u/Private"), "Private was shown before the question")
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Taxes"])
        #expect(AskClaudePrivacy.sharedFolders(in: defaults) == ["/Users/u/Private/Recipes"])
    }

    @Test func aFolderHiddenByItsOwnEntryIsAskedAboutInItsOwnWords() throws {
        let defaults = ScratchDefaults("NewRows-share-own")
        AskClaudePrivacy.hide("/Users/u/Private", in: defaults)
        var question: RemovalPrompt?

        IntelligenceSettingsTab.shareIfConfirmed("/Users/u/Private", in: defaults) { question = $0; return true }

        let asked = try #require(question)
        #expect(asked.informativeText.hasPrefix("It’s hidden from Claude now"), "\(asked.informativeText)")
        #expect(!asked.informativeText.contains("inside"))
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults).isEmpty)
        #expect(AskClaudePrivacy.sharedFolders(in: defaults) == ["/Users/u/Private"])
    }

    /// A folder hidden inside the one shared stays hidden: sharing never reaches below itself.
    @Test func aHiddenFolderInsideTheSharedOneStaysHidden() {
        let defaults = ScratchDefaults("NewRows-share-below")
        AskClaudePrivacy.hide("/Users/u/Documents/Taxes", in: defaults)
        var asked = 0

        IntelligenceSettingsTab.shareIfConfirmed("/Users/u/Documents", in: defaults) { _ in asked += 1; return true }

        #expect(asked == 0)
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Documents/Taxes"])
        #expect(AskClaudePrivacy.isHidden("/Users/u/Documents/Taxes/2025.pdf",
                                          by: AskClaudePrivacy.hiddenFolders(in: defaults)))
    }

    // MARK: Organize ▸ Duplicates ▸ Groups kept separate ▸ Show Again…

    private func keptSeparate(_ defaults: ScratchDefaults) -> FileSyncManager {
        let manager = FileSyncManager(defaults: defaults)
        // Two folders' groups: Show Again here forgets every folder's, unlike the lens's.
        manager.ignoredDuplicateKeys = ["/Users/u/A/report.pdf\n/Users/u/B/report.pdf",
                                        "/Volumes/X/a.jpg\n/Volumes/X/b.jpg"]
        return manager
    }

    @Test func decliningShowAgainKeepsEveryGroupSeparate() {
        let defaults = ScratchDefaults("NewRows-kept-decline")
        let manager = keptSeparate(defaults)
        var asked = 0

        let forgotten = DuplicatesSettingsTab.showAgainIfConfirmed(manager) { asked += 1; return false }

        #expect(forgotten == nil)
        #expect(asked == 1, "Show Again didn't ask")
        #expect(manager.keptSeparateGroupCount == 2, "a declined Show Again forgot groups")
    }

    @Test func confirmingShowAgainForgetsEveryFolderAfterAsking() {
        let defaults = ScratchDefaults("NewRows-kept-confirm")
        let manager = keptSeparate(defaults)
        var countWhenAsked = -1

        let forgotten = DuplicatesSettingsTab.showAgainIfConfirmed(manager) {
            countWhenAsked = manager.keptSeparateGroupCount; return true
        }

        #expect(forgotten == 2)
        #expect(countWhenAsked == 2, "the groups were forgotten before the question")
        #expect(manager.keptSeparateGroupCount == 0)
        // Read back from the store, not the manager's view of it.
        #expect(defaults.stringArray(forKey: "tidyIgnoredGroupKeys") == [])
    }

    @Test func showAgainWithNothingKeptSeparateNeverAsks() {
        let defaults = ScratchDefaults("NewRows-kept-none")
        let manager = FileSyncManager(defaults: defaults)
        var asked = 0

        #expect(DuplicatesSettingsTab.showAgainIfConfirmed(manager) { asked += 1; return true } == nil)
        #expect(asked == 0)
    }

    /// The card's button forgets the same way, after the card's own question.
    @Test func anAskClaudeCardsShowAgainForgetsEveryGroup() async {
        let defaults = ScratchDefaults("NewRows-kept-card")
        let manager = keptSeparate(defaults)
        let actions = SettingsActions(settings: nil, sync: manager, lookup: nil)

        #expect(actions.prompt("duplicates.keptSeparateShowAgain", target: nil)?.messageText
                == "Show all 2 groups kept separate again?")
        let result = await actions.run("duplicates.keptSeparateShowAgain", target: nil)

        #expect(result == .done("Forgot 2 groups kept separate. The next duplicate scan flags any that are still duplicates."))
        #expect(manager.keptSeparateGroupCount == 0)
    }

    @Test func theQuestionsSayWhatChangesAndThatFilesStay() {
        let one = RemovalPrompt.showKeptSeparateAgain(count: 1)
        #expect(one.messageText == "Show 1 group kept separate again?")
        #expect(one.informativeText.contains("in every folder"))
        #expect(one.informativeText.contains("Your files aren’t affected."))
        #expect(one.confirmTitle == "Show Again")
        let two = RemovalPrompt.shareHidden(named: "Recipes", above: ["Private", "Home"])
        #expect(two.informativeText.contains("“Private”, “Home”") && two.informativeText.contains("those folders"))
        #expect(two.informativeText.contains("Whole documents still ask."))
    }

    // MARK: The keys the other modules read

    /// Persistence formats: renaming either would silently reset what people chose.
    @Test func theMovedKeysKeepTheirStoredNames() {
        #expect(DifferencesSettings.groupByFolderKey == "differencesGroupByFolder")
        #expect(DifferencesSettings.groupByFolderDefault)
        #expect(OneWaySyncNoticeBoard.notifyKey == "oneWaySyncNotifications")
    }

    @Test func theNewRowsAreFoundOnTheirPages() {
        #expect(SettingsPlace.holding("Notify when One-Way Sync needs attention") == SettingsPlace(.general))
        #expect(SettingsPlace.holding("group by folder") == SettingsPlace(.differences))
        #expect(SettingsPlace.holding("show again") == SettingsPlace(.duplicates))
        #expect(SettingsPlace.holding("customize pane bar") == SettingsPlace(.panes))
        #expect(SettingsPlace.holding("saved signatures") == SettingsPlace(.pdf))
    }

    // MARK: The wiring

    private static let modules = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        let text = try #require(try? String(contentsOf: Self.modules.appendingPathComponent(relative), encoding: .utf8),
                                "cannot read \(relative) — the checks below would be vacuous")
        try #require(text.count > 1_000, "\(relative) is implausibly short")
        return SourceComments.stripped(text)
    }

    @Test func everyNewControlReachesWhatItSets() throws {
        func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
        let settings = try source("Settings/Sources/Settings/SettingsView.swift")
        let rows = try source("Settings/Sources/Settings/GeneralRows.swift")

        // Shared without asking's Add… shares only through its gate, which asks with the standard alert.
        #expect(count("AskClaudePrivacy.shareWithoutAsking(", in: settings) == 1,
                "a folder is shared somewhere in Settings besides the gate")
        #expect(settings.contains("Self.shareIfConfirmed(url.path, in: .standard) { $0.ask() }"))

        // Show Again forgets only through its gate, asking with its own question.
        #expect(count("forgetAllKeptSeparateGroups()", in: settings) == 1)
        #expect(settings.contains("RemovalPrompt.showKeptSeparateAgain(count: keptSeparateCount).ask()"))
        #expect(settings.contains("DuplicatesSettingsTab(syncManager: syncManager)"),
                "the Duplicates page is built without the engine, so Show Again can never run")

        // One-Way Sync's switch is on General and asks macOS for permission when it turns on.
        #expect(settings.contains("OneWaySyncNotifyRow()"))
        #expect(rows.contains("@AppStorage(OneWaySyncNoticeBoard.notifyKey) private var notifyOneWaySync"))
        #expect(rows.contains(".asksNotificationPermission(when: notifyOneWaySync, denied: $notificationsDenied)"))
        #expect(rows.contains(".asksNotificationPermission(when: notifyInBackground, denied: $notificationsDenied)"))
        #expect(rows.contains("BackgroundNotificationPermission.request {"))

        // Group by folder: Settings and the table read one key.
        #expect(settings.contains("Toggle(\"Group by folder\", isOn: $groupByFolder.loggingSettingsChange(\"sync.groupByFolder\"))"))
        let differences = try source("FileExplorer/Sources/FileExplorer/DifferencesView.swift")
        #expect(differences.contains("@AppStorage(DifferencesSettings.groupByFolderKey)"))
        #expect(!differences.contains("\"differencesGroupByFolder\""), "the table spells the key itself again")

        // The two rows the app supplies reach the pages, and the app supplies them.
        #expect(settings.contains("BrowseSettingsTab(page: subTab ?? .panes, onCustomizePaneBar: onCustomizePaneBar)"))
        #expect(settings.contains("Button(\"Customize Pane Bar…\", action: onCustomizePaneBar)"))
        #expect(settings.contains("EditSettingsTab(page: subTab ?? .text, savedSignatures: savedSignatures)"))
        let app = try source("../MacApp/ContentView.swift")
        #expect(app.contains("onCustomizePaneBar: { showPaneBarCustomizer = true }"))
        #expect(app.contains(".sheet(isPresented: $showPaneBarCustomizer)"))
        #expect(app.contains("PaneBarCustomizeSheet()"))
        #expect(app.contains("savedSignatures: AnyView(EditorPDFSavedSignaturesList())"))
    }
}
