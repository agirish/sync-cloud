import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
import Sync
@testable import SyncCloud

// Tap to talk in Ask Claude. Every clip is made with `say` and fed at the pace a microphone would
// send it, then silence for as long as the turn lasts: the test host is SyncCloud.app, so a test
// must never open the real microphone.

/// A spoken clip, made afresh by each test that needs it, written under a name of its own and
/// renamed into place: the temp folder is shared by every test process on this Mac, and a clip
/// rewritten in place is missing or half-written while `say` runs (flaky-tests.md, "A spoken clip
/// another test was rewriting in place was missing or half-written when a turn read it").
enum AskClaudeVoiceClips {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudeVoiceTests", isDirectory: true)

    /// How long one `say` may take. It takes about 2 s, but once in about 120 runs it wrote its
    /// clip and never exited, and an unbounded wait held a test host's main thread for 52 minutes.
    static let sayLimit: TimeInterval = 30

    static func clip(_ text: String, named name: String) throws -> URL {
        let (url, fresh) = try paths(name, extension: "aiff")
        defer { try? FileManager.default.removeItem(at: fresh) }
        // Once more if it hangs.
        let said = try say(text, to: fresh) || say(text, to: fresh)
        try #require(said, "say didn't finish \(name) in \(Int(sayLimit)) s, twice")
        try putInPlace(fresh, at: url)
        return url
    }

    /// Runs `say` into `file`. False if it hasn't exited within `sayLimit`; it is stopped then.
    private static func say(_ text: String, to file: URL) throws -> Bool {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // A named voice, the one these clips were measured with; the default is a Mac setting.
        say.arguments = ["-v", "Samantha", "-o", file.path, text]
        let exited = DispatchSemaphore(value: 0)
        say.terminationHandler = { _ in exited.signal() }
        try say.run()
        guard exited.wait(timeout: .now() + sayLimit) == .success else {
            say.terminate()
            return false
        }
        try #require(say.terminationStatus == 0, "say couldn't make \(file.lastPathComponent)")
        return true
    }

    /// Where the clip goes, and a name of its own to write it under first.
    private static func paths(_ name: String, extension ext: String) throws -> (url: URL, fresh: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder.appendingPathComponent("\(name).\(ext)"), folder.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)"))
    }

    /// `rename(2)`, one step: whoever opens `url` gets a whole clip, the old one or the new.
    private static func putInPlace(_ fresh: URL, at url: URL) throws {
        let result = rename(fresh.path, url.path)
        try #require(result == 0, "couldn't put \(url.lastPathComponent) in place: \(String(cString: strerror(errno)))")
    }

    static var receipts: URL { get throws { try clip("Open the folder called Receipts", named: "receipts") } }

    /// Steady noise at about −20 dBFS: loud, with no words in it.
    static func noise(seconds: Double) throws -> URL {
        let (url, fresh) = try paths("noise", extension: "caf")
        defer { try? FileManager.default.removeItem(at: fresh) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float.random(in: -0.17...0.17, using: &generator) }
        let file = try AVAudioFile(forWriting: fresh, settings: format.settings)
        try file.write(from: buffer)
        // Its header is finished when it closes, so it closes before it moves.
        file.close()
        try putInPlace(fresh, at: url)
        return url
    }
}

/// Plays a clip as a microphone would: 0.1 s at a time, in real time, then silence until stopped.
@MainActor
final class AskClaudeClipSource: AskClaudeVoiceSource {
    let url: URL
    var allowed = true
    private(set) var authorizations = 0
    private(set) var starts = 0
    private(set) var isStreaming = false
    /// When the clip's last words had been sent.
    private(set) var audioEnded = false
    private var feeding: Task<Void, Never>?

    init(_ url: URL) { self.url = url }

    func authorize() async -> Bool {
        authorizations += 1
        return allowed
    }

    func start(_ deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let whole = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: whole)
        let step = AVAudioFrameCount(format.sampleRate / 10)
        let slices = stride(from: AVAudioFrameCount(0), to: whole.frameLength, by: Int(step)).compactMap {
            Self.slice(whole, from: $0, frames: min(step, whole.frameLength - $0))
        }
        starts += 1
        isStreaming = true
        feeding = Task.detached { [weak self] in
            for slice in slices {
                guard !Task.isCancelled else { return }
                deliver(slice)
                try? await Task.sleep(for: .milliseconds(100))
            }
            await MainActor.run { self?.audioEnded = true }
            while !Task.isCancelled {
                if let quiet = Self.slice(whole, from: 0, frames: step, silent: true) { deliver(quiet) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        isStreaming = false
        feeding?.cancel()
    }

    nonisolated private static func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount, frames: AVAudioFrameCount,
                                          silent: Bool = false) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let from = buffer.floatChannelData, let to = out.floatChannelData else { return nil }
        out.frameLength = frames
        for channel in 0..<Int(buffer.format.channelCount) {
            if silent {
                to[channel].initialize(repeating: 0, count: Int(frames))
            } else {
                to[channel].update(from: from[channel].advanced(by: Int(start)), count: Int(frames))
            }
        }
        return out
    }
}

/// What a turn gave, if anything.
@MainActor
private final class Heard {
    var text: String?
    var count = 0
    func take(_ text: String) {
        self.text = text
        count += 1
    }
}

@Suite struct AskClaudeTalkKeyTests {

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: code == 49 ? "\u{A0}" : "\u{1B}", charactersIgnoringModifiers: code == 49 ? " " : "\u{1B}",
                         isARepeat: isRepeat, keyCode: code)!
    }

    @Test func optionSpaceTalksAndEscCancels() {
        #expect(AskClaudeTalkKey(key(49, .option)) == .toggle(isRepeat: false))
        #expect(AskClaudeTalkKey(key(49, .option, repeat: true)) == .toggle(isRepeat: true))
        #expect(AskClaudeTalkKey(key(53, [])) == .cancel)
        // Caps Lock changes nothing; any other modifier makes it someone else's key.
        #expect(AskClaudeTalkKey(key(49, [.option, .capsLock])) == .toggle(isRepeat: false))
        for flags: NSEvent.ModifierFlags in [[], .shift, [.option, .shift], [.option, .command], .control] {
            #expect(AskClaudeTalkKey(key(49, flags)) == nil, "space with \(flags.rawValue)")
        }
        #expect(AskClaudeTalkKey(key(53, .command)) == nil)
    }
}

/// When a turn ends by itself (`AskClaudeVoice.ending`). Words can settle at a one-second pause
/// mid-question, so settled words alone must not send the first half.
@Suite struct AskClaudeVoiceEndingTests {

    private func ending(settled: String = "Find my latest", tentative: String = "", quiet: Double, sinceWords: Double = 0)
        -> AskClaudeVoice.Ending {
        AskClaudeVoice.ending(settled: settled, tentative: tentative, quiet: .milliseconds(Int(quiet * 1000)),
                              sinceWords: .milliseconds(Int(sinceWords * 1000)), endSilence: .milliseconds(1800),
                              settledLimit: .seconds(3), tentativeLimit: .seconds(10), firstWordLimit: .seconds(8))
    }

    /// `(settled, tentative, quiet, sinceWords, ending)`, seconds.
    @Test(arguments: [
        // A pause mid-question goes on though words have settled.
        ("Find my latest", "", 1.0, 0.2, AskClaudeVoice.Ending.goOn),
        ("Find my latest", "", 1.7, 1.5, .goOn),
        // Quiet after settled words sends.
        ("Find my latest", "", 1.8, 1.0, .send),
        // Words still tentative keep it listening.
        ("Find my latest", "tax form", 5, 5, .goOn),
        ("", "Find", 9, 9, .goOn),
        // Ten seconds with nothing new ends a turn whose words are still tentative, in a quiet
        // room or a loud one, or a stalled transcriber would keep it listening for good.
        ("Find my latest", "tax form", 10, 10, .send),
        ("", "Find", 0, 10, .send),
        ("", "Find", 0, 9.9, .goOn),
        // A room never quiet enough for the meter: settled words still send once nothing new comes.
        ("Find my latest", "", 0, 2.9, .goOn),
        ("Find my latest", "", 0, 3.0, .send),
        // No words at all gives up after the first-word limit.
        ("", "", 7.9, 0, .goOn),
        ("", "", 8.0, 0, .heardNothing),
    ] as [(String, String, Double, Double, AskClaudeVoice.Ending)])
    func aTurnEndsWhenItsWordsAndItsQuietSay(settled: String, tentative: String, quiet: Double, sinceWords: Double,
                                             expected: AskClaudeVoice.Ending) {
        #expect(ending(settled: settled, tentative: tentative, quiet: quiet, sinceWords: sinceWords) == expected)
    }
}

/// The spoken flag on a question: a mic in its bubble, kept with the chat.
@MainActor
@Suite struct AskClaudeSpokenItemTests {

    @Test func aSpokenQuestionIsMarkedAndATypedOneIsNot() async {
        // Scratch defaults and a center of its own: each question records its spend, and the test
        // host is SyncCloud, with his own.
        let d = ScratchDefaults("AskClaudeSpokenItemTests")
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: OneLineTransport(text: "Opened."), defaults: d) },
                                 readKey: { "k" }, keyChanges: NotificationCenter())
        let screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "", sort: "Name", rows: [], selection: [],
                                     toolsAvailable: true)
        chat.ask("Open Receipts", spoken: true, screen: screen, tools: NoTools())
        await waitUntil("the spoken question is answered", timeout: 60) { !chat.isRunning }
        chat.ask("Open Taxes", screen: screen, tools: NoTools())
        await waitUntil("the typed question is answered", timeout: 60) { !chat.isRunning }
        let questions = chat.items.filter { if case .user = $0.kind { true } else { false } }
        #expect(questions.map(\.kind) == [.user("Open Receipts"), .user("Open Taxes")])
        #expect(questions.map(\.spoken) == [true, nil])
    }

    /// Optional, so a chat saved before the field existed still loads, and a typed question
    /// writes nothing new.
    @Test func theFieldIsOptionalInTheSavedChat() throws {
        let typed = AskClaudeChat.Item(kind: .user("Open Taxes"))
        let typedJSON = try #require(String(data: JSONEncoder().encode(typed), encoding: .utf8))
        #expect(!typedJSON.contains("spoken"))
        let old = try JSONDecoder().decode(AskClaudeChat.Item.self, from: Data(typedJSON.utf8))
        #expect(old.spoken == nil && old.kind == .user("Open Taxes"))
        let spoken = AskClaudeChat.Item(kind: .user("Open Receipts"), spoken: true)
        let back = try JSONDecoder().decode(AskClaudeChat.Item.self, from: JSONEncoder().encode(spoken))
        #expect(back == spoken)
    }
}

/// The engine itself, fed clips. Serialized: each holds the on-device speech model for a turn,
/// and the turns are timed against the clips' real-time pace.
@MainActor
@Suite(.serialized, .machinePinned(.speechRecognition)) struct AskClaudeVoiceEngineTests {

    @Test func silenceEndsTheTurnWithWhatWasSaid() async throws {
        let voice = AskClaudeVoice()
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let heard = Heard()
        voice.start(from: source, hints: [], onHeard: heard.take)
        await waitUntil("the turn ends by itself", timeout: 60) { heard.text != nil }
        #expect(heard.text?.lowercased().contains("open the folder called receipts") == true, "heard \(heard.text ?? "nothing")")
        // Ended by the silence after the words, not before them.
        #expect(source.audioEnded)
        #expect(heard.count == 1)
        #expect(voice.phase == .idle && voice.notice == nil)
        #expect(!source.isStreaming)
    }

    /// The second tap. Silence can't end this turn: its limits are longer than the test.
    @Test func aSecondTapSendsWhatWasSaidSoFar() async throws {
        let voice = AskClaudeVoice()
        voice.endSilence = .seconds(120)
        voice.settledLimit = .seconds(120)
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let heard = Heard()
        voice.start(from: source, hints: [], onHeard: heard.take)
        await waitUntil("the clip is said", timeout: 60) { source.audioEnded }
        #expect(voice.phase == .listening)
        #expect(!(voice.settled + voice.tentative).isEmpty, "nothing on the strip as it was said")
        voice.finish()
        #expect(voice.phase == .finishing)
        await waitUntil("the tap sends", timeout: 10) { heard.text != nil }
        #expect(heard.text?.lowercased().contains("receipts") == true, "heard \(heard.text ?? "nothing")")
        #expect(voice.phase == .idle)
        #expect(!source.isStreaming)
    }

    @Test func escKeepsNothing() async throws {
        let voice = AskClaudeVoice()
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let heard = Heard()
        voice.start(from: source, hints: [], onHeard: heard.take)
        await waitUntil("words come in", timeout: 60) { !voice.tentative.isEmpty || !voice.settled.isEmpty }
        voice.cancel()
        #expect(voice.phase == .idle && voice.settled.isEmpty && voice.tentative.isEmpty)
        #expect(!source.isStreaming)
        // Longer than the transcriber's own end of speech, which would have sent it.
        try await Task.sleep(for: .seconds(4))
        #expect(heard.text == nil)
        #expect(voice.notice == nil)
    }

    /// The words on screen reach the transcriber. This clip is heard as "Ellie" without the hint
    /// and "Ally" with it. The whole name "Ally Statements" as one hint still gives "Ellie", so the
    /// hints are its words.
    @Test func theNamesOnScreenAreListenedFor() async throws {
        let clip = try AskClaudeVoiceClips.clip("Show me the statements from Ally", named: "ally")
        func hear(hints: [String]) async -> String {
            let voice = AskClaudeVoice()
            let heard = Heard()
            voice.start(from: AskClaudeClipSource(clip), hints: hints, onHeard: heard.take)
            await waitUntil("the turn ends", timeout: 60) { heard.text != nil }
            return heard.text ?? ""
        }
        let without = await hear(hints: [])
        let with = await hear(hints: AskClaudeVoiceHints.words(of: "Ally Statements") + ["Taxes"])
        #expect(!without.contains("Ally"), "the control heard \(without)")
        #expect(with.contains("Ally"), "heard \(with)")
    }

    @Test func aRefusedMicrophoneSaysWhereToAllowIt() async throws {
        let voice = AskClaudeVoice()
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        source.allowed = false
        voice.start(from: source, hints: [], onHeard: { _ in Issue.record("heard with the mic refused") })
        await waitUntil("listening gives up", timeout: 10) { voice.phase == .idle }
        #expect(voice.notice == AskClaudeVoice.micRefused)
        #expect(source.starts == 0)
    }

    @Test func nothingSaidEndsTheTurnWithANote() async throws {
        let voice = AskClaudeVoice()
        voice.firstWordLimit = .seconds(2)
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.clip("[[slnc 300]]", named: "quiet"))
        voice.start(from: source, hints: [], onHeard: { _ in Issue.record("heard words in silence") })
        await waitUntil("listening starts", timeout: 60) { voice.phase == .listening }
        await waitUntil("listening gives up", timeout: 10) { voice.phase == .idle }
        #expect(voice.notice == AskClaudeVoice.heardNothing)
        #expect(!source.isStreaming)
    }

    /// The wait for a first word runs from the last loud input, so a transcriber behind on a busy
    /// Mac never ends the turn while someone is still talking. Loud noise with no words stands in.
    @Test func loudInputKeepsItListeningPastTheLimit() async throws {
        let voice = AskClaudeVoice()
        voice.firstWordLimit = .seconds(2)
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.noise(seconds: 6))
        voice.start(from: source, hints: [], onHeard: { _ in })
        await waitUntil("listening starts", timeout: 60) { voice.phase == .listening }
        try await Task.sleep(for: .seconds(4))
        #expect(voice.phase == .listening, "gave up with \(voice.notice ?? "no note") while the input was loud")
        voice.cancel()
    }
}

/// The panel's keys and mic, in the window's column. Never ordered in: SwiftUI lays it out and the
/// column answers the talk keys it is handed.
@MainActor
@Suite(.serialized, .machinePinned(.speechRecognition)) struct AskClaudePanelVoiceTests {

    private final class Panel {
        let window: NSWindow
        let column: AskClaudeColumnView
        let host: NSHostingView<AskClaudePanel>
        var typed: [String] = []
        var spoken: [String] = []
        var closed = 0

        init(chat: AskClaudeChat, source: AskClaudeClipSource) {
            let container = CGSize(width: 1000, height: 800)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: container), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            column = AskClaudeColumnView(frame: NSRect(origin: .zero, size: container))
            host = NSHostingView(rootView: AskClaudePanel(chat: chat, place: AskClaudePanelHostedTests.place, accent: .blue,
                                                          accentFill: .blue, onAccent: .white, onAsk: { _ in }, onClose: {},
                                                          onOpenSettings: { _ in },
                                                          settingsBridge: .keySaved))
            host.frame = NSRect(origin: .zero, size: container)
            // Weak, not unowned: a turn still listening when a case ends (a failing one, or a
            // mutant that leaves the mic open) delivers its words after the fixture is gone, and an
            // unowned capture there would abort the whole test host.
            host.rootView = AskClaudePanel(chat: chat, place: AskClaudePanelHostedTests.place, accent: .blue, accentFill: .blue,
                                           onAccent: .white, onAsk: { [weak self] in self?.typed.append($0) },
                                           onClose: { [weak self] in self?.closed += 1 }, onOpenSettings: { _ in },
                                           settingsBridge: .keySaved, onAskSpoken: { [weak self] in self?.spoken.append($0) },
                                           voiceHints: { ["Receipts"] }, voiceSource: { source })
            window.contentView = NSView(frame: host.frame)
            window.contentView?.addSubview(column)
            column.adopt(host)
            column.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
        }

        /// ⌥Space (49) or Esc (53), as the column hands them to the panel: the column's own monitor
        /// needs the keyboard in it and a running event loop, which a test that is never key has not.
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
            let key: AskClaudeTalkKey = code == 49 ? .toggle(isRepeat: false) : .cancel
            _ = column.onTalkKey?(key)
        }
    }

    @Test func optionSpaceListensAndTheTurnSendsAsASpokenQuestion() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelVoiceTests"), readKey: { nil }, keyChanges: NotificationCenter())
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        #expect(panel.column.onTalkKey != nil, "the panel never reached its column")
        panel.press(49, .option)
        await waitUntil("the clip plays into it", timeout: 60) { source.isStreaming }
        await waitUntil("the turn ends and sends", timeout: 60) { !panel.spoken.isEmpty }
        #expect(panel.spoken.count == 1)
        #expect(panel.spoken.first?.lowercased().contains("receipts") == true, "sent \(panel.spoken)")
        #expect(panel.typed.isEmpty)
        #expect(!source.isStreaming)
        // Sent as typing is: it joins the questions Up brings back.
        #expect(chat.recallOlder(than: "") == panel.spoken.first)
        withExtendedLifetime(panel) {}
    }

    @Test func escWhileListeningKeepsNothingAndLeavesThePanelOpen() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelVoiceTests"), readKey: { nil }, keyChanges: NotificationCenter())
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        panel.press(49, .option)
        await waitUntil("listening starts", timeout: 60) { source.isStreaming }
        panel.press(53, [])
        #expect(!source.isStreaming)
        try await Task.sleep(for: .seconds(4))
        #expect(panel.spoken.isEmpty && panel.typed.isEmpty)
        #expect(panel.closed == 0)
        // With nothing being said, Esc is passed on: the column then stops an edit, and never closes
        // the panel.
        #expect(panel.column.onTalkKey?(.cancel) == false)
        withExtendedLifetime(panel) {}
    }

    @Test func aPausedColumnStopsTheMicrophone() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelVoiceTests"), readKey: { nil }, keyChanges: NotificationCenter())
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        panel.press(49, .option)
        await waitUntil("listening starts", timeout: 60) { source.isStreaming }
        panel.column.isPaused = true
        #expect(!source.isStreaming)
        try await Task.sleep(for: .seconds(4))
        #expect(panel.spoken.isEmpty)
        withExtendedLifetime(panel) {}
    }

    /// Said while Claude answers: it listens, and what was said waits for the answer to end, as a
    /// typed question does, marked spoken.
    @Test func whatIsSaidWhileClaudeAnswersWaitsForTheAnswer() async throws {
        let d = ScratchDefaults("AskClaudePanelVoiceTests")
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: NeverAnswers(), defaults: d) },
                                 readKey: { "k" }, keyChanges: NotificationCenter())
        chat.ask("Which are big?", screen: AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "", sort: "Name", rows: [],
                                                          selection: [], toolsAvailable: true), tools: NoTools())
        #expect(chat.isRunning)
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        panel.press(49, .option)
        await waitUntil("the clip plays into it", timeout: 60) { source.isStreaming }
        await waitUntil("the turn ends and waits", timeout: 60) { chat.queued != nil }
        #expect(chat.queued?.spoken == true)
        #expect(chat.queued?.text.lowercased().contains("receipts") == true, "queued \(chat.queued?.text ?? "nothing")")
        #expect(panel.spoken.isEmpty && panel.typed.isEmpty)
        #expect(chat.isRunning)
        chat.stop()
        await waitUntil("the question stops", timeout: 60) { !chat.isRunning }
        withExtendedLifetime(panel) {}
    }
}

/// Holds every request until it is cancelled.
private struct NeverAnswers: AskClaudeTransport {
    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}
