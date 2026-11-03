import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftUI
import Events

// MARK: - Tap to talk (TE311)
//
// A question can be spoken: tap ⌥Space in the panel, or its mic button, and talk. The words are
// turned into text on this Mac by SpeechAnalyzer's dictation model, go into the text box, and send
// as typed text does. No audio leaves the Mac, and nothing Claude is sent changes.
//
// Measured in the voice spike (2026-11-02, this Mac; memory `voice-spike-2026-11-02`):
// - **DictationTranscriber, given the words of the names on screen.** SpeechTranscriber ignores
//   contextual strings; this one heard 88% of the name words in his reading with them, 83%
//   without. A whole name as a hint does nothing (`AskClaudeVoiceHints`).
// - **A second tap finalizes in about 0.06 s.** Without one, silence ends the turn: 1.8 s of
//   quiet input once words have settled (`ending`). The transcriber's settling alone is not the
//   end: `say` clips settled only ~2 s after the last word, but his own voice settled at a
//   one-second pause and sent half a question. Without `.frequentFinalization` nothing settles
//   until a finalize, so it stays on.
// - **The microphone is the only prompt.** Dictation asked for nothing, even unauthorized.
// - **The speech model's status says `.supported` while it works**, so it isn't gated on; only a
//   non-nil installation request means there is something to download.

/// Where the voice comes from: the microphone, or a file in tests, which must never open the mic
/// (their host is SyncCloud.app).
@MainActor
protocol AskClaudeVoiceSource: AnyObject {
    /// Whether it may listen; the microphone asks the first time.
    func authorize() async -> Bool
    /// Starts sending audio, in whatever format it has, to `deliver`, on its own thread.
    func start(_ deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// The Mac's microphone, opened only while a question is being spoken.
@MainActor
final class AskClaudeMicrophone: AskClaudeVoiceSource {
    private let engine = AVAudioEngine()
    private var tapped = false

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone is connected." }
    }

    func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(_ deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw NoMicrophone() }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(deliver))
        tapped = true
        engine.prepare()
        try engine.start()
    }

    /// Built outside the main actor: the tap runs on the audio thread, and a block written inside
    /// this class would be taken to belong to the main actor.
    nonisolated private static func tap(_ deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in deliver(buffer) }
    }

    func stop() {
        if tapped { engine.inputNode.removeTap(onBus: 0) }
        tapped = false
        engine.stop()
    }
}

/// One spoken question: listening, the words so far, and the end of the turn.
@MainActor
final class AskClaudeVoice: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Asking for the microphone, or readying the speech model.
        case starting
        /// Downloading the speech model to this Mac, the first time it is needed.
        case installing
        case listening
        /// Tapped to send: the last words are settling.
        case finishing
    }

    @Published private(set) var phase = Phase.idle
    /// Words the transcriber has settled.
    @Published private(set) var settled = ""
    /// The words after them it may still change, shown greyed.
    @Published private(set) var tentative = ""
    /// The last few input levels, 0 to 1, oldest first, for the meter.
    @Published private(set) var levels: [Double] = Array(repeating: 0, count: AskClaudeVoice.meterBars)
    /// Why the last turn ended without words, until the next one starts.
    @Published var notice: String?

    var isActive: Bool { phase != .idle }

    static let meterBars = 12
    static let micRefused = "SyncCloud isn’t allowed to use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
    static let heardNothing = "Didn’t hear anything."

    /// How long the input must be quiet, after words have settled, for the turn to end by itself.
    /// **Not the transcriber's own settling.** With his voice it settles words at a one-second
    /// pause mid-question, and a turn that ended there sent half of it (hand check, 2026-11-02);
    /// `say` clips never settled before about 2 s, so the tests hadn't seen it.
    var endSilence: Duration = .milliseconds(1800)
    /// In a room too loud ever to count as quiet, a settled turn ends this long after the last
    /// words came in, so it can't listen for good.
    var settledLimit: Duration = .seconds(3)
    /// Words left tentative that nothing new has changed for this long end the turn too, so a
    /// transcriber that stalls mid-word can't keep the microphone open for good (v7.0 review).
    var tentativeLimit: Duration = .seconds(10)
    /// How long listening waits for a first word, counted from the last time the input was loud:
    /// a transcriber behind on a busy Mac mustn't end the turn while they are still talking.
    var firstWordLimit: Duration = .seconds(8)
    /// A level this high is someone talking, not the room.
    static let loud = 0.3

    private struct Session {
        let source: AskClaudeVoiceSource
        let analyzer: SpeechAnalyzer
        let feed: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<Void, Never>
    }

    private var session: Session?
    /// Each turn's number: work left over from a turn that ended checks it and stops.
    private var turn = 0
    private var starting: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var onHeard: (String) -> Void = { _ in }
    private var lastLoud = ContinuousClock.now
    private var lastWords = ContinuousClock.now

    /// Starts listening. `onHeard` gets the words once the turn ends with some, by a second tap
    /// (`finish`) or by silence; Esc (`cancel`) ends it with nothing.
    func start(from source: AskClaudeVoiceSource, hints: [String], onHeard: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        turn += 1
        let turn = turn
        self.onHeard = onHeard
        notice = nil
        settled = ""
        tentative = ""
        levels = Array(repeating: 0, count: Self.meterBars)
        phase = .starting
        starting = Task { await self.begin(turn, source: source, hints: hints) }
    }

    private func begin(_ turn: Int, source: AskClaudeVoiceSource, hints: [String]) async {
        guard await source.authorize() else {
            guard turn == self.turn else { return }
            Logger.shared.info("Ask Claude: the microphone isn’t allowed")
            end(notice: Self.micRefused)
            return
        }
        guard turn == self.turn else { return }
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en_US")
        let transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard turn == self.turn else { return }
                phase = .installing
                Logger.shared.info("Ask Claude: downloading the speech model for \(locale.identifier)")
                try await request.downloadAndInstall()
                guard turn == self.turn else { return }
                phase = .starting
            }
            if !hints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = hints
                try await analyzer.setContext(context)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CocoaError(.featureUnsupported)
            }
            try await analyzer.prepareToAnalyze(in: format)
            guard turn == self.turn else { await analyzer.cancelAndFinishNow(); return }
            let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: input)
            guard turn == self.turn else { feed.finish(); await analyzer.cancelAndFinishNow(); return }
            let results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.take(String(result.text.characters), isFinal: result.isFinal, turn: turn)
                    }
                } catch {
                    Logger.shared.warning("Ask Claude: transcription stopped: \(error.localizedDescription)")
                }
                // Ended by itself while listening: nothing more will come, so the turn ends with
                // what it heard, as a second tap would.
                self?.resultsEnded(turn: turn)
            }
            let converter = AskClaudeVoiceConverter(to: format)
            try source.start { [weak self] buffer in
                let level = AskClaudeVoiceConverter.level(of: buffer)
                if let converted = converter.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
                Task { @MainActor in self?.hear(level, turn: turn) }
            }
            session = Session(source: source, analyzer: analyzer, feed: feed, results: results)
            phase = .listening
            Logger.shared.info("Ask Claude: listening, with \(hints.count) word\(hints.count == 1 ? "" : "s") from the screen as hints")
            lastLoud = .now
            lastWords = .now
            watching = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, turn == self.turn, self.phase == .listening else { return }
                    let now = ContinuousClock.now
                    switch Self.ending(settled: self.settled, tentative: self.tentative, quiet: now - self.lastLoud,
                                       sinceWords: now - self.lastWords, endSilence: self.endSilence,
                                       settledLimit: self.settledLimit, tentativeLimit: self.tentativeLimit,
                                       firstWordLimit: self.firstWordLimit) {
                    case .goOn: continue
                    case .heardNothing:
                        self.cancel(notice: Self.heardNothing)
                    case .send:
                        Logger.shared.info("Ask Claude: the question ended in silence")
                        self.finish()
                    }
                    return
                }
            }
        } catch {
            source.stop()
            await analyzer.cancelAndFinishNow()
            guard turn == self.turn else { return }
            Logger.shared.warning("Ask Claude: couldn’t listen: \(error.localizedDescription)")
            end(notice: "Couldn’t listen: \(error.localizedDescription)")
        }
    }

    private func take(_ text: String, isFinal: Bool, turn: Int) {
        guard turn == self.turn, phase == .listening || phase == .finishing else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastWords = .now
        guard isFinal else {
            tentative = words
            return
        }
        if !words.isEmpty { settled = settled.isEmpty ? words : settled + " " + words }
        tentative = ""
    }

    /// The transcriber's results ended while still listening — it threw, or stopped — and the turn
    /// would otherwise wait on words that never settle.
    private func resultsEnded(turn: Int) {
        guard turn == self.turn, phase == .listening else { return }
        Logger.shared.info("Ask Claude: the transcriber stopped, so the question ends with what it heard")
        finish()
    }

    enum Ending: Equatable { case goOn, send, heardNothing }

    /// Whether a turn still listening should end, and how. It sends once words have settled,
    /// none are still tentative, and the input has been quiet for `endSilence` — or, in a room
    /// that never falls quiet, once nothing new has come in for `settledLimit`; with words still
    /// tentative, once nothing new has come in for `tentativeLimit`. With no words at all it gives
    /// up after `firstWordLimit` of quiet.
    nonisolated static func ending(settled: String, tentative: String, quiet: Duration, sinceWords: Duration,
                       endSilence: Duration, settledLimit: Duration, tentativeLimit: Duration,
                       firstWordLimit: Duration) -> Ending {
        if settled.isEmpty && tentative.isEmpty { return quiet >= firstWordLimit ? .heardNothing : .goOn }
        if !tentative.isEmpty { return sinceWords >= tentativeLimit ? .send : .goOn }
        return quiet >= endSilence || sinceWords >= settledLimit ? .send : .goOn
    }

    private func hear(_ level: Double, turn: Int) {
        guard turn == self.turn, phase == .listening else { return }
        levels = Array(levels.dropFirst()) + [level]
        if level >= Self.loud { lastLoud = .now }
    }

    /// The second tap: what was said so far settles and goes to `onHeard`. Before listening has
    /// begun there is nothing to send, so it is the same as Esc.
    func finish() {
        switch phase {
        case .idle, .finishing: return
        case .starting, .installing: cancel(); return
        case .listening: break
        }
        guard let session else { cancel(); return }
        phase = .finishing
        watching?.cancel()
        let turn = turn
        session.source.stop()
        session.feed.finish()
        Task {
            try? await session.analyzer.finalizeAndFinishThroughEndOfInput()
            // The results end with the analyzer; never wait on them for long.
            let late = Task { try? await Task.sleep(for: .seconds(2)); session.results.cancel() }
            await session.results.value
            late.cancel()
            guard turn == self.turn else { return }
            let heard = [settled, tentative].filter { !$0.isEmpty }.joined(separator: " ")
            end(notice: heard.isEmpty ? Self.heardNothing : nil)
            if !heard.isEmpty { onHeard(heard) }
        }
    }

    /// Esc, a closed panel, or a question started by a card: listening stops and keeps nothing.
    func cancel() { cancel(notice: nil) }

    private func cancel(notice: String?) {
        guard phase != .idle else { return }
        if let session {
            session.source.stop()
            session.feed.finish()
            session.results.cancel()
            Task { await session.analyzer.cancelAndFinishNow() }
        }
        starting?.cancel()
        end(notice: notice)
    }

    /// Back to idle, ready for the next turn; work left from this one finds the turn moved on.
    private func end(notice: String?) {
        turn += 1
        session = nil
        starting = nil
        watching?.cancel()
        settled = ""
        tentative = ""
        levels = Array(repeating: 0, count: Self.meterBars)
        self.notice = notice
        phase = .idle
    }
}

/// Converts what a source sends to the analyzer's format, on the source's thread, and reads its
/// level for the meter.
final class AskClaudeVoiceConverter: @unchecked Sendable {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let frames = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var given = false
        var error: NSError?
        // `.noDataNow`, not the end of the stream: the converter carries on with the next buffer.
        let status = converter.convert(to: out, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// The buffer's loudness, from silence (0) at −55 dBFS to full (1) at −15.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum = 0.0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<count { sum += Double(samples[index] * samples[index]) }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<count {
                let value = Double(samples[index]) / Double(Int16.max)
                sum += value * value
            }
        } else {
            return 0
        }
        let rms = (sum / Double(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 55) / 40))
    }
}

/// The listening strip's level meter: a bar per recent buffer, newest at the trailing end.
struct AskClaudeLevelMeter: View {
    let levels: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 3 + 13 * level)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

/// Gives the panel's window its talk keys and its going-away call (TE311), from a view behind
/// the panel that finds the window it is in.
struct AskClaudeTalkKeys: NSViewRepresentable {
    let onKey: (AskClaudeTalkKey) -> Bool
    let onGone: () -> Void

    func makeNSView(context: Context) -> HookView {
        let view = HookView(frame: .zero)
        view.onKey = onKey
        view.onGone = onGone
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {
        view.onKey = onKey
        view.onGone = onGone
        view.hook()
    }

    final class HookView: NSView {
        var onKey: (AskClaudeTalkKey) -> Bool = { _ in false }
        var onGone: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hook()
        }

        func hook() {
            guard let window = window as? AskClaudePanelWindow else { return }
            window.onTalkKey = { [weak self] key in self?.onKey(key) ?? false }
            window.onGone = { [weak self] in self?.onGone() }
        }
    }
}
