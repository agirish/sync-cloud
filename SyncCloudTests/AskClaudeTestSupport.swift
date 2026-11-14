import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// A tool runner with nothing to run: every call answers empty.
@MainActor
final class NoTools: AskClaudeToolRunning {
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: "", step: "")
    }
}

/// Waits for the question to finish, and fails at the call if it never does. A fixed pump can give
/// up in silence under load and let the test change the model mid-question (`docs/flaky-tests.md`,
/// "Fixed pumps and fixed sleeps").
@MainActor
func waitUntilIdle(_ chat: AskClaudeChat, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil("the chat finishes its question", timeout: 30, sourceLocation: sourceLocation) { !chat.isRunning }
}

/// The event-stream lines of one model turn, as the Messages API sends them, for fake transports.
/// Each transport keeps its own sequencing; these are only its lines.
enum SSE {
    /// The turn's opening line: the model that served it and the input it read.
    static func start(model: String = "claude-sonnet-5-5", cacheRead: Int? = nil) -> String {
        let cache = cacheRead.map { #","cache_read_input_tokens":\#($0)"# } ?? ""
        return #"data: {"type":"message_start","message":{"model":"\#(model)","usage":{"input_tokens":300\#(cache)}}}"#
    }

    /// One text block saying `text`, which goes into the JSON string as it is (escape it first).
    static func textBlock(_ text: String, index: Int = 0) -> [String] {
        [#"data: {"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#,
         #"data: {"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#,
         #"data: {"type":"content_block_stop","index":\#(index)}"#]
    }

    /// One `tool_use` block calling `name`, its input JSON as it sits inside the delta's string.
    static func toolBlock(id: String, name: String, input: String, index: Int = 0) -> [String] {
        [#"data: {"type":"content_block_start","index":\#(index),"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#,
         #"data: {"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":"\#(input)"}}"#,
         #"data: {"type":"content_block_stop","index":\#(index)}"#]
    }

    /// The turn's close: why it stopped and what it wrote.
    static func end(_ stop: String = "end_turn", outputTokens: Int) -> [String] {
        [#"data: {"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":\#(outputTokens)}}"#,
         #"data: {"type":"message_stop"}"#]
    }

    /// A whole turn answering `text`.
    static func text(_ text: String, model: String = "claude-sonnet-5-5", cacheRead: Int? = nil,
                     stop: String = "end_turn", outputTokens: Int) -> [String] {
        [start(model: model, cacheRead: cacheRead)] + textBlock(text) + end(stop, outputTokens: outputTokens)
    }

    /// `lines` as a response, the stream finished after the last.
    static func response(_ lines: [String], status: Int = 200) -> AskClaudeTransportResponse {
        AskClaudeTransportResponse(status: status, retryAfter: nil, lines: AsyncThrowingStream { c in
            lines.forEach { c.yield($0) }
            c.finish()
        })
    }
}

/// A transport that answers every request with one short text reply.
struct OneLineTransport: AskClaudeTransport {
    let text: String

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        SSE.response(SSE.text(text, cacheRead: 4500, outputTokens: 700))
    }
}

/// A one-line transport that keeps each request's body, to read what was sent.
final class RecordingTransport: AskClaudeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [String] = []
    let text: String
    var bodies: [String] { lock.withLock { _bodies } }

    init(text: String = "ok") { self.text = text }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        lock.withLock { _bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
        return try await OneLineTransport(text: text).send(request)
    }
}

/// Plays one reply per request, in order, and keeps each request's body.
final class ScriptedChatTransport: AskClaudeTransport, @unchecked Sendable {
    enum Reply {
        case text(String)
        /// The first words of an answer, then silence until the question is stopped.
        case hang
        /// A turn of only thinking: empty, so it can't join the transcript.
        case onlyThinking
        /// One read_text call.
        case toolCall
        /// "Looking.", then one list_folder call.
        case textThenTool
        case status(Int)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var _bodies: [String] = []
    var bodies: [String] { lock.withLock { _bodies } }

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let reply = lock.withLock {
            _bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return replies.isEmpty ? Reply.status(500) : replies.removeFirst()
        }
        let start = SSE.start()
        let lines: [String]
        switch reply {
        case .text(let text):
            return try await OneLineTransport(text: text).send(request)
        case .hang:
            return AskClaudeTransportResponse(status: 200, retryAfter: nil, lines: AsyncThrowingStream { c in
                c.yield(start)
                c.yield(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
                c.yield(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Partly"}}"#)
            })
        case .onlyThinking:
            lines = [start,
                     #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
                     #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hm."}}"#,
                     #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
                     #"data: {"type":"content_block_stop","index":0}"#] + SSE.end(outputTokens: 5)
        case .toolCall:
            lines = [start] + SSE.toolBlock(id: "toolu_1", name: "read_text", input: #"{\"handle\":\"f1\"}"#)
                + SSE.end("tool_use", outputTokens: 20)
        case .textThenTool:
            lines = [start] + SSE.textBlock("Looking.")
                + SSE.toolBlock(id: "toolu_t", name: "list_folder", input: #"{\"folder\":\"\"}"#, index: 1)
                + SSE.end("tool_use", outputTokens: 20)
        case .status(let status):
            return SSE.response([], status: status)
        }
        return SSE.response(lines)
    }
}

/// A value a `@Sendable` closure can change and a test read back.
final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A lock-guarded count, bumped from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// A borderless window that may become key, which a plain borderless one may not: a test that
/// clicks the panel's buttons or types in its box needs one.
final class KeyableTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Ask Claude panel hosted in a 1000×800 borderless window: with `parked`, one that can become
/// key, parked off every display (a click reaches a SwiftUI button only in a window that is ordered
/// in); otherwise a plain one. Laid out, never ordered in or made key: each test does that, and
/// focuses the box, in its own order.
@MainActor
final class AskClaudePanelRig {
    static let container = CGSize(width: 1000, height: 800)
    let window: NSWindow
    let host: NSView

    init(chat: AskClaudeChat, bridge: AskClaudeSettingsBridge = .keySaved,
         place: AskClaudePlace = AskClaudePanelHostedTests.place,
         onAsk: @escaping (String) -> Void = { _ in }, topLeading: Bool = false, parked: Bool = false,
         suggestions: AskClaudeSuggestionSources? = nil) {
        let container = Self.container
        let panel = AskClaudePanel(chat: chat, place: place, accent: .blue, accentFill: .blue, onAccent: .white,
                                   onAsk: onAsk, onClose: {}, onOpenSettings: { _ in },
                                   settingsBridge: bridge, suggestions: suggestions)
        host = topLeading
            ? NSHostingView(rootView: AnyView(panel.frame(width: container.width, height: container.height,
                                                          alignment: .topLeading)))
            : NSHostingView(rootView: AnyView(panel))
        host.frame = NSRect(origin: .zero, size: container)
        window = parked
            ? KeyableTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            : NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        if parked { window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) }
        host.layoutSubtreeIfNeeded()
    }

    /// The first text field in the panel: the question box.
    var field: NSTextField? {
        func field(in view: NSView) -> NSTextField? { (view as? NSTextField) ?? view.subviews.lazy.compactMap(field).first }
        return field(in: host)
    }
}

/// Clicks `point`, in `window`'s coordinates, down then up, as a person would.
@MainActor
func click(_ point: NSPoint, in window: NSWindow) {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
        window.sendEvent(event)
    }
}

/// Clicks down `host` at `x`, from just under the panel's header, until `done` or past `limit`,
/// and returns how far from the top that happened. SwiftUI's bordered buttons are no `NSButton`s,
/// so a click is the only way to find one. Ordered in, never made key: a key test window takes key
/// from other suites' panels, and ⌘K's palette closes when it loses key (`CommandPalettePanelTests`).
@MainActor
func clickDown(_ window: NSWindow, _ host: NSView, x: CGFloat, limit: CGFloat = 320,
               done: () -> Bool) async -> CGFloat? {
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    for y in stride(from: 60.0, through: limit, by: 3) {
        click(NSPoint(x: x, y: host.bounds.height - y), in: window)
        try? await Task.sleep(for: .milliseconds(10))
        if done() { return y }
    }
    return nil
}
