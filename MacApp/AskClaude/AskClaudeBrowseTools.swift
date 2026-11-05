import AppKit
import Foundation
import Settings
import Sync
import UniformTypeIdentifiers
import Events

/// Ask Claude’s tools: they look, move the view and offer cards. Nothing here changes a file on
/// disk; a card changes one only on the person's click.
///
/// Reads the pane first, then the disk. A folder the Browse pane has loaded is read from its tree,
/// which is what the person sees. One it hasn’t is listed from disk, names and metadata only
/// (`AskClaudeDisk`), so an unloaded folder doesn't cost a wasted round; names are searched
/// through Spotlight’s index.
@MainActor
final class AskClaudeBrowseTools: AskClaudeToolRunning {

    /// What the tools need from the window, read fresh at each call: the person may have moved
    /// between two tool calls.
    struct Context {
        let inBrowse: Bool
        let sourceName: String
        /// The source’s root, absolute.
        let root: String
        /// The folder on screen, relative to the root.
        let folder: String
        let sort: SortOption
        /// The folder’s direct items, as the pane lists them; nil when that folder isn’t loaded.
        let items: (_ absoluteFolder: String) -> [FileNode]?
        /// A node by absolute path, if the pane has it.
        let node: (_ absolutePath: String) -> FileNode?
        let selection: Set<String>
        /// Why the view can’t be moved right now, or nil when it can.
        let busyReason: String?
        let goTo: (_ absoluteFolder: String) -> Void
        let select: (_ absolutePaths: Set<String>) -> Void
        /// The Browse pane's source, and every source it can switch to.
        var sourceID = ""
        var sources: [Source] = []
        /// Switches the Browse pane to a source, landing on a folder in it when one is given.
        var switchSource: (_ id: String, _ absoluteFolder: String?) -> Void = { _, _ in }
        /// Switches workspace by name; false for a name that isn't one.
        var switchWorkspace: (_ name: String) -> Bool = { _ in false }
        /// Opens a file in the Edit workspace.
        var openInEdit: (_ absolutePath: String) -> EditOutcome = { _ in .notNow }
        /// Opens a PDF form in Edit with Fill & Sign on, once it has loaded.
        var openForFill: (_ absolutePath: String) async -> FillOutcome = { _ in .notNow }
        /// The Never show Claude list, absolute.
        var hidden: [String] = []
        /// Built from `hidden` at first use and kept with this context, so a folder's rows share
        /// their parent's resolved spelling.
        var hiddenMatcher = MatcherBox()
        func isHidden(_ path: String) -> Bool { hiddenMatcher.matcher(for: hidden).isHidden(path) }
        /// The folders shared without asking, absolute; hidden wins over them.
        var shared: [String] = []
        var sharedMatcher = MatcherBox()
        /// Whether what's in `path` goes without a card: a folder shared without asking holds it,
        /// and it is not hidden.
        func sharesFreely(_ path: String) -> Bool {
            !isHidden(path) && sharedMatcher.matcher(for: shared).holds(path)
        }
        /// Apple Intelligence's answers go without a card for the rest of this chat (the card's
        /// tick); page text and whole documents still ask.
        var sharesAnswers = false
        /// Lookups beyond the folder on screen go without a card for the rest of this chat (the
        /// lookup card's tick).
        var sharesNames = false
        /// Whether a folder is the one on screen or inside it: its names are there to see, so a
        /// lookup in it goes without a card. Any other waits on one. By where it really is: a link
        /// inside the folder on screen to a folder elsewhere is not on screen, as a shared folder's
        /// link is not shared.
        func isOnScreen(_ absolute: String) -> Bool {
            onScreenMatcher.matcher(for: [folder.isEmpty ? root : (root as NSString).appendingPathComponent(folder)]).holds(absolute)
        }
        var onScreenMatcher = MatcherBox()
        /// Whether a lookup's names go without a card: on screen, shared, or ticked for the chat.
        func lookupGoes(_ folder: (absolute: String, relative: String, label: String)) -> Bool {
            !isHidden(folder.absolute) && (isOnScreen(folder.absolute) || sharesNames || sharesFreely(folder.absolute))
        }
        /// The pane's tabs, the one on screen first, and how to switch or open one.
        var tabs: [Tab] = []
        var switchTab: (_ id: UUID) -> Void = { _ in }
        var addTab: (_ absoluteFolder: String) -> Void = { _ in }
        /// Closes the pane's tabs by id; the last one never closes.
        var closeTabs: (_ ids: [UUID]) -> Void = { _ in }
        /// Each side's live source and folder (left true), and the move that points one side at a
        /// source, a folder, or both — Compare's two sides.
        var pane: (_ isLeft: Bool) -> Pane = { _ in Pane(sourceID: "", root: "", folder: "") }
        var movePane: (_ isLeft: Bool, _ sourceID: String?, _ absoluteFolder: String?) -> Void = { _, _, _ in }
        /// Compare's differences as the list shows them, and the comparison they come from; nil
        /// when Compare has no two sides.
        var differences: () -> [FileDifference] = { [] }
        var comparison: () -> AskClaudeDifferences.Comparison? = { nil }
        /// Scan Again; false when it can't start.
        var rescan: () -> Bool = { false }
        /// Narrows Compare's differences list to a kind and selects rows there; false when it can't.
        var showDifferences: (_ kind: AskClaudeDifferences.Kind, _ ids: Set<UUID>) -> Bool = { _, _ in false }
        /// Why Compare's list can't show rows right now, though nothing else is busy — a guided
        /// review holds it; nil when it can. Asked before Compare is switched to.
        var differencesHeldBy: () -> String? = { nil }
        /// Clock, for how old a comparison is.
        var now: () -> Date = Date.init
        /// How long a Scan Again asked for is given to land before the list read before it is
        /// answered from; a test shortens it.
        var scanStartWait: Duration = .seconds(5)
        /// Where a file belongs by the Filing profile, preferring a place they named, absolute;
        /// nil when filing help can't run.
        var whereToFile: (_ path: String, _ place: String?) async -> FilingHelpAnswer? = { _, _ in nil }
        /// The rule a correction teaches, from page 1; nil when the folder isn't in a survey.
        var ruleFromCorrection: (_ path: String, _ folder: String, _ name: String, _ words: [String], _ also: [String],
                                 _ page: String?) -> Result<AutomationRuleProposer.Correction, AutomationRuleProposer.CorrectionRefusal>? = { _, _, _, _, _, _ in nil }
        /// A folder of the survey by what they called it ("Travel"), absolute; nil when it has none.
        var surveyFolder: (_ name: String) -> String? = { _ in nil }
        /// The folder the survey covers, absolute; nil with no survey.
        var surveyRoot: String?
        /// The root of the survey filing help answers from for a path: it follows the source, so a
        /// place in Google Drive gets Google Drive's own survey. Nil uses ``surveyRoot``.
        var surveyRootFor: ((_ path: String) -> String?)?

        /// The survey that answers for `path`, absolute; nil with no survey.
        func survey(for path: String) -> String? { surveyRootFor.map { $0(path) } ?? surveyRoot }
        /// Why a change can't run: hidden, gone, taken, another disk…; nil when it can.
        /// `creating` are folders the same card makes.
        var planRefusal: (_ change: AskClaudePlan.Change, _ creating: Set<String>) -> String? = { _, _ in nil }
        /// The items on this chat's cards so far, absolute: a filing card's Next shows the files
        /// none of them showed.
        var shownOnCards: Set<String> = []
        /// Whether a file is only in the cloud, for the already-filed check, which never reads one.
        var isCloudOnly: (_ path: String) -> Bool = { MaterializationStatus.isCloudOnlyIfKnown(atPath: $0) == true }
        /// Organize's Refine with Claude is set up, so the card may offer it.
        var canRefineFiling = false
        /// The pane's Back (false) and Forward (true); false when there was nowhere to go.
        var history: (_ forward: Bool) -> Bool = { _ in false }
        /// Quick Look on a file.
        var preview: (_ url: URL) -> Void = { _ in }
        /// View changes; each false when the value isn't one.
        var setSort: (_ name: String) -> Bool = { _ in false }
        var setHiddenFiles: (_ shown: Bool) -> Void = { _ in }
        var setMode: (_ name: String) -> Bool = { _ in false }
        /// Opens settings (and a tab), activity, help or the Trash; false for a place that isn't one.
        var showPlace: (_ place: String, _ tab: String?, _ visible: Bool) -> Bool = { _, _, _ in false }
        /// The settings tool's answers; nil where there is no app to read.
        var settingsLookup: SettingsLookup?
        /// Whether the chat panel is on screen; Claude changes nothing itself while it isn't.
        var chatIsOpen = true
        /// Writes a setting Claude may change itself, through its owner.
        var setSetting: (_ id: String, _ value: SettingValue, _ target: String?) -> SettingsWriter.Outcome = { _, _, _ in
            .refused("Settings can’t be changed here.")
        }
    }

    struct Tab: Equatable {
        let id: UUID
        let title: String
        /// Pinned tabs survive "every tab but this one", as they do the strip's Close Other Tabs.
        var isPinned = false
        /// At a hidden folder: titled "(hidden)", and never switched to.
        var isHidden = false
    }

    struct Pane: Equatable {
        let sourceID: String
        let root: String
        /// Relative to `root`.
        let folder: String
    }

    /// How a hand-off to Edit ended.
    enum EditOutcome: Equatable {
        case opened
        /// Edit loaded it and couldn't show it (a kind it can't open, say).
        case refused
        /// Canceled, or waiting on a question about the open document; it may open after that.
        case notNow
    }

    /// One matcher for the list it was built from, rebuilt if the list differs.
    final class MatcherBox {
        private var built: (list: [String], matcher: AskClaudePrivacy.Matcher)?
        func matcher(for list: [String]) -> AskClaudePrivacy.Matcher {
            if let built, built.list == list { return built.matcher }
            let matcher = AskClaudePrivacy.Matcher(list)
            built = (list, matcher)
            return matcher
        }
    }

    struct Source: Equatable {
        let id: String
        let name: String
        let root: String
    }

    /// A source whose own folder is hidden from Claude, as Claude is told it.
    static let hiddenSourceName = "a source hidden from you"

    /// A source's name as Claude is told it: one whose own folder is hidden isn't named, since
    /// a folder source is named after its folder.
    static func spokenName(_ provider: CloudProvider, isHidden: (String) -> Bool) -> String {
        isHidden((provider.rootPath as NSString).expandingTildeInPath) ? hiddenSourceName : provider.displayName
    }

    /// The sources as Claude is told them, with absolute roots.
    static func spokenSources(_ providers: [CloudProvider], isHidden: (String) -> Bool) -> [Source] {
        providers.map { Source(id: $0.id, name: spokenName($0, isHidden: isHidden), root: ($0.rootPath as NSString).expandingTildeInPath) }
    }

    static let maxListed = 60
    static let maxFound = 50

    private let context: () -> Context
    private let listDisk: (String) async -> [FileNode]?
    private let searchNames: ([String], String) async -> [String]?
    private let statDisk: (String) -> FileNode?
    private let openFile: (URL) -> Bool
    private let extract: (String) async -> [String]?
    private let read: (String) async -> AskClaudeReading.Read?
    private let answerOnDevice: (_ question: String, _ text: String, _ file: String) async -> AskClaudeReading.OnDeviceAnswer
    private let searchContents: ([String], String) async -> [String]?
    private let isCloudOnly: (String) -> Bool?

    init(context: @escaping () -> Context,
         listDisk: @escaping (String) async -> [FileNode]? = { await AskClaudeDisk.list($0) },
         searchNames: @escaping ([String], String) async -> [String]? = { await AskClaudeDisk.findNames($0, under: $1) },
         statDisk: @escaping (String) -> FileNode? = { AskClaudeDisk.node(atPath: $0) },
         openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         extract: @escaping (String) async -> [String]? = { await AskClaudeReading.extract($0) },
         read: @escaping (String) async -> AskClaudeReading.Read? = { await AskClaudeReading.read($0) },
         answerOnDevice: @escaping (String, String, String) async -> AskClaudeReading.OnDeviceAnswer = { await AskClaudeReading.answerOnDevice($0, from: $1, file: $2) },
         searchContents: @escaping ([String], String) async -> [String]? = { await AskClaudeDisk.findContents($0, under: $1) },
         isCloudOnly: @escaping (String) -> Bool? = { MaterializationStatus.isCloudOnlyIfKnown(atPath: $0) }) {
        self.context = context
        self.isCloudOnly = isCloudOnly
        self.extract = extract
        self.read = read
        self.answerOnDevice = answerOnDevice
        self.searchContents = searchContents
        self.openFile = openFile
        self.listDisk = listDisk
        self.searchNames = searchNames
        self.statDisk = statDisk
    }

    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        var ctx = context()
        // Look tools and open work from any workspace: they read the source, not the pane. A tool
        // that moves or selects in the Browse pane takes them to Browse first, and says so.
        var movedToBrowse: String?
        // A call that would be refused is refused before it moves them anywhere.
        if !ctx.inBrowse, Self.needsBrowsePane(call), let refusal = preflight(call, ctx, handles) { return refusal }
        if !ctx.inBrowse, Self.needsBrowsePane(call) {
            guard ctx.busyReason == nil, ctx.switchWorkspace("Browse") else {
                return AskClaudeToolOutcome(result: "That needs the Browse pane, and the window is busy.", isError: true,
                                            step: "Couldn’t reach Browse")
            }
            try? await Task.sleep(for: .milliseconds(300))
            ctx = context()
            movedToBrowse = "Moved you to Browse"
        }
        let outcome = await dispatch(call, ctx, &handles)
        guard let movedToBrowse, outcome.movedView == nil else { return outcome }
        return AskClaudeToolOutcome(result: outcome.result, isError: outcome.isError, step: outcome.step,
                                    movedView: movedToBrowse, passage: outcome.passage, download: outcome.download,
                                    filing: outcome.filing, plan: outcome.plan, choices: outcome.choices,
                                    rule: outcome.rule, settings: outcome.settings)
    }

    /// What a Browse-pane call would refuse anyway (an unknown or hidden handle, a folder that isn't
    /// there or is hidden), checked before the switch to Browse it would otherwise cost them.
    private func preflight(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome? {
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t move the view right now: \(busy).", isError: true, step: "Didn’t move the view: \(busy)")
        }
        let named = ([call.string("handle")].compactMap { $0 } + (call.strings("handles") ?? []))
        for handle in named {
            guard let path = handles.path(for: handle) else { return unknownHandle(handle) }
            if ctx.isHidden(path) { return hiddenFolder() }
        }
        switch AskClaudeToolCatalog.Name(rawValue: call.name) {
        case .goTo:
            // The source and folder it names, in that source.
            var root = ctx.root
            var sourceName = ctx.sourceName
            if let name = call.string("source")?.trimmingCharacters(in: .whitespaces).nonEmpty {
                guard let source = Self.source(named: name, in: ctx.sources) else {
                    return AskClaudeToolOutcome(result: "There is no source called \(name). Sources: \(ctx.sources.map(\.name).joined(separator: ", ")).",
                                                isError: true, step: "No source \(name)")
                }
                // A source whose own folder is hidden is a hidden folder to move to.
                if ctx.isHidden(source.root) { return hiddenFolder() }
                root = source.root
                sourceName = source.name
            }
            if let folderArg = call.string("folder") {
                guard let folder = Self.resolve(folderArg, root: root) else { return badFolder(folderArg) }
                if ctx.isHidden(folder.absolute) { return hiddenFolder() }
                guard Self.isFolder(folder.absolute) else {
                    return AskClaudeToolOutcome(result: "There is no folder \(folder.label) in \(sourceName).", isError: true,
                                                step: Self.sentence("No folder \(folder.label)"))
                }
            }
            if let name = call.string("tab"), Self.tab(named: name, in: ctx.tabs) == nil {
                return AskClaudeToolOutcome(result: "There’s no tab called \(name). Tabs: \(ctx.tabs.map(\.title).joined(separator: ", ")).",
                                            isError: true, step: "No tab \(name)")
            }
            if let history = call.string("history")?.lowercased(), history != "back", history != "forward" {
                return AskClaudeToolOutcome(result: "history is back or forward.", isError: true, step: "No history \(history)")
            }
        case .view:
            let sorts = ["name", "kind", "date", "date modified", "size", "tags"]
            if let sort = call.string("sort"), !sorts.contains(sort.lowercased()) {
                return AskClaudeToolOutcome(result: "Sort by name, kind, date, size or tags.", isError: true, step: "No sort called \(sort)")
            }
            if let mode = call.string("mode"), !["columns", "list", "tree"].contains(mode.lowercased()) {
                return AskClaudeToolOutcome(result: "The view is columns or list.", isError: true, step: "No view called \(mode)")
            }
        case .open, .reveal:
            if let path = call.string("handle").flatMap(handles.path(for:)),
               Self.relativeIfInside(path, root: ctx.root) == nil, Self.closestSource(containing: path, in: ctx.sources) == nil {
                return AskClaudeToolOutcome(result: "That item isn’t in any source SyncCloud shows.", isError: true,
                                            step: "Couldn’t show it: not in a source")
            }
            if AskClaudeToolCatalog.Name(rawValue: call.name) == .open, let path = call.string("handle").flatMap(handles.path(for:)),
               let node = ctx.node(path) ?? statDisk(path) {
                if node.isDirectory {
                    return AskClaudeToolOutcome(result: "\(node.name) is a folder. Use go_to to show it.", isError: true, step: "Didn’t open a folder")
                }
                if Self.launches(path) {
                    return AskClaudeToolOutcome(result: "\(node.name) is an app, script, installer or shortcut, and Ask Claude doesn’t open those. Reveal it, and they can open it themselves.",
                                                isError: true, step: "Didn’t open \(node.name): it would run something")
                }
                // A card, not a trip to Browse: nothing opens until they download it.
                if let size = largeCloudOnly(node, path), let handle = call.string("handle") {
                    let mode = call.string("in")?.lowercased()
                    return offerDownload(node, path, handle: handle, size: size, purpose: .open(in: mode == "preview" ? mode : nil), ctx)
                }
            }
        default:
            break
        }
        return nil
    }

    /// Tools that act on the Browse pane itself.
    static func needsBrowsePane(_ call: AskClaudeToolCall) -> Bool {
        switch AskClaudeToolCatalog.Name(rawValue: call.name) {
        case .reveal, .select, .view: return true
        case .goTo:
            // A side of Compare is set in Compare, not Browse.
            guard call.string("pane") == nil else { return false }
            return call.string("folder") != nil || call.string("source") != nil
                || call.string("history") != nil || call.string("tab") != nil
        // Every open but Edit's shows the file in the Browse pane first.
        case .open: return call.string("in")?.lowercased() != "edit"
        default: return false
        }
    }

    /// SyncCloud's own settings: find, get and changed read them; show puts a card in the chat;
    /// set is Claude's own change, for the few it may make.
    private func settings(_ call: AskClaudeToolCall, _ ctx: Context) async -> AskClaudeToolOutcome {
        guard let lookup = ctx.settingsLookup else {
            return AskClaudeToolOutcome(result: "Settings can’t be looked up here.", isError: true, step: "Couldn’t look up settings")
        }
        switch (call.string("action") ?? "").lowercased() {
        case "find":
            let words = call.string("words") ?? ""
            return AskClaudeToolOutcome(result: await lookup.find(words), step: "Looked up settings for “\(words)”")
        case "get":
            let ids = call.strings("ids") ?? call.string("id").map { [$0] } ?? []
            return AskClaudeToolOutcome(result: await lookup.get(ids),
                                        step: ids.count == 1 ? "Read a setting" : "Read \(ids.count) settings")
        case "changed":
            return AskClaudeToolOutcome(result: await lookup.changed(), step: "Listed changed settings")
        case "show":
            return showSettings(call, lookup)
        case "set":
            return setSetting(call, ctx, lookup)
        default:
            return AskClaudeToolOutcome(result: "action is find, get, changed, show or set.", isError: true, step: "No such settings action")
        }
    }

    /// The controls a card can hold in this version; the rest open Settings.
    static func cardHolds(_ control: SettingControl) -> Bool {
        switch control {
        case .toggle, .segmented, .menu, .stepper, .slider, .swatches, .secret, .text, .folder, .button: true
        default: false
        }
    }

    /// Whether `entry` can be a card in this version: its control can, it is one of the lists, or
    /// it is a person or Add Person, which bring their own fields.
    static func cardHolds(_ entry: SettingEntry) -> Bool {
        if entry.id.hasPrefix("people.") { return entry.id == "people.edit" || entry.id == "people.add" || SettingsActions.ids.contains(entry.id) }
        if SettingsLists.ids.contains(entry.id) { return true }
        switch entry.control {
        case .button, .secret: return true
        case .folder where entry.id == "sources.addFolder": return true
        default:
            // A control whose click the writer always refuses is never offered.
            return cardHolds(entry.control) && SettingsWriter.canWrite(entry)
        }
    }

    /// Whether `source` is the kind of source `entry` is about: a folder you added, a cloud
    /// account, or any; a sync pair isn't a source at all.
    static func fits(_ entry: SettingEntry, _ source: CloudProvider) -> Bool {
        switch entry.target {
        case .folderSource: FolderSource.isFolderSourceId(source.id)
        case .cloudSource: !source.isLocalFolder
        case .syncPair: false
        default: true
        }
    }

    /// Puts a card of settings in the chat. Every item is checked first — a setting that exists,
    /// can be a card, has its target, and a pick that is one of its own values — so a card never
    /// offers something its click couldn't do.
    private func showSettings(_ call: AskClaudeToolCall, _ lookup: SettingsLookup) -> AskClaudeToolOutcome {
        let given = call.input["items"]?.arrayValue ?? []
        guard !given.isEmpty else {
            return AskClaudeToolOutcome(result: "Give items: each an id, and a target and pick when needed.", isError: true,
                                        step: "No settings to show")
        }
        var rows: [AskClaudeSettingCard.Row] = []
        var shown: [String] = []
        for item in given {
            guard let id = item["id"]?.stringValue, let entry = SettingsCatalog.entry(id) else {
                return AskClaudeToolOutcome(result: "\(item["id"]?.stringValue ?? "An item") isn’t a setting id. Use find.", isError: true,
                                            step: "No such setting")
            }
            guard entry.tier != .notInChat, entry.tier != .readOnly, entry.tier != .viewTools else {
                return AskClaudeToolOutcome(result: "\(entry.label) isn’t offered on a card.", isError: true, step: "Not a card")
            }
            guard Self.cardHolds(entry) else {
                return AskClaudeToolOutcome(
                    result: "\(entry.label) can’t be a card in this version. Open Settings at it with show_in_app (place settings, tab: \(entry.label)).",
                    isError: true, step: "\(entry.label) isn’t a card yet")
            }
            let targetID: String?
            switch Self.target(item["target"]?.stringValue, of: entry, lookup) {
            case .success(let id): targetID = id
            case .failure(let refused): return refused.outcome
            }
            var pick: SettingValue?
            if let text = item["pick"]?.stringValue, SettingsLists.ids.contains(entry.id) {
                // A list's pick is an item to add, and only a pattern may come from Claude: it
                // never sees the paths and names the other lists hold.
                guard SettingsLists.takesClaudesPick(entry.id), let pattern = IgnoreRules.normalized(text) else {
                    return AskClaudeToolOutcome(
                        result: SettingsLists.takesClaudesPick(entry.id) ? "“\(text)” isn’t a name pattern." : "Only they can add to \(entry.label); show it without a pick.",
                        isError: true, step: "Not a pick for \(entry.label)")
                }
                pick = .string(pattern)
            } else if item["pick"]?.stringValue != nil, entry.control == .folder {
                // A path comes from their Choose…, never from Claude.
                return AskClaudeToolOutcome(result: "Claude never fills in a folder; show \(entry.label) without a pick, and they choose it.",
                                            isError: true, step: "Not a pick for \(entry.label)")
            } else if let text = item["pick"]?.stringValue, entry.control == .text {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let others = (lookup.settings?.availableProviders ?? []).filter { $0.id != targetID }.map(\.displayName)
                // The inbox is a folder name inside the source: never a path that leaves it.
                let leaves = entry.id == "organize.inbox" && (trimmed.contains("/") || trimmed.contains("..") || trimmed.hasPrefix("~"))
                guard SettingsWriter.acceptsClaudesText(trimmed), !leaves, !(entry.id == "sources.name" && others.contains(trimmed)) else {
                    return AskClaudeToolOutcome(result: "“\(text)” can’t be offered for \(entry.label): one line of up to 64 characters, and not another source’s name.",
                                                isError: true, step: "Not a pick for \(entry.label)")
                }
                pick = .string(trimmed)
            } else if let text = item["pick"]?.stringValue {
                guard let value = SettingsCatalog.value(text, for: entry) else {
                    return AskClaudeToolOutcome(result: "“\(text)” isn’t one of \(entry.label)’s choices. get it for its choices.",
                                                isError: true, step: "Not a choice for \(entry.label)")
                }
                pick = value
            }
            rows.append(AskClaudeSettingCard.Row(id: entry.id, target: targetID, pick: pick?.stored))
            shown.append(entry.label + (pick.map { " (suggested \(SettingsLookup.label($0, entry)))" } ?? ""))
        }
        let title = call.string("title").map(Self.cardTitle).flatMap { $0.isEmpty ? nil : $0 }
        let card = AskClaudeSettingCard(title: rows.count > 1 ? title : nil, rows: rows)
        return AskClaudeToolOutcome(
            result: "Showed a card: \(shown.joined(separator: "; ")). Their click on it changes the setting, and what they do reaches you with their next question. Don’t say it’s changed.",
            step: rows.count == 1 ? "Showed \(shown[0])" : "Showed \(rows.count) settings", settings: card)
    }

    /// A refusal as the tool's answer, carried through a `Result`.
    struct Refused: Error {
        let outcome: AskClaudeToolOutcome
    }

    /// The source a setting belongs to, by its id, from what Claude named it (its id or its name);
    /// nil for an app-wide setting.
    private static func target(_ given: String?, of entry: SettingEntry, _ lookup: SettingsLookup) -> Result<String?, Refused> {
        guard entry.target != .app else { return .success(nil) }
        if entry.target == .person {
            let people = lookup.people()
            guard let given, let person = people.first(where: { $0.id == given })
                    ?? people.first(where: { $0.displayName.compare(given, options: .caseInsensitive) == .orderedSame }) else {
                return .failure(Refused(outcome: AskClaudeToolOutcome(
                    result: people.isEmpty ? "There are no people to edit yet. Show people.add for Add Person."
                        : "\(entry.label) is for one person: give target, one of " + people.map(\.displayName).joined(separator: ", ") + ".",
                    isError: true, step: "Which person?")))
            }
            return .success(person.id)
        }
        let sources = (lookup.settings?.availableProviders ?? []).filter { fits(entry, $0) }
        // A source whose own folder is hidden is never named, and so is matched by its id alone.
        let spoken = { (source: CloudProvider) in spokenName(source, isHidden: lookup.isHidden) }
        guard let given, let source = sources.first(where: { $0.id == given || (spoken($0) != hiddenSourceName && $0.displayName == given) }) else {
            return .failure(Refused(outcome: AskClaudeToolOutcome(
                result: sources.isEmpty ? "\(entry.label) has no source here it applies to; it’s in Settings ▸ \(entry.tabName)."
                    : "\(entry.label) belongs to a source: give target, one of " + sources.map(spoken).joined(separator: ", ") + ".",
                isError: true, step: "Which source?")))
        }
        return .success(source.id)
    }

    /// Claude's own change to a setting: only one `get` says it may make (a Direct setting, or one
    /// that lowers its own reach), and only while the chat is on screen, so the card showing it,
    /// with Undo, is in front of them.
    private func setSetting(_ call: AskClaudeToolCall, _ ctx: Context, _ lookup: SettingsLookup) -> AskClaudeToolOutcome {
        guard let id = call.string("id"), let entry = SettingsCatalog.entry(id) else {
            return AskClaudeToolOutcome(result: "\(call.string("id") ?? "That") isn’t a setting id. Use find.", isError: true,
                                        step: "No such setting")
        }
        guard ctx.chatIsOpen else {
            return AskClaudeToolOutcome(result: "Not changed: the chat is closed, so they wouldn’t see the change or its Undo.",
                                        isError: true, step: "Left \(entry.label) alone: the chat is closed")
        }
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(
                result: "Not changed: \(busy), which hides this chat, so they wouldn’t see the change or its Undo. Say so; it can change once that’s closed.",
                isError: true, step: "Left \(entry.label) alone: \(busy)")
        }
        guard let text = call.string("value"), let value = SettingsCatalog.value(text, for: entry) else {
            return AskClaudeToolOutcome(result: "“\(call.string("value") ?? "")” isn’t one of \(entry.label)’s choices. get it for its choices.",
                                        isError: true, step: "Not a choice for \(entry.label)")
        }
        let targetID: String?
        switch Self.target(call.string("target"), of: entry, lookup) {
        case .success(let id): targetID = id
        case .failure(let refused): return refused.outcome
        }
        let current = lookup.currentValue(entry, target: targetID)
        let now = SettingsLookup.label(value, entry)
        if current == value {
            return AskClaudeToolOutcome(result: "\(entry.label) is already \(now). Nothing changed.", step: "\(entry.label) is already \(now)")
        }
        if let why = ClaudeSettingRule.refusal(entry, from: current, to: value, defaults: lookup.defaults) {
            return AskClaudeToolOutcome(result: "Not changed: \(why) Offer it on a card with show; their click changes it.",
                                        isError: true, step: "Left \(entry.label) for their click")
        }
        // Stopped, or replaced by New Chat: its card would never reach the chat, so nothing changes.
        guard !Task.isCancelled else {
            return AskClaudeToolOutcome(result: "Not changed: they stopped the question.", isError: true,
                                        step: "Left \(entry.label) alone: stopped")
        }
        switch ctx.setSetting(entry.id, value, targetID) {
        case .done:
            let was = current.map { SettingsLookup.label($0, entry) }
            let card = AskClaudeSettingCard(rows: [.init(id: entry.id, target: targetID, changedFrom: current?.stored, byClaude: true)])
            return AskClaudeToolOutcome(
                result: "Done: \(entry.label) is now \(now)" + (was.map { " (was \($0))" } ?? "") + ". A card shows it with Undo.",
                step: "Changed \(entry.label) to \(now)", settings: card)
        case .refused(let why):
            return AskClaudeToolOutcome(result: "Not changed: \(why)", isError: true, step: "Couldn’t change \(entry.label)")
        }
    }

    /// Claude's card title, held to what a title should be: one short line, no control or
    /// direction-changing characters.
    static func cardTitle(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces).prefix(64).description
    }

    private func dispatch(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        // The Never show Claude list: a hidden item can't be named into any tool.
        let named = ([call.string("handle")].compactMap { $0 } + (call.strings("handles") ?? [])).compactMap { handles.path(for: $0) }
        if named.contains(where: { ctx.isHidden($0) }) {
            return AskClaudeToolOutcome(result: "That item is on their Hidden from Claude list. Don’t ask about it or guess what it holds.",
                                        isError: true, step: "Left alone: hidden from Claude")
        }
        switch AskClaudeToolCatalog.Name(rawValue: call.name) {
        case .readText: return await readText(call, ctx, handles)
        case .findInContents: return await findInContents(call, ctx, &handles)
        case .view: return view(call, ctx)
        case .showInApp:
            let place = (call.string("place") ?? "").lowercased()
            if let busy = ctx.busyReason {
                return AskClaudeToolOutcome(result: "Can’t open it right now: \(busy).", isError: true, step: "Didn’t open \(place): \(busy)")
            }
            let visible = call.input["visible"]?.boolValue ?? true
            guard ctx.showPlace(place, call.string("tab"), visible) else {
                return AskClaudeToolOutcome(result: "Places are settings, activity, help, trash, info and sidebar; a settings tab or setting must be one Settings has.",
                                            isError: true, step: "No place called \(place)")
            }
            let names = ["info": "the Info inspector", "sidebar": "the sidebar"]
            if let name = names[place] {
                let did = visible ? "Showed \(name)" : "Hid \(name)"
                return AskClaudeToolOutcome(result: did + ".", step: did)
            }
            let label = place == "settings" ? "Settings" + (call.string("tab").map { " ▸ \($0.capitalized)" } ?? "") : place.capitalized
            return AskClaudeToolOutcome(result: "Opened \(label).", step: "Opened \(label)", movedView: "Opened \(label)")
        case .settings: return await settings(call, ctx)
        case .listFolder: return await listFolder(call, ctx, &handles)
        case .findByName: return await findByName(call, ctx, &handles)
        case .fileDetails: return fileDetails(call, ctx, handles)
        case .goTo: return await goTo(call, ctx)
        case .open: return await open(call, ctx, handles)
        case .reveal: return await reveal(call, ctx, handles)
        case .select: return select(call, ctx, handles)
        case .closeTabs: return closeTabs(call, ctx)
        case .differences: return await differences(call, ctx, &handles)
        case .whereToFile: return await whereToFile(call, ctx, handles)
        case .fileLooseFiles: return await fileLooseFiles(call, ctx)
        case .proposeChanges: return proposeChanges(call, ctx, handles)
        case .offerRule: return await offerRule(call, ctx, handles)
        case .pdf: return await pdf(call, ctx, handles)
        case nil:
            return AskClaudeToolOutcome(result: "There is no tool called \(call.name).", isError: true,
                                        step: "Asked for an unknown tool")
        }
    }

    // MARK: Look

    private func listFolder(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let folder = Self.resolve(call.string("folder") ?? "", root: ctx.root) else {
            return badFolder(call.string("folder"))
        }
        // Checked before anything is read, so a hidden folder answers the same whether a path in
        // it exists or not.
        if ctx.isHidden(folder.absolute) { return hiddenFolder() }
        var loaded = ctx.items(folder.absolute)
        if loaded == nil { loaded = await listDisk(folder.absolute) }
        guard let everything = loaded else {
            return AskClaudeToolOutcome(result: "\(folder.label) couldn’t be read: it may not exist, or the cloud is slow to answer.",
                                        isError: true, step: Self.sentence("\(folder.label) couldn’t be read"))
        }
        let items = everything.filter { !ctx.isHidden($0.id) }
        let from = max(0, call.int("from") ?? 0)
        let page = items.dropFirst(from).prefix(Self.maxListed)
        let goes = ctx.lookupGoes(folder)
        var lines = ["folder: \(AskClaudeScreenCard.escape(folder.label)) · \(items.count) items",
                     "rows: handle|name|kind|size|modified|tags" + (goes ? "" : "|folder")]
        let header = lines.joined(separator: "\n")
        let files = goes ? [] : page.map { foundFile($0, ctx) }
        lines += goes ? page.map { AskClaudeScreenCard.row(for: Self.row($0), handles: &handles) } : files.map(\.row)
        let rest = items.count - from - page.count
        if rest > 0 { lines.append("\(rest) more; call again with from \(from + page.count).") }
        if everything.count > items.count { lines.append("\(everything.count - items.count) more hidden from Claude by them.") }
        let step = "Listed \(folder.label) · \(items.count) item\(items.count == 1 ? "" : "s")"
        guard goes || page.isEmpty else {
            // A folder they aren't looking at says what's in it by its names alone, so they wait on
            // a card, as a search inside files does.
            let found = AskClaudeFoundNames(words: "", folderLabel: folder.label, names: page.map(\.name), count: items.count,
                                            rows: lines.joined(separator: "\n"), paths: page.map(\.id), files: files,
                                            header: header, source: .listing)
            return AskClaudeToolOutcome(result: Self.heldNames("\(AskClaudeScreenCard.escape(folder.label)) holds \(Self.count(items.count, "item")), on their Mac."),
                                        step: step, found: found)
        }
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: step)
    }

    /// A file held on a card: its row with its folder, as Share Details sends it,
    /// but no handle yet. Handles run r1, r2, r3, so one minted now could be guessed and asked
    /// about before they share; `AskClaudeChat.takeFound` mints it with the share.
    private func foundFile(_ node: FileNode, _ ctx: Context) -> AskClaudeFoundNames.File {
        let where_ = Self.relative((node.id as NSString).deletingLastPathComponent, root: ctx.root)
        let folder = where_.isEmpty ? "(top level)" : where_
        var scratch = AskClaudeHandles()
        let minted = AskClaudeScreenCard.row(for: Self.row(node), handles: &scratch)
        let row = String(minted.drop { $0 != "|" }) + "|" + AskClaudeScreenCard.escape(folder)
        return .init(name: node.name, folder: folder, modified: node.modificationDate, row: row, path: node.id)
    }

    /// What Claude is told of names held on a card: how many, and what to do until they share.
    static func heldNames(_ found: String) -> String {
        found + " Their names weren’t sent to you: they’re shown the list and can share it. In one short sentence, say what you would do with them if they share it, and stop. If they share it, it arrives as their next message."
    }

    /// What Claude is told of a search inside files held on a card: not even how many, since
    /// whether any file mentions a word says what the files hold.
    static func heldSearch(_ words: String, _ folder: String) -> String {
        "Spotlight searched inside the files under \(AskClaudeScreenCard.escape(folder)) for “\(words)”, on their Mac. What it found wasn’t sent to you, not even how many: whether a file mentions a word says what it holds. They’re shown the result and can share it. In one short sentence, say what you would do with it if they share it, and stop. If they share it, it arrives as their next message."
    }

    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    private func findByName(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        let words = (call.string("words") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return AskClaudeToolOutcome(result: "Give at least one word to look for.", isError: true, step: "Search had no words")
        }
        guard let folder = Self.resolve(call.string("folder") ?? ctx.folder, root: ctx.root) else {
            return badFolder(call.string("folder"))
        }
        // A search with no folder named runs where they are; in a hidden folder even its name is
        // not said, so it isn't searched.
        if ctx.isHidden(folder.absolute) { return hiddenFolder() }
        let kind = call.string("kind")?.trimmingCharacters(in: .whitespaces)
        let minBytes = call.input["larger_than_mb"].flatMap { value -> Double? in
            if case .number(let d) = value { return d }
            return value.intValue.map(Double.init)
        }.map { Int(exactly: ($0 * 1_000_000).rounded()) ?? (($0 < 0) ? 0 : Int.max) }

        // Spotlight first: it covers folders the pane has never opened. Where it can’t answer, the
        // pane’s loaded tree is searched instead, and the result says so. Either way an item
        // matches when its folders and name TOGETHER hold every word: in a filed archive the
        // folders say what a file is (a person, a year, a period) and many names say nothing.
        var candidates: [FileNode] = []
        var searchedIndex = false
        if let paths = await searchNames(words, folder.absolute) {
            searchedIndex = true
            let matching = paths.filter { Self.holdsEvery(words, in: Self.relative($0, root: ctx.root)) && !ctx.isHidden($0) }
            candidates = matching.prefix(AskClaudeDisk.maxExamined).compactMap { ctx.node($0) ?? statDisk($0) }
        } else if let top = ctx.items(folder.absolute) {
            var stack = top.reversed() as [FileNode]
            while let node = stack.popLast() {
                if Self.holdsEvery(words, in: Self.relative(node.id, root: ctx.root)), !ctx.isHidden(node.id) { candidates.append(node) }
                if let children = node.children { stack.append(contentsOf: children.reversed()) }
            }
        }
        var kept = candidates.filter { node in
            let kindMatches = kind.map { Self.kind(node).localizedCaseInsensitiveContains($0) } ?? true
            let sizeMatches = minBytes.map { !node.isDirectory && (node.fileSize ?? 0) > $0 } ?? true
            return kindMatches && sizeMatches
        }
        // Newest first, judged the way the archive is filed: the latest year anywhere in the path
        // (“2026-2029” counts as 2029), then items whose own name holds every word, then the
        // modified date. So the newest period leads for every model, not only one that reasons it.
        // Copies under an Archive or Backup folder come after all of those, unless the words ask
        // for one: they are rarely the copy meant.
        let years = Dictionary(kept.map { ($0.id, Self.latestYear(in: Self.relative($0.id, root: ctx.root)) ?? 0) },
                               uniquingKeysWith: { a, _ in a })
        let wantsSetAside = words.contains(where: Self.namesSetAside)
        let setAside = Dictionary(kept.map { ($0.id, !wantsSetAside && Self.isSetAside(Self.relative($0.id, root: ctx.root))) },
                                  uniquingKeysWith: { a, _ in a })
        kept.sort { a, b in
            let aa = setAside[a.id] ?? false, ba = setAside[b.id] ?? false
            if aa != ba { return ba }
            let ay = years[a.id] ?? 0, by = years[b.id] ?? 0
            if ay != by { return ay > by }
            let an = Self.holdsEvery(words, in: a.name), bn = Self.holdsEvery(words, in: b.name)
            if an != bn { return an }
            return (a.modificationDate ?? .distantPast) > (b.modificationDate ?? .distantPast)
        }
        let total = kept.count
        let hits = Array(kept.prefix(Self.maxFound))
        let label = words.joined(separator: " ")
        guard total > 0 else {
            let scope = searchedIndex ? "" : " Spotlight didn’t answer, so only folders the pane has open were searched."
            return AskClaudeToolOutcome(result: "Nothing under \(folder.label) matches “\(label)”.\(scope)",
                                        step: "Found nothing for “\(label)”")
        }
        var lines = ["\(total) match\(total == 1 ? "" : "es") under \(AskClaudeScreenCard.escape(folder.label)), newest period first:",
                     "rows: handle|name|kind|size|modified|tags|folder"]
        let header = lines.joined(separator: "\n")
        let goes = ctx.lookupGoes(folder)
        let files = goes ? [] : hits.map { foundFile($0, ctx) }
        lines += goes ? hits.map { node in
            let where_ = Self.relative((node.id as NSString).deletingLastPathComponent, root: ctx.root)
            return AskClaudeScreenCard.row(for: Self.row(node), handles: &handles) + "|" + AskClaudeScreenCard.escape(where_.isEmpty ? "(top level)" : where_)
        } : files.map(\.row)
        if total > hits.count { lines.append("\(total - hits.count) more not listed; narrow the words or the folder.") }
        if kept.contains(where: { setAside[$0.id] == true }) {
            lines.append("Rows under an Archive or Backup folder are listed last: they are usually older copies.")
        }
        lines.append("If they asked to find or show something, reveal the best row now, without asking.")
        let step = "Found \(total) for “\(label)”"
        guard goes else {
            // Names found beyond the folder on screen wait on a card for their click.
            let found = AskClaudeFoundNames(words: label, folderLabel: folder.label, names: hits.map(\.name), count: total,
                                            rows: lines.joined(separator: "\n"), paths: hits.map(\.id), files: files, header: header,
                                            source: .names, fromIndex: searchedIndex, allFiles: !hits.contains(where: \.isDirectory))
            let who = searchedIndex ? "Spotlight found" : "The folders the pane has opened hold"
            return AskClaudeToolOutcome(result: Self.heldNames("\(who) \(total) match\(total == 1 ? "" : "es") for “\(label)” under \(AskClaudeScreenCard.escape(folder.label)), on their Mac."),
                                        step: step, found: found)
        }
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: step)
    }

    private func fileDetails(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        guard let node = ctx.node(path) ?? statDisk(path) else {
            return AskClaudeToolOutcome(result: "\(handle) is gone from the pane; it may have moved or been renamed. Look again.",
                                        isError: true, step: "\(handle) is no longer in the pane")
        }
        let folder = Self.relative((path as NSString).deletingLastPathComponent, root: ctx.root)
        var lines = ["name: \(AskClaudeScreenCard.escape(node.name))",
                     "folder: \(folder.isEmpty ? "(top level)" : AskClaudeScreenCard.escape(folder))",
                     "kind: \(AskClaudeScreenCard.escape(Self.kind(node)))"]
        if node.isDirectory {
            lines.append(node.isUnexplored == true ? "items: not loaded" : node.children.map { "items: \($0.count)" } ?? "items: not loaded")
        } else if let size = node.fileSize {
            lines.append("size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) bytes)")
        }
        if let date = node.modificationDate { lines.append("modified: \(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))") }
        if let tags = node.tags, !tags.isEmpty { lines.append("tags: \(tags.map(AskClaudeScreenCard.escape).joined(separator: ", "))") }
        if !node.isDirectory, let cloudOnly = MaterializationStatus.isCloudOnlyIfKnown(atPath: path) {
            lines.append(cloudOnly ? "on this Mac: no, only in the cloud" : "on this Mac: yes")
        }
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: "Read the details of \(node.name)")
    }

    // MARK: Steer

    /// Shows an item where it lives: its folder in the pane, with it selected. Its own tool, and
    /// the first half of `open`, so the person always sees where a file is before it opens.
    private func reveal(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        switch await show(path, ctx) {
        case .failure(let failure): return failure.outcome
        case .success(let moved):
            let name = (path as NSString).lastPathComponent
            return AskClaudeToolOutcome(result: "Showing \(name) in its folder, selected.", step: "Selected \(name)",
                                        movedView: moved)
        }
    }

    /// Reveals a file named in an answer: its folder in the pane, the file selected.
    func reveal(path: String) async {
        var ctx = context()
        let name = (path as NSString).lastPathComponent
        guard !ctx.isHidden(path) else { return }
        if let busy = ctx.busyReason {
            Logger.shared.info("Ask Claude didn’t reveal \(name): \(busy)")
            return
        }
        guard Self.relativeIfInside(path, root: ctx.root) != nil || Self.closestSource(containing: path, in: ctx.sources) != nil else {
            Logger.shared.info("Ask Claude didn’t reveal \(name): it is in no source SyncCloud shows")
            return
        }
        if !ctx.inBrowse {
            guard ctx.switchWorkspace("Browse") else { return }
            try? await Task.sleep(for: .milliseconds(200))
            ctx = context()
        }
        if case .failure(let failure) = await show(path, ctx) {
            Logger.shared.info("Ask Claude didn’t reveal \(name): \(failure.outcome.step)")
        }
    }

    /// Moves the pane to `path`'s folder if it isn't there, waits for it, and selects `path`.
    /// Succeeds with the "Moved you to …" note when the view moved, nil when it was already there.
    private func show(_ path: String, _ ctx: Context) async -> Result<String?, ShowFailure> {
        if let busy = ctx.busyReason {
            return .failure(.init(AskClaudeToolOutcome(result: "Can’t move the view right now: \(busy).", isError: true,
                                                       step: "Didn’t move the view: \(busy)")))
        }
        let parent = (path as NSString).deletingLastPathComponent
        // A handle stays good for the whole chat, so it can name a file in another source than
        // the one on screen: that source is switched to, never a same-named folder in this one.
        guard let relative = Self.relativeIfInside(parent, root: ctx.root) else {
            guard let source = Self.closestSource(containing: parent, in: ctx.sources) else {
                Logger.shared.info("Ask Claude couldn’t show \((path as NSString).lastPathComponent): it is in no source SyncCloud shows")
                return .failure(.init(AskClaudeToolOutcome(result: "That item isn’t in any source SyncCloud shows.", isError: true,
                                                           step: "Couldn’t show it: not in a source")))
            }
            ctx.switchSource(source.id, parent)
            for _ in 0..<60 {
                let now = context()
                if now.sourceID == source.id, (now.items(parent) ?? []).contains(where: { AskClaudePaths.same($0.id, path) }) {
                    now.select([(now.items(parent) ?? []).first(where: { AskClaudePaths.same($0.id, path) })?.id ?? path])
                    return .success("Moved you to \(source.name)")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            Logger.shared.info("Ask Claude switched to \(source.name) but the item hadn’t shown after 3 seconds")
            return .failure(.init(AskClaudeToolOutcome(result: "Switched the pane to \(source.name), but it hadn’t shown the item after 3 seconds.",
                                                       isError: true, step: "Couldn’t select it yet", movedView: "Moved you to \(source.name)")))
        }
        var moved: String?
        if relative != ctx.folder {
            ctx.goTo(parent)
            // Said only once the pane is there: a move that didn't happen isn't claimed.
            if await waitForPane(at: relative, absolute: parent) {
                moved = "Moved you to \(relative.isEmpty ? ctx.sourceName : (relative as NSString).lastPathComponent)"
            }
        }
        let now = context()
        guard (now.items(parent) ?? []).contains(where: { AskClaudePaths.same($0.id, path) }) else {
            return .failure(.init(AskClaudeToolOutcome(result: "The pane didn’t reach \(relative.isEmpty ? "the top level" : relative) in time to select it.",
                                                       isError: true, step: "Couldn’t select it yet", movedView: moved)))
        }
        now.select([(now.items(parent) ?? []).first(where: { AskClaudePaths.same($0.id, path) })?.id ?? path])
        return .success(moved)
    }

    struct ShowFailure: Error {
        let outcome: AskClaudeToolOutcome
        init(_ outcome: AskClaudeToolOutcome) { self.outcome = outcome }
    }

    /// The pane moves on a later turn of the run loop. Waits for it (up to 2 s), so whatever comes
    /// next in the same round sees the folder Claude went to, not the one it left.
    /// True when the pane got there; its listing may still be loading, as a slow cloud folder's is.
    @discardableResult
    private func waitForPane(at relative: String, absolute: String) async -> Bool {
        for _ in 0..<40 {
            let now = context()
            if now.folder == relative, now.items(absolute) != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return context().folder == relative
    }

    private func open(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        guard let node = ctx.node(path) ?? statDisk(path) else {
            return AskClaudeToolOutcome(result: "\(handle) is gone; it may have moved or been renamed. Look again.",
                                        isError: true, step: "\(handle) is no longer there")
        }
        guard !node.isDirectory else {
            return AskClaudeToolOutcome(result: "\(node.name) is a folder. Use go_to to show it.", isError: true,
                                        step: "Didn’t open a folder")
        }
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t open it right now: \(busy).", isError: true, step: "Didn’t open: \(busy)")
        }
        // Opening a cloud-only file downloads it. Up to 25 MB that happens on its own; above it,
        // they get a card and it opens when they download it.
        if let size = largeCloudOnly(node, path) {
            let mode = call.string("in")?.lowercased()
            return offerDownload(node, path, handle: handle, size: size, purpose: .open(in: mode == "edit" || mode == "preview" ? mode : nil), ctx)
        }
        if call.string("in")?.lowercased() == "preview" {
            var moved: String?
            if case .success(let note) = await show(path, ctx) { moved = note }
            ctx.preview(URL(fileURLWithPath: path))
            return AskClaudeToolOutcome(result: "Showing a Quick Look preview of \(node.name).", step: "Previewed \(node.name)", movedView: moved)
        }
        if call.string("in")?.lowercased() == "edit" {
            // Edit's own hand-off shows the file in its folder there, so no reveal here first.
            switch ctx.openInEdit(AskClaudePaths.canonical(path)) {
            case .opened:
                return AskClaudeToolOutcome(result: "Opened \(node.name) in SyncCloud’s Edit workspace.", step: "Opened \(node.name) in Edit",
                                            movedView: "Moved you to Edit")
            case .refused:
                return AskClaudeToolOutcome(result: "Edit couldn’t show \(node.name); it may be a kind Edit doesn’t open. Edit says why.",
                                            isError: true, step: "Edit couldn’t show \(node.name)", movedView: "Moved you to Edit")
            case .notNow:
                return AskClaudeToolOutcome(result: "\(node.name) didn’t open in Edit yet: it was canceled, or Edit is waiting on a question about the open document. It opens if they answer that.",
                                            isError: true, step: "Didn’t open \(node.name) in Edit yet")
            }
        }
        // Never something that runs: an app, a script, an installer or a link that launches one.
        // A file's name can carry words that ask Claude to open it, and a click by the person is
        // the only thing that should start a program.
        if Self.launches(path) {
            return AskClaudeToolOutcome(result: "\(node.name) is an app, script, installer or shortcut, and Ask Claude doesn’t open those. Reveal it, and they can open it themselves.",
                                        isError: true, step: "Didn’t open \(node.name): it would run something")
        }
        // Shown where it lives first, always: a file opening from somewhere the person can't see
        // leaves them not knowing where it is. A failed reveal doesn't stop the open.
        var moved: String?
        var shown = false
        if case .success(let note) = await show(path, ctx) { moved = note; shown = true }
        guard openFile(URL(fileURLWithPath: path)) else {
            return AskClaudeToolOutcome(result: "macOS couldn’t open \(node.name).", isError: true, step: "Couldn’t open \(node.name)",
                                        movedView: moved)
        }
        return AskClaudeToolOutcome(result: shown ? "Showed \(node.name) in its folder, selected, and opened it in its default app."
                                        : "Opened \(node.name) in its default app; the pane couldn’t show it in its folder.",
                                    step: "Opened \(node.name)", movedView: moved)
    }

    /// The most a read or open downloads on its own; over it, a card asks.
    static let autoDownloadBytes = 25_000_000

    /// When reading or opening `path` would download more than `autoDownloadBytes`: the size, nil
    /// when unknown; or nil when it wouldn't. Through a link, the file it points to is the one
    /// fetched, so that is the one checked, and a size the provider doesn't give counts as large.
    private func largeCloudOnly(_ node: FileNode, _ path: String) -> Int?? {
        let target = MaterializationStatus.linkTarget(of: path)
        guard isCloudOnly(target) == true else { return nil }
        let size = target == path ? node.fileSize : statDisk(target)?.fileSize
        guard let size else { return .some(nil) }
        return size > Self.autoDownloadBytes ? .some(size) : nil
    }

    /// The tool's answer when a card is offered instead: nothing is downloaded yet.
    private func offerDownload(_ node: FileNode, _ path: String, handle: String, size: Int?,
                               purpose: AskClaudeDownload.Purpose, _ ctx: Context) -> AskClaudeToolOutcome {
        let source = Self.closestSource(containing: path, in: ctx.sources)?.name ?? ctx.sourceName
        let download = AskClaudeDownload(fileName: node.name, path: path, handle: handle, size: size,
                                         sourceName: source, purpose: purpose)
        let verb = purpose == .read ? "read" : "open"
        return AskClaudeToolOutcome(result: "\(download.summary) It isn’t downloaded without them: they have a Download card in the chat now. Tell them in a line and stop; once it’s here, the file \(purpose == .read ? "comes back to you to read" : "opens on its own").",
                                    step: "Offered to download \(node.name) to \(verb) it", download: download)
    }

    /// Why a card's Download is refused at the click, or nil: hidden since the card
    /// appeared, gone, or less free space than twice its size on its volume.
    static func downloadRefusal(_ download: AskClaudeDownload, isHidden: (String) -> Bool,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                freeBytes: (String) -> Int64? = AskClaudeBrowseTools.freeBytes) -> String? {
        if isHidden(download.path) { return "it’s in a folder hidden from Claude now" }
        guard exists(download.path) else { return "it isn’t there anymore; it may have moved or been renamed" }
        if let size = download.size, let free = freeBytes((download.path as NSString).deletingLastPathComponent),
           free < 2 * Int64(size) {
            let need = ByteCountFormatter.string(fromByteCount: 2 * Int64(size), countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "this Mac has \(have) free, and it needs \(need)"
        }
        return nil
    }

    /// Free space for files the person keeps, on the volume holding `folder`; nil when unknown.
    nonisolated static func freeBytes(_ folder: String) -> Int64? {
        (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// How long a card waits for its file, as Edit's Download does.
    static let downloadWait: Duration = .seconds(600)

    /// The wait behind a card: the system's download first, where the provider takes it, then the
    /// one-byte read every provider answers (`ExternalOpen.fetch`).
    nonisolated static func fetch(_ download: AskClaudeDownload, timeout: Duration = downloadWait) async -> AskClaudeChat.Fetched {
        try? MaterializationStatus.download(atPath: download.path)
        let started = ContinuousClock.now
        if await ExternalOpen.fetch(download.path, timeout: timeout) { return .landed }
        // The fetch answers false both when it gave up waiting and when the read came back with
        // the file still in the cloud; only the clock tells them apart.
        return ContinuousClock.now - started >= timeout - .seconds(1) ? .timedOut : .failed
    }

    /// Opens a file a card just downloaded, as the open that offered the card asked. Run
    /// as that call again, so every check it made is made again now.
    func openDownloaded(_ download: AskClaudeDownload) async -> AskClaudeToolOutcome {
        guard case .open(let mode) = download.purpose else {
            return AskClaudeToolOutcome(result: "", isError: true, step: "Nothing to open")
        }
        var handles = AskClaudeHandles()
        let handle = handles.handle(for: download.path)
        var input: [String: JSONFragment] = ["handle": .string(handle)]
        if let mode { input["in"] = .string(mode) }
        return await run(AskClaudeToolCall(id: "download", name: "open", input: .object(input)), handles: &handles)
    }

    /// Whether opening `path` would start a program: an app or executable, a script, an
    /// installer, or a shortcut file that opens one (Terminal settings, a workflow, a web or file
    /// location). By type, and by the file's execute bit for anything without a known type.
    /// A link is judged by what it points at too: macOS opens the target, so `Invoice.pdf` linked
    /// to a script would run it.
    static func launches(_ path: String) -> Bool {
        let target = MaterializationStatus.linkTarget(of: path)
        return runsAsIs(path) || (target != path && runsAsIs(target))
    }

    private static func runsAsIs(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let launchers: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "csh", "pkg", "mpkg", "workflow", "action",
                                      "terminal", "webloc", "inetloc", "fileloc", "scpt", "scptd", "applescript", "prefpane",
                                      "kext", "dmg", "jar", "py", "rb", "pl"]
        if launchers.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext),
           [UTType.application, .executable, .script, .shellScript, .applicationBundle, .package].contains(where: { type.conforms(to: $0) }) {
            return type.conforms(to: .package) ? type.conforms(to: .applicationBundle) : true
        }
        var isDirectory: ObjCBool = false
        return ext.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private func goTo(_ call: AskClaudeToolCall, _ ctx: Context) async -> AskClaudeToolOutcome {
        let folderArg = call.string("folder")
        let sourceArg = call.string("source")?.trimmingCharacters(in: .whitespaces).nonEmpty
        let workspaceArg = call.string("workspace")?.trimmingCharacters(in: .whitespaces).nonEmpty
        // Every move waits for the window: never under a sheet or a question.
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t move the view right now: \(busy). Tell them where it is instead.",
                                        isError: true, step: "Didn’t move the view: \(busy)")
        }
        // A side of Compare first: `history` and the rest move the Browse pane.
        if let pane = call.string("pane")?.lowercased() {
            return await goToPane(pane, call, ctx)
        }
        if let history = call.string("history")?.lowercased() {
            guard history == "back" || history == "forward" else {
                return AskClaudeToolOutcome(result: "history is back or forward.", isError: true, step: "No history \(history)")
            }
            guard ctx.history(history == "forward") else {
                return AskClaudeToolOutcome(result: "There’s nowhere to go \(history).", isError: true, step: "Nowhere to go \(history)")
            }
            try? await Task.sleep(for: .milliseconds(300))
            let now = context()
            // Back can land in a hidden folder Claude never named; it isn't named now either.
            let hidden = now.isHidden(Self.absolute(now.folder, root: now.root))
            let landed = hidden ? "a folder hidden from Claude" : now.folder.isEmpty ? "the top level" : now.folder
            return AskClaudeToolOutcome(result: "Went \(history) to \(landed).", step: "Went \(history)",
                                        movedView: "Moved you \(history)" + (hidden ? "" : " to \(now.folder.isEmpty ? now.sourceName : (now.folder as NSString).lastPathComponent)"))
        }
        if let tabName = call.string("tab") {
            guard let tab = Self.tab(named: tabName, in: ctx.tabs) else {
                return AskClaudeToolOutcome(result: "There’s no tab called \(tabName). Tabs: \(ctx.tabs.map(\.title).joined(separator: ", ")).",
                                            isError: true, step: "No tab \(tabName)")
            }
            ctx.switchTab(tab.id)
            try? await Task.sleep(for: .milliseconds(300))
            return AskClaudeToolOutcome(result: "Switched to the \(tab.title) tab.", step: "Switched to the \(tab.title) tab",
                                        movedView: "Moved you to the \(tab.title) tab")
        }
        if call.input["new_tab"]?.boolValue == true, let folderArg {
            // A new tab opens in the pane's source; another source is a switch first.
            if let sourceArg, Self.source(named: sourceArg, in: ctx.sources)?.id != ctx.sourceID {
                return AskClaudeToolOutcome(result: "A new tab opens in the source on screen (\(ctx.sourceName)). Switch to \(sourceArg) with go_to first, then open the tab.",
                                            isError: true, step: "Didn’t open a tab in another source")
            }
            guard let folder = Self.resolve(folderArg, root: ctx.root) else { return badFolder(folderArg) }
            if ctx.isHidden(folder.absolute) { return hiddenFolder() }
            guard Self.isFolder(folder.absolute) else { return badFolder(folderArg) }
            ctx.addTab(folder.absolute)
            try? await Task.sleep(for: .milliseconds(300))
            return AskClaudeToolOutcome(result: "Opened \(folder.label) in a new tab.", step: "Opened \(folder.label) in a new tab",
                                        movedView: "Opened a tab at \(folder.relative.isEmpty ? ctx.sourceName : (folder.relative as NSString).lastPathComponent)")
        }
        guard folderArg != nil || sourceArg != nil || workspaceArg != nil else {
            return AskClaudeToolOutcome(result: "Give a folder, a source or a workspace.", isError: true, step: "go_to had nothing to go to")
        }
        var steps: [String] = []
        var moved: String?
        var folderDone = false
        // 1. The source, with the folder inside it when one is named: one move, not two.
        if let sourceArg {
            guard let source = Self.source(named: sourceArg, in: ctx.sources) else {
                return AskClaudeToolOutcome(result: "There is no source called \(sourceArg). Sources: \(ctx.sources.map(\.name).joined(separator: ", ")).",
                                            isError: true, step: "No source \(sourceArg)")
            }
            if ctx.isHidden(source.root) { return hiddenFolder() }
            if source.id != ctx.sourceID {
                var target: (absolute: String, relative: String, label: String)?
                if let folderArg {
                    guard let resolved = Self.resolve(folderArg, root: source.root) else { return badFolder(folderArg) }
                    if ctx.isHidden(resolved.absolute) { return hiddenFolder() }
                    guard Self.isFolder(resolved.absolute) else {
                        return AskClaudeToolOutcome(result: "There is no folder \(resolved.label) in \(source.name).", isError: true,
                                                    step: Self.sentence("No folder \(resolved.label) in \(source.name)"))
                    }
                    target = resolved
                }
                ctx.switchSource(source.id, target?.absolute)
                var landed = false
                for _ in 0..<60 {
                    let now = context()
                    if now.sourceID == source.id, target.map({ now.folder == $0.relative }) ?? true { landed = true; break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard landed else {
                    return AskClaudeToolOutcome(result: "Asked the pane to switch to \(source.name), but it hadn’t got there after 3 seconds. The next screen says where it is.",
                                                isError: true, step: "Switching to \(source.name) hadn’t finished")
                }
                folderDone = folderArg != nil
                steps.append("Switched to \(source.name)" + (target.map { " › \($0.label)" } ?? ""))
                moved = "Moved you to " + (target.map { $0.relative.isEmpty ? source.name : ($0.relative as NSString).lastPathComponent } ?? source.name)
            }
        }
        // 2. A folder in whichever source the pane is on now.
        if let folderArg, !folderDone {
            let now = context()
            guard let folder = Self.resolve(folderArg, root: now.root) else { return badFolder(folderArg) }
            if now.isHidden(folder.absolute) { return hiddenFolder() }
            guard Self.isFolder(folder.absolute) else {
                return AskClaudeToolOutcome(result: "There is no folder \(folder.label) in \(now.sourceName).", isError: true,
                                            step: Self.sentence("No folder \(folder.label)"))
            }
            if !(now.inBrowse && now.folder == folder.relative) {
                now.goTo(folder.absolute)
                guard await waitForPane(at: folder.relative, absolute: folder.absolute) else {
                    return AskClaudeToolOutcome(result: "Asked the pane to go to \(folder.label), but it hadn’t got there after 2 seconds. The next screen says where it is.",
                                                isError: true, step: Self.sentence("The pane hadn’t reached \(folder.label)"))
                }
                steps.append("Went to \(folder.label)")
                moved = "Moved you to \(folder.relative.isEmpty ? now.sourceName : (folder.relative as NSString).lastPathComponent)"
            }
        }
        // 3. The workspace, last, so a folder named with it is where that workspace opens.
        if let workspaceArg {
            guard ctx.switchWorkspace(workspaceArg) else {
                return AskClaudeToolOutcome(result: "There is no workspace called \(workspaceArg). Workspaces: Browse, Compare, Organize, Edit.",
                                            isError: true, step: "No workspace \(workspaceArg)")
            }
            steps.append("Switched to \(workspaceArg.capitalized)")
            moved = "Moved you to \(workspaceArg.capitalized)"
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !steps.isEmpty else {
            return AskClaudeToolOutcome(result: "They are already there.", step: "Already there")
        }
        return AskClaudeToolOutcome(result: steps.joined(separator: "; ") + ". The next message’s screen describes it.",
                                    step: steps.joined(separator: " · "), movedView: moved)
    }

    /// Sets one side of Compare to a source, a folder, or both, opening Compare unless another
    /// workspace is named.
    private func goToPane(_ paneArg: String, _ call: AskClaudeToolCall, _ ctx: Context) async -> AskClaudeToolOutcome {
        guard paneArg == "left" || paneArg == "right" else {
            return AskClaudeToolOutcome(result: "pane is left or right.", isError: true, step: "No pane \(paneArg)")
        }
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t move the view right now: \(busy).", isError: true, step: "Didn’t move the view: \(busy)")
        }
        let isLeft = paneArg == "left"
        let side = isLeft ? "left" : "right"
        let before = ctx.pane(isLeft)
        var source = ctx.sources.first { $0.id == before.sourceID } ?? Source(id: before.sourceID, name: before.sourceID, root: before.root)
        if let name = call.string("source")?.trimmingCharacters(in: .whitespaces).nonEmpty {
            guard let named = Self.source(named: name, in: ctx.sources) else {
                return AskClaudeToolOutcome(result: "There is no source called \(name). Sources: \(ctx.sources.map(\.name).joined(separator: ", ")).",
                                            isError: true, step: "No source \(name)")
            }
            if ctx.isHidden(named.root) { return hiddenFolder() }
            source = named
        }
        var target: (absolute: String, relative: String, label: String)?
        if let folderArg = call.string("folder") {
            guard let resolved = Self.resolve(folderArg, root: source.root) else { return badFolder(folderArg) }
            if ctx.isHidden(resolved.absolute) { return hiddenFolder() }
            guard Self.isFolder(resolved.absolute) else {
                return AskClaudeToolOutcome(result: "There is no folder \(resolved.label) in \(source.name).", isError: true,
                                            step: Self.sentence("No folder \(resolved.label) in \(source.name)"))
            }
            target = resolved
        }
        // Sides are Compare's: Browse shows one pane, and the others aren't a comparison.
        let workspace = call.string("workspace")?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Compare"
        guard workspace.caseInsensitiveCompare("Compare") == .orderedSame else {
            return AskClaudeToolOutcome(result: "pane sets a side of Compare. Leave out workspace, or use go_to without pane to move the Browse pane.",
                                        isError: true, step: "pane is for Compare")
        }
        guard ctx.switchWorkspace(workspace) else {
            return AskClaudeToolOutcome(result: "There is no workspace called \(workspace).", isError: true, step: "No workspace \(workspace)")
        }
        ctx.movePane(isLeft, source.id == before.sourceID ? nil : source.id, target?.absolute)
        var landed = false
        for _ in 0..<60 {
            let now = context().pane(isLeft)
            if now.sourceID == source.id, target.map({ now.folder == $0.relative }) ?? true { landed = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let what = source.name + (target.map { " › \($0.label)" } ?? "")
        guard landed else {
            return AskClaudeToolOutcome(result: "Asked the \(side) side to show \(what), but it hadn’t got there after 3 seconds. The next screen says where it is.",
                                        isError: true, step: "The \(side) side hadn’t reached \(what)")
        }
        return AskClaudeToolOutcome(result: "The \(side) side of \(workspace.capitalized) shows \(what).", step: "Set the \(side) side to \(what)",
                                    movedView: "Set \(workspace.capitalized)’s \(side) side to \(what)")
    }

    /// The tab a name means: its whole title, or else the one tab with a word starting with it.
    /// Never a substring, as for sources.
    static func tab(named name: String, in allTabs: [Tab]) -> Tab? {
        let tabs = allTabs.filter { !$0.isHidden }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = tabs.first(where: { $0.title.compare(name, options: options) == .orderedSame }) { return exact }
        let byWord = tabs.filter { tab in
            tab.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.range(of: name, options: options.union(.anchored)) != nil }
        }
        return byWord.count == 1 ? byWord[0] : nil
    }

    private func closeTabs(_ call: AskClaudeToolCall, _ ctx: Context) -> AskClaudeToolOutcome {
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t close tabs right now: \(busy).", isError: true, step: "Didn’t close tabs: \(busy)")
        }
        guard let current = ctx.tabs.first else {
            return AskClaudeToolOutcome(result: "There are no tabs to close.", isError: true, step: "No tabs to close")
        }
        var closing: [Tab]
        if call.input["all_but_current"]?.boolValue == true {
            closing = ctx.tabs.dropFirst().filter { !$0.isPinned }
        } else {
            let names = call.strings("tabs") ?? []
            var unknown: [String] = []
            closing = names.compactMap { name in
                guard let tab = Self.tab(named: name, in: ctx.tabs) else { unknown.append(name); return nil }
                return tab
            }
            guard unknown.isEmpty else {
                return AskClaudeToolOutcome(result: "There’s no tab called \(unknown.joined(separator: ", ")). Tabs: \(ctx.tabs.map(\.title).joined(separator: ", ")).",
                                            isError: true, step: "No tab \(unknown.joined(separator: ", "))")
            }
        }
        // Each tab once, however many times it was named.
        var seen = Set<UUID>()
        closing = closing.filter { seen.insert($0.id).inserted }
        // Closing every tab would close the window; the one on screen stays.
        let keptLast = Set(closing.map(\.id)) == Set(ctx.tabs.map(\.id))
        if keptLast { closing.removeAll { $0.id == current.id } }
        guard !closing.isEmpty else {
            return AskClaudeToolOutcome(result: "Only the tab on screen is open, and closing it would close the window, so it stays.",
                                        step: "Kept the only tab")
        }
        ctx.closeTabs(closing.map(\.id))
        let names = closing.map(\.title).joined(separator: ", ")
        let what = "Closed \(closing.count) tab\(closing.count == 1 ? "" : "s"): \(names)"
        return AskClaudeToolOutcome(result: what + (keptLast ? ". Kept \(current.title), the tab on screen: closing the last tab closes the window." : "."),
                                    step: what, movedView: what)
    }

    /// The source a name means: its full name, or else the one source with a word starting with
    /// it (“google” → “Google Drive” when there is one). Never a substring: “Box” is not Dropbox.
    static func source(named name: String, in sources: [Source]) -> Source? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = sources.first(where: { $0.name.compare(name, options: options) == .orderedSame }) { return exact }
        let byWord = sources.filter { source in
            source.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.range(of: name, options: options.union(.anchored)) != nil }
        }
        return byWord.count == 1 ? byWord[0] : nil
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func select(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome {
        let wanted = call.strings("handles") ?? []
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t change the selection right now: \(busy).", isError: true,
                                        step: "Didn’t select: \(busy)")
        }
        // The pane's own ids, by real spelling: at iCloud's top level a row's id is the link
        // spelling (root/Documents), and selecting the resolved one selects nothing on screen.
        let rows = ctx.items(Self.absolute(ctx.folder, root: ctx.root)) ?? []
        let byReal = Dictionary(rows.map { (AskClaudePaths.canonical($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
        var paths = Set<String>()
        var refused: [String] = []
        for handle in wanted {
            if let path = handles.path(for: handle), let id = byReal[AskClaudePaths.canonical(path)] { paths.insert(id) } else { refused.append(handle) }
        }
        guard refused.isEmpty else {
            return AskClaudeToolOutcome(result: "These aren’t rows in the folder on screen: \(refused.joined(separator: ", ")). Only rows on screen can be selected; go_to their folder first.",
                                        isError: true, step: "Couldn’t select \(refused.count) item\(refused.count == 1 ? "" : "s")")
        }
        ctx.select(paths)
        let what = paths.isEmpty ? "Cleared the selection" : "Selected \(paths.count) item\(paths.count == 1 ? "" : "s")"
        return AskClaudeToolOutcome(result: what + ".", step: what)
    }

    // MARK: Reading (TE240, TE239)

    private func readText(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        let question = call.string("question") ?? "What does it say?"
        guard let node = ctx.node(path) ?? statDisk(path), !node.isDirectory else {
            return AskClaudeToolOutcome(result: "\(handle) isn’t a file that’s still there.", isError: true, step: "Couldn’t read \(handle)")
        }
        if let size = largeCloudOnly(node, path) {
            return offerDownload(node, path, handle: handle, size: size, purpose: .read, ctx)
        }
        let found = await read(path)
        if Task.isCancelled { return Self.stoppedReading(node.name) }
        guard let reading = found else {
            let why = AskClaudeReading.isPaged(path)
                ? "couldn’t be read here: it doesn’t open as a PDF, or reading it took over \(AskClaudeReading.extractTimeout.components.seconds) seconds."
                : "has no text this version can read (pictures aren’t read yet)."
            return AskClaudeToolOutcome(result: "\(node.name) \(why)", isError: true, step: "No readable text in \(node.name)")
        }
        if reading.locked {
            return AskClaudeToolOutcome(result: "\(node.name) is locked with a password, so its text can’t be read here.",
                                        isError: true, step: "\(node.name) is locked")
        }
        guard reading.hasText else {
            // `read` gives a PDF without text only with a note saying why.
            let why = reading.ocrNote ?? "It holds no text this version can read (pictures aren’t read yet)."
            return AskClaudeToolOutcome(result: "No text was read from \(node.name). " + why,
                                        isError: true, step: "No readable text in \(node.name)")
        }
        let pages = reading.pages
        let paged = AskClaudeReading.isPaged(path)
        var limit = AskClaudeReading.onDeviceChars
        var local = AskClaudeReading.passage(from: pages, question: question, limit: limit, paged: paged)
        let forClaude = AskClaudeReading.claudePassage(from: pages, question: question, paged: paged)
        var answer = await answerOnDevice(question, local.text, node.name)
        // Chinese or Japanese runs near a token a character: 16,000 characters of it are about
        // 12,500 tokens, past the model's 8,192. So a passage that doesn't fit halves, twice at
        // most; 4,000 characters fit any script measured.
        for _ in 0..<2 where answer == .tooLong && !Task.isCancelled {
            limit = min(limit, local.text.count) / 2
            local = AskClaudeReading.passage(from: pages, question: question, limit: limit, paged: paged)
            answer = await answerOnDevice(question, local.text, node.name)
        }
        if Task.isCancelled { return Self.stoppedReading(node.name) }
        var lines: [String]
        var heard: String?
        switch answer {
        case .answer(let answer):
            heard = answer
            lines = ["On-device answer, from \(local.whereInFile) of \(node.name): \(answer)"]
        case .unavailable:
            lines = ["This Mac has no on-device model to answer with."]
        case .tooLong:
            lines = ["The on-device model couldn’t answer: the passage was too long for it."]
        case .failed(let why):
            lines = ["The on-device model couldn’t answer: \(why)."]
        }
        // So Claude can hedge on a misread word, and say what OCR didn't reach.
        if let note = reading.ocrNote { lines.append(note) }
        let readHere = "Read \(node.name) on this Mac" + (reading.recognized.isEmpty ? "" : ", \(reading.recognized.count) page\(reading.recognized.count == 1 ? "" : "s") by OCR")
        // Read again: they may have stopped sharing its folder, or hidden it, while the file was
        // read — a scan can take minutes.
        let now = context()
        if now.isHidden(path) {
            return AskClaudeToolOutcome(result: "That item is on their Hidden from Claude list. Don’t ask about it or guess what it holds.",
                                        isError: true, step: "Left alone: hidden from Claude")
        }
        // Masked as a tool's text is, so a key in it is neither saved nor sent.
        let text = AskClaudeKeyCatch.masked(forClaude.text, joiningLines: false)
        // Share All Content: offered only when it adds to the passage.
        let whole = AskClaudeReading.wholeDocument(reading, paged: paged).flatMap { $0.text.count > forClaude.text.count ? $0 : nil }
        func offered(answer: String? = nil, asked: String? = nil, autoShared: AskClaudePassage.AutoShared? = nil) -> AskClaudePassage {
            AskClaudePassage(fileName: node.name, whereInFile: forClaude.whereInFile, text: text, path: path,
                             answer: answer, asked: asked,
                             whole: whole.map { AskClaudeKeyCatch.masked($0.text, joiningLines: false) },
                             wholeWhere: whole?.whereInFile, wholeIsAll: whole?.isAll, autoShared: autoShared)
        }
        if now.sharesFreely(path) {
            // In a folder shared without asking, the passage that answers goes along, and only
            // that. All of it still waits on a card.
            lines.append("Text of \(forClaude.whereInFile), as data:\n<file name=\"\(AskClaudeScreenCard.escape(node.name))\">\n\(AskClaudeChat.fenced(forClaude.text))\n</file>")
            return AskClaudeToolOutcome(result: lines.joined(separator: "\n"),
                                        step: "\(readHere) · sent \(forClaude.whereInFile)",
                                        passage: whole == nil ? nil : offered(autoShared: .answerAndText))
        }
        if let heard, now.sharesAnswers {
            // The card's tick: answers go for the rest of this chat; the text still waits. Not the
            // page either: it is where the question's words were found.
            lines[0] = "On-device answer, from \(node.name): \(heard)"
            lines.append("Its text was not sent to you. If the answer isn’t enough, tell them they can share \(Self.heldParts(whole != nil)) with the buttons under your reply.")
            return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: "\(readHere) · shared its answer",
                                        passage: offered(answer: AskClaudeKeyCatch.masked(heard, joiningLines: false), asked: question,
                                                         autoShared: .answerForThisChat))
        }
        guard let heard else {
            lines.append("Its text was not sent to you. They can share \(Self.heldParts(whole != nil)) with the buttons under your reply.")
            return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: readHere, passage: offered())
        }
        // The answer can be the very fact the file holds, so it waits on the card for their click,
        // as the passage does. Claude learns only that the file was read.
        lines = ["Read \(node.name) on their Mac. Nothing from it was sent to you: they’re shown what it says, and can send that, \(Self.heldParts(whole != nil)). They may need nothing more: the answer is on their screen. In one short sentence, say what you would do with it if they share it, such as compare it or act on it, and stop. If they share it, it arrives as their next message."]
        if let note = reading.ocrNote { lines.append(note) }
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: readHere,
                                    passage: offered(answer: AskClaudeKeyCatch.masked(heard, joiningLines: false), asked: question))
    }

    /// What a held read's card offers, said without naming the page: the page is the one the
    /// question's words were found on, so naming it would say the words are in the file.
    static func heldParts(_ more: Bool) -> String {
        more ? "the part it came from or more of it" : "the part it came from"
    }

    /// A read the person stopped: nothing about the file, and no passage to send.
    private static func stoppedReading(_ name: String) -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "Not read: they stopped the question.", isError: true, step: "Stopped reading \(name)")
    }

    private func findInContents(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        let words = (call.string("words") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return AskClaudeToolOutcome(result: "Give at least one word to look for.", isError: true, step: "Search had no words")
        }
        guard let folder = Self.resolve(call.string("folder") ?? ctx.folder, root: ctx.root) else {
            return badFolder(call.string("folder"))
        }
        // A search with no folder named runs where they are; in a hidden folder even its name is
        // not said, so it isn't searched.
        if ctx.isHidden(folder.absolute) { return hiddenFolder() }
        let label = words.joined(separator: " ")
        // A search inside a folder shared without asking goes without a card.
        let free = ctx.sharesFreely(folder.absolute)
        guard let paths = await searchContents(words, folder.absolute) else {
            return AskClaudeToolOutcome(result: "Spotlight didn’t answer, so the text couldn’t be searched.", isError: true,
                                        step: "Couldn’t search inside files")
        }
        let kept = paths.filter { !ctx.isHidden($0) }
        var nodes = kept.prefix(AskClaudeDisk.maxExamined).compactMap { ctx.node($0) ?? statDisk($0) }
        let years = Dictionary(nodes.map { ($0.id, Self.latestYear(in: Self.relative($0.id, root: ctx.root)) ?? 0) }, uniquingKeysWith: { a, _ in a })
        nodes.sort { (years[$0.id] ?? 0, $0.modificationDate ?? .distantPast) > (years[$1.id] ?? 0, $1.modificationDate ?? .distantPast) }
        let noMatch = "No file under \(folder.label) has text matching “\(label)”. Scans without a text layer and files only in the cloud may not be searchable."
        guard !nodes.isEmpty else {
            guard free else {
                // Whether any file mentions a word says what the files hold, so even "none" waits:
                // a count of 0 or 1 in a folder of one file is the answer.
                let found = AskClaudeFoundNames(words: label, folderLabel: folder.label, names: [], count: 0, rows: noMatch,
                                                paths: [], files: [], header: noMatch)
                return AskClaudeToolOutcome(result: Self.heldSearch(label, folder.label), step: "Found no text matching “\(label)”", found: found)
            }
            return AskClaudeToolOutcome(result: noMatch, step: "Found no text matching “\(label)”")
        }
        var lines = ["\(nodes.count) file\(nodes.count == 1 ? "" : "s") under \(AskClaudeScreenCard.escape(folder.label)) contain “\(label)”, newest period first:",
                     "rows: handle|name|kind|size|modified|tags|folder" + (free ? "|line" : "")]
        let header = lines.joined(separator: "\n")
        var files: [AskClaudeFoundNames.File] = []
        // One deadline for all the matching lines: ten slow reads in a row must not hold the answer.
        let readUntil = Date().addingTimeInterval(30)
        for (index, node) in nodes.prefix(Self.maxFound).enumerated() {
            let where_ = Self.relative((node.id as NSString).deletingLastPathComponent, root: ctx.root)
            guard free else {
                files.append(foundFile(node, ctx))
                lines.append(files[files.count - 1].row)
                continue
            }
            var line = AskClaudeScreenCard.row(for: Self.row(node), handles: &handles) + "|" + AskClaudeScreenCard.escape(where_.isEmpty ? "(top level)" : where_)
            // The matching line goes out, for the first ten: the folder is shared without asking.
            // Never a cloud-only file over the download limit: reading it would fetch it.
            let fetches = largeCloudOnly(node, node.id) != nil
            if free, index < 10, !fetches, Date() < readUntil, let text = await extract(node.id)?.joined(separator: " "),
               let match = AskClaudeReading.matchingLine(in: text, words: words) {
                line += "|" + AskClaudeScreenCard.escape(match)
            }
            lines.append(line)
        }
        if nodes.count > Self.maxFound { lines.append("\(nodes.count - Self.maxFound) more not listed.") }
        let step = "Found \(nodes.count) with “\(label)” inside"
        guard free else {
            // Which files mention a word says what is in them, so outside a shared folder the
            // names wait on a card for their click, as a file's answer does.
            let listed = nodes.prefix(Self.maxFound)
            let found = AskClaudeFoundNames(words: label, folderLabel: folder.label, names: listed.map(\.name),
                                            count: nodes.count, rows: lines.joined(separator: "\n"), paths: listed.map(\.id),
                                            files: files, header: header)
            return AskClaudeToolOutcome(result: Self.heldSearch(label, folder.label), step: step, found: found)
        }
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"), step: step)
    }

    // MARK: Filing help (TE255)

    private func whereToFile(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        guard let node = ctx.node(path) ?? statDisk(path), !node.isDirectory else {
            return AskClaudeToolOutcome(result: "\(handle) isn’t a file that’s still there; filing help is for files.", isError: true,
                                        step: "Filing help needs a file")
        }
        var place: String?
        if let into = call.string("into")?.trimmingCharacters(in: .whitespaces).nonEmpty {
            guard let resolved = Self.place(into, ctx) else {
                return AskClaudeToolOutcome(result: "There’s no folder called \(into) in their folder survey or their sources. Ask where they mean.",
                                            isError: true, step: "No place called \(into)")
            }
            if ctx.isHidden(resolved) { return hiddenFolder() }
            place = resolved
        }
        guard let answer = await ctx.whereToFile(path, place) else {
            return AskClaudeToolOutcome(result: "Filing help can’t run right now.", isError: true, step: "Filing help couldn’t run")
        }
        let card = Self.filingCard(answer, node: node, ctx: ctx, place: place)
        let step: String
        switch card.kind {
        case .suggestions: step = "Found where \(node.name) fits: \(card.folders.first?.label ?? "")"
        case .noProfile: step = "No folder survey to go by"
        case .outside: step = "\(card.place ?? "That place") is outside the folder survey"
        case .noMatch: step = "No folder fits \(node.name)"
        }
        return AskClaudeToolOutcome(result: AskClaudeFiling.result(card, sharesFreely: ctx.sharesFreely(path)), step: step, filing: card)
    }

    /// The card for an answer: each folder by source and path, as To File shows it.
    static func filingCard(_ answer: FilingHelpAnswer, node: FileNode, ctx: Context, place: String? = nil) -> AskClaudeFilingCard {
        let placeLabel = place.map { breadcrumb($0, sources: ctx.sources, fallback: ($0 as NSString).lastPathComponent) }
        switch answer.outcome {
        case .noProfile:
            return AskClaudeFilingCard(fileName: node.name, filePath: node.id, kind: .noProfile)
        case .outsideProfile(let surveyed):
            let named = breadcrumb(surveyed, sources: ctx.sources, fallback: (surveyed as NSString).lastPathComponent)
            return AskClaudeFilingCard(fileName: node.name, filePath: node.id, kind: .outside(surveyed: named), place: placeLabel)
        case .noMatch:
            return AskClaudeFilingCard(fileName: node.name, filePath: node.id, kind: .noMatch, place: placeLabel)
        case .suggested(let list):
            let shortPlace = place.map { ($0 as NSString).lastPathComponent }
            let folders = list.map { s in
                AskClaudeFilingCard.Folder(label: breadcrumb(s.folder, sources: ctx.sources, fallback: s.relativePath),
                                           path: s.folder, confidence: AskClaudeFiling.label(s.confidence),
                                           reason: s.reason, fromFile: s.evidenceToken != nil,
                                           note: s.outsidePlace ? shortPlace.map { "Outside \($0)" } : nil)
            }
            return AskClaudeFilingCard(fileName: node.name, filePath: node.id, kind: .suggestions, folders: folders,
                                       staleDays: answer.isStale(now: ctx.now()) ? answer.surveyAgeDays(now: ctx.now()) : nil,
                                       canRefine: ctx.canRefineFiling && list.first?.confidence != .high, place: placeLabel)
        }
    }

    // MARK: Rules from corrections (TE286)

    /// A correction offered as a rule. Page 1 is read here, on this Mac, so the year and month
    /// folders can be checked; a file only in the cloud over the download limit is offered by name.
    private func offerRule(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard let handle = call.string("handle"), let path = handles.path(for: handle) else {
            return unknownHandle(call.string("handle"))
        }
        guard let node = ctx.node(path) ?? statDisk(path), !node.isDirectory else {
            return AskClaudeToolOutcome(result: "\(handle) isn’t a file that’s still there; a rule is taught by a file.", isError: true,
                                        step: "A rule needs a file")
        }
        let into = call.string("folder")?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !into.isEmpty, let folder = Self.place(into, ctx) else {
            return AskClaudeToolOutcome(result: "There’s no folder called \(into) in their folder survey or their sources. Ask where they mean.",
                                        isError: true, step: "No folder called \(into)")
        }
        if ctx.isHidden(folder) { return hiddenFolder() }
        let words = call.input["words"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let also = call.input["also"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let page = largeCloudOnly(node, path) == nil ? await extract(path)?.first : nil
        guard let answer = ctx.ruleFromCorrection(path, folder, call.string("name") ?? "", words, also, page) else {
            return AskClaudeToolOutcome(result: "Rules file into their folder survey, and \(into) isn’t in it. Offer no rule.",
                                        isError: true, step: "\(into) is outside the folder survey")
        }
        // A rule is checked against the file's first page: its words, its date. Unless the file
        // shares freely, Claude mustn't learn what that check found: one call per word would tell
        // it which words the page holds. So Claude is told only that they see the outcome, whatever
        // it is, except for what depends on Claude's own words and folder alone. The step line
        // tells them why.
        if page != nil, !ctx.sharesFreely(path), !Self.dependsOnInputAlone(answer) {
            let neutral = "Whether a rule fits depends on the file’s first page, which isn’t sent to you, so they see the result and you don’t, now or when they answer it. Say in a line that they can see whether a rule was offered, and stop. If they tell you a word that sets this file apart, you can offer it again with also."
            switch answer {
            case .failure(let refusal):
                if case .covered = refusal { return AskClaudeToolOutcome(result: neutral, step: "A saved rule already files \(node.name) there") }
                return AskClaudeToolOutcome(result: neutral, step: "No rule offered: " + Self.refusalForThem(refusal))
            case .success(let correction):
                var card = AskClaudeRuleCard(fileName: node.name, correction: correction)
                card.held = true
                return AskClaudeToolOutcome(result: neutral, step: "Offered a rule: \(card.rule.name)", rule: card)
            }
        }
        switch answer {
        case .failure(let refusal):
            let covered: Bool
            if case .covered = refusal { covered = true } else { covered = false }
            return AskClaudeToolOutcome(result: AskClaudeRuleCard.refusal(refusal), isError: !covered,
                                        step: covered ? "A saved rule already files \(node.name) there" : "No rule offered")
        case .success(let correction):
            let card = AskClaudeRuleCard(fileName: node.name, correction: correction)
            return AskClaudeToolOutcome(result: AskClaudeRuleCard.result(card), step: "Offered a rule: \(card.rule.name)", rule: card)
        }
    }

    /// Whether a rule's outcome comes from Claude's words and folder alone, not the file.
    static func dependsOnInputAlone(_ answer: Result<AutomationRuleProposer.Correction, AutomationRuleProposer.CorrectionRefusal>) -> Bool {
        switch answer {
        case .failure(.noWords), .failure(.unusableFolder): true
        default: false
        }
    }

    /// A rule refusal, said to them in the step line when Claude isn't told it.
    static func refusalForThem(_ refusal: AutomationRuleProposer.CorrectionRefusal) -> String {
        switch refusal {
        case .notInFile: "none of those words is in the file’s name or on its first page"
        case .covered: "a saved rule already files it there"
        case .needsAlso: "a rule like it already files those words elsewhere"
        case .noWords: "none of those words can be matched on"
        case .unusableFolder: "that folder can’t be a rule’s destination"
        }
    }

    /// Where they said a file should go, absolute: a source and folder when the first
    /// part names a source ("Dropbox", "iCloud/Documents/Travel"), else a folder of their survey
    /// ("Travel", "Documents/Taxes/2025"). Nil when it is neither.
    static func place(_ into: String, _ ctx: Context) -> String? {
        let trimmed = into.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        if let first = parts.first, let source = Self.source(named: first, in: ctx.sources),
           let folder = Self.resolve(parts.count > 1 ? parts[1] : "", root: source.root) {
            return folder.absolute
        }
        return ctx.surveyFolder(trimmed)
    }

    // MARK: Plan card (TE262)

    /// Claude proposes; nothing runs until they click Apply. Each row is checked now, and again at
    /// the click.
    private func proposeChanges(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: AskClaudeHandles) -> AskClaudeToolOutcome {
        guard let list = call.input["changes"]?.arrayValue, !list.isEmpty else {
            return AskClaudeToolOutcome(result: "Give changes: a list of moves, renames, new folders and moves to the Trash.",
                                        isError: true, step: "Proposed nothing")
        }
        guard list.count <= Self.changesPerCard else {
            return AskClaudeToolOutcome(result: "At most \(Self.changesPerCard) changes on one card. Propose the first \(Self.changesPerCard), and the rest once they’ve applied it.",
                                        isError: true, step: "Too many changes for one card")
        }
        // A folder named by source and path, or in the source on screen.
        func folder(_ entry: JSONFragment) -> (absolute: String, label: String)? {
            var root = ctx.root
            if let name = entry["source"]?.stringValue?.nonEmpty {
                guard let source = Self.source(named: name, in: ctx.sources) else { return nil }
                root = source.root
            }
            guard let resolved = Self.resolve(entry["folder"]?.stringValue ?? "", root: root) else { return nil }
            return (resolved.absolute, Self.breadcrumb(resolved.absolute, sources: ctx.sources, fallback: resolved.label))
        }
        var rows: [AskClaudePlan.Row] = []
        var creating = Set<String>()
        var problems: [String] = []
        for (index, entry) in list.enumerated() {
            let action = entry["action"]?.stringValue?.lowercased() ?? ""
            let handle = entry["handle"]?.stringValue
            let item = handle.flatMap(handles.path(for:))
            let newName = entry["name"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            var change: AskClaudePlan.Change?
            var shown = ""
            var label: String?
            switch action {
            case "move":
                if let item, let to = folder(entry) {
                    change = .move(from: item, toFolder: to.absolute)
                    shown = (item as NSString).lastPathComponent
                    label = to.label
                }
            case "rename":
                if let item, let newName, !newName.isEmpty {
                    change = .rename(path: item, to: newName)
                    shown = (item as NSString).lastPathComponent
                    label = "Rename to \(newName)"
                }
            case "new_folder":
                if let to = folder(entry), let newName, !newName.isEmpty {
                    change = .newFolder(in: to.absolute, name: newName)
                    creating.insert((to.absolute as NSString).appendingPathComponent(newName))
                    shown = "New folder “\(newName)”"
                    label = to.label
                }
            case "trash":
                if let item {
                    change = .trash(path: item)
                    shown = (item as NSString).lastPathComponent
                }
            default:
                break
            }
            guard let change else {
                problems.append("change \(index + 1) (\(action.isEmpty ? "no action" : action)) needs \(Self.needs(action)), and a handle or folder that exists")
                continue
            }
            rows.append(AskClaudePlan.Row(id: rows.count, name: shown, change: change, ticked: !Self.isTrash(change),
                                          folderLabel: label))
        }
        guard problems.isEmpty else {
            return AskClaudeToolOutcome(result: "Nothing was offered: " + problems.joined(separator: "; ") + ".", isError: true,
                                        step: "Couldn’t propose those changes")
        }

        // Checked now, with the folders this card makes counted as there.
        for index in rows.indices {
            // A place in a hidden folder is refused before anything is checked on disk, so "already
            // there" can't say what a hidden folder holds.
            if let hidden = Self.places(rows[index].change).first(where: ctx.isHidden) {
                rows[index].refusal = "\((Self.hiddenEntry(hidden, ctx.hidden) as NSString).lastPathComponent) is hidden from Claude"
                rows[index].ticked = false
                continue
            }
            if let why = ctx.planRefusal(rows[index].change, creating) {
                rows[index].refusal = why
                rows[index].ticked = false
            }
        }
        let title = call.string("title")?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? "\(rows.count) Change\(rows.count == 1 ? "" : "s")"
        let plan = AskClaudePlan(title: title, subtitle: "", rows: rows)
        var lines = ["Offered them a card: \(AskClaudeScreenCard.escape(title)), \(rows.count) change\(rows.count == 1 ? "" : "s"). Nothing has happened: they review it and click Apply or Not Now."]
        for row in rows where row.refusal != nil {
            lines.append("Can’t apply \(AskClaudeScreenCard.escape(row.name)): \(AskClaudeScreenCard.escape(row.refusal ?? ""))")
        }
        if rows.contains(where: { Self.isTrash($0.change) }) { lines.append("Moves to the Trash are unticked until they tick them.") }
        lines.append("Say in one line what you proposed, and stop. Never say it’s done.")
        return AskClaudeToolOutcome(result: lines.joined(separator: "\n"),
                                    step: "Proposed \(rows.count) change\(rows.count == 1 ? "" : "s")", plan: plan)
    }

    /// The entry on the hidden list that covers `path`, so a refusal names only what they hid.
    static func hiddenEntry(_ path: String, _ hidden: [String]) -> String {
        hidden.first { AskClaudePrivacy.isHidden(path, by: [$0]) } ?? path
    }

    /// Every path a change would make or fill: a move's new path and folder, a rename's new name.
    static func places(_ change: AskClaudePlan.Change) -> [String] {
        switch change {
        case .move(let from, let folder):
            return [folder, (folder as NSString).appendingPathComponent((from as NSString).lastPathComponent)]
        case .rename(let path, let name):
            return [((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)]
        case .newFolder(let folder, let name):
            return [folder, (folder as NSString).appendingPathComponent(name)]
        default:
            return []
        }
    }

    static func isTrash(_ change: AskClaudePlan.Change) -> Bool {
        switch change {
        case .trash, .trashIfEmptied: return true
        default: return false
        }
    }

    static func needs(_ action: String) -> String {
        switch action {
        case "move": return "a handle and a folder"
        case "rename": return "a handle and a name"
        case "new_folder": return "a folder and a name"
        case "trash": return "a handle"
        default: return "an action: move, rename, new_folder or trash"
        }
    }

    // MARK: Loose files (TE285)

    /// Files on one filing card.
    static let looseFilesPerCard = AskClaudeLooseFiles.perCard
    /// Changes on one card Claude proposes.
    static let changesPerCard = 50

    private func fileLooseFiles(_ call: AskClaudeToolCall, _ ctx: Context) async -> AskClaudeToolOutcome {
        guard let folder = Self.resolve(call.string("folder") ?? ctx.folder, root: ctx.root) else {
            return badFolder(call.string("folder"))
        }
        if ctx.isHidden(folder.absolute) { return hiddenFolder() }
        let shown = Self.breadcrumb(folder.absolute, sources: ctx.sources, fallback: folder.label)
        // The survey that answers for these files: their source's own, or the primary one.
        guard let surveyRoot = ctx.survey(for: folder.absolute) else {
            let card = AskClaudeFilingCard(fileName: shown, filePath: folder.absolute, kind: .noProfile)
            return AskClaudeToolOutcome(result: AskClaudeFiling.result(card, sharesFreely: ctx.sharesFreely(folder.absolute)),
                                        step: "No folder survey to go by", filing: card)
        }
        let surveyLabel = Self.breadcrumb(surveyRoot, sources: ctx.sources, fallback: (surveyRoot as NSString).lastPathComponent)
        let surveyName = (surveyRoot as NSString).lastPathComponent
        // Off the main thread: a cloud folder can be slow to list. The list's matcher is built
        // there, since it reads the disk too.
        let hiddenList = ctx.hidden
        let found = await Task.detached(priority: .userInitiated) {
            let matcher = AskClaudePrivacy.Matcher(hiddenList)
            return AskClaudeLooseFiles.collect(in: folder.absolute, isHidden: { matcher.isHidden($0) })
        }.value
        let total = found.files.count
        guard total > 0 else {
            return AskClaudeToolOutcome(result: "\(AskClaudeScreenCard.escape(shown)) has no loose files to file\(found.installers.isEmpty ? "" : "; \(found.installers.count) apps or installers stay where they are").",
                                        step: "No loose files in \(folder.label)")
        }
        let counted = Self.looseCount(found)
        // Without a place, they are asked, with buttons.
        guard let into = call.string("into")?.trimmingCharacters(in: .whitespaces).nonEmpty else {
            let choices = [AskClaudeChoice("Into \(surveyName), by how I file", sends: "Into \(surveyName), by how I file"),
                           AskClaudeChoice("Somewhere else…", sends: nil)]
            return AskClaudeToolOutcome(
                result: "\(AskClaudeScreenCard.escape(shown)) has \(counted). Their folder survey covers \(AskClaudeScreenCard.escape(surveyLabel)). They have two buttons: “Into \(surveyName), by how I file” and “Somewhere else…”. Ask where these should go in one short sentence, with the count, and stop.",
                step: "Counted \(total) loose file\(total == 1 ? "" : "s") in \(folder.label)", choices: choices)
        }
        // "Into <survey>" — the button's words — names the survey offered, even a source's own one,
        // whose folder the primary survey's names don't know.
        let namesSurvey = into.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).caseInsensitiveCompare(surveyName) == .orderedSame
        guard let place = namesSurvey ? surveyRoot : Self.place(into, ctx) else {
            return AskClaudeToolOutcome(result: "There’s no folder called \(into) in their folder survey or their sources. Ask where they mean.",
                                        isError: true, step: "No place called \(into)")
        }
        if ctx.isHidden(place) { return hiddenFolder() }
        let placeLabel = Self.breadcrumb(place, sources: ctx.sources, fallback: (place as NSString).lastPathComponent)
        // A named place decides the survey, as filing help decides it: "into Google Drive's Finance"
        // is Google Drive's survey, wherever the files sit.
        let placeSurvey = ctx.survey(for: place) ?? surveyRoot
        // A place the survey doesn't cover is said, and the survey offered instead.
        guard FileSyncManager.isAtOrUnderSurvey(place, root: placeSurvey) else {
            let placeSurveyLabel = Self.breadcrumb(placeSurvey, sources: ctx.sources, fallback: (placeSurvey as NSString).lastPathComponent)
            let card = AskClaudeFilingCard(fileName: shown, filePath: folder.absolute, kind: .outside(surveyed: placeSurveyLabel), place: placeLabel)
            return AskClaudeToolOutcome(result: AskClaudeFiling.result(card, sharesFreely: ctx.sharesFreely(folder.absolute)),
                                        step: "\(placeLabel) is outside the folder survey", filing: card,
                                        choices: [AskClaudeChoice("Into \(surveyName), by how I file", sends: "Into \(surveyName), by how I file"),
                                                  AskClaudeChoice("Name a \(placeLabel.components(separatedBy: " › ").last ?? placeLabel) folder…", sends: nil)])
        }
        let from = max(0, call.int("from") ?? 0)
        // Next pages by what no card showed: files the last card moved are gone from the list,
        // and counting from `from` again would skip as many as it moved.
        let paged = AskClaudeLooseFiles.page(found.files, from: from, shown: ctx.shownOnCards.filter {
            AskClaudeBrowseTools.relativeIfInside($0, root: folder.absolute) != nil
        }, count: Self.looseFilesPerCard)
        let page = paged.files
        guard !page.isEmpty else {
            return AskClaudeToolOutcome(result: "There are only \(total) loose files; none from \(from).", isError: true,
                                        step: "No loose files past \(total)")
        }
        // Always the place, the survey's root included: it is what picks the survey each file is
        // answered from, so the card's rows and its "into" title come from the same one.
        let preferring: String? = place
        var rows: [AskClaudePlan.Row] = []
        var noHome = 0, atHome = 0
        for file in page {
            guard let answer = await ctx.whereToFile(file.path, preferring), case .suggested(let list) = answer.outcome,
                  let best = list.first else {
                noHome += 1
                continue
            }
            // Already in its home, under this spelling or another (iCloud's Documents is a link
            // to ~/Documents): nothing to do, and no copy of it to trash.
            if PathBoundary.resolvesToSameDirectory((file.path as NSString).deletingLastPathComponent, best.folder, caseSensitive: false) {
                atHome += 1
                continue
            }
            // The card is on their Mac, so it says which word decided it; what Claude is told
            // carries no reason at all.
            let choices = list.map { s in
                AskClaudePlan.Choice(label: Self.breadcrumb(s.folder, sources: ctx.sources, fallback: s.relativePath),
                                     path: s.folder, confidence: AskClaudeFiling.label(s.confidence), reason: s.reason)
            }
            let fromLabel = Self.breadcrumb((file.path as NSString).deletingLastPathComponent, sources: ctx.sources,
                                            fallback: ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            let label = choices[0].label
            // The same bytes already in its home is a copy to put in the Trash.
            let isCloudOnly = ctx.isCloudOnly
            if let twin = await Task.detached(priority: .userInitiated, operation: {
                AskClaudeLooseFiles.sameFile(as: file.path, in: best.folder, size: file.size, isCloudOnly: isCloudOnly)
            }).value {
                var row = AskClaudePlan.Row(id: rows.count, name: file.name, change: .trash(path: file.path, copyOf: twin), ticked: false,
                                            reason: "The same file is in \(label)", note: (twin as NSString).lastPathComponent == file.name ? nil : "As \((twin as NSString).lastPathComponent)",
                                            folderLabel: label, choices: choices, alreadyFiled: true)
                (row.size, row.modified, row.fromLabel) = (file.size, file.modified, fromLabel)
                rows.append(row)
                continue
            }
            // Its landing name (numbered when the name is taken) is noted once the card is built,
            // after the rows above it.
            var row = AskClaudePlan.Row(id: rows.count, name: file.name, change: .move(from: file.path, toFolder: best.folder),
                                        ticked: best.confidence == .high, confidence: AskClaudeFiling.label(best.confidence),
                                        reason: choices[0].reason,
                                        note: best.outsidePlace ? "Outside \((place as NSString).lastPathComponent)" : nil,
                                        folderLabel: label, choices: choices)
            (row.size, row.modified, row.fromLabel) = (file.size, file.modified, fromLabel)
            rows.append(row)
        }
        // Subfolders these files would leave empty, as one unticked Trash row.
        let emptied = AskClaudeLooseFiles.emptiedFolders(found, onCard: Set(rows.map(\.change.path)))
        // A home not made yet (a saved rule's new month folder, "2026 › Oct"): the card makes it,
        // a row per folder, outermost first, ticked while a ticked move goes into it.
        var making: [String] = []
        for row in rows {
            guard case .move(_, let to) = row.change else { continue }
            var missing: [String] = []
            var folder = to
            while !folder.isEmpty, folder != "/", !FileManager.default.fileExists(atPath: folder), !making.contains(folder) {
                missing.insert(folder, at: 0)
                folder = (folder as NSString).deletingLastPathComponent
            }
            making += missing
        }
        for path in making {
            let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
            var row = AskClaudePlan.Row(id: rows.count, name: "New folder “\(name)”", change: .newFolder(in: parent, name: name),
                                        ticked: false, reason: "For the files filed in it",
                                        folderLabel: Self.breadcrumb(parent, sources: ctx.sources, fallback: (parent as NSString).lastPathComponent))
            row.forMoves = true
            rows.append(row)
        }
        if !emptied.isEmpty {
            let names = emptied.map { "“\(($0 as NSString).lastPathComponent)”" }
            rows.append(AskClaudePlan.Row(id: rows.count, name: "Move \(emptied.count) emptied folder\(emptied.count == 1 ? "" : "s") to Trash",
                                          change: .trashIfEmptied(folders: emptied), ticked: false,
                                          reason: ListFormatter.localizedString(byJoining: names) + ", once their files are filed"))
        }
        // Each row checked now, as a proposed card's are, with the folders it makes counted
        // as there: one that can't run says why and has no tick, rather than failing at Apply.
        let creating = Set(making)
        for index in rows.indices {
            // A place in a hidden folder is refused before anything is checked on disk, so "already
            // there" can't say what a hidden folder holds.
            if let hidden = Self.places(rows[index].change).first(where: ctx.isHidden) {
                rows[index].refusal = "\((Self.hiddenEntry(hidden, ctx.hidden) as NSString).lastPathComponent) is hidden from Claude"
                rows[index].ticked = false
                continue
            }
            if let why = ctx.planRefusal(rows[index].change, creating) {
                rows[index].refusal = why
                rows[index].ticked = false
            }
        }
        var left: [String] = []
        if !found.installers.isEmpty { left.append("\(found.installers.count) app\(found.installers.count == 1 ? "" : "s") or installer\(found.installers.count == 1 ? "" : "s")") }
        if atHome > 0 { left.append("\(atHome) file\(atHome == 1 ? "" : "s") already in \(atHome == 1 ? "its" : "their") folder") }
        if noHome > 0 { left.append("\(noHome) file\(noHome == 1 ? "" : "s") no folder fits") }
        if found.unfinished > 0 { left.append("\(found.unfinished) unfinished download\(found.unfinished == 1 ? "" : "s")") }
        // Numbered as the first card numbered them, by what is left past the ones shown.
        let numbered = paged.total
        let end = from + page.count
        let next = min(Self.looseFilesPerCard, numbered - end)
        let more = end < numbered ? "\(from + 1)–\(end) of \(numbered) · \(numbered - end) more" : nil
        let files = rows.filter { row in
            if case .newFolder = row.change { return false }
            return !row.isTrash || row.alreadyFiled
        }.count
        var plan = AskClaudePlan(title: "File \(files) Loose File\(files == 1 ? "" : "s")", subtitle: "into \(placeLabel)", rows: rows,
                                 leftHere: left.isEmpty ? nil : "Left here: " + left.joined(separator: ", "), more: more)
        plan.tickNeededFolders()
        plan.noteLandingNames()
        if end < total {
            // The same words they could type; Claude has the place and where to start from.
            plan.nextAsk = "Show me the next \(next) loose file\(next == 1 ? "" : "s")."
            plan.nextLabel = "Next \(next)"
        }
        Logger.shared.info("Ask Claude filing card: \(rows.count) rows from \(page.count) of \(total) loose files in \(folder.label), \(noHome) with no home")
        let sure = plan.rows.filter { row in
            if case .newFolder = row.change { return false }
            return row.ticked
        }.count
        // Names and homes go only from a folder that shares freely: a home
        // can be picked from a file's first page, and the names of a folder off screen are held
        // like a lookup's. The card shows them all; Claude gets the counts.
        let sendsRows = ctx.sharesFreely(folder.absolute)
        return AskClaudeToolOutcome(result: AskClaudeLooseFiles.result(plan, leftHereCount: left.count, nextFrom: more == nil ? nil : end,
                                                                       rows: sendsRows),
                                    step: "Found homes for \(files - rows.filter(\.alreadyFiled).count) of \(page.count) files · \(sure) sure", plan: plan)
    }

    /// "132 loose files: 74 at the top level and 58 in 9 subfolders; 3 unfinished downloads skipped".
    static func looseCount(_ found: AskClaudeLooseFiles.Found) -> String {
        let total = found.files.count
        var text = "\(total) loose file\(total == 1 ? "" : "s")"
        let inSub = total - found.topLevel
        if inSub > 0 {
            text += ": \(found.topLevel) at the top level and \(inSub) in \(found.subfolders) subfolder\(found.subfolders == 1 ? "" : "s")"
        }
        if found.unfinished > 0 { text += "; \(found.unfinished) unfinished download\(found.unfinished == 1 ? "" : "s") skipped" }
        if !found.installers.isEmpty { text += "; \(found.installers.count) apps or installers stay" }
        if found.truncated { text += "; the folder holds more than SyncCloud looked through" }
        return text
    }

    /// "iCloud › Documents › Taxes", from the source holding `absolute`.
    static func breadcrumb(_ absolute: String, sources: [Source], fallback: String) -> String {
        guard let source = closestSource(containing: absolute, in: sources),
              let relative = relativeIfInside(absolute, root: source.root) else {
            return fallback.split(separator: "/").joined(separator: " › ")
        }
        return ([source.name] + relative.split(separator: "/").map(String.init)).joined(separator: " › ")
    }

    /// Go to Folder on filing help's card: go_to, run with every check it makes.
    func goToFolder(_ absolute: String) async -> AskClaudeToolOutcome {
        let ctx = context()
        guard let source = Self.closestSource(containing: absolute, in: ctx.sources),
              let relative = Self.relativeIfInside(absolute, root: source.root) else {
            return AskClaudeToolOutcome(result: "", isError: true, step: "That folder isn’t in a source SyncCloud shows")
        }
        var handles = AskClaudeHandles()
        return await run(AskClaudeToolCall(id: "filing", name: "go_to",
                                           input: .object(["source": .string(source.name), "folder": .string(relative)])),
                         handles: &handles)
    }

    // MARK: Differences (TE261)

    /// Seconds a scan may take before the tool answers without waiting for it.
    static let scanWait: Duration = .seconds(90)

    private func differences(_ call: AskClaudeToolCall, _ ctx: Context, _ handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        guard var comparison = ctx.comparison() else {
            return AskClaudeToolOutcome(result: "Compare has no two sides to compare yet. Set them with go_to pane left and right.",
                                        isError: true, step: "Nothing compared yet")
        }
        let kindArg = (call.string("kind") ?? "all").lowercased()
        guard let kind = AskClaudeDifferences.Kind(rawValue: kindArg) else {
            return AskClaudeToolOutcome(result: "kind is all, only_left, only_right, changed, name_conflicts or held_back.",
                                        isError: true, step: "No kind called \(kindArg)")
        }
        var steps: [String] = []
        var scanDidntLand = false
        // A comparison that's missing or over an hour old is scanned again first:
        // nothing on disk changes, and an answer from an old list would be wrong in ways that
        // don't show. A scan already running is waited for.
        if comparison.isScanning || !comparison.hasScanned || comparison.isStale(now: ctx.now()) {
            let before = comparison.readAt, hadScanned = comparison.hasScanned
            var asked = false
            if !comparison.isScanning {
                if let busy = ctx.busyReason {
                    steps.append("Didn’t rescan: \(busy)")
                } else if ctx.rescan() {
                    asked = true
                    Logger.shared.info("Ask Claude asked for Scan Again: the comparison was \(hadScanned ? "over an hour old" : "never scanned")")
                } else {
                    steps.append("Couldn’t start a scan")
                }
            }
            // A scan asked for here shows as running only once it has begun, a turn or more later,
            // so until its list lands it is waited for a little even while nothing shows: the list
            // read before it would otherwise be answered from, as if it were the new one.
            let asking = ContinuousClock.now
            let deadline = asking + Self.scanWait
            while ContinuousClock.now < deadline, let now = context().comparison(),
                  now.isScanning || (asked && now.readAt == before && ContinuousClock.now < asking + ctx.scanStartWait) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            comparison = context().comparison() ?? comparison
            if comparison.isScanning {
                return AskClaudeToolOutcome(result: "The scan is still running after 90 seconds; the list isn’t ready. Tell them it’s still scanning.",
                                            isError: true, step: "Still scanning")
            }
            if asked {
                if comparison.readAt != before {
                    steps.append(hadScanned ? "Scanned again: the comparison was over an hour old" : "Scanned the two sides")
                } else {
                    Logger.shared.warning("Ask Claude’s Scan Again didn’t land within \(ctx.scanStartWait); answering from the list read before it")
                    steps.append("Scan Again didn’t run")
                    scanDidntLand = true
                }
            }
            guard comparison.hasScanned else {
                return AskClaudeToolOutcome(result: "The two sides haven’t been compared, and a scan couldn’t start" + (ctx.busyReason.map { ": \($0)." } ?? "."),
                                            isError: true, step: "Nothing compared yet")
            }
        }
        // Rows with either side in a hidden folder are left out, and counted.
        let everything = context().differences()
        let visible = everything.filter { !ctx.isHidden($0.leftItemPath) && !ctx.isHidden($0.rightItemPath) }
        let words = (call.string("words") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let folder = call.string("folder")
        let rows = AskClaudeDifferences.filter(visible, kind: kind, folder: folder, words: words)
        var result = AskClaudeDifferences.render(rows, allRows: visible, hiddenCount: everything.count - visible.count,
                                                 comparison: comparison, from: max(0, call.int("from") ?? 0),
                                                 handles: &handles, now: ctx.now())
        if scanDidntLand { result += "\nScan Again didn’t run, so this is the list read before it; say how old it is." }
        let summary = "\(rows.count) difference\(rows.count == 1 ? "" : "s")" + (AskClaudeDifferences.label(kind, comparison: comparison).map { " (\($0))" } ?? "")
        steps.append("Read \(summary)")
        var moved: String?
        // Shown in the list too: Compare opens, its list narrows to the kind, and
        // these rows are selected.
        if call.input["show"]?.boolValue == true, !rows.isEmpty {
            if let busy = ctx.busyReason ?? ctx.differencesHeldBy() {
                result += "\nNot shown in the list: \(busy)."
            } else if ctx.switchWorkspace("Compare"), ctx.showDifferences(kind, Set(rows.map(\.id))) {
                result += "\nShowing these \(rows.count) in Compare’s differences list, selected."
                moved = "Showing \(summary) in Compare’s list"
                steps.append("Showed them in Compare’s list")
            } else {
                result += "\nCouldn’t show them in Compare’s list."
            }
        }
        return AskClaudeToolOutcome(result: result, step: steps.joined(separator: " · "), movedView: moved)
    }

    // MARK: View (TE244)

    private func view(_ call: AskClaudeToolCall, _ ctx: Context) -> AskClaudeToolOutcome {
        if let busy = ctx.busyReason {
            return AskClaudeToolOutcome(result: "Can’t change the view right now: \(busy).", isError: true, step: "Didn’t change the view: \(busy)")
        }
        var done: [String] = []
        if let sort = call.string("sort") {
            guard ctx.setSort(sort) else {
                return AskClaudeToolOutcome(result: "Sort by name, kind, date, size or tags.", isError: true, step: "No sort called \(sort)")
            }
            done.append("Sorted by \(sort)")
        }
        if let shown = call.input["hidden_files"]?.boolValue {
            ctx.setHiddenFiles(shown)
            done.append(shown ? "Showing hidden files" : "Hiding hidden files")
        }
        if let mode = call.string("mode") {
            guard ctx.setMode(mode) else {
                return AskClaudeToolOutcome(result: "The view is columns or list.", isError: true, step: "No view called \(mode)")
            }
            done.append("Switched to \(mode)")
        }
        guard !done.isEmpty else {
            return AskClaudeToolOutcome(result: "Give a sort, hidden_files or mode.", isError: true, step: "view had nothing to change")
        }
        return AskClaudeToolOutcome(result: done.joined(separator: "; ") + ".", step: done.joined(separator: " · "))
    }

    // MARK: Shared

    private func hiddenFolder() -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "That folder is on their Hidden from Claude list. Don’t ask about it or guess what it holds.",
                             isError: true, step: "Left alone: hidden from Claude")
    }

    private func badFolder(_ folder: String?) -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "“\(folder ?? "")” isn’t a folder path inside this source. Use a path relative to the source, like Documents/Taxes.",
                             isError: true, step: "Asked for a folder outside the source")
    }

    private func unknownHandle(_ handle: String?) -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "\(handle ?? "That handle") isn’t one this chat has seen. Use a handle from the screen or a tool’s rows.",
                             isError: true, step: "Asked about an unknown handle")
    }

    /// A folder argument made absolute, refusing anything that climbs out of the source.
    static func resolve(_ folder: String, root: String) -> (absolute: String, relative: String, label: String)? {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespaces))
        let joined = absolute(trimmed, root: root)
        var standardized = (joined as NSString).standardizingPath
        let rootStandard = (root as NSString).standardizingPath
        guard standardized == rootStandard || standardized.hasPrefix(rootStandard + "/") else { return nil }
        // The disk's own spelling of an existing folder: "documents/taxes" finds Documents/Taxes on
        // a disk that ignores case, and the pane must be sent the name it lists.
        if let real = AskClaudePaths.trueSpelling(standardized, root: rootStandard) { standardized = real }
        let rel = relative(standardized, root: rootStandard)
        return (standardized, rel, rel.isEmpty ? "the top level" : rel)
    }

    static func absolute(_ relative: String, root: String) -> String {
        relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
    }

    static func relative(_ absolute: String, root: String) -> String {
        AskClaudePaths.relative(absolute, root: root)
    }

    /// The source a path is in, by the deepest root that holds it ("Home folder" holds a Dropbox
    /// file's path too); a source with no root holds nothing.
    static func closestSource(containing path: String, in sources: [Source]) -> Source? {
        sources.filter { !$0.root.isEmpty && relativeIfInside(path, root: $0.root) != nil }
            .max { ($0.root as NSString).standardizingPath.count < ($1.root as NSString).standardizingPath.count }
    }

    /// `absolute` relative to `root` in either spelling, or nil when it is outside the root.
    static func relativeIfInside(_ absolute: String, root: String) -> String? {
        guard !root.isEmpty else { return nil }
        let root = (root as NSString).standardizingPath
        let spelled = AskClaudePaths.spelled(absolute, root: root)
        guard spelled == root || spelled.hasPrefix(root + "/") else { return nil }
        return AskClaudePaths.relative(spelled, root: root)
    }

    /// The latest four-digit year (1900–2099) anywhere in `path`: “H-1B/2026-2029/Approval” is 2029.
    static func latestYear(in path: String) -> Int? {
        // Runs of digits, kept when exactly four long: a regex lookbehind isn't available here.
        path.split(whereSeparator: { !$0.isNumber }).compactMap { run -> Int? in
            guard run.count == 4, let year = Int(run), (1900...2099).contains(year) else { return nil }
            return year
        }.max()
    }

    /// Whether a word names a set-aside copy: archive, archived, backups, back-up….
    static func namesSetAside(_ word: String) -> Bool {
        let word = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter }
        return word.hasPrefix("archiv") || word.hasPrefix("backup")
    }

    /// Whether any folder in `path` (not the item's own name) is an Archive or Backup folder:
    /// “Passport/Shweta/Archive/All Pages.pdf”, “Old Backups/Taxes/2024.pdf”.
    static func isSetAside(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { folder in
            folder.split(whereSeparator: { !$0.isLetter }).contains { namesSetAside(String($0)) }
                || namesSetAside(String(folder))
        }
    }

    /// Whether `text` holds every word, ignoring case and accents.
    static func holdsEvery(_ words: [String], in text: String) -> Bool {
        words.allSatisfy { PaneTreeSearch.match(name: text, query: $0) != nil }
    }

    /// A step line starts with a capital, whatever the folder label it opens with.
    static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func kind(_ node: FileNode) -> String {
        if node.isDirectory { return "Folder" }
        if let kind = node.kind, !kind.isEmpty { return kind }
        let ext = (node.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    static func row(_ node: FileNode) -> AskClaudeScreen.Row {
        AskClaudeScreen.Row(path: node.id, name: node.name, isDirectory: node.isDirectory, kind: kind(node),
                            size: node.fileSize, modified: node.modificationDate, tags: node.tags ?? [],
                            childCount: node.isDirectory && node.isUnexplored != true ? node.children?.count : nil)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
