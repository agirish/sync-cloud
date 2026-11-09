import Foundation
import Events
import Sync

/// Ask Claude's past chats (TE306): every chat put away by New Chat, an hour away, an update or a
/// hidden folder, kept on this Mac for as long as Settings says (decision IL), listed by day,
/// searched here, and opened read-only or carried on.
///
/// A past chat is the same saved form as the chat in the panel (`AskClaudeChat.Stored`), so it reads
/// the same tolerant way: one card this build can't read becomes a note, never a lost chat.
@MainActor
final class AskClaudePastChats: ObservableObject {

    /// One file: the chat, and when it was put away.
    struct File: Codable {
        var id: UUID
        var archivedAt: Date
        var chat: AskClaudeChat.Stored
    }

    /// One line of a past chat as the read-only view draws it, its names already hidden where a
    /// folder has been hidden from Claude since (decision LN).
    enum Line: Equatable, Identifiable {
        case question(String, spoken: Bool)
        case answer(String)
        case meta(String)
        case card(symbol: String, text: String)

        var id: String {
            switch self {
            case .question(let text, _): "q" + text
            case .answer(let text): "a" + text
            case .meta(let text): "m" + text
            case .card(_, let text): "c" + text
            }
        }

        var text: String {
            switch self {
            case .question(let text, _), .answer(let text), .meta(let text), .card(_, let text): text
            }
        }
    }

    /// How Continue carries a chat on (decision JJ).
    enum Resume: Equatable {
        /// Claude reads it back in once, as it was: about `costUSD` at the model it was on.
        case readBack(costUSD: Double, tokens: Int)
        /// An update changed what Claude is told, a folder was hidden since, or it ended mid-answer:
        /// a new chat starts, carrying it as text, about `costUSD` to send.
        case asText(reason: String, costUSD: Double)
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let lastAsked: Date
        let bytes: Int
        let firstQuestion: String
        let folder: String?
        let questions: Int
        let costUSD: Double
        let hiddenNames: Int
        let lines: [Line]
        let resume: Resume
        /// What search looks in: questions and answers, folded for case and accents.
        let searchText: String

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id && a.lastAsked == b.lastAsked && a.hiddenNames == b.hiddenNames }

        /// "Immigration · 5 questions · 6.1¢"
        var detail: String {
            var parts: [String] = []
            if let folder, !folder.isEmpty { parts.append(folder) }
            parts.append("\(questions) question\(questions == 1 ? "" : "s")")
            if costUSD > 0 { parts.append(AskClaudeSpend.format(costUSD)) }
            if hiddenNames > 0 { parts.append("hid \(hiddenNames) item\(hiddenNames == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }

        /// The line of the chat that matches a search, for under its row.
        func match(_ query: String) -> String? {
            let folded = AskClaudePastChats.fold(query)
            guard !folded.isEmpty else { return nil }
            for line in lines {
                switch line {
                case .question(let text, _) where AskClaudePastChats.fold(text).contains(folded): return "You: " + text
                case .answer(let text) where AskClaudePastChats.fold(text).contains(folded): return "Claude: " + text
                default: continue
                }
            }
            return nil
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// The chat Delete last took, for Undo until the panel closes or another goes (decision LM).
    @Published private(set) var lastDeleted: (id: UUID, title: String)?
    private var deletedData: (data: Data, lastAsked: Date)?

    let files: AskClaudePastChatFiles?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var changeObserver: NSObjectProtocol?
    private var privacyObserver: NSObjectProtocol?

    /// `folder` nil keeps nothing: tests and previews that pass none never touch his chats.
    init(folder: URL?, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         notifications: NotificationCenter = .default) {
        files = folder.map(AskClaudePastChatFiles.init(folder:))
        self.defaults = defaults
        self.now = now
        self.notifications = notifications
        // At launch: what the keep length has passed goes, without reading any chat.
        if let files { files.prune(keep: AskClaudePastChatKeep.stored(in: defaults), now: now()) }
        changeObserver = notifications.addObserver(forName: AskClaudePastChatFiles.didChange, object: nil, queue: .main) { [weak self] note in
            // Its own posts carry it as the sender, and it has refreshed already.
            guard note.object as AnyObject? !== self else { return }
            MainActor.assumeIsolated {
                // Cleared or pruned elsewhere (Settings): an Undo would write a chat back after it.
                self?.forgetDeleted()
                self?.refresh()
            }
        }
        privacyObserver = notifications.addObserver(forName: AskClaudePrivacy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private let notifications: NotificationCenter

    deinit {
        if let changeObserver { notifications.removeObserver(changeObserver) }
        if let privacyObserver { notifications.removeObserver(privacyObserver) }
    }

    var keep: AskClaudePastChatKeep { AskClaudePastChatKeep.stored(in: defaults) }

    /// Called after every refresh, so the chat can follow a chat deleted or re-hidden under it.
    var onRefresh: (() -> Void)?

    /// Each file as last read, by its date: a refresh reads only what is new or changed.
    private var decoded: [UUID: (lastAsked: Date, file: File)] = [:]

    /// Deletes what the keep length has passed, then reads every chat. Run at launch, when the list
    /// opens, and after a chat is put away.
    func refresh() {
        guard let files else { entries = []; return }
        files.prune(keep: keep, now: now())
        let context = Context(hiddenFolders: AskClaudePrivacy.hiddenFolders(in: defaults),
                              model: AskClaudeModels.option(for: defaults.string(forKey: AskClaudeModels.defaultsKey)), now: now())
        let onDisk = files.entries()
        decoded = decoded.filter { id, _ in onDisk.contains { $0.id == id } }
        entries = onDisk.compactMap { entry in
            let file: File
            if let cached = decoded[entry.id], cached.lastAsked == entry.lastAsked {
                file = cached.file
            } else {
                guard let data = try? Data(contentsOf: entry.url) else { return nil }
                do {
                    file = try JSONDecoder().decode(File.self, from: data)
                } catch {
                    Logger.shared.warning("Ask Claude: a past chat couldn’t be read and isn’t listed — \(error.localizedDescription)")
                    return nil
                }
                decoded[entry.id] = (entry.lastAsked, file)
            }
            return Self.entry(file, lastAsked: entry.lastAsked, bytes: entry.bytes, context: context)
        }
        onRefresh?()
    }

    /// What every entry of one refresh is judged against: what is hidden now, through one matcher,
    /// and the model a Continue would ask.
    struct Context {
        let hiddenFolders: [String]
        let matcher: AskClaudePrivacy.Matcher
        let model: AskClaudeModels.Option
        let now: Date

        init(hiddenFolders: [String], model: AskClaudeModels.Option = AskClaudeModels.defaultModel, now: Date = Date()) {
            self.hiddenFolders = hiddenFolders
            matcher = AskClaudePrivacy.Matcher(hiddenFolders)
            self.model = model
            self.now = now
        }
    }

    /// Puts a chat away. A chat whose questions never got an answer isn't kept.
    func archive(_ chat: AskClaudeChat.Stored, id: UUID = UUID()) {
        guard let files, Self.isWorthKeeping(chat.items) else { return }
        let lastAsked = chat.talkedAt ?? chat.lastActivity
        do {
            let data = try JSONEncoder().encode(File(id: id, archivedAt: now(), chat: chat))
            try files.write(data, id: id, lastAsked: lastAsked)
            Logger.shared.info("Ask Claude: put a chat away in Past Chats")
        } catch {
            Logger.shared.warning("Ask Claude: a chat couldn’t be kept in Past Chats — \(error.localizedDescription)")
            return
        }
        refresh()
        notifications.post(name: AskClaudePastChatFiles.didChange, object: self)
    }

    /// "14 chats, 840 KB" for what is listed, or nil with none.
    var described: String? {
        guard !entries.isEmpty else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(entries.reduce(0) { $0 + $1.bytes }), countStyle: .file)
        return "\(entries.count) chat\(entries.count == 1 ? "" : "s"), \(size)"
    }

    /// One listed chat, reading the folder first when nothing has been read yet (at launch).
    func entry(_ id: UUID) -> Entry? {
        if entries.isEmpty { refresh() }
        return entries.first { $0.id == id }
    }

    /// The saved chat, for Continue.
    func chat(_ id: UUID) -> AskClaudeChat.Stored? {
        guard let data = files?.read(id) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data).chat
    }

    /// Takes a chat out of the list, for Continue: it becomes the chat in the panel.
    func take(_ id: UUID) -> AskClaudeChat.Stored? {
        guard let chat = chat(id) else { return nil }
        files?.delete(id)
        refresh()
        notifications.post(name: AskClaudePastChatFiles.didChange, object: self)
        return chat
    }

    func delete(_ id: UUID) {
        guard let files, let entry = entries.first(where: { $0.id == id }) else { return }
        deletedData = files.read(id).map { ($0, entry.lastAsked) }
        files.delete(id)
        lastDeleted = (id, entry.firstQuestion)
        Logger.shared.info("Ask Claude: deleted a past chat")
        refresh()
        notifications.post(name: AskClaudePastChatFiles.didChange, object: self)
    }

    func undoDelete() {
        guard let files, let deleted = lastDeleted, let kept = deletedData else { return }
        do {
            try files.write(kept.data, id: deleted.id, lastAsked: kept.lastAsked)
        } catch {
            Logger.shared.warning("Ask Claude: a deleted past chat couldn’t be put back — \(error.localizedDescription)")
        }
        forgetDeleted()
        refresh()
        notifications.post(name: AskClaudePastChatFiles.didChange, object: self)
    }

    /// The panel closed: Undo goes with it.
    func forgetDeleted() {
        lastDeleted = nil
        deletedData = nil
    }

    /// The chats matching a search, newest first: every chat for an empty one.
    func search(_ query: String) -> [Entry] {
        let folded = Self.fold(query)
        guard !folded.isEmpty else { return entries }
        return entries.filter { $0.searchText.contains(folded) }
    }

    // MARK: Building an entry

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A chat is kept once a question got an answer or a card.
    static func isWorthKeeping(_ items: [AskClaudeChat.Item]) -> Bool {
        guard items.contains(where: { if case .user = $0.kind { true } else { false } }) else { return false }
        return items.contains { item in
            switch item.kind {
            case .user, .step, .note, .problem, .receipt, .moved: false
            // The at-limit card and a held-back key stand in for an answer, not give one.
            case .settings(let card): card.askAgain == nil && card.caught == nil
            default: true
            }
        }
    }

    /// The names a past chat must not show: every file or folder it named inside something hidden
    /// from Claude now, and the hidden folders' own names when it saw inside them, or was about one.
    /// Longest first, so a name holding another is hidden whole.
    static func hiddenNames(in chat: AskClaudeChat.Stored, context: Context) -> [String] {
        let paths = chat.engine.handles.paths
        var names = Set<String>()
        for path in paths where context.matcher.isHidden(path) {
            let name = (path as NSString).lastPathComponent
            if name.count >= 2 { names.insert(name) }
        }
        let folderName = chat.folder.map { ($0 as NSString).lastPathComponent.lowercased() }
        for folder in context.hiddenFolders {
            let name = (folder as NSString).lastPathComponent
            guard name.count >= 2 else { continue }
            // By the matcher's spellings (a link, another case), not the path as typed.
            let one = AskClaudePrivacy.Matcher([folder])
            if paths.contains(where: one.isHidden) || folderName == name.lowercased() { names.insert(name) }
        }
        return names.sorted { $0.count > $1.count }
    }

    static let hiddenWord = "a hidden item"

    /// `text` with each name replaced, as a whole word only: "Tax" never cuts into "syntax".
    static func redact(_ text: String, _ names: [String]) -> String {
        guard !names.isEmpty else { return text }
        var text = text
        for name in names {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: hiddenWord))
        }
        return text
    }

    /// Whether something was hidden from Claude since the chat began, judged as `AskClaudeChat`
    /// judges it at launch: a chat saved without its baseline counts anything hidden.
    static func hiddenSince(_ chat: AskClaudeChat.Stored, hiddenNow: [String]) -> Bool {
        let now = Set(hiddenNow)
        guard let atStart = chat.hiddenAtStart else { return !now.isEmpty }
        return !now.subtracting(atStart).isEmpty
    }

    static func entry(_ file: File, lastAsked: Date, bytes: Int, context: Context) -> Entry {
        let chat = file.chat
        let names = hiddenNames(in: chat, context: context)
        let lines = Self.lines(chat.items).map { line -> Line in
            switch line {
            case .question(let text, let spoken): .question(redact(text, names), spoken: spoken)
            case .answer(let text): .answer(redact(text, names))
            case .meta(let text): .meta(redact(text, names))
            case .card(let symbol, let text): .card(symbol: symbol, text: redact(text, names))
            }
        }
        let questions = lines.compactMap { if case .question(let text, _) = $0 { text } else { nil } }
        let answers = lines.compactMap { if case .answer(let text) = $0 { text } else { nil } }
        let cost = chat.items.reduce(0.0) { sum, item in
            if case .receipt(let receipt) = item.kind { sum + receipt.costUSD } else { sum }
        }
        return Entry(id: file.id, lastAsked: lastAsked, bytes: bytes,
                     firstQuestion: questions.first ?? "A chat",
                     folder: chat.folder.map { redact(($0 as NSString).lastPathComponent, names) },
                     questions: questions.count, costUSD: cost, hiddenNames: names.count, lines: lines,
                     resume: resume(chat, hiddenNames: names.count, hiddenSince: hiddenSince(chat, hiddenNow: context.hiddenFolders),
                                    model: context.model, warm: context.now.timeIntervalSince(lastAsked) <= AskClaudeChat.idleReset,
                                    hiddenFolders: context.hiddenFolders),
                     searchText: fold((questions + answers).joined(separator: "\n")))
    }

    /// Continue's way for a saved chat (decision JJ), priced for `model`, the one the next question
    /// goes to. `warm`: asked within the hour, so Claude still has it cached and reading it again
    /// costs a cache read, unless the model changed.
    static func resume(_ chat: AskClaudeChat.Stored, hiddenNames: Int, hiddenSince: Bool, model: AskClaudeModels.Option,
                       warm: Bool, hiddenFolders: [String]) -> Resume {
        func asText(_ reason: String) -> Resume {
            let text = carriedText(chat, hiddenFolders: hiddenFolders)
            return .asText(reason: reason, costUSD: AskClaudeModels.catchUpCost(contextTokens: max(1, text.count / 4), to: model))
        }
        if hiddenNames > 0 {
            return asText("Something this chat named is hidden from Claude now, so it can’t pick it up where it was, and only your questions go.")
        }
        if hiddenSince { return asText("A folder was hidden from Claude since this chat began, so it can’t pick it up where it was.") }
        guard let setting = chat.engine.setting else {
            return asText("This chat ended while Claude was answering, so it can’t be picked up exactly where it was.")
        }
        guard AskClaudeEngine.isCurrent(setting: setting) else {
            return asText("Ask Claude was updated since this chat, so Claude can’t pick it up exactly where it was.")
        }
        let tokens = chat.engine.contextTokens ?? 0
        let cost = warm && chat.engine.lastKept?.model == model.id
            ? Double(tokens) * model.price.forPrompt(tokens).cacheRead / 1_000_000
            : AskClaudeModels.catchUpCost(contextTokens: tokens, to: model)
        return .readBack(costUSD: cost, tokens: tokens)
    }

    /// The read-only lines of a chat: questions, answers, what happened, and each card as one line
    /// saying what it was and how it ended. Their buttons are gone: their Undo ended with the chat.
    static func lines(_ items: [AskClaudeChat.Item]) -> [Line] {
        items.compactMap { item -> Line? in
            switch item.kind {
            case .user(let text): return .question(text, spoken: item.spoken == true)
            case .assistant(let text): return text.isEmpty ? nil : .answer(text)
            case .step(let text, _), .moved(let text), .note(let text): return .meta(text)
            case .receipt(let receipt):
                return receipt.costUSD > 0 ? .meta(AskClaudeSpend.format(receipt.costUSD)) : nil
            case .problem(let problem): return .meta(problem.message)
            case .offer(let passage, let sent):
                return .card(symbol: "doc.text", text: "\(passage.whereInFile) of \(passage.fileName)" + (sent ? " · sent to Claude" : " · not sent"))
            case .download(let download, let state):
                return .card(symbol: "icloud.and.arrow.down", text: "Download \(download.fileName) · \(word(state))")
            case .filing(let card):
                return .card(symbol: "folder", text: "Where \(card.fileName) could go: " + card.folders.map(\.label).joined(separator: ", "))
            case .plan(let plan):
                return .card(symbol: "checklist", text: plan.title + " · " + (plan.summary ?? "\(plan.state)"))
            case .choices(let choices, _):
                return .card(symbol: "list.bullet", text: choices.map(\.label).joined(separator: " · "))
            case .rule(let card):
                return .card(symbol: "wand.and.stars", text: "Rule: \(card.title) · \(card.state)")
            case .settings(let card):
                let rows = card.rows.map(\.id).joined(separator: ", ")
                return .card(symbol: "gearshape", text: (card.title ?? "Settings") + (rows.isEmpty ? "" : ": " + rows))
            case .pdf(let card):
                return .card(symbol: "doc.richtext", text: card.title + " · \(card.state)")
            case .found(let found):
                return .card(symbol: "magnifyingglass", text: "Found \(found.count) in \(found.folderLabel)")
            case .reads(let group):
                return .card(symbol: "doc.text.magnifyingglass", text: "Read " + group.files.map(\.fileName).joined(separator: ", "))
            case .refine(let card):
                return .card(symbol: "sparkles", text: card.title)
            case .tryAnother(let line):
                return .meta(line.text)
            }
        }
    }

    private static func word(_ state: AskClaudeChat.DownloadState) -> String {
        switch state {
        case .offered: "offered"
        case .downloading: "downloading"
        case .done: "downloaded"
        case .declined: "not now"
        case .failed: "failed"
        case .timedOut: "timed out"
        }
    }

    /// The most a carried chat sends, in characters: about 6,000 tokens, newest lines kept.
    static let carryLimit = 24_000

    /// The chat as text, for Continue when it can't be read back in. When it named something hidden
    /// since, only the questions go: an answer can hold what Claude read in a hidden file without
    /// naming it. A line naming something hidden never goes.
    static func carriedText(_ chat: AskClaudeChat.Stored, hiddenFolders: [String]) -> String {
        let names = hiddenNames(in: chat, context: Context(hiddenFolders: hiddenFolders))
        let questionsOnly = !names.isEmpty
        var dropped = 0
        var body = lines(chat.items).compactMap { line -> String? in
            let text: String
            switch line {
            case .question(let question, _): text = "Me: " + question
            case .answer(let answer) where !questionsOnly: text = "You: " + answer
            default: return nil
            }
            if names.contains(where: { redact(text, [$0]) != text }) { dropped += 1; return nil }
            return text
        }
        var cut = 0
        while body.count > 1, body.joined(separator: "\n\n").count > carryLimit {
            body.removeFirst()
            cut += 1
        }
        var note = questionsOnly
            ? "An earlier chat we had: my questions only, since I’ve hidden something it touched from you."
            : "An earlier chat we had, carried on as text. You don’t have what you read from files then; look again if you need it."
        if dropped > 0 { note += " \(dropped) line\(dropped == 1 ? " was" : "s were") left out: they named something I’ve hidden from you since." }
        if cut > 0 { note += " The first \(cut) line\(cut == 1 ? " was" : "s were") left out for length." }
        return "<earlier_chat>\n" + note + "\n\n" + body.joined(separator: "\n\n") + "\n</earlier_chat>"
    }
}
