import AppKit
import Design
import Events
import Foundation
import Sync

/// The buttons an Ask Claude card presses, through the code Settings' own buttons call.
///
/// What asks twice asks in the card, in Settings' words: the card shows `prompt`'s question with
/// Cancel, and only the red button runs `run`, which hands each owner's "if confirmed" a yes, so
/// there is no third question and nothing changes on Cancel. None can be undone, so none goes on
/// an undo stack; each says what it did.
@MainActor
public struct SettingsActions {

    /// What a press did, in words for the card and for Claude.
    public enum Result: Equatable, Sendable {
        case done(String)
        case refused(String)
    }

    /// The buttons a card runs itself. Any other button opens Settings at its place.
    public static let ids: Set<String> = [
        "general.runSetupAgain", "sources.refresh", "sources.showInFinder", "sources.rootReset", "sources.openAtReset",
        "sources.removeFolder", "people.defaultOrder", "people.remove", "sync.ignoredItemsClearAll",
        "organize.keptNamesClearAll", "intelligence.apiKeyRemove", "intelligence.costClear",
        "intelligence.savedSuggestionsClear", "advanced.logShowInFinder", "advanced.logClear", "advanced.sweep",
        "advanced.fileDigestsClear", "advanced.storageReportsClear", "advanced.resetSetup", "advanced.resetAll",
    ]

    public var settings: SettingsManager?
    public var sync: FileSyncManager?
    public var lookup: SettingsLookup?
    /// The app's own flows, which hide the chat while they run: setup, and the two resets.
    public var runSetup: () -> Void = {}
    public var resetSetup: () -> Void = {}
    public var resetAll: () -> Void = {}
    public var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    public var keychain: KeychainStore = SecItemKeychainStore()

    public init(settings: SettingsManager?, sync: FileSyncManager?, lookup: SettingsLookup?) {
        self.settings = settings
        self.sync = sync
        self.lookup = lookup
    }

    /// Settings' question for a button that asks twice; nil for one that runs on a click.
    public func prompt(_ id: String, target: String?) -> RemovalPrompt? {
        switch id {
        case "sources.removeFolder":
            return .removeFolderSource(named: sourceName(target))
        case "people.remove":
            let name = target.flatMap { sync?.filingPeopleStore?.person(id: $0)?.displayName } ?? "this person"
            return RemovalPrompt(messageText: PersonRemoval.title(name), informativeText: PersonRemoval.message, confirmTitle: "Remove")
        case "sync.ignoredItemsClearAll":
            return .clearIgnoredItems(count: sync?.ignoredItemsStore?.rootRelativePaths.count ?? 0)
        case "organize.keptNamesClearAll":
            return .clearKeptNames(count: sync?.keptNamesStore?.names.count ?? 0)
        case "intelligence.apiKeyRemove":
            let words = CloudKeyRow.removePrompt
            return RemovalPrompt(messageText: words.messageText, informativeText: words.informativeText, confirmTitle: words.confirmTitle)
        case "intelligence.costClear":
            let words = FilingSpendStore.clearPrompt
            return RemovalPrompt(messageText: words.messageText, informativeText: words.informativeText, confirmTitle: words.confirmTitle)
        case "intelligence.savedSuggestionsClear":
            return .clearSavedSuggestions(count: sync?.filingVerdictCacheCountNow ?? 0)
        case "advanced.logClear":
            return RemovalPrompt(messageText: Logger.clearPrompt.messageText, informativeText: Logger.clearPrompt.informativeText,
                                 confirmTitle: Logger.clearLogName)
        case "advanced.resetSetup":
            return RemovalPrompt(messageText: AdvancedSettingsTab.resetSetupPrompt.messageText,
                                 informativeText: AdvancedSettingsTab.resetSetupPrompt.informativeText, confirmTitle: "Reset")
        case "readability.columnWidths":
            // Asked only when All columns would release columns sized on their own.
            let stored = lookup?.defaults.string(forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
            let count = stored.flatMap(ColumnWidthOverrides.init(rawValue:))?.widths.count ?? 0
            return count > 0 ? .releaseColumnWidths(count: count) : nil
        case "advanced.resetAll":
            return RemovalPrompt(messageText: "Reset all settings?",
                                 informativeText: AdvancedSettingsTab.resetAllQuestion(raising: resetAllRaises()), confirmTitle: "Reset")
        default:
            return nil
        }
    }

    /// What Reset All would raise, from the values now: each setting it takes back to a default
    /// that lets Claude do more, and each source it turns back on. The limits are kept, so they
    /// never appear here.
    public func resetAllRaises() -> [String] {
        guard let lookup else { return [] }
        var raised: [String] = []
        for entry in SettingsCatalog.all where entry.raises != nil {
            guard let base = entry.defaultValue, let now = lookup.currentValue(entry), now != base,
                  !Self.keptByReset(entry), entry.raises(from: now, to: base) else { continue }
            raised.append("\(entry.label) back to \(SettingsLookup.label(base, entry))")
        }
        // A folder you added is removed by the reset, not turned back on.
        for source in settings?.availableProviders ?? []
        where settings?.isEnabled(source.id) == false && !FolderSource.isFolderSourceId(source.id) {
            raised.append("\(sourceName(source.id)) turned back on")
        }
        return raised
    }

    /// Presses the button. For one that asks twice, only after the card's question was answered;
    /// `scope` is what `scope(_:)` gave when it opened.
    public func run(_ id: String, target: String?, scope asked: String? = nil) async -> Result {
        if let asked, asked != scope(id) {
            return .refused("The comparison changed since you were asked, so nothing was cleared.")
        }
        switch id {
        case "general.runSetupAgain":
            runSetup()
            return .done("Setup is open.")
        case "sources.refresh":
            guard let settings else { return unavailable }
            await settings.discoverProviders()
            return .done("Refreshed: \(settings.availableProviders.count) sources.")
        case "sources.showInFinder":
            guard let settings, let target else { return unavailable }
            let root = settings.rootPath(for: target)
            guard !root.isEmpty else { return .refused("That source isn’t there right now.") }
            reveal(URL(fileURLWithPath: (root as NSString).expandingTildeInPath))
            return .done("Shown in Finder.")
        case "sources.rootReset":
            guard let settings, let target else { return unavailable }
            guard settings.hasRootOverride(for: target) else { return .refused("\(sourceName(target)) has no root of its own to reset.") }
            settings.resetPath(for: target)
            return .done("\(sourceName(target)) is back at its own root.")
        case "sources.openAtReset":
            guard let settings, let target else { return unavailable }
            guard settings.hasOpenAtOverride(for: target) else { return .refused("\(sourceName(target)) already opens at its default folder.") }
            settings.resetOpenAt(for: target)
            return .done("\(sourceName(target)) opens at its default folder again.")
        case "sources.removeFolder":
            guard let settings, let target else { return unavailable }
            guard FolderSource.isFolderSourceId(target) else { return .refused("Only a folder you added can be removed.") }
            let name = sourceName(target)
            ProviderSettingsSection.removeFolderSourceIfConfirmed(id: target, from: settings, confirm: { true })
            return .done("Removed \(name) from your sources. The folder and its files stay where they are.")
        case "people.remove":
            guard let store = sync?.filingPeopleStore, let target, let person = store.person(id: target) else { return unavailable }
            if let refusal = SettingsPeople(store: store).refusal { return .refused(refusal) }
            store.remove(id: target)
            return .done("Removed \(person.displayName). Their folders and files are as they were.")
        case "sync.ignoredItemsClearAll":
            guard let sync else { return unavailable }
            let count = sync.ignoredItemsStore?.rootRelativePaths.count ?? 0
            sync.clearAllIgnoredItems()
            return .done("Stopped ignoring \(count) item\(count == 1 ? "" : "s").")
        case "organize.keptNamesClearAll":
            guard let store = sync?.keptNamesStore else { return unavailable }
            let count = store.names.count
            store.stopKeepingAll()
            return .done("Cleared \(count) allowed name\(count == 1 ? "" : "s").")
        case "intelligence.apiKeyRemove":
            if let refusal = APIKeyRemoval.remove(from: keychain) { return .refused(refusal) }
            return .done("Removed the API key. Ask Claude and Refine need a key again to use Claude.")
        case "intelligence.costClear":
            FilingSpendStore.clearIfConfirmed(defaults: lookup?.defaults ?? .standard, confirm: { true })
            return .done("Cleared the recorded spend.")
        case "intelligence.savedSuggestionsClear":
            guard let sync else { return unavailable }
            let count = sync.filingVerdictCacheCountNow
            sync.clearFilingVerdictCache()
            return .done("Cleared \(count) saved suggestion\(count == 1 ? "" : "s").")
        case "advanced.logShowInFinder":
            reveal(Logger.shared.logFileURL)
            return .done("Shown in Finder.")
        case "advanced.logClear":
            Logger.shared.clearIfConfirmed { true }
            return .done("Cleared the Activity Log.")
        case "advanced.sweep":
            guard let sync else { return unavailable }
            sync.sweepOrphanedTempArtifactsNow()
            return .done("Swept: working files over an hour old went to the Trash.")
        case "advanced.fileDigestsClear":
            Logger.shared.info("User cleared the saved file digests")
            await ContentHashCache.forgetAllPersistedIndexes()
            return .done("Cleared the saved file digests. The next scan reads files again.")
        case "advanced.storageReportsClear":
            guard let sync else { return unavailable }
            Logger.shared.info("User cleared the saved Storage reports")
            sync.forgetStoredStorageLens()
            return .done("Cleared the saved Storage reports.")
        case "advanced.resetSetup":
            resetSetup()
            return .done("Setup was reset and is open.")
        case "advanced.resetAll":
            resetAll()
            return .done("Settings were reset. Kept: the folders you hid from Claude, your spending limits for Claude, and the record of what it has cost.")
        default:
            return .refused("That button is in Settings.")
        }
    }

    private var unavailable: Result { .refused("That can’t be done here right now.") }

    /// A source by name, unless its own folder is hidden from Claude: these words reach Claude.
    private func sourceName(_ target: String?) -> String {
        guard let provider = target.flatMap({ id in settings?.availableProviders.first { $0.id == id } }) else { return "this source" }
        return lookup?.isHidden(provider.rootPath) == true ? "a source hidden from Claude" : provider.displayName
    }

    /// What a question is about, taken when it opens: the pair of sources whose ignored items Clear
    /// All would empty. A press after the pair changed is refused, as Settings' own Clear All is.
    public func scope(_ id: String) -> String? {
        id == "sync.ignoredItemsClearAll" ? sync?.ignoredItemsStore?.activeKey : nil
    }

    /// Whether Reset All keeps this setting as it is.
    private static func keptByReset(_ entry: SettingEntry) -> Bool {
        if case .appStorage(let key, _, _) = entry.storage { return SettingsResetKeeps.keeps(key) }
        return false
    }
}
