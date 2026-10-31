import Foundation
import Sync
import Events

/// The chat in Ask Claude’s panel (RD69, v7.0): what the thread shows, and the one question running.
///
/// **One chat for the window** (decision DU, revised: the app has one main window). It follows the
/// person across workspaces and tabs, starts fresh after an hour away, and New chat starts fresh
/// any time. The transcript itself lives in `AskClaudeEngine`; this holds only what is drawn.
/// Keeps one chat alive for a view that must not redraw when it changes: it publishes nothing.
///
/// Whether the panel is open is its own object, apart from the chat and from window state: the
/// window doesn't observe either, so opening and closing redraw only the panel's layer and the
/// toolbar button (2026-10-30: Close took about a second), and a streamed word redraws only the
/// thread, not the layer that builds the panel.
@MainActor
final class AskClaudeChatHolder: ObservableObject {
    let chat = AskClaudeChat(storeURL: AskClaudeChat.defaultStore)
    let visibility = AskClaudeVisibility()
}

@MainActor
final class AskClaudeVisibility: ObservableObject {
    @Published var isOpen = false
}

@MainActor
final class AskClaudeChat: ObservableObject {

    struct Item: Identifiable, Equatable, Codable {
        enum Kind: Equatable, Codable {
            case user(String)
            case assistant(String)
            case step(String, isError: Bool)
            case moved(String)
            case receipt(Receipt)
            case problem(AskClaudeProblem)
            case note(String)
            /// A passage the on-device read found, which the person may send to Claude (DS).
            case offer(AskClaudePassage, sent: Bool)
            /// A cloud-only file Claude wanted, offered for download (TE258).
            case download(AskClaudeDownload, state: DownloadState)
        }
        var id = UUID()
        var kind: Kind
    }

    /// Where a download card is (TE258).
    enum DownloadState: Equatable, Codable {
        case offered
        case downloading
        case done
        /// Not Now.
        case declined
        /// Refused at the click (hidden since, gone, no room) or not delivered; says why.
        case failed(String)
        case timedOut
    }

    /// How a download's wait ended.
    enum Fetched: Equatable { case landed, failed, timedOut }

    /// What one question sent and cost, under its answer.
    struct Receipt: Equatable, Codable {
        let screenText: String
        let screenUnchanged: Bool
        let rowsSent: Int
        let rowsTotal: Int
        var promptTokens = 0
        var outputTokens = 0
        var costUSD = 0.0
        var rounds = 0
        var model = ""
    }

    /// An hour away starts a new chat; the cache would be cold by then anyway.
    static let idleReset: TimeInterval = 3600

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isThinking = false
    /// Names in answers that can be clicked to reveal the file (TE245): name → path, only for
    /// names this chat has seen, five characters or longer, and unique.
    @Published private(set) var linkTargets: [String: String] = [:]

    private var engine: AskClaudeEngine
    private var task: Task<Void, Never>?
    private var lastActivity: Date?
    private var streamingItem: UUID?
    private var receipt: Receipt?
    private var warnedNearLimit = false
    /// What was typed and not sent when the panel closed; Esc or ✕ doesn't throw it away.
    var draft = ""
    /// Counts key changes, so a read that overlapped one isn't cached.
    private var keyChanges = 0
    /// A folder was hidden since this chat began. What Claude already saw of it is in the chat it
    /// would resend, so the next question starts a new one.
    private var hiddenSinceStart = false
    private var knownHidden: Set<String>
    /// Counts questions and new chats, so a run that New Chat replaced is ignored as it unwinds.
    private var run = 0
    private let defaults: UserDefaults
    private let makeEngine: @MainActor () -> AskClaudeEngine
    private let readKey: @Sendable () -> String?
    /// The key, read once per chat. Reading it is a Keychain decrypt through securityd, which on
    /// 2026-10-30 held the main thread 4.1 s on the first question; it now happens off the main
    /// thread, and only once.
    private var cachedKey: String?
    private let now: () -> Date
    /// Where the chat is kept between launches (TE247); nil keeps it in memory only.
    private let storeURL: URL?

    static let defaultStore: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SyncCloud/AskClaude/chat.json")

    /// What is written between launches: the thread, when it was last used, and the transcript.
    private struct Stored: Codable {
        var items: [Item]
        var lastActivity: Date
        var engine: AskClaudeEngine.Snapshot
    }

    init(defaults: UserDefaults = .standard,
         makeEngine: @escaping @MainActor () -> AskClaudeEngine = { AskClaudeEngine() },
         readKey: @escaping @Sendable () -> String? = { AnthropicKeychain.read() },
         now: @escaping () -> Date = Date.init,
         // Nil by default: only the app's own chat passes the real file, so a test host (which IS
         // SyncCloud, with his home folder) can never write over his chat. It did once, 2026-10-30.
         storeURL: URL? = nil,
         // Where a changed key is announced; tests pass their own, since a post to the shared
         // one reaches every chat in the process.
         keyChanges: NotificationCenter = .default) {
        self.knownHidden = Set(AskClaudePrivacy.hiddenFolders(in: defaults))
        self.defaults = defaults
        self.makeEngine = makeEngine
        self.readKey = readKey
        self.now = now
        self.storeURL = storeURL
        self.engine = makeEngine()
        restore()
        // A key replaced or removed in Settings reaches this chat at once, not at its next start.
        keyCenter = keyChanges
        // Hiding a folder (from the panel or Settings) marks the chat to start fresh.
        hiddenObserver = keyChanges.addObserver(forName: AskClaudePrivacy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteHiddenListChanged() }
        }
        keyObserver = keyChanges.addObserver(forName: AnthropicKeychain.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedKey = nil
                self?.keyChanges += 1
            }
        }
    }

    nonisolated(unsafe) private var keyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var hiddenObserver: NSObjectProtocol?

    private func noteHiddenListChanged() {
        let now = Set(AskClaudePrivacy.hiddenFolders(in: defaults))
        if !now.subtracting(knownHidden).isEmpty, !items.isEmpty { hiddenSinceStart = true }
        knownHidden = now
    }
    nonisolated(unsafe) private var keyCenter: NotificationCenter?

    deinit {
        if let keyObserver { keyCenter?.removeObserver(keyObserver) }
        if let hiddenObserver { keyCenter?.removeObserver(hiddenObserver) }
    }

    /// Picks up the last chat if it was used within the hour; an older one is deleted.
    private func restore() {
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL) else {
            Logger.shared.warning("Ask Claude: the saved chat couldn’t be read and starts fresh")
            return
        }
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            // Said, not silent: the chat he expected back is gone, and this is why.
            Logger.shared.warning("Ask Claude: the saved chat couldn’t be read and starts fresh — \(error.localizedDescription)")
            return
        }
        guard now().timeIntervalSince(stored.lastActivity) <= Self.idleReset else {
            Logger.shared.info("Ask Claude: the saved chat is over an hour old, so a new one starts")
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        engine.restore(stored.engine)
        items = Self.withoutRepeatedSteps(stored.items).map(Self.notWaiting)
        lastActivity = stored.lastActivity
        refreshLinkTargets()
    }

    /// A chat saved before a move took its step's place still holds both lines.
    static func withoutRepeatedSteps(_ items: [Item]) -> [Item] {
        var kept: [Item] = []
        for item in items {
            if case .moved = item.kind, let last = kept.last, case .step(_, isError: false) = last.kind { kept.removeLast() }
            kept.append(item)
        }
        return kept
    }

    /// A card saved mid-download comes back offered: the wait ended with the app, and a second
    /// click finds the file already here if the download finished on its own.
    static func notWaiting(_ item: Item) -> Item {
        guard case .download(let download, .downloading) = item.kind else { return item }
        var item = item
        item.kind = .download(download, state: .offered)
        return item
    }

    private func save() {
        guard let storeURL else { return }
        guard let lastActivity, !items.isEmpty else {
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        let stored = Stored(items: items, lastActivity: lastActivity, engine: engine.snapshot)
        do {
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Logger.shared.warning("Ask Claude: the chat couldn’t be saved — \(error.localizedDescription)")
        }
    }

    private func refreshLinkTargets() {
        var byName: [String: [String]] = [:]
        for path in engine.handles.paths {
            let name = (path as NSString).lastPathComponent
            if name.count >= 5 { byName[name, default: []].append(path) }
        }
        linkTargets = byName.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// A line in the thread from the app itself, such as a folder just hidden.
    func addNote(_ text: String) {
        items.append(Item(kind: .note(text)))
        // Not mid-question: between rounds the transcript ends in tool calls whose results aren't
        // in it yet, and a chat restored from that is refused by the API. The run saves when it ends.
        if !isRunning { save() }
    }

    /// A file's text made safe inside a `<file>` block: a `</file>` in it can't end the block.
    static func fenced(_ text: String) -> String {
        text.replacingOccurrences(of: "</file", with: "<\u{200B}/file", options: .caseInsensitive)
    }

    /// The question that sends an offered passage (DS), and what the thread shows for it; marks the
    /// offer sent. Nil when that offer is gone or already sent.
    func takeOffer(_ id: UUID) -> (question: String, shown: String)? {
        // Not while a question runs: the send would be refused, and the offer marked sent anyway.
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }),
              case .offer(let passage, let sent) = items[index].kind, !sent else { return nil }
        items[index].kind = .offer(passage, sent: true)
        let shown = "Sent \(passage.whereInFile) of \(passage.fileName)"
        let question = "Here is \(passage.whereInFile) of \(passage.fileName), as data. Answer my last question from it.\n"
            + "<file name=\"\(AskClaudeScreenCard.escape(passage.fileName))\">\n\(AskClaudeChat.fenced(passage.text))\n</file>"
        return (question, shown)
    }

    /// Counts each card's waits, so Stop Waiting, or a second click, makes an earlier wait's end
    /// change nothing (TE258).
    private var downloadWaits: [UUID: Int] = [:]

    /// Download on a card (TE258): `refusal` is checked first, at the click (hidden since the card
    /// appeared, gone, not enough room); then the wait, and `landed` once the file is here.
    func download(_ id: UUID, refusal: (AskClaudeDownload) -> String?,
                  fetch: @escaping (AskClaudeDownload) async -> Fetched,
                  landed: @escaping (AskClaudeDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .download(let download, let state) = items[index].kind,
              state == .offered || state == .timedOut || Self.isFailure(state) else { return }
        if let why = refusal(download) {
            Logger.shared.info("Ask Claude didn’t download \(download.fileName): \(why)")
            setDownload(id, .failed(why))
            return
        }
        setDownload(id, .downloading)
        let wait = (downloadWaits[id] ?? 0) + 1
        downloadWaits[id] = wait
        Logger.shared.info("Ask Claude is downloading \(download.fileName)" + (download.size.map { ", \($0) bytes" } ?? ""))
        Task { [weak self] in
            let fetched = await fetch(download)
            guard let self, self.downloadWaits[id] == wait, self.downloadState(id) == .downloading else { return }
            switch fetched {
            case .landed:
                Logger.shared.info("Ask Claude downloaded \(download.fileName)")
                self.setDownload(id, .done)
                landed(download)
            case .failed:
                Logger.shared.warning("Ask Claude couldn’t download \(download.fileName): the cloud app didn’t deliver it")
                self.setDownload(id, .failed("\(download.sourceName) didn’t deliver it"))
            case .timedOut:
                Logger.shared.warning("Ask Claude stopped waiting for \(download.fileName): it didn’t arrive within ten minutes")
                self.setDownload(id, .timedOut)
            }
        }
    }

    /// Stop Waiting: the card goes back to offering. The download itself can't be stopped.
    func stopWaiting(_ id: UUID) {
        guard downloadState(id) == .downloading else { return }
        downloadWaits[id, default: 0] += 1
        setDownload(id, .offered)
    }

    /// Not Now.
    func declineDownload(_ id: UUID) {
        guard downloadState(id) == .offered else { return }
        setDownload(id, .declined)
    }

    /// The question that goes again once a download for a read lands, and what the thread shows.
    static func reask(after download: AskClaudeDownload) -> (question: String, shown: String) {
        ("\(download.fileName) (\(download.handle)) is on this Mac now. Read it and answer my last question.",
         "Downloaded \(download.fileName)")
    }

    func downloadState(_ id: UUID) -> DownloadState? {
        guard let item = items.first(where: { $0.id == id }), case .download(_, let state) = item.kind else { return nil }
        return state
    }

    private static func isFailure(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func setDownload(_ id: UUID, _ state: DownloadState) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .download(let download, _) = items[index].kind else { return }
        items[index].kind = .download(download, state: state)
        if !isRunning { save() }
    }

    var model: AskClaudeModels.Option {
        AskClaudeModels.option(for: defaults.string(forKey: AskClaudeModels.defaultsKey))
    }

    /// Starts a question about `screen`, run with `tools`.
    func ask(_ question: String, shown: String? = nil, screen: AskClaudeScreen, tools: AskClaudeToolRunning) {
        ask(question, shown: shown, preparing: { screen }, tools: tools)
    }

    /// Starts a question whose screen takes a moment to read (a folder the pane hasn't loaded is
    /// read from disk first). The question shows, and the chat counts as running, at once: a
    /// second Send in that moment would otherwise pass and then be dropped with its draft cleared.
    func ask(_ question: String, shown: String? = nil, preparing screen: @escaping @MainActor () async -> AskClaudeScreen,
             tools: AskClaudeToolRunning) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        if let last = lastActivity, now().timeIntervalSince(last) > Self.idleReset, !items.isEmpty {
            startOver()
            items.append(Item(kind: .note("Started a new chat after an hour away.")))
        }
        if hiddenSinceStart, !items.isEmpty {
            startOver()
            items.append(Item(kind: .note("Started a new chat: a folder was hidden, so nothing Claude saw of it stays.")))
        }
        // A chat keeps the model and answer style it started with (the API refuses a changed
        // system text under replayed thinking), so a change in Settings starts a new one.
        let model = self.model
        let detail = AskClaudeDetail.stored(in: defaults)
        if let setting = engine.setting, setting != AskClaudeEngine.setting(model: model, detail: detail), !items.isEmpty {
            // Same model and style, so what changed is Ask Claude itself: an update since.
            let settingsChanged = setting.split(separator: "|").prefix(2).map(String.init) != [model.id, detail.rawValue]
            startOver()
            items.append(Item(kind: .note(settingsChanged ? "Started a new chat for \(model.displayName), as set in Settings."
                                                          : "Started a new chat: Ask Claude was updated since this one began.")))
        }
        lastActivity = now()

        items.append(Item(kind: .user(shown ?? question)))
        streamingItem = nil
        isRunning = true
        isThinking = true
        run += 1
        let thisRun = run
        let engine = self.engine
        let readKey = self.readKey
        let known = cachedKey
        task = Task { [weak self] in
            let screen = await screen()
            guard let self, self.run == thisRun else { return }
            // Stopped while the screen was read: the run ends here, as a stop does later on.
            if Task.isCancelled {
                self.items.append(Item(kind: .note("Stopped.")))
                Logger.shared.info("Ask Claude question stopped before it was sent")
                self.finishRun()
                return
            }
            var handles = engine.handles
            let rendered = AskClaudeScreenCard.render(screen, handles: &handles)
            engine.handles = handles
            let block = engine.screenBlock(for: rendered.text)
            self.receipt = Receipt(screenText: rendered.text, screenUnchanged: block != rendered.text,
                                   rowsSent: rendered.rowsSent, rowsTotal: rendered.rowsTotal)
            let key: String?
            let keyChangesBefore = self.keyChanges
            if let known { key = known } else { key = await Task.detached(priority: .userInitiated) { readKey() }.value }
            // Not kept when the key changed during the read: that copy may be the old key.
            if self.run == thisRun, self.keyChanges == keyChangesBefore { self.cachedKey = key }
            // The style checked above, not read again: Settings can change it while the screen is read.
            await engine.ask(question, card: rendered.text, key: key, model: model, detail: detail, tools: tools) { [weak self] event in
                // A run New Chat replaced keeps unwinding; nothing it says reaches the new chat.
                guard let self, self.run == thisRun else { return }
                self.apply(event)
            }
            if self.run == thisRun { self.finishRun() }
        }
    }

    /// Stops the question running. What already ran stays done.
    func stop() {
        task?.cancel()
    }

    /// Clears the thread and the transcript. The handle table goes with it.
    func startOver() {
        task?.cancel()
        task = nil
        run += 1
        warnedNearLimit = false
        engine = makeEngine()
        cachedKey = nil
        items = []
        isRunning = false
        isThinking = false
        streamingItem = nil
        receipt = nil
        lastActivity = nil
        linkTargets = [:]
        hiddenSinceStart = false
        save()
    }

    private func apply(_ event: AskClaudeEvent) {
        switch event {
        case .text(let piece):
            isThinking = false
            if let id = streamingItem, let index = items.firstIndex(where: { $0.id == id }),
               case .assistant(let text) = items[index].kind {
                items[index].kind = .assistant(text + piece)
            } else {
                let item = Item(kind: .assistant(piece))
                streamingItem = item.id
                items.append(item)
            }
        case .thinking:
            isThinking = true
        case .retractAnswer:
            if let id = streamingItem { items.removeAll { $0.id == id } }
            streamingItem = nil
        case .step(let label, let isError):
            // Text after a tool call is a new paragraph under the step, not more of the old one.
            streamingItem = nil
            items.append(Item(kind: .step(label, isError: isError)))
        case .offer(let passage):
            streamingItem = nil
            items.append(Item(kind: .offer(passage, sent: false)))
        case .offerDownload(let download):
            streamingItem = nil
            items.append(Item(kind: .download(download, state: .offered)))
        case .movedView(let note):
            // The move says what the step said ("Opened Help" twice, 2026-10-30): it takes the
            // step's place rather than repeating it.
            if let last = items.last, case .step(_, isError: false) = last.kind { items.removeLast() }
            items.append(Item(kind: .moved(note)))
        case .round(let usage, let cost, let model):
            receipt?.promptTokens += usage.promptTokens
            receipt?.outputTokens += usage.outputTokens
            receipt?.costUSD += cost
            receipt?.rounds += 1
            receipt?.model = model
        case .finished(let reason):
            if reason == "max_tokens" {
                items.append(Item(kind: .note("The answer hit its length limit and was cut short.")))
            } else if reason == "canceled" {
                items.append(Item(kind: .note("Stopped.")))
            }
        case .problem(let problem):
            // A key that failed is read again next time: it may have just been fixed in Settings.
            if problem.kind == .keyRejected || problem.kind == .noKey { cachedKey = nil }
            items.append(Item(kind: .problem(problem)))
        }
    }

    private func finishRun() {
        if let receipt, receipt.rounds > 0 { items.append(Item(kind: .receipt(receipt))) }
        // The 80% warning (decision DZ), once per chat: the limit itself stops the next question.
        if !warnedNearLimit, case .nearLimit(let spent, let limit) = AskClaudeSpend.state(in: defaults, now: now()) {
            warnedNearLimit = true
            items.append(Item(kind: .note("Ask Claude has used \(AskClaudeSpend.format(spent)) of its \(AskClaudeSpend.format(limit)) limit this month.")))
        }
        receipt = nil
        streamingItem = nil
        isRunning = false
        isThinking = false
        task = nil
        refreshLinkTargets()
        save()
    }
}
