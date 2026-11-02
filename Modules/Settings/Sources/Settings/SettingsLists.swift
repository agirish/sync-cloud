import Foundation
import Sync

/// The four lists an Ask Claude card edits (TE290 step 8) — Ignored name patterns, Ignored
/// items, Kept names, Hidden from Claude — through the owners Settings edits them with.
///
/// **One item at a time, as a yes or no.** A card's edit is "this item is in the list" turned on
/// or off, so its undo, its Changed from Chat line and its Revert hold that one item, never the
/// whole list, and each goes back only while the item still is (or isn't) there.
///
/// **Ignored items belong to a pair of sources.** An item's key carries the pair it was edited
/// under (`scoped`), and reads as unknown under any other, so an Undo after switching pairs
/// can't ignore a path in the wrong comparison.
@MainActor
public struct SettingsLists {
    public static let ids: Set<String> = ["sync.ignorePatterns", "sync.ignoredItems", "organize.keptNames", "intelligence.hidden"]

    public var settings: SettingsManager?
    public var sync: FileSyncManager?
    public var defaults: UserDefaults

    public init(settings: SettingsManager?, sync: FileSyncManager?, defaults: UserDefaults) {
        self.settings = settings
        self.sync = sync
        self.defaults = defaults
    }

    /// The list now, in Settings' order; nil when its owner isn't here.
    public func items(_ id: String) -> [String]? {
        switch id {
        case "sync.ignorePatterns": settings?.ignorePatterns
        case "sync.ignoredItems": sync?.ignoredItemsStore?.sortedPaths
        case "organize.keptNames": sync?.keptNamesStore.map { $0.names.sorted() }
        case "intelligence.hidden": AskClaudePrivacy.hiddenFolders(in: defaults)
        default: nil
        }
    }

    /// The item as an undo step and the record hold it: with the pair, for an ignored item.
    public func scoped(_ id: String, _ item: String) -> String {
        guard id == "sync.ignoredItems", let pair = sync?.ignoredItemsStore?.activeKey else { return item }
        return pair + "\n" + item
    }

    /// Whether the scoped item is in its list now; nil when that can't be told — the owner is
    /// missing, or the ignored item was edited under another pair.
    public func contains(_ id: String, scoped: String) -> Bool? {
        guard let item = unscoped(id, scoped), let items = items(id) else { return nil }
        return items.contains(item)
    }

    /// Puts the scoped item in its list (true) or takes it out (false).
    public func set(_ id: String, scoped: String, present: Bool) -> SettingsWriter.Outcome {
        guard let item = unscoped(id, scoped) else { return .refused("That list now belongs to another pair of sources.") }
        return present ? add(id, item) : remove(id, item)
    }

    /// Adds `item` as Settings would: a pattern is normalized, and a repeat or a blank refused.
    public func add(_ id: String, _ item: String) -> SettingsWriter.Outcome {
        switch id {
        case "sync.ignorePatterns":
            guard let settings else { return .refused("Ignored name patterns can’t be changed here.") }
            guard let pattern = IgnoreRules.normalized(item) else { return .refused("“\(item)” isn’t a name pattern.") }
            guard !settings.ignorePatterns.contains(pattern) else { return .refused("\(pattern) is already in the list.") }
            settings.addIgnorePattern(pattern)
        case "sync.ignoredItems":
            guard let store = sync?.ignoredItemsStore else { return .refused("Ignored items can’t be changed here.") }
            store.add([item])
        case "organize.keptNames":
            guard let store = sync?.keptNamesStore else { return .refused("Kept names can’t be changed here.") }
            store.keep(item)
        case "intelligence.hidden":
            AskClaudePrivacy.hide(item, in: defaults)
        default:
            return .refused("That isn’t a list.")
        }
        return .done
    }

    /// Takes `item` out, as Settings' remove does.
    public func remove(_ id: String, _ item: String) -> SettingsWriter.Outcome {
        guard items(id)?.contains(item) == true else { return .refused("That’s no longer in the list.") }
        switch id {
        case "sync.ignorePatterns": settings?.removeIgnorePattern(item)
        // Settings' own remove: the session's ignore under the current folder goes too.
        case "sync.ignoredItems": sync?.unignoreRootRelative(item)
        case "organize.keptNames": sync?.keptNamesStore?.stopKeeping(item)
        case "intelligence.hidden": AskClaudePrivacy.unhide(item, in: defaults)
        default: return .refused("That isn’t a list.")
        }
        return .done
    }

    /// Whether putting an item in (true) or taking it out (false) raises Claude's access: only
    /// taking something off Hidden from Claude does.
    public static func raises(_ id: String, present: Bool) -> Bool {
        id == "intelligence.hidden" && !present
    }

    /// Whether a card may offer to add an item Claude names: a pattern only. Claude never sees
    /// paths it could name for the others, and Hidden from Claude adds only through Choose….
    public static func takesClaudesPick(_ id: String) -> Bool { id == "sync.ignorePatterns" }

    /// "added ~$*", "removed Taxes", "hid a folder": the edit in words, for the card, the record and
    /// Claude. Nothing on Hidden from Claude is ever named, and nor is an item inside it.
    public static func edit(_ id: String, _ item: String, present: Bool, isHidden: (String) -> Bool) -> String {
        if id == "intelligence.hidden" { return present ? "hid a folder" : "unhid a folder" }
        return (present ? "added " : "removed ") + (isHidden(item) ? "an item hidden from Claude" : item)
    }

    /// The item without its pair, for showing; the item itself for the other lists.
    public static func shown(_ id: String, _ scoped: String) -> String {
        guard id == "sync.ignoredItems", let cut = scoped.firstIndex(of: "\n") else { return scoped }
        return String(scoped[scoped.index(after: cut)...])
    }

    /// The item without its pair; nil for an ignored item edited under another pair.
    private func unscoped(_ id: String, _ scoped: String) -> String? {
        guard id == "sync.ignoredItems" else { return scoped }
        guard let cut = scoped.firstIndex(of: "\n") else { return scoped }
        guard String(scoped[..<cut]) == sync?.ignoredItemsStore?.activeKey else { return nil }
        return String(scoped[scoped.index(after: cut)...])
    }
}
