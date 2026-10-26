@testable import SyncCloud
import FileExplorer
import Testing
import AppKit

/// **Edit ▸ Undo waits during a long run, for the file operations' stack only** (Banner Room, CF).
///
/// A window of the test's own, whose stack holds one file operation, as the app's holds
/// `FileSyncManager`'s; the gate's chain is the window's responder chain, which `NSApp` would only
/// walk for a key window. Edit's typing undo against the real editor is pinned beside the rule in
/// `EditorUndoAcrossModesTests.typingUndoAndTheFileOperationsAreSeparateStacks`.
@MainActor
@Suite(.serialized) struct RunUndoGateTests {

    static let reason = "Wait for the merge to finish"

    final class Marker { var undone = 0 }

    /// The file pane, as far as ⌘Z is concerned: takes the keyboard, answers no `undo:` itself.
    final class Pane: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A text view's delegate naming a stack of its own — what `PlainTextEditor`'s coordinator does.
    @MainActor
    final class OwnStack: NSObject, NSTextViewDelegate {
        let stack = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { stack }
    }

    @MainActor
    final class Rig {
        let window: NSWindow
        let pane = Pane(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let text = NSTextView(frame: NSRect(x: 100, y: 0, width: 200, height: 100))
        let own = OwnStack()
        let marker = Marker()
        let gate = RunUndoGate()
        var refusals: [String] = []

        init() throws {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: window.contentLayoutRect)
            content.addSubview(pane)
            content.addSubview(text)
            window.contentView = content
            text.allowsUndo = true
            text.delegate = own
            let files = try #require(window.undoManager)
            files.groupsByEvent = false
            files.beginUndoGrouping()
            files.registerUndo(withTarget: marker) { $0.undone += 1 }
            files.setActionName("Move")
            files.endUndoGrouping()
            gate.fileStack = { [weak window] in window?.undoManager }
            gate.chainTarget = { [weak window] action, _ in
                window.flatMap { UndoStackReached.target(of: action, in: $0) }
            }
            gate.refuse = { [unowned self] in refusals.append($0) }
        }

        func undoItem() -> NSMenuItem {
            let item = NSMenuItem(title: "Undo", action: RunUndoGate.undo, keyEquivalent: "z")
            item.target = gate
            return item
        }
    }

    static func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6))
    }

    /// **With the file pane focused, Undo waits and says why**: greyed, the reason its tooltip and
    /// the step still named; pressed anyway it is refused aloud and the file stays where it is. When
    /// the run ends, the same press undoes it.
    @Test func aFileOperationsUndoWaitsForTheRun() throws {
        let rig = try Rig()
        defer { rig.window.close() }
        rig.window.makeFirstResponder(rig.pane)
        rig.gate.reason = Self.reason
        let item = rig.undoItem()

        #expect(!rig.gate.validateMenuItem(item), "Edit ▸ Undo is live during a run")
        #expect(item.toolTip == Self.reason)
        #expect(item.title == "Undo Move", "the greyed item no longer names the step: \(item.title)")
        rig.gate.undo(item)
        #expect(rig.marker.undone == 0, "a file operation was undone during a run")
        #expect(rig.refusals == [Self.reason])
        #expect(rig.gate.refusesKey(try Self.key("z", .command)), "⌘Z pressed anyway is not refused aloud")
        #expect(rig.refusals.count == 2)

        rig.gate.reason = nil
        #expect(rig.gate.validateMenuItem(item), "Edit ▸ Undo stayed greyed after the run")
        #expect(item.toolTip == nil, "the reason outlived the run")
        #expect(!rig.gate.refusesKey(try Self.key("z", .command)))
        rig.gate.undo(item)
        #expect(rig.marker.undone == 1, "Undo after the run did not undo the file operation")
    }

    /// **Typing undo goes on**: with a text view that names its own stack holding the keyboard, Undo
    /// is live during a run and undoes the typing, and the file operation stays.
    @Test func typingUndoGoesOnDuringARun() async throws {
        let rig = try Rig()
        defer { rig.window.close() }
        rig.window.makeFirstResponder(rig.text)
        rig.text.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        // The run loop closes the typing's group — never closed by hand (`EditorUndoAcrossModesTests`).
        for _ in 0..<100 where rig.own.stack.groupingLevel > 0 || !rig.own.stack.canUndo {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(rig.own.stack.canUndo, "fixture: the typing put nothing on the text view's stack")
        rig.gate.reason = Self.reason
        let item = rig.undoItem()

        #expect(rig.gate.validateMenuItem(item), "typing undo was greyed during a run")
        #expect(item.toolTip == nil)
        #expect(!rig.gate.refusesKey(try Self.key("z", .command)), "⌘Z in a text view was refused")
        rig.gate.undo(item)
        #expect(rig.text.string == "", "Undo left the typing: \(rig.text.string.debugDescription)")
        #expect(rig.marker.undone == 0, "Undo in the text view reached the file operations")
        #expect(rig.refusals.isEmpty)
    }

    /// ⌘Z and ⇧⌘Z are the keys caught; ⌥⌘Z and a bare Z are not.
    @Test func theKeysAreUndoAndRedo() throws {
        #expect(RunUndoGate.undoRedoAction(of: try Self.key("z", .command)) == RunUndoGate.undo)
        #expect(RunUndoGate.undoRedoAction(of: try Self.key("Z", [.command, .shift])) == RunUndoGate.redo)
        #expect(RunUndoGate.undoRedoAction(of: try Self.key("z", [.command, .option])) == nil)
        #expect(RunUndoGate.undoRedoAction(of: try Self.key("z", [])) == nil)
        #expect(RunUndoGate.undoRedoAction(of: try Self.key("x", .command)) == nil)
    }

    /// **The app's own Edit ▸ Undo and Redo go through the gate** — installed at launch, and the test
    /// host is the app — and `adopt` takes them in any menu it is given, at any depth.
    @Test func theAppsUndoAndRedoAreTheGates() throws {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let all = items(try #require(NSApp.mainMenu, "the app has no menu bar — this check would be vacuous"))
        let undoRedo = all.filter { $0.action == RunUndoGate.undo || $0.action == RunUndoGate.redo }
        #expect(undoRedo.count == 2, "found \(undoRedo.map(\.title)) for Undo and Redo")
        #expect(undoRedo.allSatisfy { $0.target === RunUndoGate.shared }, "Edit ▸ Undo or Redo bypasses the run lock")

        let edit = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: RunUndoGate.undo, keyEquivalent: "z")
        let other = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(undo)
        edit.addItem(other)
        let bar = NSMenu()
        bar.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))
        bar.items[0].submenu = edit
        let gate = RunUndoGate()
        gate.adopt(in: bar)
        #expect(undo.target === gate)
        #expect(other.target == nil, "the gate took an item that is not Undo or Redo")
    }

    /// **Every Undo the window draws waits with ⌘Z**: the result message's button greys under the
    /// run lock (inside its own tooltip, so the reason shows), the gate is fed the window's run and
    /// stack, and Sync History's Undo Last Run greys too, in a window the main one's environment does
    /// not reach.
    @Test func everyUndoButtonIsWiredToTheLock() throws {
        func source(_ name: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(name)
            return try String(contentsOf: url, encoding: .utf8)
        }
        let banner = try source("MacApp/OperationBannerView.swift")
        let lock = try #require(banner.range(of: ".lockedDuringRun()"), "the result message's Undo is not locked")
        let help = try #require(banner.range(of: ".help(ShortcutHint.tooltip(\"Undo this operation\""))
        #expect(lock.lowerBound < help.lowerBound, "the lock sits outside the tooltip, so the reason never shows")
        let content = try source("MacApp/ContentView.swift")
        #expect(content.contains(".onChange(of: runWriteLockReason, initial: true)"))
        #expect(content.contains("gate.reason = reason"))
        #expect(content.contains("gate.fileStack = { [weak manager = syncManager] in manager?.undoManager }"))
        let message = try source("MacApp/ContentView+ResultMessage.swift")
        #expect(message.contains("guard !refusedWhileRunLocked() else { return }"),
                "the message's Undo undoes during a run if the grey is slipped")
        let history = try source("Modules/Dashboard/Sources/Dashboard/SyncHistoryView.swift")
        #expect(history.contains(".lockedDuringRun()\n            .help(\"Reverse the most recent sync run\")"))
        let app = try source("MacApp/SyncCloudApp.swift")
        #expect(app.contains(".modifier(RunWriteLockFromManager(syncManager: syncManager))"),
                "Sync History is not told when a run is going")
        #expect(app.contains("RunUndoGate.shared.install()"))
    }
}
