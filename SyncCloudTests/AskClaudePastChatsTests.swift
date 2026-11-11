import Foundation
import Testing
import Sync
@testable import SyncCloud

/// Answers every request with one line, keeping each request's body.
private final class PastChatTransport: AskClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [String] = []
    let text: String
    var bodies: [String] { lock.withLock { _bodies } }

    init(text: String = "In Immigration.") { self.text = text }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        lock.withLock { _bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
        return SSE.response(SSE.text(text, cacheRead: 4500, outputTokens: 700))
    }
}

/// Past Chats (TE306): what is kept, what a past chat shows, and what Continue does.
@MainActor
@Suite struct AskClaudePastChatsTests {

    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudePast-\(UUID().uuidString)")
    private let center = NotificationCenter()

    private func defaults(_ test: String = #function) -> UserDefaults {
        ScratchDefaults("AskClaudePastChatsTests." + test.prefix { $0 != "(" })
    }

    private func screen(rows: [AskClaudeScreen.Row] = []) -> AskClaudeScreen {
        AskClaudeScreen(workspace: "Browse", source: "iCloud Drive", folder: "Immigration", sort: "Name",
                        rows: rows, selection: [], toolsAvailable: true)
    }

    private func make(_ transport: any AskClaudeTransport, _ d: UserDefaults, now: @escaping () -> Date = Date.init,
                      storeURL: URL? = nil) -> (AskClaudeChat, AskClaudePastChats) {
        let past = AskClaudePastChats(folder: folder, defaults: d, now: now, notifications: center)
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: transport, defaults: d) },
                                 readKey: { "k" }, now: now, storeURL: storeURL, keyChanges: center, pastChats: past)
        return (chat, past)
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    @Test func newChatPutsTheChatAwayAndItReadsAsItWas() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("Where is my I-797?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        #expect(chat.items.isEmpty)
        #expect(chat.earlier == nil)
        let entry = try #require(past.entries.first)
        #expect(past.entries.count == 1)
        #expect(entry.firstQuestion == "Where is my I-797?")
        #expect(entry.folder == "Immigration")
        #expect(entry.questions == 1)
        #expect(entry.costUSD > 0)
        #expect(entry.lines.contains(.answer("In Immigration.")))
    }

    /// What the row says a chat cost counts the answers Edit and Retry took back: spent all the
    /// same. Mutation: summing only the receipts left counts one answer of two.
    @Test func aTakenBackAnswerStillCounts() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("Where is my I-797?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        let one = chat.items.reduce(0.0) { if case .receipt(let r) = $1.kind { $0 + r.costUSD } else { $0 } }
        #expect(one > 0)
        let first = try #require(chat.items.first?.id)
        #expect(chat.rewind(from: first))
        chat.ask("Where is my I-94?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let entry = try #require(past.entries.first)
        #expect(abs(entry.costUSD - 2 * one) < 0.000_001, "row says \(entry.costUSD), two answers cost \(2 * one)")
    }

    /// Decision JK: an hour away, the next question starts a new chat and the old one stays above it.
    @Test func anHourAwayKeepsTheEarlierChatInViewAboveTheNewOne() async {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let (chat, past) = make(PastChatTransport(), d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.currentResume == nil)
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        guard case .readBack(let cost, _)? = chat.currentResume else { Issue.record("no Continue offered"); return }
        #expect(cost > 0)
        chat.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.earlier?.firstQuestion == "one")
        #expect(!chat.items.contains { $0.kind == .user("one") })
        #expect(!chat.items.contains { $0.kind == .note("Started a new chat after an hour away.") })
        #expect(past.entries.map(\.firstQuestion) == ["one"])
    }

    /// Decision JJ: Continue on a chat this build wrote reads it back in, as it was.
    @Test func continueReadsAPastChatBackInAndItLeavesTheList() async throws {
        defer { clean() }
        let d = defaults()
        let transport = PastChatTransport()
        let (chat, past) = make(transport, d)
        chat.ask("remember the first one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let id = try #require(past.entries.first?.id)
        guard case .readBack? = past.entries.first?.way else { Issue.record("not read back"); return }
        chat.continuePast(id)
        #expect(chat.items.contains { $0.kind == .user("remember the first one") })
        #expect(chat.continuing)
        #expect(past.entries.isEmpty)
        chat.ask("and now?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(!chat.continuing)
        let last = transport.bodies.last ?? ""
        #expect(last.contains("remember the first one"))
        #expect(last.contains("and now?"))
    }

    /// A chat from before an update can't be read back in: Continue carries it as text, once.
    @Test func continueAfterAnUpdateCarriesTheChatAsText() async throws {
        defer { clean() }
        let d = defaults()
        let transport = PastChatTransport()
        let (chat, past) = make(transport, d)
        chat.ask("what was in Taxes?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let id = try #require(past.entries.first?.id)
        // Written by an earlier build, whose instructions differ from this one's.
        let url = folder.appendingPathComponent(id.uuidString + ".json")
        var file = try JSONDecoder().decode(AskClaudePastChats.File.self, from: Data(contentsOf: url))
        file.chat.engine.setting = "an earlier build"
        try JSONEncoder().encode(file).write(to: url)
        past.refresh()
        guard case .asText? = past.entries.first?.way else { Issue.record("not carried as text"); return }

        chat.continuePast(id)
        #expect(chat.items.isEmpty)
        #expect(chat.earlier?.id == id)
        #expect(chat.carryingText?.contains("Me: what was in Taxes?") == true)
        chat.ask("and the 1099s?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.carryingText == nil)
        #expect(transport.bodies.last?.contains("<earlier_chat>") == true)
        // Sent once: the next question doesn't carry it again as new text.
        chat.ask("thanks", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        let last = try #require(transport.bodies.last)
        #expect(last.components(separatedBy: "<earlier_chat>").count == 2)
    }

    /// Decision LN: a folder hidden after the chat hides its names in the chat, its search, and
    /// what Continue carries.
    @Test func aFolderHiddenLaterIsHiddenInPastChats() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(text: "Secret-Plan.pdf is the newest; the Secret-Plan scan is older."), d)
        let row = AskClaudeScreen.Row(path: "/Users/me/Private/Secret-Plan.pdf", name: "Secret-Plan.pdf", isDirectory: false,
                                      kind: "PDF document", size: 1_000, modified: nil, tags: [])
        chat.ask("Which is Secret-Plan.pdf?", screen: screen(rows: [row]), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        #expect(past.search("Secret-Plan").count == 1)

        d.set(["/Users/me/Private"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        past.refresh()
        let entry = try #require(past.entries.first)
        #expect(entry.hiddenNames >= 1)
        #expect(entry.detail.contains("hid"))
        // The name without its extension too: "the Secret-Plan scan".
        #expect(!entry.lines.contains { $0.text.contains("Secret-Plan") })
        #expect(entry.lines.contains { $0.text.contains(AskClaudePastChats.hiddenWord) })
        #expect(past.search("Secret-Plan").isEmpty)
        guard case .asText = entry.way else { Issue.record("a chat naming a hidden file was offered as it was"); return }
        let stored = try #require(past.chat(entry.id))
        let carried = AskClaudePastChats.carriedText(stored, hiddenFolders: ["/Users/me/Private"])
        #expect(!carried.contains("Secret-Plan"))
        // An answer can hold what Claude read in the hidden file without naming it: none goes.
        #expect(!carried.contains("You: "))
    }

    @Test func aQuestionThatNeverGotAnAnswerIsntKept() {
        let asked = AskClaudeChat.Item(kind: .user("hi"))
        #expect(!AskClaudePastChats.isWorthKeeping([asked, AskClaudeChat.Item(kind: .note("Stopped."))]))
        #expect(!AskClaudePastChats.isWorthKeeping([AskClaudeChat.Item(kind: .assistant("hello"))]))
        #expect(AskClaudePastChats.isWorthKeeping([asked, AskClaudeChat.Item(kind: .assistant("hello"))]))
    }

    /// A chat saved before Past Chats (no id, folder or earlier) comes back after an hour rather than
    /// being deleted, and is put away when the next question starts afresh. Its questions keep every
    /// field added since: spoken, asked, turn and told.
    @Test func anOldSavedChatComesBackAndIsPutAwayWithEveryField() async throws {
        defer { clean() }
        let store = folder.appendingPathComponent("chat.json")
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        do {
            let (first, _) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
            first.ask("spoken one", spoken: true, editable: true, screen: screen(), tools: NoTools())
            await waitUntilIdle(first)
        }
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        for key in ["id", "folder", "earlier"] { json[key] = nil }
        try JSONSerialization.data(withJSONObject: json).write(to: store)

        clock = clock.addingTimeInterval(3 * 3600)
        let (again, past) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
        let question = try #require(again.items.first)
        #expect(question.kind == .user("spoken one"))
        #expect(question.spoken == true)
        #expect(question.asked?.question == "spoken one")
        #expect(question.turn != nil)
        #expect(again.startsOverAtNextQuestion)

        again.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(again)
        #expect(again.earlier?.firstQuestion == "spoken one")
        let keptID = try #require(past.entries.first?.id)
        let kept = try #require(past.chat(keptID))
        #expect(kept.items.first?.spoken == true)
        #expect(kept.items.first?.asked?.editable == true)
        #expect(kept.items.first?.turn == question.turn)
        #expect(past.entries.first?.lines.first == .question("spoken one", spoken: true))
    }

    /// A chat past the keep length isn't brought back at launch, and Past Chats doesn't keep it.
    @Test func aSavedChatPastTheKeepLengthIsNotBroughtBack() async throws {
        defer { clean() }
        let store = folder.appendingPathComponent("chat.json")
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        do {
            let (first, _) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
            first.ask("long ago", screen: screen(), tools: NoTools())
            await waitUntilIdle(first)
        }
        clock = clock.addingTimeInterval(31 * 86_400)
        let (later, past) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
        #expect(later.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.path))
        past.refresh()
        #expect(past.entries.isEmpty)
    }

    /// Decision LM: Delete asks nothing, and Undo brings it back until the list closes.
    @Test func deleteTakesAChatAndUndoPutsItBack() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("keep me", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let id = try #require(past.entries.first?.id)
        past.delete(id)
        #expect(past.entries.isEmpty)
        #expect(past.lastDeleted?.title == "keep me")
        past.undoDelete()
        #expect(past.entries.map(\.id) == [id])
        #expect(past.lastDeleted == nil)
        past.delete(id)
        past.forgetDeleted()
        past.undoDelete()
        #expect(past.entries.isEmpty)
    }

    @Test func searchMatchesQuestionsAndAnswersWithTheirLine() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(text: "The newest is the approval notice."), d)
        chat.ask("Find my latest I-797", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        #expect(past.search("i-797").count == 1)
        #expect(past.search("APPROVAL").first?.match("approval") == "Claude: The newest is the approval notice.")
        #expect(past.search("passport").isEmpty)
        #expect(past.search("  ").count == 1)
    }

    @Test func daysReadTodayYesterdayAWeekdayThenADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func entry(_ hoursAgo: Double) -> AskClaudePastChats.Entry {
            AskClaudePastChats.Entry(id: UUID(), lastAsked: now.addingTimeInterval(-hoursAgo * 3600), bytes: 0, firstQuestion: "q",
                                     folder: nil, questions: 1, costUSD: 0, hiddenNames: 0, lines: [], way: .asText(reason: "", tokens: 1),
                                     searchText: "q")
        }
        #expect(AskClaudePastChatsView.dayTitle(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar).contains("2025"))
        let titles = AskClaudePastChatsView.days([entry(0.1), entry(0.2), entry(24), entry(72), entry(24 * 20)], now: now, calendar: calendar)
            .map(\.title)
        #expect(titles.count == 4)
        #expect(titles[0] == "Today")
        #expect(titles[1] == "Yesterday")
        #expect(titles[2] != titles[3])
        #expect(titles[0 ..< 2].allSatisfy { !$0.contains(" ") })
    }

    /// A folder hidden since a chat began, which it never named, still rules out reading it back in
    /// (Claude may have seen the folder's name in a listing): the list must not promise it.
    @Test func aFolderHiddenSinceMakesContinueCarryTextAndSaySo() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("what's in Taxes?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        d.set(["/Users/me/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        past.refresh()
        let entry = try #require(past.entries.first)
        #expect(entry.hiddenNames == 0)
        guard case .asText(let reason, let cost) = entry.resume(model: AskClaudeModels.defaultModel, now: Date()) else {
            Issue.record("promised a read-back")
            return
        }
        #expect(reason.contains("hidden"))
        #expect(cost > 0)
        #expect(chat.continuePast(entry.id))
        #expect(chat.carryingText?.contains("You: In Immigration.") == true)
        #expect(!chat.continuing)
    }

    /// Clear All in Settings takes the chat shown above the line too, and an Undo from before it
    /// can't write a chat back.
    @Test func clearAllElsewhereTakesTheEarlierChatAndTheUndo() async throws {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let (chat, past) = make(PastChatTransport(), d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let first = try #require(past.entries.first?.id)
        chat.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        chat.ask("three", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.earlier?.firstQuestion == "two")
        past.delete(first)
        try #require(past.files).clearAll()
        center.post(name: AskClaudePastChatFiles.didChange, object: nil)
        #expect(chat.earlier == nil)
        #expect(past.lastDeleted == nil)
        past.undoDelete()
        #expect(past.entries.isEmpty)
    }

    /// Edit or Retry on the first question after Continue in a New Chat carries the earlier chat again.
    @Test func takingBackTheQuestionThatCarriedAChatCarriesItAgain() async throws {
        defer { clean() }
        let d = defaults()
        let transport = PastChatTransport()
        let (chat, past) = make(transport, d)
        chat.ask("first", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        d.set(["/Users/me/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        past.refresh()
        #expect(chat.continuePast(try #require(past.entries.first?.id)))
        chat.ask("next", editable: true, screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.carryingText == nil)
        let asked = try #require(chat.items.first { $0.kind == .user("next") })
        #expect(chat.rewind(from: asked.id))
        #expect(chat.carryingText?.contains("Me: first") == true)
    }

    /// A chat put away while Claude was answering can't be read back in, and says why; the at-limit
    /// card isn't an answer, so a chat holding only that isn't kept.
    @Test func aChatStoppedMidAnswerSaysSoAndAnAtLimitCardIsntAnAnswer() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(SlowSecondTransport(), d)
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.ask("two", screen: screen(), tools: NoTools())
        #expect(chat.isRunning)
        chat.newChat()
        guard case .asText(let reason, _)? = past.entries.first?.way else { Issue.record("offered as it was"); return }
        #expect(reason.contains("while Claude was answering"))

        let atLimit = AskClaudeChat.Item(kind: .settings(.caughtKey(in: "sk-ant-api03-xxxxxxxxxxxxxxxxxxxx")))
        #expect(!AskClaudePastChats.isWorthKeeping([AskClaudeChat.Item(kind: .user("hi")), atLimit]))
    }

    /// An on-device command after an hour away starts a new chat, as a question to Claude does.
    @Test func anOnDeviceCommandAfterAnHourStartsANewChat() async {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let (chat, _) = make(PastChatTransport(), d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        var wentToClaude = false
        chat.tryOnDevice("show hidden files", decide: { nil }, tools: NoTools(), otherwise: { wentToClaude = true })
        await waitUntilIdle(chat)
        #expect(wentToClaude)
        #expect(chat.earlier?.firstQuestion == "one")
        #expect(!chat.items.contains { $0.kind == .user("one") })
    }

    /// Cards from an earlier session have their buttons off: after an hour, and after Continue,
    /// though new ones don't.
    @Test func cardsFromAnEarlierSessionAreOff() async throws {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let (chat, _) = make(PastChatTransport(), d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        let old = try #require(chat.items.last?.id)
        #expect(!chat.cardIsExpired(old))
        // What the panel turns off for an expired item: cards, never the conversation or Refine.
        #expect(AskClaudeChat.expires(.download(AskClaudeDownload(fileName: "a.pdf", path: "/x/a.pdf", handle: "r1", size: 1, sourceName: "iCloud", purpose: .read), state: .offered)))
        #expect(!AskClaudeChat.expires(.assistant("hi")))
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        #expect(chat.cardIsExpired(old))
        chat.continueThisChat()
        #expect(chat.continuing)
        #expect(chat.cardIsExpired(old))
        chat.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(chat.cardIsExpired(old))
        #expect(!chat.cardIsExpired(try #require(chat.items.last?.id)))
    }


    /// A carry is built when the question goes: a folder hidden after Continue in a New Chat keeps
    /// what the chat read there from Claude, and a chat deleted since sends nothing.
    @Test func aCarryFollowsWhatIsHiddenAndDeletedAfterContinue() async throws {
        defer { clean() }
        let d = defaults()
        let transport = PastChatTransport(text: "Secret-Plan.pdf says to move in May.")
        let (chat, past) = make(transport, d)
        let row = AskClaudeScreen.Row(path: "/Users/me/Private/Secret-Plan.pdf", name: "Secret-Plan.pdf", isDirectory: false,
                                      kind: "PDF document", size: 1_000, modified: nil, tags: [])
        chat.ask("what does the plan say?", screen: screen(rows: [row]), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        d.set(["/Users/me/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        past.refresh()
        let id = try #require(past.entries.first?.id)
        #expect(chat.continuePast(id))
        #expect(chat.isCarrying)
        #expect(chat.carryingText?.contains("move in May") == true)

        d.set(["/Users/me/Medical", "/Users/me/Private"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        center.post(name: AskClaudePrivacy.didChange, object: nil)
        chat.ask("and then?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        let sent = try #require(transport.bodies.last)
        #expect(sent.contains("<earlier_chat>"))
        #expect(sent.contains("what does the plan say?"))
        #expect(!sent.contains("move in May"))
        #expect(!sent.contains("Secret-Plan"))

        // Deleted after Continue: the note goes, and nothing is carried.
        chat.newChat()
        #expect(chat.continuePast(id))
        #expect(chat.isCarrying)
        past.delete(id)
        #expect(!chat.isCarrying)
        chat.ask("anything?", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(transport.bodies.last?.contains("<earlier_chat>") == false)
    }

    /// Continue outlasts a quit: a read-back still reads the chat back in, and a carry still goes.
    @Test func continueSurvivesARelaunch() async throws {
        defer { clean() }
        let store = folder.appendingPathComponent("chat.json")
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        do {
            let (chat, past) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
            chat.ask("first", screen: screen(), tools: NoTools())
            await waitUntilIdle(chat)
            clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
            chat.continueThisChat()
            #expect(chat.continuing)
            _ = past
        }
        do {
            let (again, _) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
            #expect(again.continuing)
            #expect(!again.startsOverAtNextQuestion)
            again.newChat()
        }
        do {
            let (chat, past) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
            d.set(["/Users/me/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)
            past.refresh()
            #expect(chat.continuePast(try #require(past.entries.first?.id)))
            #expect(chat.isCarrying)
        }
        let (relaunched, _) = make(PastChatTransport(), d, now: { clock }, storeURL: store)
        #expect(relaunched.isCarrying)
        #expect(relaunched.carryingText?.contains("Me: first") == true)
        #expect(relaunched.earlier?.firstQuestion == "first")
    }

    /// The note over the box prices a read-back as the button did, and the button follows the model.
    @Test func continuesPriceFollowsTheModelAndTheNoteAgrees() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        let entry = try #require(past.entries.first)
        let models = AskClaudeModels.options
        let cheap = try #require(models.first { $0.id == chat.model.id })
        let other = try #require(models.first { $0.id != cheap.id })
        guard case .readBack(let warm, _) = entry.resume(model: cheap, now: Date()),
              case .readBack(let switched, _) = entry.resume(model: other, now: Date()),
              case .readBack(let cold, _) = entry.resume(model: cheap, now: Date().addingTimeInterval(2 * 3600)) else {
            Issue.record("not read back")
            return
        }
        #expect(warm < switched)
        #expect(warm < cold)
        #expect(chat.continuePast(entry.id))
        #expect(chat.continuingCost == warm)
    }

    /// An on-device command after an hour away keeps what Claude hasn't been told yet, as a question does.
    @Test func anOnDeviceCommandAfterAnHourKeepsWhatClaudeIsStillToHear() async throws {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let transport = PastChatTransport()
        let (chat, _) = make(transport, d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.tellClaude("They applied your card “File 3 Scans”.")
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        chat.tryOnDevice("show hidden files", decide: { nil }, tools: NoTools(), otherwise: {})
        await waitUntilIdle(chat)
        chat.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        #expect(transport.bodies.last?.contains("File 3 Scans") == true)
    }

    /// New Chat while an on-device command runs puts away a whole chat: Claude was never asked.
    @Test func newChatDuringAnOnDeviceCommandKeepsTheReadBack() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        chat.tryOnDevice("show hidden files", decide: { try? await Task.sleep(for: .seconds(5)); return nil },
                         tools: NoTools(), otherwise: {})
        #expect(chat.isRunning)
        chat.newChat()
        guard case .readBack? = past.entries.first?.way else { Issue.record("said it ended while Claude was answering"); return }
    }

    /// Undo on the chat shown above the line brings it back on screen.
    @Test func undoingADeleteBringsTheEarlierChatBack() async throws {
        defer { clean() }
        let d = defaults()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        let (chat, past) = make(PastChatTransport(), d, now: { clock })
        chat.ask("one", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        clock = clock.addingTimeInterval(AskClaudeChat.idleReset + 1)
        chat.ask("two", screen: screen(), tools: NoTools())
        await waitUntilIdle(chat)
        let id = try #require(chat.earlier?.id)
        past.delete(id)
        #expect(chat.earlier == nil)
        past.undoDelete()
        #expect(chat.earlier?.id == id)
    }

    /// Hiding a folder reaches the list and the chat above the line on its own, with no refresh asked for.
    @Test func hidingAFolderRedactsTheListAtOnce() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(text: "Secret-Plan.pdf is the newest."), d)
        let row = AskClaudeScreen.Row(path: "/Users/me/Private/Secret-Plan.pdf", name: "Secret-Plan.pdf", isDirectory: false,
                                      kind: "PDF document", size: 1_000, modified: nil, tags: [])
        chat.ask("Which is newest?", screen: screen(rows: [row]), tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        #expect(past.search("Secret-Plan").count == 1)
        d.set(["/Users/me/Private"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        center.post(name: AskClaudePrivacy.didChange, object: nil)
        #expect(past.search("Secret-Plan").isEmpty)
    }

    /// A chat about a folder hidden since doesn't show its name, even from a folder inside it; one
    /// asked while the folder on screen was hidden doesn't keep it.
    @Test func aChatsHiddenFolderIsntShownOnItsRow() async throws {
        defer { clean() }
        let d = defaults()
        let (chat, past) = make(PastChatTransport(), d)
        let inside = AskClaudeScreen(workspace: "Browse", source: "iCloud Drive", folder: "Medical/2024", sort: "Name",
                                     rows: [], selection: [], toolsAvailable: true)
        chat.ask("what's here?", screen: inside, tools: NoTools())
        await waitUntilIdle(chat)
        chat.newChat()
        #expect(past.entries.first?.folder == "2024")
        d.set(["/Users/me/iCloud/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)
        past.refresh()
        #expect(past.entries.first?.folder == nil)

        var hidden = inside
        hidden.folderHidden = true
        chat.ask("and here?", screen: hidden, tools: NoTools())
        await waitUntilIdle(chat)
        d.set([], forKey: AskClaudePrivacy.hiddenFoldersKey)
        chat.newChat()
        #expect(past.entries.first { $0.firstQuestion == "and here?" }?.folder == nil)
    }

    @Test func cardLinesReadInWordsNotCode() {
        #expect(AskClaudePastChats.word(AskClaudePlan.State.partlyApplied) == "partly applied")
        #expect(AskClaudePastChats.word(AskClaudePDFCard.State.quitWhileRunning) == "stopped when SyncCloud quit")
        #expect(AskClaudePastChats.word(AskClaudeRuleCard.State.declined) == "not now")
    }

    /// The length cut keeps the newest lines, whole, and says how many went.
    @Test func aLongCarryKeepsItsNewestLines() {
        let long = String(repeating: "x", count: 5_000)
        var items: [AskClaudeChat.Item] = []
        for n in 0 ..< 10 {
            items.append(AskClaudeChat.Item(kind: .user("q\(n) " + long)))
            items.append(AskClaudeChat.Item(kind: .assistant("a\(n)")))
        }
        let stored = AskClaudeChat.Stored(items: items, lastActivity: Date(), engine: AskClaudeEngine(defaults: ScratchDefaults("AskClaudePastChatsTests.carry")).snapshot,
                                          sinceLastAnswer: nil, hiddenAtStart: [], sharesAnswers: nil)
        let text = AskClaudePastChats.carriedText(stored, hiddenFolders: [])
        #expect(text.count < AskClaudePastChats.carryLimit + 1_000)
        #expect(text.contains("a9"))
        #expect(!text.contains("q0 "))
        #expect(text.contains("left out for length"))
    }

    @Test func hidingReplacesWholeWordsOnly() {
        #expect(AskClaudePastChats.redact("Tax files and syntax", ["Tax"]) == "a hidden item files and syntax")
        #expect(AskClaudePastChats.redact("the HR folder; THREE", ["HR"]) == "the a hidden item folder; THREE")
    }
}

/// Answers the first request at once and holds the second for ten seconds.
private final class SlowSecondTransport: AskClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let n = lock.withLock { count += 1; return count }
        if n > 1 { try await Task.sleep(for: .seconds(10)) }
        return SSE.response(SSE.text("ok", cacheRead: 4500, outputTokens: 700))
    }
}