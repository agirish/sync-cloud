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

/// A spoken clip, made once per run.
enum AskClaudeVoiceClips {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudeVoiceTests", isDirectory: true)

    static func clip(_ text: String, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".aiff")
        try? FileManager.default.removeItem(at: url)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // A named voice, the one these clips were measured with; the default is a Mac setting.
        say.arguments = ["-v", "Samantha", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0, "say couldn't make \(name)")
        return url
    }

    static var receipts: URL { get throws { try clip("Open the folder called Receipts", named: "receipts") } }

    /// Steady noise at about −20 dBFS: loud, with no words in it.
    static func noise(seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("noise.caf")
        try? FileManager.default.removeItem(at: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float.random(in: -0.17...0.17, using: &generator) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
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

    @Test func aPauseMidQuestionGoesOnThoughWordsHaveSettled() {
        #expect(ending(quiet: 1.0, sinceWords: 0.2) == .goOn)
        #expect(ending(quiet: 1.7, sinceWords: 1.5) == .goOn)
    }

    @Test func quietAfterSettledWordsSends() {
        #expect(ending(quiet: 1.8, sinceWords: 1.0) == .send)
    }

    @Test func wordsStillTentativeKeepItListening() {
        #expect(ending(tentative: "tax form", quiet: 5, sinceWords: 5) == .goOn)
        #expect(ending(settled: "", tentative: "Find", quiet: 9, sinceWords: 9) == .goOn)
    }

    /// Ten seconds with nothing new ends a turn whose words are still tentative, in a quiet room or
    /// a loud one, or a stalled transcriber would keep it listening for good.
    @Test func wordsTentativeForTenSecondsSend() {
        #expect(ending(tentative: "tax form", quiet: 10, sinceWords: 10) == .send)
        #expect(ending(settled: "", tentative: "Find", quiet: 0, sinceWords: 10) == .send)
        #expect(ending(settled: "", tentative: "Find", quiet: 0, sinceWords: 9.9) == .goOn)
    }

    /// A room never quiet enough for the meter: settled words still send once nothing new comes.
    @Test func aLoudRoomSendsOnceNothingNewComes() {
        #expect(ending(quiet: 0, sinceWords: 2.9) == .goOn)
        #expect(ending(quiet: 0, sinceWords: 3.0) == .send)
    }

    @Test func noWordsAtAllGivesUpAfterTheFirstWordLimit() {
        #expect(ending(settled: "", quiet: 7.9) == .goOn)
        #expect(ending(settled: "", quiet: 8.0) == .heardNothing)
    }
}

/// The spoken flag on a question: a mic in its bubble, kept with the chat.
@MainActor
@Suite struct AskClaudeSpokenItemTests {

    @Test func aSpokenQuestionIsMarkedAndATypedOneIsNot() async {
        // Scratch defaults and a center of its own: each question records its spend, and the test
        // host is SyncCloud, with his own.
        let d = ScratchDefaults("AskClaudeSpokenItemTests")
        let chat = AskClaudeChat(defaults: d, makeEngine: { AskClaudeEngine(transport: AnswersAtOnce(), defaults: d) },
                                 readKey: { "k" }, keyChanges: NotificationCenter())
        let screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "", sort: "Name", rows: [], selection: [],
                                     toolsAvailable: true)
        chat.ask("Open Receipts", spoken: true, screen: screen, tools: AnswersNothing())
        await waitUntil("the spoken question is answered", timeout: 60) { !chat.isRunning }
        chat.ask("Open Taxes", screen: screen, tools: AnswersNothing())
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

/// The panel's keys and mic, in its own kind of window. Never ordered in: SwiftUI lays it out and
/// the window takes the keys it is sent.
@MainActor
@Suite(.serialized, .machinePinned(.speechRecognition)) struct AskClaudePanelVoiceTests {

    private final class Panel {
        let window: AskClaudePanelWindow
        let host: NSHostingView<AskClaudePanel>
        var typed: [String] = []
        var spoken: [String] = []
        var closed = 0

        init(chat: AskClaudeChat, source: AskClaudeClipSource) {
            let container = CGSize(width: 1000, height: 800)
            window = AskClaudePanelWindow(contentRect: NSRect(origin: .zero, size: container), styleMask: [.borderless],
                                          backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AskClaudePanel(chat: chat, place: AskClaudePanelHandleTests.place, accent: .blue,
                                                          accentFill: .blue, onAccent: .white, onAsk: { _ in }, onClose: {},
                                                          onOpenSettings: {}, container: container,
                                                          settingsBridge: .keySaved))
            host.frame = NSRect(origin: .zero, size: container)
            // Weak, not unowned: a turn still listening when a case ends (a failing one, or a
            // mutant that leaves the mic open) delivers its words after the fixture is gone, and an
            // unowned capture there would abort the whole test host.
            host.rootView = AskClaudePanel(chat: chat, place: AskClaudePanelHandleTests.place, accent: .blue, accentFill: .blue,
                                           onAccent: .white, onAsk: { [weak self] in self?.typed.append($0) },
                                           onClose: { [weak self] in self?.closed += 1 }, onOpenSettings: {}, container: container,
                                           settingsBridge: .keySaved, onAskSpoken: { [weak self] in self?.spoken.append($0) },
                                           voiceHints: { ["Receipts"] }, voiceSource: { source })
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
            let space = code == 49
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: space ? "\u{A0}" : "\u{1B}", charactersIgnoringModifiers: space ? " " : "\u{1B}",
                                         isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
    }

    @Test func optionSpaceListensAndTheTurnSendsAsASpokenQuestion() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelVoiceTests"), readKey: { nil }, keyChanges: NotificationCenter())
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        #expect(panel.window.onTalkKey != nil, "the panel never reached its window")
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
        // With nothing being said, Esc is passed on, to close the panel as it always has. (Not
        // pressed here: a window that is never key has no field editor to carry it there.)
        #expect(panel.window.onTalkKey?(.cancel) == false)
        withExtendedLifetime(panel) {}
    }

    @Test func theWindowGoingAwayStopsTheMicrophone() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelVoiceTests"), readKey: { nil }, keyChanges: NotificationCenter())
        let source = AskClaudeClipSource(try AskClaudeVoiceClips.receipts)
        let panel = Panel(chat: chat, source: source)
        panel.press(49, .option)
        await waitUntil("listening starts", timeout: 60) { source.isStreaming }
        panel.window.orderOut(nil)
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
                                                          selection: [], toolsAvailable: true), tools: AnswersNothing())
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

/// Answers every request with one line of text.
private struct AnswersAtOnce: AskClaudeTransport {
    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let lines = [
            #"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":300}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Opened."}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return AskClaudeTransportResponse(status: 200, retryAfter: nil, lines: AsyncThrowingStream { c in
            lines.forEach { c.yield($0) }
            c.finish()
        })
    }
}

/// Holds every request until it is cancelled.
private struct NeverAnswers: AskClaudeTransport {
    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        try await Task.sleep(for: .seconds(600))
        throw CancellationError()
    }
}

@MainActor
private final class AnswersNothing: AskClaudeToolRunning {
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "", step: "")
    }
}
