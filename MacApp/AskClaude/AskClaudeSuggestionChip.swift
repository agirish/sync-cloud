import SwiftUI
import Sync

/// What the chip above Ask Claude's box may be about (TE309), as ContentView sees it: each
/// source's Downloads, the loose-files inbox, and Compare's list. Values only; the disk is read by
/// `AskClaudeSuggestionFeed`.
struct AskClaudeSuggestionSources: Equatable {
    struct Target: Equatable {
        /// Absolute.
        var path: String
        /// "Downloads".
        var name: String
        /// "iCloud › Downloads".
        var place: String
        var hidden: Bool
    }

    var workspace: String
    var downloads: [Target] = []
    var inbox: Target?
    var comparison: AskClaudeSuggestions.Comparison?

    /// The folders whose files are counted. A hidden one is never read.
    var watched: [String] {
        (downloads + [inbox].compactMap { $0 }).filter { !$0.hidden }.map(\.path)
    }
}

/// Counts arrivals in the watched folders, on this Mac, as files come and go. One for the app: a
/// window's panel is rebuilt on every redraw, and the counts outlive it.
@MainActor
final class AskClaudeSuggestionFeed: ObservableObject {
    static let shared = AskClaudeSuggestionFeed()

    /// When each watched folder's loose files arrived, by absolute path.
    @Published private(set) var arrivals: [String: [Date]] = [:]
    /// Ticks once a minute, so a Compare list goes stale and a first look's day moves on.
    @Published private(set) var now = Date()
    private var tick: Timer?

    private var switchedOn = AskClaudeSuggestions.isEnabled(.standard)
    private var defaultsChanged: NSObjectProtocol?

    private init() {
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AskClaudeSuggestionFeed.shared.now = Date() }
        }
        // Turned back on in Settings: count now, not at the next file that arrives. On the
        // posting thread, so no defaults writer waits for the main one.
        defaultsChanged = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                 object: UserDefaults.standard, queue: nil) { _ in
            Task { @MainActor in
                let feed = AskClaudeSuggestionFeed.shared
                let on = AskClaudeSuggestions.isEnabled(.standard)
                guard on != feed.switchedOn else { return }
                feed.switchedOn = on
                feed.recount()
            }
        }
    }

    private var paths: [String] = []
    private var watcher: FolderWatcher?
    private var counting: Task<Void, Never>?
    private var hiddenChanged: NSObjectProtocol?

    /// Watches exactly `paths` from now on (none stops it), and counts them now.
    func watch(_ wanted: [String]) {
        // A source with no Downloads has nothing to watch.
        let paths = wanted.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard paths != self.paths else { return }
        self.paths = paths
        if paths.isEmpty {
            watcher = nil
            arrivals = [:]
            return
        }
        if watcher == nil {
            watcher = FolderWatcher(history: .inMemory(), quiet: 2, maxDelay: 10) { [weak self] _ in
                Task { @MainActor in self?.recount() }
            }
        }
        watcher?.watch(Set(paths.map(FolderWatchRoot.init(path:))), replay: .none)
        if hiddenChanged == nil {
            hiddenChanged = NotificationCenter.default.addObserver(forName: AskClaudePrivacy.didChange, object: nil,
                                                                   queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recount() }
            }
        }
        recount()
    }

    /// Off the main thread: an iCloud folder can be slow to list.
    func recount() {
        counting?.cancel()
        // Off in Settings, no folder is read.
        let paths = AskClaudeSuggestions.isEnabled(.standard) ? self.paths : []
        let hidden = AskClaudePrivacy.hiddenFolders(in: .standard)
        counting = Task {
            let counted = await Task.detached(priority: .utility) { () -> [String: [Date]] in
                let matcher = AskClaudePrivacy.Matcher(hidden)
                var counted: [String: [Date]] = [:]
                for path in paths where !matcher.isHidden(path) {
                    counted[path] = AskClaudeSuggestions.arrivals(in: path, isHidden: { matcher.isHidden($0) })
                }
                return counted
            }.value
            guard !Task.isCancelled else { return }
            arrivals = counted
        }
    }
}

/// The one chip above Ask Claude's box: "6 new files in Downloads · File them?" A click sends its
/// question as if typed; ✕ puts it away until there is more; nothing reaches Claude before a click.
struct AskClaudeSuggestionChip: View {
    let sources: AskClaudeSuggestionSources
    @ObservedObject var chat: AskClaudeChat
    let listening: Bool
    let draft: String
    let keySaved: Bool
    let accent: Color
    let onSend: (String) -> Void
    let onOpenSettings: () -> Void

    /// Where the switch, the memory and the monthly limit are read: the chat's, a scratch one in tests.
    let defaults: UserDefaults

    @ObservedObject private var feed = AskClaudeSuggestionFeed.shared
    @AppStorage private var enabled: Bool
    @AppStorage private var memoryData: Data
    /// The kind just put away, offered "Don't Suggest …" for a few seconds.
    @State private var putAway: AskClaudeSuggestions.Kind?

    static let putAwaySeconds: Double = 6

    init(sources: AskClaudeSuggestionSources, chat: AskClaudeChat, listening: Bool, draft: String, keySaved: Bool,
         accent: Color, onSend: @escaping (String) -> Void, onOpenSettings: @escaping () -> Void) {
        self.sources = sources
        self.chat = chat
        self.listening = listening
        self.draft = draft
        self.keySaved = keySaved
        self.accent = accent
        self.onSend = onSend
        self.onOpenSettings = onOpenSettings
        defaults = chat.settingsDefaults
        _enabled = AppStorage(wrappedValue: true, AskClaudeSuggestions.enabledKey, store: chat.settingsDefaults)
        _memoryData = AppStorage(wrappedValue: Data(), AskClaudeSuggestions.memoryKey, store: chat.settingsDefaults)
    }

    /// Nothing at all when there is no chip, so the box keeps its place. ContentView starts the
    /// feed watching (`AskClaudeSuggestionSources.watched`).
    var body: some View {
        content(now: feed.now)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let putAway {
            putAwayLine(putAway)
        } else if enabled, let chip = suggestion(now: now) {
            chipView(chip, now: now)
        }
    }

    private var memory: AskClaudeSuggestions.Memory {
        (try? JSONDecoder().decode(AskClaudeSuggestions.Memory.self, from: memoryData)) ?? .init()
    }

    private func save(_ memory: AskClaudeSuggestions.Memory) {
        if let data = try? JSONEncoder().encode(memory) { memoryData = data }
    }

    private var box: AskClaudeSuggestions.Box {
        let overLimit: Bool = {
            if case .overLimit = AskClaudeSpend.state(in: defaults) { return true }
            return false
        }()
        return .init(isRunning: chat.isRunning, hasQueued: chat.queued != nil, isEditing: chat.editing != nil,
                     isListening: listening, hasDraft: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     canAsk: keySaved && !overLimit, hasAttachments: !chat.attachments.isEmpty)
    }

    private func folder(_ target: AskClaudeSuggestionSources.Target) -> AskClaudeSuggestions.Folder {
        .init(name: target.name, place: target.place, arrivals: feed.arrivals[target.path] ?? [], hidden: target.hidden)
    }

    private var facts: AskClaudeSuggestions.Facts {
        .init(workspace: sources.workspace, downloads: sources.downloads.map(folder),
              inbox: sources.inbox.map(folder), comparison: sources.comparison)
    }

    func suggestion(now: Date) -> AskClaudeSuggestions.Suggestion? {
        AskClaudeSuggestions.suggestion(facts, box: box, memory: memory, now: now)
    }

    /// Whether suggestions are switched on in Settings.
    var isOn: Bool { enabled }

    /// Not Now and Don't Suggest on the suggestion where a new chat's starters lead with it
    /// (TE347 review): remembered as the chip's own are.
    func recordPutAway(_ chip: AskClaudeSuggestions.Suggestion) {
        var memory = memory
        AskClaudeSuggestions.putAway(chip, memory: &memory)
        save(memory)
    }

    func recordTurnOff(_ kind: AskClaudeSuggestions.Kind) {
        var memory = memory
        memory.off.insert(kind)
        save(memory)
    }

    /// A click on the suggestion where a new chat's starters show it (TE347b): remembered as the
    /// chip's own click is, so the same files aren't suggested again.
    func recordClick(_ chip: AskClaudeSuggestions.Suggestion) {
        var memory = memory
        AskClaudeSuggestions.clicked(chip, memory: &memory, now: Date())
        save(memory)
    }

    private func chipView(_ chip: AskClaudeSuggestions.Suggestion, now: Date) -> some View {
        HStack(spacing: 6) {
            Button {
                var memory = memory
                AskClaudeSuggestions.clicked(chip, memory: &memory, now: Date())
                save(memory)
                onSend(chip.question)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(.green)
                    Text(chip.text).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                    Text("·").foregroundStyle(.secondary)
                    Text(chip.action).foregroundStyle(accent).fontWeight(.semibold).fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Asks Claude “\(chip.question)”. Nothing is sent until you click.")
            Button { notNow(chip) } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Not now")
            .accessibilityLabel("Not now")
        }
        .scaledFont(.caption)
        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 4)
        .background(Color.green.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.green.opacity(0.28)))
        .contextMenu {
            Button(chip.kind == .compare ? "Ask About Them" : "File Them") {
                var memory = memory
                AskClaudeSuggestions.clicked(chip, memory: &memory, now: Date())
                save(memory)
                onSend(chip.question)
            }
            Divider()
            Button("Not Now") { notNow(chip) }
            Button("Don’t Suggest \(chip.kind.title)") { turnOff(chip.kind) }
            Divider()
            Button("Suggestion Settings…", action: onOpenSettings)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Not Now") { notNow(chip) }
        .accessibilityAction(named: "Don’t Suggest \(chip.kind.title)") { turnOff(chip.kind) }
    }

    private func putAwayLine(_ kind: AskClaudeSuggestions.Kind) -> some View {
        HStack(spacing: 4) {
            Text(kind == .compare ? "Put away until the next scan ·" : "Put away until more files arrive ·")
                .foregroundStyle(.secondary)
            Button("Don’t Suggest \(kind.title)") { turnOff(kind) }
                .buttonStyle(.link)
        }
        .scaledFont(.caption)
        .padding(.horizontal, 4)
        .task(id: kind) {
            try? await Task.sleep(for: .seconds(Self.putAwaySeconds))
            if !Task.isCancelled, putAway == kind { putAway = nil }
        }
    }

    private func notNow(_ chip: AskClaudeSuggestions.Suggestion) {
        var memory = memory
        AskClaudeSuggestions.putAway(chip, memory: &memory)
        save(memory)
        putAway = chip.kind
    }

    private func turnOff(_ kind: AskClaudeSuggestions.Kind) {
        var memory = memory
        memory.off.insert(kind)
        save(memory)
        putAway = nil
    }
}
