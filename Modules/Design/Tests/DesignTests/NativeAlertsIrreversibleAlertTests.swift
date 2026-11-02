import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmIrreversible` — the confirm/cancel alert for a deletion with no Trash to
/// come back from (the API key, the spend totals the caps count against).
///
/// Asked of the alert `irreversibleAlert` builds, never of `confirmIrreversible`, whose
/// `runModal()` would park this test's main thread on a session nothing here can dismiss.
@Suite @MainActor struct NativeAlertsIrreversibleAlertTests {

    private func alert() -> NSAlert {
        NativeAlerts.irreversibleAlert(messageText: "Remove the API key?",
                                       informativeText: "This deletes it from the Keychain.",
                                       confirmTitle: "Remove Key")
    }

    /// **Return cancels.** The destructive button comes first, is marked destructive, and takes no
    /// key at all; Cancel answers Return — the convention of Sync History's Clear History and
    /// Settings' Reset All Settings…, and the opposite of `confirmDelete`, whose items go to the
    /// Trash and can come back.
    @Test func cancelIsTheDefaultAndTheDestructionTakesNoKey() throws {
        let built = alert()
        #expect(built.alertStyle == .warning)
        #expect(built.buttons.count == 2, "the alert no longer offers exactly a confirm and a cancel")
        let confirm = try #require(built.buttons.first)
        let cancel = try #require(built.buttons.last)
        #expect(confirm.title == "Remove Key")
        #expect(confirm.hasDestructiveAction, "the confirm is not marked destructive")
        #expect(confirm.keyEquivalent == "", "Return or Escape would delete")
        #expect(cancel.title == "Cancel")
        #expect(cancel.keyEquivalent == "\r", "Return does not cancel")
    }

    @Test func theCallersWordsArriveIntact() {
        let built = alert()
        #expect(built.messageText == "Remove the API key?")
        #expect(built.informativeText == "This deletes it from the Keychain.")
    }
}

/// **Escape cancels a Cancel-is-default alert.** Making Cancel answer Return takes Escape from it —
/// NSAlert gives a button titled "Cancel" Escape, and a button holds one key equivalent — so Escape
/// did nothing in every such alert (measured 2026-11-01 with a real key event through
/// `NSApp.sendEvent`: Escape left the alert up, Return cancelled; with the monitor, both cancelled).
///
/// The modal session itself cannot be run here, so this pins the monitor's decision on real key
/// events, and the scan holds every Cancel-takes-Return alert in the app to the monitor.
@Suite @MainActor struct EscapeCancelsTests {

    private func key(_ characters: String, code: UInt16, in window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    @Test func plainEscapeAtTheAlertIsAnsweredAndNothingElseIs() throws {
        let alert = NativeAlerts.irreversibleAlert(messageText: "Clear?", informativeText: "",
                                                   confirmTitle: "Clear All")
        let other = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        // Ordered in, far off screen: a window gets its number when it reaches the window server.
        alert.window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        alert.window.orderFrontRegardless()
        other.orderFrontRegardless()
        defer { alert.window.orderOut(nil); other.orderOut(nil) }
        try #require(alert.window.windowNumber > 0 && other.windowNumber > 0,
                     "no window numbers — the events below would name no window and prove nothing")

        let escape = try key("\u{1b}", code: 53, in: alert.window)
        try #require(escape.window === alert.window, "the event does not resolve to the alert's window")
        #expect(NativeAlerts.isPlainEscape(escape, in: alert.window))
        #expect(!NativeAlerts.isPlainEscape(try key("\r", code: 36, in: alert.window), in: alert.window),
                "Return is Cancel's own key; the monitor must leave it to the button")
        #expect(!NativeAlerts.isPlainEscape(try key("\u{1b}", code: 53, in: other), in: alert.window),
                "Escape aimed at another window cancelled the alert")
        #expect(!NativeAlerts.isPlainEscape(try key("\u{1b}", code: 53, in: alert.window, modifiers: .command),
                                            in: alert.window))
    }

    /// Every alert whose Cancel answers Return runs through an Escape monitor — one call per such
    /// alert, counted, so a new alert built the same way without it fails here.
    @Test func everyCancelDefaultAlertAnswersEscape() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let roots = ["Modules", "MacApp"].map { repo.appendingPathComponent($0) }
        var scanned = 0
        var cancelTakesReturn = 0
        for root in roots {
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" {
                let path = url.path
                guard !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                scanned += 1
                let returns = text.components(separatedBy: "buttons.last?.keyEquivalent = \"\\r\"").count - 1
                    + text.components(separatedBy: "cancel.keyEquivalent = \"\\r\"").count - 1
                guard returns > 0 else { continue }
                cancelTakesReturn += returns
                let calls = text.components(separatedBy: "runModalCancellingOnEscape(").count - 1
                    - text.components(separatedBy: "func runModalCancellingOnEscape(").count + 1
                #expect(calls >= returns,
                        "\(url.lastPathComponent): \(returns) alert(s) give Cancel Return but \(calls) run with the Escape monitor")
            }
        }
        try #require(scanned > 100, "scanned \(scanned) files — the walk is not reading the app")
        #expect(cancelTakesReturn >= 5, "found \(cancelTakesReturn) Cancel-takes-Return alerts — the pattern moved")
    }
}
