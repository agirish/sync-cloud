import Testing
import AppKit
import SwiftUI
import Design
import FileExplorer
import Sync
@testable import SyncCloud

/// The palette panel's two load-bearing rules, **against real windows**.
///
/// Both of them were broken when the palette was an in-window overlay, and neither was a rule
/// anything could have tested then, because neither existed: an overlay has no key state and no
/// resign-key event. They are the whole reason the palette became a window.
///
/// - **It becomes key.** An overlay could not, so its text field never took first responder and the
///   characters went to the pane's search field instead — visible in `~/sync-cloud.log` as a run of
///   `[columns] left pane depth …` lines stamped while the palette was open.
/// - **Anything else taking key dismisses it.** The overlay's scrim could only ever catch clicks
///   inside the window's own content, and not even those: the panes are `NSViewRepresentable`s, so
///   clicks landed in the `NSTableView` underneath (`[click] left pane selected 1 item(s)`, again
///   while the palette was open). Resigning key covers another of this app's windows, and another
///   app. It does **not** cover clicks over the host itself: the panel spans the host's frame and
///   its scrim hit-tests, so those land on the panel and never move key — the scrim's own tap
///   dismisses them. `CommandPalettePanelController.clickDismissesThePalette` carries that boundary
///   in full, and an earlier version of this comment had it wrong.
///
/// ## Where the boundary is, measured
///
/// **Real key transfer is not observable in this test host.** `makeKeyAndOrderFront` gives a window
/// key only while its *application* is active, and an `xcodebuild test` host is not — even after
/// `NSApp.activate(ignoringOtherApps:)`, `isKeyWindow` stayed false through a five-second poll. So
/// two tests here originally asserted `isKeyWindow` and were meaningless: they passed on the one
/// run where the host happened to be frontmost and failed the next, which is a test that answers
/// only when nobody is looking.
///
/// The split this suite settled on is the honest one. **AppKit's key machinery is not mine to
/// test**; what is mine is (1) the window class *permitting* key at all, which is the exact default
/// that was broken, and (2) what this controller does when key is lost, which is driven here by
/// posting the notification AppKit would post. Both mutations that matter — a panel that refuses
/// key, a resign handler that does nothing — are still killed by that pair.
///
/// `.serialized` because these order real windows in and out, which is process-wide state.
@MainActor
@Suite(.serialized) struct CommandPalettePanelTests {

    /// A host to hang the panel on. `.titled` so it can take key the way the real window does;
    /// ordered out and released at the end of each test rather than `close()`d — closing a titled
    /// window in a test host has ended runs with no verdict before.
    private func makeHost() -> NSWindow {
        let host = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 900, height: 600),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        return host
    }

    private func teardown(_ host: NSWindow, _ controller: CommandPalettePanelController) {
        controller.dismiss()
        host.orderOut(nil)
    }

    private var index: PaletteIndex {
        PaletteIndex(providers: [PaletteProvider(id: "icloud", name: "iCloud",
                                                 isMounted: true, isCurrent: true)],
                     providerRoot: "/root", folders: ["Legal"], recentFolders: [],
                     people: [], registry: nil, isScanning: false, hasSurvey: false)
    }

    @discardableResult
    private func present(_ controller: CommandPalettePanelController, over host: NSWindow,
                         onRun: @escaping (PaletteRoute) -> Void = { _ in },
                         onDismiss: @escaping () -> Void = {}) -> CommandPaletteState {
        let state = CommandPaletteState(index: index)
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           onRun: onRun, onDismiss: onDismiss)
        return state
    }

    /// The panel this app raises must be *able* to take key. A borderless `NSPanel` refuses by
    /// default, and refusing is the whole defect: no key window means no first responder means the
    /// keystrokes go somewhere else.
    @Test func theWindowClassCanBecomeKeyAtAll() {
        let panel = CommandPaletteWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // `isReleasedWhenClosed = false` says "ARC owns this", which only settles the question if
        // something ever closes it. These panels are never ordered in, so the `defer` costs nothing
        // on screen and takes them out of the app's window list at the end of the test rather than
        // whenever the host process gets round to it. **Closed, not `orderOut`-ed, and only because
        // they are borderless and were never shown** — the `.titled` hosts below are ordered out
        // instead, for the measured reason `makeHost` gives.
        defer { panel.close() }
        #expect(panel.canBecomeKey, "a borderless panel that cannot become key cannot hold a caret")
        // ...and never main, so the menu bar and window title keep describing the document window.
        #expect(!panel.canBecomeMain)
    }

    @Test func presentingRaisesAPanelParentedToAndSizedWithTheHost() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        #expect(controller.isPresented)
        let panel = try? #require(host.childWindows?.compactMap { $0 as? CommandPaletteWindow }.first)
        #expect(panel != nil, "the panel is not a child of the host — it will not move or order with it")
        // Sized to the host, because the scrim is inside it and has to dim the whole window —
        // including the title bar. That sizing is also *why* a title-bar click never moves key: it
        // lands on this panel, and the scrim's tap dismisses it. Sizing alone was once claimed to
        // be what made clicking there dismiss; it is not, and it was reported broken twice.
        #expect(panel?.frame == host.frame)
        // Whether it *did* take key is AppKit's business and unobservable here; that it *may* is
        // this app's, and `theWindowClassCanBecomeKeyAtAll` holds it.
        #expect(panel?.canBecomeKey == true)
        teardown(host, controller)
    }

    /// **Click-away, for the half of it that key state actually owns: another window.**
    ///
    /// Clicking another of this app's windows — or another app — makes that window key, which makes
    /// the panel resign it. Not the host's own content, toolbar or title bar: the panel spans those
    /// and takes the click itself. Driven by posting the notification AppKit posts, because the
    /// transfer itself does not happen in a test host (see the suite's note): what is under test is
    /// this controller's reaction, not AppKit's delivery.
    @Test func resigningKeyDismissesThePalette() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        // Deferred, because the `#require` below can throw past a trailing call: that would leave a
        // presented panel and its two app-wide event monitors installed for the rest of the process,
        // which is the exact hazard `theMonitorHelperInstallsAndDismissDrainsThem` names.
        defer { teardown(host, controller) }
        var dismissed = false
        present(controller, over: host, onDismiss: { dismissed = true })
        #expect(controller.isPresented)
        let panel = try #require(host.childWindows?.first, "no panel to resign key")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        // Delivered on the main queue, so it lands on a later turn. Bounded, and it fails at the
        // deadline rather than passing on timeout.
        await waitUntil("the palette dismissed after resigning key") { !controller.isPresented }
        #expect(dismissed, "onDismiss did not fire, so the chord suspension stays stuck on")
    }

    /// Every exit path runs `onDismiss` exactly once. Six things call `dismiss()` and two can
    /// race — esc arriving as the panel is already resigning key — so a second call must be inert
    /// rather than re-firing the callback that clears the chord suspension.
    @Test func dismissIsIdempotentAndFiresItsCallbackOnce() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var dismissals = 0
        present(controller, over: host, onDismiss: { dismissals += 1 })
        controller.dismiss()
        controller.dismiss()
        controller.dismiss()
        #expect(dismissals == 1, "onDismiss fired \(dismissals) times")
        #expect(!controller.isPresented)
        #expect(host.childWindows?.isEmpty != false, "the panel is still a child of the host after dismissal")
        teardown(host, controller)
    }

    /// Presenting twice replaces, and **the replaced presentation is told it is over.**
    ///
    /// The window count alone is not discriminating — dropping the `dismiss()` at the top of
    /// `present` still leaves one child, because the orphaned panel is released the moment the
    /// controller stops referencing it, and the count was the whole of this test's first version.
    /// What survives that mutation is the *callback*: without the clear-out the first
    /// presentation's `onDismiss` never fires, and the flag the chord suspension reads is left
    /// claiming a palette that is no longer on screen — every menu shortcut in the app dead until
    /// something else happens to clear it.
    @Test func presentingAgainReplacesAndRetiresTheOneItReplaced() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var firstRetired = false
        present(controller, over: host, onDismiss: { firstRetired = true })
        present(controller, over: host)
        #expect(firstRetired,
                "the replaced presentation was never told it ended — the chord suspension stays stuck on")
        #expect(host.childWindows?.count == 1,
                "presenting twice left \(host.childWindows?.count ?? 0) panels parented to the host")
        teardown(host, controller)
    }

    @Test func thePanelFollowsTheHostWhenItResizes() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        host.setFrame(CGRect(x: 120, y: 140, width: 1200, height: 800), display: true)
        await waitUntil("the panel followed the host's new frame") {
            host.childWindows?.first?.frame == host.frame
        }
        #expect(host.childWindows?.first?.frame == host.frame,
                "the scrim came adrift of the window it is dimming")
        teardown(host, controller)
    }

    // MARK: Click-away

    /// **The rule for the half of click-away that is about another window.**
    ///
    /// Not the title bar, and an earlier version of this comment claimed otherwise. The panel spans
    /// the host's whole frame and its scrim hit-tests, so a click over the host — content, toolbar
    /// band, title bar — is attributed to *the panel*, and this rule answers `false` for it; the
    /// scrim's own tap is what dismisses there. What this rule reaches is another of this app's
    /// windows: Keyboard Shortcuts, Activity Log, Sync History, an open panel. (Not "the host's
    /// resize margin", which an earlier version of this listed — that is inside `host.frame` and so
    /// is the panel by the same argument.) See
    /// `CommandPalettePanelController.clickDismissesThePalette` for the whole boundary.
    ///
    /// No real window is ordered in for this: the rule is object identity, and three `NSWindow`s
    /// on screen would be process-wide state bought for nothing. Unordered windows still have
    /// distinct identities, which is the entire input.
    @Test func aClickInAnotherWindowDismissesThePalette() {
        let panel = CommandPaletteWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        // Both are borderless and neither is ever ordered in — see `theWindowClassCanBecomeKeyAtAll`
        // for why these are closed while the titled hosts are only ordered out.
        defer { panel.close(); other.close() }
        typealias C = CommandPalettePanelController
        #expect(C.clickDismissesThePalette(clickedWindow: other, palette: panel),
                "a click in another of this app's windows left the palette up")
        // A click this app cannot attribute to a window of its own is outside by definition.
        #expect(C.clickDismissesThePalette(clickedWindow: nil, palette: panel))
    }

    /// **The rule is only worth anything if the monitor still installs it.**
    ///
    /// `clickDismissesThePalette` is pure and static, so both tests around this one pass with the
    /// entire `addMonitor(matching:)` block deleted — the rule extracted for testability, one revert
    /// from being unused. `present` is not reachable from here in a way that can synthesise an
    /// `NSEvent`, so this is a source scan of the call site, in the shape this repo already uses in
    /// `CommandPaletteRouteCallSiteTests`.
    ///
    /// **Three things an earlier version of this test got wrong, each measured by mutation:**
    ///
    /// - It bounded the block by the first eight-space `}`. Re-indenting `present` (wrapping the
    ///   installs in an `if`) made that brace the *`if`'s*, swallowing the ⌘K monitor below and
    ///   failing with a message about the wrong monitor; moving the dismissal into a
    ///   `DispatchQueue.main.async { … }` whose brace lands at eight spaces ended the block *early*
    ///   and let a monitor that **swallowed every mouse-down in the app** pass all four checks.
    ///   Bounds now come from balancing braces from the opening `{`, which no indentation can move.
    /// - The mask was checked against the whole file, so adding any second full-mask monitor let the
    ///   real one narrow to `[.leftMouseDown]` unnoticed — right- and middle-click silently stop
    ///   dismissing, and those are the two the resign observer cannot cover.
    /// - "returns the event" was `contains("return event") && !contains("return nil")`, which a
    ///   `return .none` defeats and a trailing `// … return nil …` comment falsely fails. Every
    ///   `return` in the block is now parsed and required to be `event`.
    @Test func theMonitorActuallyInstallsTheClickAwayRule() throws {
        let source = Self.masked(try Self.panelSource())
        let block = try Self.braceBalancedBlock(after: "addMonitor(matching: [.leftMouseDown",
                                                in: source,
                                                what: "the click monitor")

        #expect(block.contains("Self.clickDismissesThePalette(clickedWindow: event.window, palette: panel)"),
                "the click monitor no longer consults clickDismissesThePalette — the rule is extracted and unused")
        #expect(block.contains("self.dismiss()"), "the click monitor no longer dismisses")

        // The mask, read off the monitor's OWN call, never the file at large.
        let call = try #require(source.range(of: "addMonitor(matching: [.leftMouseDown"),
                                "the click monitor is gone")
        let maskArgument = String(source[call.lowerBound...].prefix(while: { $0 != ")" }))
        for button in [".leftMouseDown", ".rightMouseDown", ".otherMouseDown"] {
            #expect(maskArgument.contains(button),
                    "the click monitor's mask lost \(button) — that button no longer dismisses, and the resign-key observer is not believed to cover the non-left buttons")
        }

        // Returned, never swallowed. Every return is parsed rather than string-matched: `return .none`
        // swallows just as thoroughly as `return nil`, and a comment is not a return statement.
        let returns = Self.returnedExpressions(in: block)
        #expect(!returns.isEmpty, "the click monitor returns nothing — it cannot be passing the event on")
        #expect(returns.allSatisfy { $0 == "event" },
                "the click monitor returns \(returns) — anything but `event` swallows the click the user meant for whatever is under the palette")
    }

    /// **⌘K's monitor is now the only way to close the palette from the keyboard.**
    ///
    /// `a1c96082` suspended ⌘K along with every other chord while the palette is up, so the menu
    /// item is disabled exactly when the palette is on screen. Before it, a deleted keyDown monitor
    /// still left ⌘K working through the menu; now deleting it makes ⌘K appear to do nothing at all,
    /// and `closesThePalette` is pure and static, so all four chord tests below pass without it.
    /// Same "extracted for testability, one revert from unused" hazard the click monitor has a scan
    /// for — and `theMonitorHelperInstallsAndDismissDrainsThem` only covers the shared helper, not
    /// the existence of this particular caller.
    @Test func theChordMonitorActuallyInstallsTheClosingChord() throws {
        let source = Self.masked(try Self.panelSource())
        let block = try Self.braceBalancedBlock(after: "addMonitor(matching: .keyDown",
                                                in: source, what: "the ⌘K monitor")
        #expect(block.contains("Self.closesThePalette("),
                "the ⌘K monitor no longer consults closesThePalette — the chord rule is extracted and unused")
        #expect(block.contains("self.dismiss()"), "the ⌘K monitor no longer dismisses")
        // The chord is SWALLOWED and everything else PASSED ON, and the ORDER is the whole of it.
        // A set check (`contains("event") && contains("nil")`) passed with the two swapped —
        // measured — which is the inverted monitor: every non-⌘K keystroke eaten so the palette's
        // own field receives nothing, and ⌘K handed on to the menu item as well.
        let returns = Self.returnedExpressions(in: block)
        #expect(returns.count >= 2, "the ⌘K monitor has \(returns.count) return(s) — it cannot be both passing other keys on and swallowing its own chord")
        #expect(returns.last == "nil",
                "the ⌘K monitor's last return is \(returns.last ?? "none") — it must swallow its own chord, or ⌘K reaches the menu item as well")
        #expect(returns.dropLast().allSatisfy { $0 == "event" },
                "the ⌘K monitor returns \(returns) — everything that is not the chord must be passed on, or the palette's own field receives nothing")
    }

    /// **The mask fails CLOSED on Swift it cannot lex.**
    ///
    /// `masked` is a four-flag scanner, not a Swift lexer, and three constructs defeat it — each
    /// probed, each producing a wrong verdict rather than a loud one:
    ///
    /// - `"""` multi-line literals: the three quotes open/close/open, so a body with an **odd**
    ///   number of `"` inverts the string state and everything after it is masked backwards (three
    ///   red tests, all blaming code that was fine).
    /// - `#"…"#` raw strings: `\` is not an escape and `"#` is the terminator, so the mask ends at
    ///   the first bare `"` and blanks real code after it — including real braces.
    /// - interpolation containing a nested literal (`"\(d["k"])"`): the inner quotes close and
    ///   reopen the outer string, leaking its contents as code.
    ///
    /// None is in the file today. This test is what stops "not today" from becoming a silent wrong
    /// answer the day someone adds one — the scan stops instead of guessing. Also asserts the two
    /// invariants the callers depend on: the mask preserves length, and the masked file's braces
    /// balance to zero.
    @Test func rejectsConstructsTheMaskCannotLex() throws {
        let source = try Self.panelSource()
        #expect(!source.contains("\"\"\""),
                "CommandPalettePanel.swift now uses a multi-line string literal, which `masked` cannot lex — teach it `\"\"\"` before trusting any scan in this suite")
        #expect(!source.contains("#\""),
                "CommandPalettePanel.swift now uses a raw string literal, which `masked` cannot lex — teach it `#\"…\"#` before trusting any scan in this suite")
        let code = Self.masked(source)
        #expect(code.count == source.count,
                "the mask changed the source's length, so every range it produces indexes the original wrongly")
        var depth = 0
        for character in code {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
        }
        #expect(depth == 0,
                "the masked source's braces do not balance (net \(depth)) — the mask has leaked a literal or a comment, and every block bound in this suite is suspect")
    }

    /// **The helper the monitors install through must still install and still be drained.**
    ///
    /// Mutation found the previous test's blind spot one level down: gutting `addMonitor`'s body, or
    /// dropping either `eventMonitors.append` or `dismiss()`'s drain, disables **both** monitors —
    /// click-away and ⌘K — with the whole suite green. The deletable point moved below the test.
    @Test func theMonitorHelperInstallsAndDismissDrainsThem() throws {
        let source = Self.masked(try Self.panelSource())
        let helper = try Self.braceBalancedBlock(after: "private func addMonitor(matching mask:",
                                                 in: source, what: "addMonitor")
        #expect(helper.contains("NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)"),
                "addMonitor no longer calls AppKit — every monitor in this file is now a no-op")
        #expect(helper.contains("eventMonitors.append(monitor)"),
                "addMonitor no longer tracks the token, so dismiss() can never remove the monitor")

        let dismiss = try Self.braceBalancedBlock(after: "func dismiss() {", in: source, what: "dismiss()")
        #expect(dismiss.contains("eventMonitors.forEach(NSEvent.removeMonitor)"),
                "dismiss() no longer drains the monitors — they outlive the palette and fire app-wide")
        #expect(dismiss.contains("eventMonitors = []"),
                "dismiss() leaves stale tokens in the bag — the next dismiss() would remove them twice")
    }

    /// Source with every comment and every string's **contents** blanked to spaces, same length.
    ///
    /// **This is the load-bearing helper, and stripping whole lines was not enough.** Measured, all
    /// three against a green suite:
    ///
    /// - a `{` inside a string literal (`Logger.shared.debug("dismiss {")`) pushed
    ///   `braceBalancedBlock` past `dismiss()`'s real closing brace, so the block swallowed the rest
    ///   of the class and a drain moved out of `dismiss()` still satisfied its assertion;
    /// - a `}` in a **trailing** comment truncated the click monitor's block to one line, producing
    ///   three failures that all blamed production code for things it still did;
    /// - the word `return` inside a string or a trailing comment was parsed as a return statement.
    ///
    /// **Block comments nest in Swift, and a `Bool` cannot see that.** With `inBlockComment` as a
    /// flag, `/* outer /* inner */ still commented */` un-masked at the *first* `*/` and the rest was
    /// lexed as live code. Measured end-to-end: deleting the click monitor's `self.dismiss()` and
    /// leaving it inside such a comment passed all 16 tests, with click-away broken — a false pass in
    /// the check written to prevent exactly that deletion. Hence a depth counter.
    ///
    /// Offsets are preserved (characters are replaced, never removed) so a range found in the masked
    /// text indexes the original safely. Delimiters are kept so `""` still reads as a literal.
    ///
    /// **What this deliberately cannot lex** — see `rejectsConstructsTheMaskCannotLex`, which fails
    /// the scan rather than letting it answer wrongly: multi-line `"""` literals (an odd number of
    /// `"` in the body flips the parity and desyncs everything after it), raw strings `#"…"#` (`\`
    /// is not an escape and `"#` is the terminator), and interpolation containing a nested string
    /// literal (`"\(d["k"])"`, whose inner quotes close and reopen the outer literal). All three were
    /// probed and all three produce wrong verdicts; none appears in the file today, and the guard is
    /// what keeps "none today" from becoming a silent wrong answer tomorrow.
    static func masked(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var inLineComment = false, inString = false, escaped = false
        var blockDepth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let peek: Character? = next < source.endIndex ? source[next] : nil
            if inLineComment {
                if character == "\n" { inLineComment = false; out.append(character) } else { out.append(" ") }
            } else if blockDepth > 0 {
                if character == "/", peek == "*" { blockDepth += 1; out += "  "; index = next }
                else if character == "*", peek == "/" { blockDepth -= 1; out += "  "; index = next }
                else { out.append(character == "\n" ? "\n" : " ") }
            } else if inString {
                if escaped { escaped = false; out.append(" ") }
                else if character == "\\" { escaped = true; out.append(" ") }
                else if character == "\"" { inString = false; out.append(character) }
                else { out.append(character == "\n" ? "\n" : " ") }
            } else if character == "/", peek == "/" { inLineComment = true; out += "  "; index = next }
            else if character == "/", peek == "*" { blockDepth = 1; out += "  "; index = next }
            else if character == "\"" { inString = true; out.append(character) }
            else { out.append(character) }
            index = source.index(after: index)
        }
        return out
    }

    /// The text between an anchor's opening `{` and its matching `}`, found by balancing braces.
    ///
    /// Indentation is not used, deliberately: bounding a block by "the first `}` at column N" is how
    /// the first version of the monitor scan came to answer about the wrong text in both directions.
    /// Masks comments and strings itself, so callers cannot forget to.
    static func braceBalancedBlock(after anchor: String, in source: String,
                                   what: String) throws -> String {
        let code = Self.masked(source)
        let start = try #require(code.range(of: anchor), "\(what) is gone — this scan would be vacuous")
        // Uniqueness, for the same reason the FileExplorer helper asserts it: `range(of:)` takes the
        // first match silently, and a second one means this is answering about text nobody chose.
        let occurrences = code.components(separatedBy: anchor).count - 1
        try #require(occurrences == 1,
                     "\(what)'s anchor occurs \(occurrences)× in code — this scan would read the first")
        // From the START of the match, not its end: an anchor that already carries its own `{`
        // (`func dismiss() {`) would otherwise skip past it and balance the NEXT block instead —
        // which is how this first returned the body of `if let resignObserver` and passed nothing.
        let rest = code[start.lowerBound...]
        let open = try #require(rest.firstIndex(of: "{"), "no opening brace for \(what)")
        var depth = 0
        var close: String.Index?
        var index = open
        while index < rest.endIndex {
            if rest[index] == "{" { depth += 1 }
            if rest[index] == "}" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
            index = rest.index(after: index)
        }
        let end = try #require(close, "no matching closing brace for \(what)")
        return String(rest[rest.index(after: open)..<end])
    }

    /// Every `return <expr>` in a block, as the expression's text, in source order.
    ///
    /// A `guard … else { return x }` is a swallow just as much as a tail return, so its return
    /// counts even though it sits inside braces. A `return` sharing its line with the closure brace
    /// that owns it (`filter { w in return w.isVisible }`) does not — counting it failed correct
    /// code. The discriminator is the keyword in front of that brace, not the depth.
    ///
    /// **Scope, stated precisely because an earlier version of this comment over-claimed:** depth is
    /// computed from the current line only, so a `return` on its own line inside a *multi-line*
    /// nested closure is still attributed to this block. That is the conservative direction — it can
    /// false-fail, never silently miss a swallow — but it is not the "own depth" analysis the first
    /// draft of this sentence claimed. Pass an already-masked block.
    static func returnedExpressions(in block: String) -> [String] {
        var expressions: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            var tail = Substring(line)
            while let keyword = tail.range(of: "return") {
                let prefix = line[line.startIndex..<keyword.lowerBound]
                let before = keyword.lowerBound == line.startIndex ? " " : line[line.index(before: keyword.lowerBound)]
                let after = keyword.upperBound == line.endIndex ? " " : line[keyword.upperBound]
                tail = line[keyword.upperBound...]
                // `returnValue` is not a return statement.
                guard !before.isLetter, !before.isNumber, before != "_",
                      !after.isLetter, !after.isNumber, after != "_" else { continue }
                // **Whose block does this return belong to?** At depth 0 it is this one's. At depth 1
                // it depends entirely on what opened the brace: `guard … else { return event }` is a
                // statement-level return and counts, while `filter { w in return w.isVisible }` is
                // the closure's and does not — counting it failed correct code. The discriminator is
                // the keyword in front of the brace, not the depth, which is why depth alone was
                // wrong here in both directions.
                var depth = 0
                for character in prefix {
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                }
                var statementLevel = depth == 0
                if depth == 1, let brace = prefix.lastIndex(of: "{") {
                    let opener = prefix[..<brace].trimmingCharacters(in: .whitespaces)
                    statementLevel = opener.hasSuffix("else") || opener.hasPrefix("if ")
                        || opener.hasPrefix("guard ")
                }
                guard statementLevel else { continue }
                let expression = tail.prefix { $0 != "}" && $0 != ";" }
                    .trimmingCharacters(in: .whitespaces)
                // `return(event)` and `return event` are the same statement written twice.
                expressions.append(expression.hasPrefix("(") && expression.hasSuffix(")")
                                   ? String(expression.dropFirst().dropLast()) : expression)
            }
        }
        return expressions
    }

    /// Reads `CommandPalettePanel.swift` itself. Fails loudly when it cannot be found, so a rename
    /// cannot leave an empty haystack in which every `contains` quietly answers false.
    static func panelSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/CommandPalettePanel.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read CommandPalettePanel.swift — the scan would be vacuous")
        // `#require`, not `#expect`: a truncated file (a bad merge, a half-written checkout) makes
        // every `contains` below answer false and every `!contains` pass. Continuing past a
        // known-bad haystack turns one loud issue into a page of quiet green.
        try #require(text.count > 500, "CommandPalettePanel.swift is implausibly short")
        return text
    }

    /// ...and a click **on** the palette must not dismiss it, or the card would close under the
    /// pointer before it could be used. The scrim's own tap owns the dimmed area.
    @Test func aClickOnThePaletteItselfIsLeftAlone() {
        let panel = CommandPaletteWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // Never ordered in; closed for the reason `theWindowClassCanBecomeKeyAtAll` gives.
        defer { panel.close() }
        #expect(!CommandPalettePanelController.clickDismissesThePalette(clickedWindow: panel,
                                                                        palette: panel),
                "clicking the palette dismissed it — its own field and rows would be unusable")
    }

    // MARK: ⌘K, while the panel holds the keyboard

    /// **The chord must survive Caps Lock.**
    ///
    /// While the panel is key the menu item cannot fire — it reads a `@FocusedValue` published by
    /// the window underneath — so ⌘K comes from a local event monitor, and the obvious way to write
    /// that test is wrong: `.deviceIndependentFlagsMask` includes `.capsLock`, `.function` and
    /// `.numericPad`, so comparing the whole intersection to `.command` made ⌘K stop closing the
    /// palette for anyone with Caps Lock on. Only the four modifiers a chord is made of count.
    @Test func theClosingChordIgnoresKeyStateThatIsNotPartOfAChord() {
        typealias C = CommandPalettePanelController
        #expect(C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: "k"))
        #expect(C.closesThePalette(modifiers: [.command, .capsLock], charactersIgnoringModifiers: "K"),
                "⌘K stopped closing the palette because Caps Lock was on")
        #expect(C.closesThePalette(modifiers: [.command, .function], charactersIgnoringModifiers: "k"))
        #expect(C.closesThePalette(modifiers: [.command, .numericPad], charactersIgnoringModifiers: "k"))
    }

    /// ...and it must not fire for a *different* chord, or the palette would swallow keys that
    /// belong to the app. A monitor that returns nil eats the event for everyone.
    @Test func theClosingChordIsOnlyTheChordItself() {
        typealias C = CommandPalettePanelController
        #expect(!C.closesThePalette(modifiers: [.command, .shift], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [.command, .option], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [.command, .control], charactersIgnoringModifiers: "k"))
        #expect(!C.closesThePalette(modifiers: [], charactersIgnoringModifiers: "k"),
                "a bare k closed the palette — every letter typed into the field would close it")
        #expect(!C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: "j"))
        #expect(!C.closesThePalette(modifiers: [.command], charactersIgnoringModifiers: nil))
    }

    /// The chord comes from `AppChord`, so the monitor and the menu item cannot come to disagree
    /// about which key opens and closes the palette.
    @Test func theClosingChordIsTheRegisteredOne() {
        #expect(!CommandPalettePanelController.closesThePalette(
            modifiers: [.command],
            charactersIgnoringModifiers: String(AppChord.commandPalette.key.character) + "x"))
        #expect(CommandPalettePanelController.closesThePalette(
            modifiers: [.command],
            charactersIgnoringModifiers: String(AppChord.commandPalette.key.character)))
    }

    // MARK: The state the panel owns

    @Test func typingMovesTheSelectionWithTheListRatherThanLeavingItBehind() {
        let state = CommandPaletteState(index: index)
        // Opens on the first choosable row of the empty-query landing.
        #expect(state.selection == PaletteSelection.initialIndex(in: state.rows))
        state.selection = 4
        state.setQuery("legal")
        #expect(state.rows.count > 0)
        #expect(state.selection == PaletteSelection.initialIndex(in: state.rows),
                "the selection is a stale index into the previous results — ↩ would run a row nobody looked at")
    }

    @Test func theIndexIsSnapshottedRatherThanReReadPerKeystroke() {
        // A palette that re-indexed between a key and its character would be walking the folder
        // profile inside a keystroke. The state takes the index once, at init.
        let state = CommandPaletteState(index: index)
        state.setQuery("legal")
        #expect(state.index.folders == ["Legal"])
    }
}
