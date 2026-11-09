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
         onAsk: @escaping (String) -> Void = { _ in }, topLeading: Bool = false, parked: Bool = false) {
        let container = Self.container
        let panel = AskClaudePanel(chat: chat, place: place, accent: .blue, accentFill: .blue, onAccent: .white,
                                   onAsk: onAsk, onClose: {}, onOpenSettings: { _ in },
                                   settingsBridge: bridge)
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
