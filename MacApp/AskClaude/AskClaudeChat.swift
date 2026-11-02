import CoreGraphics
import Foundation
import Settings
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
    let chat = AskClaudeChat(storeURL: AskClaudeChat.defaultStore, historyURL: AskClaudeChat.defaultHistoryStore)
    let visibility = AskClaudeVisibility()
}

@MainActor
final class AskClaudeVisibility: ObservableObject {
    @Published var isOpen = false
    /// Bumped to bring an open panel's text box the keyboard (TE263: a row's Ask Claude About This).
    @Published var focusRequests = 0
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
            /// Filing help's answer (TE255): folders with Go to Folder.
            case filing(AskClaudeFilingCard)
            /// A card of changes to review (TE285): rows ticked, sent elsewhere, untouched.
            case plan(AskClaudePlan)
            /// Buttons answering Claude's question (decision GB); used once one is clicked.
            case choices([AskClaudeChoice], used: Bool)
            /// A rule offered from a correction (TE286): Save or Not Now.
            case rule(AskClaudeRuleCard)
            /// Settings with their real controls (TE290); a click changes one.
            case settings(AskClaudeSettingCard)
            /// One of the PDF tools, run on their click (TE294).
            case pdf(AskClaudePDFCard)
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
        /// The model that answered (the last round's; a fallback's when one stepped in).
        var model = ""
        /// The model asked for (TE292). Optional, like `showsModel`, so a chat saved before they
        /// existed still loads.
        var requested: String?
        /// Whether the line under the answer names the model: when a fallback answered any round,
        /// when the model asked for differs from the last kept answer's, and on a chat's first
        /// answer when it isn't the default. A chat on one model doesn't say so under every answer.
        var showsModel: Bool?
        /// The first model other than the one asked for that answered a round, when a fallback
        /// stepped in: marked even when a later round went back to the model asked for.
        var fallbackModel: String?
        /// Whether the question joined the chat. A declined or stopped one's receipt doesn't count
        /// as the model the chat was last answered on.
        var kept: Bool?
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
    /// The question running, or last run: what a download card offered during it was wanted for.
    private var askedQuestion: String?
    private var streamingItem: UUID?
    /// The question running, as the thread shows it: where a switch's note goes (TE292).
    private var askedItem: UUID?
    private var receipt: Receipt?
    private var warnedNearLimit = false
    /// What was typed and not sent when the panel closed; Esc or ✕ doesn't throw it away.
    var draft = ""

    /// A row attached from its menu (TE263), shown as a chip above the text box until sent.
    struct Attachment: Equatable, Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        var id: String { path }
    }

    /// What the next question is about, in the order attached. Kept through New Chat: it belongs
    /// to the question not yet asked, not to the chat.
    @Published private(set) var attachments: [Attachment] = []
    /// Small pictures of the pages each PDF card acts on, by card and page — drawn for the card,
    /// never saved (TE294).
    @Published var pdfThumbnails: [UUID: [Int: CGImage]] = [:]
    /// Each PDF card's Edit ▸ Undo step, by card: the target it was registered against and the
    /// undo manager that holds it. Kept alive here — an undo manager doesn't retain its targets —
    /// for as long as the chat; a relaunch or New Chat drops them, and the card's Undo with them.
    var pdfUndoSteps: [UUID: (target: AnyObject, manager: UndoManager)] = [:]
    /// The form `pdf` with fill opened, while this chat lasts: only its filled copies are told to
    /// Claude (TE294).
    var fillOpened: String?
    /// Called with each PDF card as it joins the chat, and with each open one restored, so the
    /// window reads its files for it (TE294).
    var pdfCardOffered: ((UUID) -> Void)? {
        didSet {
            for item in items { if case .pdf(let card) = item.kind, card.state == .checking { pdfCardOffered?(item.id) } }
        }
    }

    /// Adds rows to the chips; one already there isn't added twice.
    func attach(_ items: [Attachment]) {
        let have = Set(attachments.map(\.path))
        attachments += items.filter { !have.contains($0.path) }
    }

    func detach(_ path: String) {
        attachments.removeAll { $0.path == path }
    }

    /// The chips, emptied: what the question being sent is about.
    func takeAttachments() -> [Attachment] {
        defer { attachments = [] }
        return attachments
    }
    /// Counts key changes, so a read that overlapped one isn't cached.
    private var keyChanges = 0
    /// A folder was hidden since this chat began. What Claude already saw of it is in the chat it
    /// would resend, so the next question starts a new one.
    private var hiddenSinceStart = false
    /// What was hidden when this chat began. Hiding something more restarts it at the next
    /// question; hiding and then un-hiding it before then does not (TE290 step 3).
    private var hiddenAtStart: Set<String>
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
    static let defaultHistoryStore: URL? = defaultStore?.deletingLastPathComponent().appendingPathComponent("prompts.json")

    /// The questions typed into the box, for Up and Down; kept between launches beside the chat.
    /// New Chat clears them; the chat's own fresh starts don't (`newChat`).
    private var promptHistory = AskClaudePromptHistory()
    private let historyURL: URL?

    /// What is written between launches: the thread, when it was last used, and the transcript.
    private struct Stored: Codable {
        var items: [Item]
        var lastActivity: Date
        var engine: AskClaudeEngine.Snapshot
        /// Lines for Claude not yet sent; absent in a chat saved before they existed.
        var sinceLastAnswer: [String]?

        init(items: [Item], lastActivity: Date, engine: AskClaudeEngine.Snapshot, sinceLastAnswer: [String]?) {
            self.items = items
            self.lastActivity = lastActivity
            self.engine = engine
            self.sinceLastAnswer = sinceLastAnswer
        }

        /// Items one at a time, so one that won't decode costs a note rather than the whole chat
        /// (TE290 step 0b). A card kind this build doesn't know, from a newer build or a later
        /// change to its fields, used to fail the decode of everything, and he lost the chat over it.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decode(TolerantItems.self, forKey: .items).items
            lastActivity = try container.decode(Date.self, forKey: .lastActivity)
            engine = try container.decode(AskClaudeEngine.Snapshot.self, forKey: .engine)
            sinceLastAnswer = try container.decodeIfPresent([String].self, forKey: .sinceLastAnswer)
        }
    }

    /// The saved items, each decoded on its own. A run of unreadable ones becomes one note in
    /// their place, so the chat reads as it did with a gap he can see.
    struct TolerantItems: Decodable {
        static let unreadableNote = "A card here couldn’t be read by this version of SyncCloud, so it isn’t shown."

        let items: [Item]

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var items: [Item] = []
            var skipped = 0
            while !container.isAtEnd {
                if let item = try? container.decode(Item.self) {
                    items.append(item)
                } else {
                    // A failed decode doesn't advance the container; this does.
                    _ = try container.decode(Skipped.self)
                    skipped += 1
                    if case .note(Self.unreadableNote)? = items.last?.kind { continue }
                    items.append(Item(kind: .note(Self.unreadableNote)))
                }
            }
            if skipped > 0 {
                Logger.shared.warning("Ask Claude: \(skipped) saved card\(skipped == 1 ? "" : "s") couldn’t be read and \(skipped == 1 ? "is" : "are") shown as a note")
            }
            self.items = items
        }

        /// Any one JSON value, read and thrown away.
        private struct Skipped: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    /// What they did on Claude's cards since its last answer (applied, undid, Not Now), sent with
    /// their next question: Claude sees nothing the card does, and would answer from the moment it
    /// offered the card.
    private(set) var sinceLastAnswer: [String] = []

    /// The settings cards' undo and redo (TE290 step 4b): the chat's, so they outlive the panel.
    let settingsUndo = AskClaudeSettingsUndo()

    /// A line about a card for Claude, sent with the next question.
    func tellClaude(_ line: String) {
        sinceLastAnswer.append(line)
        if !isRunning { save() }
    }

    /// A line that replaces an unsent one starting `prefix`: five clicks through a setting reach
    /// Claude as one line, first value to last (TE290).
    func tellClaude(_ line: String, replacing prefix: String) {
        sinceLastAnswer.removeAll { $0.hasPrefix(prefix) }
        tellClaude(line)
    }

    /// What Claude is told after Apply: the card, its summary, and each row that didn't run, why.
    static func applyReport(_ plan: AskClaudePlan) -> String {
        var line = "They applied your card “\(plan.title)”: \(plan.summary ?? "applied.")"
        let missed = plan.rows.filter { $0.applied == false }
        if !missed.isEmpty {
            line += " Didn’t run: " + missed.prefix(10).map { "\($0.name) (\($0.result ?? "skipped"))" }.joined(separator: "; ")
            if missed.count > 10 { line += "; and \(missed.count - 10) more" }
            line += "."
        }
        return line
    }

    /// **A file a line for Claude names, marked to get its handle when the line is sent** (TE294):
    /// "“Lease.pdf” ⟦/abs/Lease.pdf⟧" goes as "“Lease.pdf” (r52)". Kept as the path until then, so
    /// a line written while Claude answers never takes a handle the answer's own tools could give
    /// out again, and a restart mints it afresh in the new chat.
    static func fileMark(_ path: String) -> String { "⟦\(path)⟧" }

    /// The lines with each file mark made a handle — or, for a file now on Never show Claude, said
    /// to be in a hidden folder, with no handle.
    static func minted(_ lines: [String], handles: inout AskClaudeHandles, isHidden: (String) -> Bool) -> [String] {
        lines.map { line in
            var out = ""
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "⟦"), let close = rest[open...].firstIndex(of: "⟧") {
                out += rest[..<open]
                let path = String(rest[rest.index(after: open)..<close])
                out += isHidden(path) ? "(in a folder hidden from you)" : "(\(handles.handle(for: path)))"
                rest = rest[rest.index(after: close)...]
            }
            return out + rest
        }
    }

    /// The question as sent, with what happened on the cards in front of it, as data.
    static func withSinceLastAnswer(_ lines: [String], _ question: String) -> String {
        guard !lines.isEmpty else { return question }
        return "<since_last_answer>\n" + lines.map { "- " + AskClaudeScreenCard.escape($0) }.joined(separator: "\n")
            + "\n</since_last_answer>\n\n" + question
    }

    init(defaults: UserDefaults = .standard,
         makeEngine: @escaping @MainActor () -> AskClaudeEngine = { AskClaudeEngine() },
         readKey: @escaping @Sendable () -> String? = { AnthropicKeychain.read() },
         now: @escaping () -> Date = Date.init,
         // Nil by default: only the app's own chat passes the real file, so a test host (which IS
         // SyncCloud, with his home folder) can never write over his chat. It did once, 2026-10-30.
         storeURL: URL? = nil,
         historyURL: URL? = nil,
         // Where a changed key is announced; tests pass their own, since a post to the shared
         // one reaches every chat in the process.
         keyChanges: NotificationCenter = .default) {
        self.hiddenAtStart = Set(AskClaudePrivacy.hiddenFolders(in: defaults))
        self.defaults = defaults
        self.makeEngine = makeEngine
        self.readKey = readKey
        self.now = now
        self.storeURL = storeURL
        self.historyURL = historyURL
        self.engine = makeEngine()
        restore()
        restoreHistory()
        // A key replaced or removed in Settings reaches this chat at once, not at its next start.
        keyCenter = keyChanges
        // Hiding a folder (from the panel or Settings) marks the chat to start fresh.
        hiddenObserver = keyChanges.addObserver(forName: AskClaudePrivacy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteHiddenListChanged() }
        }
        // A Revert in Activity (TE290 step 5) reaches an open chat with its next question.
        revertObserver = keyChanges.addObserver(forName: SettingsRevert.didRevert, object: nil, queue: .main) { [weak self] note in
            let line = note.userInfo?["line"] as? String
            MainActor.assumeIsolated {
                guard let self, let line, !self.items.isEmpty else { return }
                self.tellClaude(line)
            }
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
    nonisolated(unsafe) private var revertObserver: NSObjectProtocol?

    private func noteHiddenListChanged() {
        let now = Set(AskClaudePrivacy.hiddenFolders(in: defaults))
        hiddenSinceStart = !now.subtracting(hiddenAtStart).isEmpty && !items.isEmpty
    }
    nonisolated(unsafe) private var keyCenter: NotificationCenter?

    deinit {
        if let keyObserver { keyCenter?.removeObserver(keyObserver) }
        if let hiddenObserver { keyCenter?.removeObserver(hiddenObserver) }
        if let revertObserver { keyCenter?.removeObserver(revertObserver) }
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
        sinceLastAnswer = stored.sinceLastAnswer ?? []
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
        var item = item
        switch item.kind {
        case .download(let download, .downloading):
            item.kind = .download(download, state: .offered)
        case .pdf(var card) where card.state == .running:
            // The app quit while it ran: the files it had written are on the card already.
            card.state = .quitWhileRunning
            item.kind = .pdf(card)
        case .pdf(var card) where card.state == .offered:
            // Read again before the button wakes: the files may have changed since.
            card.state = .checking
            item.kind = .pdf(card)
        case .plan(var plan) where plan.state == .applying:
            // The app quit while it applied: what ran is on disk, and its Undo went with the app.
            plan.state = .partlyApplied
            plan.summary = "SyncCloud quit while this was being applied, so some changes may not have run."
            item.kind = .plan(plan)
        default:
            break
        }
        return item
    }

    /// A card turned into another, in its place (Move Here on filing help's card, decision FE).
    func replace(_ id: UUID, with kind: Item.Kind) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = kind
        if !isRunning { save() }
    }

    private func save() {
        guard let storeURL else { return }
        guard let lastActivity, !items.isEmpty else {
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        let stored = Stored(items: items, lastActivity: lastActivity, engine: engine.snapshot,
                            sinceLastAnswer: sinceLastAnswer.isEmpty ? nil : sinceLastAnswer)
        do {
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Logger.shared.warning("Ask Claude: the chat couldn’t be saved — \(error.localizedDescription)")
        }
    }

    /// The question before the one in the box (Up), or nil when there's none.
    func recallOlder(than current: String) -> String? { promptHistory.older(than: current) }

    /// The question after the one in the box (Down), ending at the unsent draft; nil at the draft.
    func recallNewer(than current: String) -> String? { promptHistory.newer(than: current) }

    /// A question sent from the box, kept for Up.
    func rememberSent(_ question: String) {
        promptHistory.record(question)
        guard let historyURL else { return }
        do {
            let data = try JSONEncoder().encode(promptHistory.entries)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            Logger.shared.warning("Ask Claude: the typed questions couldn’t be saved — \(error.localizedDescription)")
        }
    }

    /// New Chat, the button: a fresh chat, and the questions typed so far forgotten with it. The
    /// chat's own fresh starts (an hour away, a hidden folder, an app update) keep them: they
    /// come as a question is sent, and that question has just been remembered.
    func newChat() {
        startOver()
        promptHistory = AskClaudePromptHistory()
        if let historyURL { try? FileManager.default.removeItem(at: historyURL) }
    }

    private func restoreHistory() {
        guard let historyURL, let data = try? Data(contentsOf: historyURL) else { return }
        guard let entries = try? JSONDecoder().decode([String].self, from: data) else {
            Logger.shared.warning("Ask Claude: the typed questions couldn’t be read, so Up starts empty")
            return
        }
        promptHistory = AskClaudePromptHistory(entries: entries)
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
    /// The file goes attached and the question it was wanted for goes with it, not as "my last
    /// question": an hour away, a folder hidden or an app update starts a new chat first, which
    /// holds neither the question nor the handle.
    static func reask(after download: AskClaudeDownload) -> (question: String, shown: String) {
        let shown = "Downloaded \(download.fileName)"
        guard let question = download.question else {
            return ("\(download.fileName) (\(download.handle)) is on this Mac now. Read it and answer my last question.", shown)
        }
        return ("\(download.fileName) is on this Mac now; it’s attached. Read it and answer what I asked before it was downloaded:\n\(question)",
                shown)
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

    /// Changes a card's rows (a tick, a folder picked from a row's menu); nothing on disk.
    func updatePlan(_ id: UUID, _ change: (inout AskClaudePlan) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .plan(var plan) = items[index].kind else { return }
        change(&plan)
        items[index].kind = .plan(plan)
        if !isRunning { save() }
    }

    /// The PDF card `id` (TE294).
    func pdfCard(_ id: UUID) -> AskClaudePDFCard? {
        guard let item = items.first(where: { $0.id == id }), case .pdf(let card) = item.kind else { return nil }
        return card
    }

    /// Changes the PDF card `id` in place — its options, what its files are, how its run ended.
    func updatePDFCard(_ id: UUID, _ change: (inout AskClaudePDFCard) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .pdf(var card) = items[index].kind else { return }
        change(&card)
        items[index].kind = .pdf(card)
        if !isRunning { save() }
    }

    /// The settings card `id` (TE290).
    func settingCard(_ id: UUID) -> AskClaudeSettingCard? {
        guard let item = items.first(where: { $0.id == id }), case .settings(let card) = item.kind else { return nil }
        return card
    }

    /// Changes the settings card `id` in place: what it changed from, a refusal.
    func updateSettingCard(_ id: UUID, _ change: (inout AskClaudeSettingCard) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .settings(var card) = items[index].kind else { return }
        change(&card)
        items[index].kind = .settings(card)
        if !isRunning { save() }
    }

    /// The rule card `id`, while it is still offered.
    func offeredRule(_ id: UUID) -> AskClaudeRuleCard? {
        guard let item = items.first(where: { $0.id == id }), case .rule(let card) = item.kind, card.state == .offered else { return nil }
        return card
    }

    /// A rule card answered: saved or Not Now.
    func answerRule(_ id: UUID, _ state: AskClaudeRuleCard.State) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .rule(var card) = items[index].kind else { return }
        card.state = state
        items[index].kind = .rule(card)
        if !isRunning { save() }
    }

    func plan(_ id: UUID) -> AskClaudePlan? {
        guard let item = items.first(where: { $0.id == id }), case .plan(let plan) = item.kind else { return nil }
        return plan
    }

    /// A button under Claude's question, clicked: the buttons are used, and it is handed back to
    /// send or to focus the box. Nil while a question runs, or once one was clicked.
    func takeChoice(_ id: UUID, at index: Int) -> AskClaudeChoice? {
        guard !isRunning, let i = items.firstIndex(where: { $0.id == id }),
              case .choices(let choices, let used) = items[i].kind, !used, choices.indices.contains(index) else { return nil }
        items[i].kind = .choices(choices, used: true)
        save()
        return choices[index]
    }

    var model: AskClaudeModels.Option {
        AskClaudeModels.option(for: defaults.string(forKey: AskClaudeModels.defaultsKey))
    }

    /// Where the model and style are kept: the composer's menu reads and writes these, so a test's
    /// chat never touches the app's own (TE292).
    var settingsDefaults: UserDefaults { defaults }

    /// Whether the next question starts a new chat rather than carrying this one on: an hour
    /// away, a folder hidden since it began, or an update the API won't continue it under. `ask`
    /// starts over for exactly these, and the menu prices no catch-up for a chat about to go.
    var startsOverAtNextQuestion: Bool {
        guard !items.isEmpty else { return false }
        if let last = lastActivity, now().timeIntervalSince(last) > Self.idleReset { return true }
        if hiddenSinceStart { return true }
        if let setting = engine.setting, !AskClaudeEngine.isCurrent(setting: setting) { return true }
        return false
    }

    /// The model the chat's last kept question went to, nil in a new chat or one the next
    /// question replaces: the menu prices a catch-up only for the others.
    var chatModel: String? { items.isEmpty || startsOverAtNextQuestion ? nil : engine.lastKept?.model }

    /// The chat's size as of its last kept round, for the catch-up estimate.
    var contextTokens: Int? { items.isEmpty || startsOverAtNextQuestion ? nil : engine.contextTokens }

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
            // What he did on cards still reaches Claude, less any line naming what he hid.
            let newlyHidden = Set(AskClaudePrivacy.hiddenFolders(in: defaults)).subtracting(hiddenAtStart)
            startOver(carrying: Self.withoutHidden(sinceLastAnswer, newlyHidden))
            items.append(Item(kind: .note("Started a new chat: a folder was hidden, so nothing Claude saw of it stays.")))
        }
        // A change of model or style, from the menu or Settings, carries on in this chat (TE292):
        // each question says which in its own block. Only an update that changed the system text
        // or the tools can't: replayed thinking is bound to both.
        let model = self.model
        let detail = AskClaudeDetail.stored(in: defaults)
        if let setting = engine.setting, !AskClaudeEngine.isCurrent(setting: setting), !items.isEmpty {
            startOver()
            items.append(Item(kind: .note("Started a new chat: Ask Claude was updated since this one began.")))
        }
        lastActivity = now()
        askedQuestion = question
        // Taken now and put back if the question never joins the transcript (a failed or stopped
        // request, an empty answer): Claude didn't get them, so they go with the next one.
        let pending = sinceLastAnswer
        sinceLastAnswer = []
        // A file a line names gets its handle now, between runs — never mid-run, where the
        // engine's own handle table would write over it (TE294).
        var minting = engine.handles
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: defaults))
        // A card's run still going is said every time, so Claude never answers as if it had ended.
        let running = items.compactMap { item -> String? in
            guard case .pdf(let card) = item.kind, card.state == .running else { return nil }
            return "Your card “\(card.title)” is still running; what it makes is reported when it ends."
        }
        let named = Self.minted(pending, handles: &minting, isHidden: hidden.isHidden) + running
        engine.handles = minting
        let sent = Self.withSinceLastAnswer(named, question)

        let questionItem = Item(kind: .user(shown ?? question))
        items.append(questionItem)
        askedItem = questionItem.id
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
                self.sinceLastAnswer = pending + self.sinceLastAnswer
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
                                   rowsSent: rendered.rowsSent, rowsTotal: rendered.rowsTotal, requested: model.id)
            let key: String?
            let keyChangesBefore = self.keyChanges
            if let known { key = known } else { key = await Task.detached(priority: .userInitiated) { readKey() }.value }
            // Not kept when the key changed during the read: that copy may be the old key.
            if self.run == thisRun, self.keyChanges == keyChangesBefore { self.cachedKey = key }
            // The model and style read above, not again: they can change while the screen is read.
            let joined = await engine.ask(sent, card: rendered.text, key: key, model: model, detail: detail,
                                          tools: tools) { [weak self] event in
                // A run New Chat replaced keeps unwinding; nothing it says reaches the new chat.
                guard let self, self.run == thisRun else { return }
                self.apply(event)
            }
            guard self.run == thisRun else { return }
            // Claude has them only if the question joined the transcript: a stop or an empty turn
            // ends without a problem and keeps nothing, and a problem in a later round comes after.
            if !joined { self.sinceLastAnswer = pending + self.sinceLastAnswer }
            self.finishRun(joined: joined)
        }
    }

    /// Stops the question running. What already ran stays done.
    func stop() {
        task?.cancel()
    }

    /// Report lines with every one that names a newly hidden item left out, and one line saying so:
    /// a restart for privacy must not carry the name into the new chat.
    static func withoutHidden(_ lines: [String], _ hidden: Set<String>) -> [String] {
        let names = hidden.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty }
        let kept = lines.filter { line in !names.contains { line.localizedCaseInsensitiveContains($0) } }
        let dropped = lines.count - kept.count
        guard dropped > 0 else { return kept }
        return kept + ["They hid an item from you; \(dropped == 1 ? "a note about it was" : "\(dropped) notes about it were") left out."]
    }

    /// Clears the thread and the transcript. The handle table goes with it. `lines` are report
    /// lines the new chat sends (a restart for privacy keeps them); every other start drops them.
    func startOver(carrying lines: [String] = []) {
        task?.cancel()
        task = nil
        run += 1
        warnedNearLimit = false
        engine = makeEngine()
        cachedKey = nil
        items = []
        pdfThumbnails = [:]
        for step in pdfUndoSteps.values { step.manager.removeAllActions(withTarget: step.target) }
        pdfUndoSteps = [:]
        fillOpened = nil
        // About cards the new chat doesn't have, unless the caller carries them on.
        sinceLastAnswer = lines
        isRunning = false
        isThinking = false
        streamingItem = nil
        receipt = nil
        lastActivity = nil
        linkTargets = [:]
        hiddenSinceStart = false
        hiddenAtStart = Set(AskClaudePrivacy.hiddenFolders(in: defaults))
        // The cards are gone; so are their undo steps. Their changes stay.
        settingsUndo.clear()
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
        case .offerDownload(var download):
            streamingItem = nil
            download.question = askedQuestion
            items.append(Item(kind: .download(download, state: .offered)))
        case .filing(let card):
            streamingItem = nil
            items.append(Item(kind: .filing(card)))
        case .plan(let plan):
            streamingItem = nil
            items.append(Item(kind: .plan(plan)))
        case .choices(let choices):
            streamingItem = nil
            items.append(Item(kind: .choices(choices, used: false)))
        case .rule(let card):
            streamingItem = nil
            items.append(Item(kind: .rule(card)))
        case .settings(let card):
            streamingItem = nil
            let item = Item(kind: .settings(card))
            items.append(item)
            settingsUndo.recordClaude(card.rows, card: item.id)
        case .pdf(let card):
            streamingItem = nil
            // A newer card for the same tool on the same files takes the older one's place.
            for index in items.indices {
                if case .pdf(var old) = items[index].kind, old.isReplaced(by: card) {
                    old.state = .replaced
                    items[index].kind = .pdf(old)
                }
            }
            let item = Item(kind: .pdf(card))
            items.append(item)
            pdfCardOffered?(item.id)
        case .kept(let previous, let now):
            // A switch is noted once it reached Claude, at the question that made it (TE292). A
            // question that failed, was declined or stopped before joining the chat notes nothing,
            // and the next one that joins makes the note instead.
            guard let previous, let at = askedItem.flatMap({ id in items.firstIndex { $0.id == id } }) else { break }
            var notes: [String] = []
            if previous.model != now.model {
                notes.append("Now on \(AskClaudeModels.option(for: now.model).displayName).")
            }
            if previous.detail != now.detail, let detail = AskClaudeDetail(rawValue: now.detail) {
                notes.append("Answers now \(detail.label).")
            }
            if !notes.isEmpty { items.insert(Item(kind: .note(notes.joined(separator: " "))), at: at) }
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
            if let requested = receipt?.requested, model != requested, receipt?.fallbackModel == nil {
                receipt?.fallbackModel = model
            }
        case .finished(let reason):
            if reason == "max_tokens" {
                items.append(Item(kind: .note("The answer hit its length limit and was cut short.")))
            } else if reason == "canceled" {
                items.append(Item(kind: .note("Stopped.")))
            }
        case .problem(let problem):
            // A key that failed is read again next time: it may have just been fixed in Settings.
            if problem.kind == .keyRejected || problem.kind == .noKey { cachedKey = nil }
            // At the limit, the panel shows the limit itself (TE290 step 6): raising it there
            // offers Ask Again with the question.
            if problem.kind == .limitReached, case .overLimit(let spent, let limit) = AskClaudeSpend.state(in: defaults, now: now()) {
                items.append(Item(kind: .settings(.atLimit(spent: spent, limit: limit,
                                                           resets: AskClaudeSpend.resetDate(after: now()), question: askedQuestion))))
                break
            }
            items.append(Item(kind: .problem(problem)))
        }
    }

    private func finishRun(joined: Bool = false) {
        if var receipt, receipt.rounds > 0 {
            receipt.kept = joined
            // Compared with the last answer Claude kept, by the model asked for (a receipt saved
            // before TE292 has only the one that answered).
            let lastKept = items.reversed().lazy.compactMap { item -> Receipt? in
                if case .receipt(let r) = item.kind, r.kept != false { r } else { nil }
            }.first
            let asked = receipt.requested ?? receipt.model
            let changed = lastKept.map { ($0.requested ?? $0.model) != asked } ?? (asked != AskClaudeModels.defaultModel.id)
            receipt.showsModel = receipt.fallbackModel != nil || changed
            items.append(Item(kind: .receipt(receipt)))
        }
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
