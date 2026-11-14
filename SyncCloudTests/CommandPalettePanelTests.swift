import Testing
import AppKit
import SwiftUI
import Design
import FileExplorer
import Sync
@testable import SyncCloud

/// The palette panel against real windows. The palette is a child window holding only its list;
/// the field it filters from is in the host window's toolbar, so the host keeps key and the field
/// keeps the caret. Two rules close it:
///
/// - The host resigning key dismisses it: that covers another of this app's windows, and another
///   app.
/// - A mouse-down outside the panel dismisses it, except over the Go-to field, which is the
///   palette's own control in the host's window.
///   `CommandPalettePanelController.clickDismissesThePalette` carries that boundary in full.
///
/// AppKit's key machinery isn't tested here, since whether an `xcodebuild` host is frontmost
/// depends on the machine. What is tested is the window class refusing key and the controller's
/// reaction to losing it, driven by posting the notification AppKit would post.
///
/// `.serialized` because these build real windows, real child windows and the controller's app-wide
/// event monitors, all process-wide state. Everything they order in is parked past every attached
/// display; see `makeHost`.
@MainActor
@Suite(.serialized) struct CommandPalettePanelTests {

    /// A host to hang the panel on: borderless, parked past every display, and never ordered out
    /// while the palette is up. Ordered out at the end of each test rather than `close()`d, since
    /// closing a window in a test host can end a run with no verdict.
    ///
    /// **Never order a window out while the palette is up.** A window holding key resigns it, the
    /// controller answers with `dismiss()` (correctly), and the panel is unparented and
    /// `isPresented` cleared, often inside `present` itself: a `queue: .main` observer runs
    /// synchronously for a post on the main thread. Whether a window holds key varies by run, so it
    /// shows as an intermittent missing panel (`docs/flaky-tests.md`, "Five palette tests the
    /// fixture dismissed out from under itself").
    ///
    /// Borderless, because `constrainFrameRect` pulls a visible titled window back onto a display;
    /// a borderless one can be parked, as `DetailsWhereItLivesTests` in Dashboard parks its own. A
    /// borderless window can't become key, so no test here reads the host's key state.
    /// `theHostAndItsPanelStayOutOfSight` guards the user's screen and accepts either remedy: not
    /// ordered in, or parked past every display.
    private func makeHost() -> NSWindow {
        let host = NSWindow(contentRect: CGRect(origin: Self.offscreenOrigin(for: Self.hostSize),
                                                size: Self.hostSize),
                            styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        return host
    }

    static let hostSize = CGSize(width: 900, height: 600)

    /// Everything this suite's windows must stay clear of: the union of every attached display.
    /// Never empty, as in `DetailsWhereItLivesTests.displayBounds`: with no displays the union is
    /// null, and "intersects no screen" would hold of every frame, so the guard could not fail.
    static func displayBounds() -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return union.isNull ? CGRect(x: 0, y: 0, width: 4000, height: 4000) : union
    }

    /// An origin far enough below-left of every display that a window of `size` cannot reach one.
    static func offscreenOrigin(for size: CGSize) -> CGPoint {
        let bounds = displayBounds()
        return CGPoint(x: bounds.minX - size.width - 2000, y: bounds.minY - size.height - 2000)
    }

    /// Every dismissal, and where it came from. The window tests fail by reporting a missing object
    /// (`childWindows → []`, `panel → nil`, `isPresented → false`), which is equally `present` never
    /// attaching the panel, a real regression, and the panel being torn down afterwards. The
    /// fixture owns `onDismiss`, so recording the activation state and the app's stack frames on
    /// each call turns "no window" into a cause.
    @MainActor private final class DismissalWitness {
        private(set) var dismissals: [String] = []

        func record() {
            // Falls back to the unfiltered head: if the app's frames are unsymbolicated the filter
            // yields nothing, and an empty stack would drop the most useful half of the message.
            let symbols = Thread.callStackSymbols
            let ours = symbols.filter { $0.contains("SyncCloud") }
            let frames = (ours.isEmpty ? symbols : ours).prefix(10).joined(separator: "\n        ")
            dismissals.append("app active=\(NSApp.isActive), key window="
                + "\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")\n        "
                + frames)
        }

        /// Read only into a failure message, so it can afford to be long. With no dismissal,
        /// `presented` separates a panel never attached from one unparented behind the controller's
        /// back. Ordering out a child detaches it from its parent, so anything that orders the panel
        /// out without `dismiss()` gives the second reading; the message names that mechanism and
        /// no particular trigger, since it can't know one.
        func report(presented: Bool) -> String {
            guard dismissals.isEmpty else {
                return "the palette was dismissed \(dismissals.count)× :\n        "
                    + dismissals.joined(separator: "\n        ")
            }
            return presented
                ? "no dismissal was recorded and the controller still holds its panel, so the panel was unparented without the controller knowing — ordering out a child detaches it from its parent, so look for whatever ordered this panel out"
                : "no dismissal was recorded and the controller holds no panel either, so `present` never attached one — this is the app, not an ambient teardown"
        }
    }

    /// One per test — swift-testing builds a fresh suite instance for each.
    private let witness = DismissalWitness()

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

    /// A stand-in for the toolbar field's screen rect, measured from the parked host so the list it
    /// anchors lands off every display too. Not centred and not square, so a transposed placement
    /// cannot come out right by accident.
    static func fieldRect(in host: NSWindow) -> CGRect {
        CGRect(x: host.frame.minX + 60, y: host.frame.maxY - 80, width: 420, height: 28)
    }

    /// Presents the palette over `host`, and witnesses any dismissal the test did not ask for.
    ///
    /// Production raises the panel with `orderFront`, and ordering a child front orders its parent
    /// in too, so both windows are visible; they stay out of sight because the host is parked and
    /// every anchor is measured from its frame (see `makeHost` for why nothing is ordered out).
    ///
    /// The default anchor must come from the host: the panel is placed under whatever the anchor
    /// says, so an on-screen literal would put a live list over the desktop for every async test,
    /// and `theHostAndItsPanelStayOutOfSight` never awaits placement, so it couldn't see that.
    /// `onDismiss` is wrapped, as the only seam an ambient teardown can be seen from.
    @discardableResult
    private func present(_ controller: CommandPalettePanelController, over host: NSWindow,
                         anchor: (() -> CGRect?)? = nil,
                         onRun: @escaping (PaletteRoute) -> Void = { _ in },
                         onDismiss: @escaping () -> Void = {}) -> CommandPaletteState {
        let state = CommandPaletteState(index: index)
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           anchor: anchor ?? { Self.fieldRect(in: host) },
                           onRun: onRun,
                           onDismiss: { [witness] in witness.record(); onDismiss() })
        return state
    }

    /// A borderless palette window, left to ARC and never ordered in: close it in a `defer`.
    private func scratchPanel() -> CommandPaletteWindow {
        let panel = CommandPaletteWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// The panel must refuse key. The field is in the host's toolbar, so a panel that took key
    /// would pull the caret out of the field mid-word. With the panel non-key the host stays key,
    /// the field editor keeps first responder, and the row highlight is this app's own fill.
    @Test func theWindowClassRefusesKeySoTheFieldKeepsTheCaret() {
        let panel = scratchPanel()
        // `isReleasedWhenClosed = false` leaves the window to ARC, and the `defer` takes it out of
        // the app's window list at the end of the test. Closed, not ordered out, only because it is
        // borderless and never shown; the hosts are ordered out instead, as `makeHost` says.
        defer { panel.close() }
        #expect(!panel.canBecomeKey,
                "the palette panel takes key — the toolbar field loses the caret the moment the list appears")
        // ...and never main, so the menu bar and window title keep describing the document window.
        #expect(!panel.canBecomeMain)
    }

    @Test func presentingRaisesAPanelParentedToTheHostButNotSizedWithIt() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        #expect(controller.isPresented, "the palette is not up — \(witness.report(presented: controller.isPresented))")
        let panel = try? #require(host.childWindows?.compactMap { $0 as? CommandPaletteWindow }.first)
        #expect(panel != nil,
                "the panel is not a child of the host — it will not move or order with it. \(witness.report(presented: controller.isPresented))")
        // Not sized to the host, or the palette would swallow every click over the app.
        // `thePanelCoversItsListAndNotTheWindowUnderIt` owns that claim in full.
        #expect(panel?.frame != host.frame,
                "the panel is the whole window again — every click over the app will land on it")
        // Parented is what still has to hold: the list rides the window it hangs off.
        #expect(panel?.parent === host, "the list is not riding the host — it will not move with it")
        // `theWindowClassRefusesKeySoTheFieldKeepsTheCaret` holds the class; this holds what was
        // actually raised.
        #expect(panel?.canBecomeKey == false)
        teardown(host, controller)
    }

    /// Neither of the real windows this suite builds may appear on the user's screen. The panel is
    /// checked as well as the host, since the controller orders it front itself. Each is checked
    /// as "not ordered in, or parked past every display", so the guard is about the user's screen
    /// and not about which remedy is in force. Both are visible today (ordering the panel front
    /// orders the host in too), so the parking carries them. An on-screen origin in `makeHost` must
    /// fail both halves.
    @Test func theHostAndItsPanelStayOutOfSight() throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        present(controller, over: host)
        let panel = try #require(host.childWindows?.first,
                                 "no panel was raised — \(witness.report(presented: controller.isPresented))")

        let bounds = Self.displayBounds()
        #expect(!host.isVisible || !bounds.intersects(host.frame),
                "the host window is on screen at \(host.frame), which is inside \(bounds)")
        #expect(!panel.isVisible || !bounds.intersects(panel.frame),
                "the palette panel is on screen at \(panel.frame), which is inside \(bounds)")
    }

    /// Click-away, for the half that key state owns: clicking another of this app's windows, or
    /// another app, makes the host resign key. Clicks over the host itself are the mouse monitor's.
    /// Driven by posting the notification AppKit posts, since what is under test is this
    /// controller's reaction, not AppKit's delivery.
    @Test func resigningKeyDismissesThePalette() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        // Deferred, because the `#require` below can throw past a trailing call and leave a
        // presented panel and its app-wide event monitors installed for the rest of the process.
        defer { teardown(host, controller) }
        var dismissed = false
        present(controller, over: host, onDismiss: { dismissed = true })
        #expect(controller.isPresented, "the palette is not up — \(witness.report(presented: controller.isPresented))")
        _ = try #require(host.childWindows?.first, "no panel at all — \(witness.report(presented: controller.isPresented))")

        // Posted for the host, not the panel. The panel can't become key, so it can never resign
        // it: an observer on the panel would never fire, and posting for the panel would test a
        // notification nothing in the app can produce.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host)
        // Delivered on the main queue, so it lands on a later turn. Bounded, and it fails at the
        // deadline rather than passing on timeout.
        await waitUntil("the palette dismissed after resigning key") { !controller.isPresented }
        #expect(dismissed, "onDismiss did not fire, so the chord suspension stays stuck on")
    }

    /// Every exit path runs `onDismiss` exactly once. Several things call `dismiss()` and two can
    /// race (Esc arriving as key is already resigning), so a second call must be inert rather than
    /// re-firing the callback that clears the chord suspension.
    ///
    /// Also the one place `DismissalWitness` is bound to an assertion: it is read only into failure
    /// messages, so deleting `witness.record()` from `present` must fail this count.
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
        #expect(witness.dismissals.count == 1,
                "the fixture's own dismissal witness saw \(witness.dismissals.count) of the 1 dismissal that happened — with it blind, every failure message in this suite loses the one thing that separates a regression from an ambient teardown")
        teardown(host, controller)
    }

    /// Presenting twice replaces, and the replaced presentation is told it is over. The window
    /// count alone can't see a dropped `dismiss()` at the top of `present`, since the orphaned panel
    /// is released anyway; the callback can. Without it, the chord suspension stays on for a palette
    /// no longer on screen, and every menu shortcut in the app is dead.
    @Test func presentingAgainReplacesAndRetiresTheOneItReplaced() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        var firstRetired = false
        present(controller, over: host, onDismiss: { firstRetired = true })
        present(controller, over: host)
        #expect(firstRetired,
                "the replaced presentation was never told it ended — the chord suspension stays stuck on")
        #expect(host.childWindows?.count == 1,
                "presenting twice left \(host.childWindows?.count ?? 0) panels parented to the host. \(witness.report(presented: controller.isPresented))")
        teardown(host, controller)
    }

    /// The new frame is parked too: resizing onto the display would put a 1200×800 window over the
    /// user's desktop for the length of this test, which `theHostAndItsPanelStayOutOfSight` would
    /// not catch, since it never resizes.
    @Test func thePanelFollowsTheFieldWhenTheHostResizes() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        // The field moves with the window, so the anchor is read live rather than captured.
        var field = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed under the field") {
            host.childWindows?.first.map { $0.frame.minX == field.minX && $0.frame.width == field.width } ?? false
        }
        // At the field's width and left edge, just under it: what makes the list read as belonging
        // to that field. The field rect is not centred and not square, so a transposed placement
        // can't land on the right answer by accident.
        #expect(host.childWindows?.first?.frame.maxY == field.minY - GoToResultsPanel.gapBelowField,
                "the list is not hanging just under the field — a gap of \(GoToResultsPanel.gapBelowField)pt is what makes the two read as one object")
        #expect((host.childWindows?.first?.frame.height ?? 0) > 0, "the list has no height — nothing is drawn")
        // The field's new rect is set before the resize, so the anchor answers with the laid-out
        // toolbar. That is the real order: `didResize` is posted from inside `setFrame`, and the
        // controller reads again a frame later for the case where it is not (see `present`).
        let grown = CGSize(width: 1200, height: 800)
        let grownOrigin = Self.offscreenOrigin(for: grown)
        field = CGRect(x: grownOrigin.x + 90, y: grownOrigin.y + grown.height - 80, width: 520, height: 28)
        host.setFrame(CGRect(origin: grownOrigin, size: grown), display: true)
        await waitUntil("the panel followed the field to its new place") {
            host.childWindows?.first.map { $0.frame.minX == field.minX && $0.frame.width == field.width } ?? false
        }
        let panel = host.childWindows?.first
        #expect(panel?.frame.minX == field.minX && panel?.frame.width == field.width,
                "the list came adrift of the field it hangs from — \(witness.report(presented: controller.isPresented))")
        #expect(panel?.frame.maxY == field.minY - GoToResultsPanel.gapBelowField,
                "the list is no longer sitting just under the field")
        teardown(host, controller)
    }

    /// The panel is the list and must not cover the window. A panel sized to the host claims hits
    /// at the host's far corner, so every click over the app would dismiss the palette instead of
    /// doing what the user meant. Click-away is the mouse monitor's job, and it returns the event.
    ///
    /// The mutation must be both halves: sizing the panel to `host.frame` alone is undone by
    /// AppKit, since `NSHostingView` publishes the list's fixed ideal size (the placement tests
    /// catch the wrong origin). Flexible content and a host-sized panel together must fail this.
    @Test func thePanelCoversItsListAndNotTheWindowUnderIt() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let field = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed and sized to its content") {
            (host.childWindows?.first?.frame.width ?? 0) == field.width
        }
        let panel = try #require(host.childWindows?.first)

        #expect(panel.frame != host.frame, "the panel is the whole window again — it will eat every click over the app")
        #expect(panel.frame.width < host.frame.width, "the panel is as wide as the window")
        #expect(panel.frame.height < host.frame.height, "the panel is as tall as the window")
        // The corner a user aims at when they mean "the pane, not the palette".
        let corner = CGPoint(x: host.frame.minX + 30, y: host.frame.minY + 30)
        #expect(!panel.frame.contains(corner),
                "a click at the far corner of the window still lands on the palette rather than on what is under it")
        // Placed means live: an unplaced panel is inert, so a passing frame check with this still
        // true would mean the list can't be clicked either.
        #expect(panel.ignoresMouseEvents == false, "the panel never became live — its own rows are unclickable")
    }

    // MARK: Click-away

    /// The click rule for another of this app's windows: Keyboard Shortcuts, Activity Log, Sync
    /// History, an open panel. See `CommandPalettePanelController.clickDismissesThePalette` for the
    /// whole boundary. No window is ordered in: the rule is object identity, which unordered windows
    /// still have.
    @Test func aClickInAnotherWindowDismissesThePalette() {
        let panel = scratchPanel()
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        // Both are borderless and never ordered in, so they are closed rather than ordered out (see
        // `theWindowClassRefusesKeySoTheFieldKeepsTheCaret`).
        defer { panel.close(); other.close() }
        typealias C = CommandPalettePanelController
        #expect(C.clickDismissesThePalette(clickedWindow: other, palette: panel, at: nil, field: nil),
                "a click in another of this app's windows left the palette up")
        // A click this app cannot attribute to a window of its own is outside by definition.
        #expect(C.clickDismissesThePalette(clickedWindow: nil, palette: panel, at: nil, field: nil))
    }

    /// The rule is only worth anything if the monitor still installs it. `clickDismissesThePalette`
    /// is pure and static, so the tests around this one pass with the whole `addMonitor(matching:)`
    /// block deleted. `present` can't be driven with a synthesised `NSEvent`, so this scans the
    /// call site, as `CommandPaletteRouteCallSiteTests` does.
    ///
    /// The block is bounded by balancing braces, so no indentation can move its end. The mask is
    /// read off this monitor's own call, so a second monitor elsewhere can't stand in for a
    /// narrowed one. Every `return` in the block is parsed and must be `event`, since
    /// `return .none` swallows as surely as `return nil`.
    @Test func theMonitorActuallyInstallsTheClickAwayRule() throws {
        let source = maskedCode(try Self.panelSource())
        let block = try declarationBody(of: "addMonitor(matching: [.leftMouseDown", in: source)

        #expect(block.contains("self.clickDismissesThePalette(clickedWindow: event.window,"),
                "the click monitor no longer consults clickDismissesThePalette — the rule is extracted and unused")
        #expect(block.contains("at: Self.screenPoint(of: event))"),
                "the monitor asks the rule without a point — the Go to field stops being spared, so clicking it closes the palette")
        #expect(block.contains("self.dismiss()"), "the click monitor no longer dismisses")

        // The mask, read off the monitor's own call, never the file at large.
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

    /// No keyDown monitor. The host keeps key, so the ⌘K menu item (which reads a `@FocusedValue`
    /// from that window) works throughout, and ⌘K on an open field selects what is in it. A monitor
    /// would swallow the chord before the menu item saw it.
    @Test func thereIsNoKeyDownMonitorSwallowingTheChord() throws {
        let source = maskedCode(try Self.panelSource())
        #expect(!source.contains("addMonitor(matching: .keyDown"),
                "a keyDown monitor is back — ⌘K is being intercepted before the menu item sees it")
    }

    /// The resign observer is on the host. On the panel it would never fire, since a window that
    /// cannot take key cannot resign it.
    @Test func theResignObserverWatchesTheHostRatherThanThePanel() throws {
        let source = maskedCode(try Self.panelSource())
        // The registration's arguments, not its closure body: `braceBalancedBlock` starts at the
        // first brace, which is the handler, and `object:` is named before it.
        let anchor = try #require(source.range(of: "resignObserver = NotificationCenter.default.addObserver"),
                                  "the resign observer is gone — nothing closes the palette when focus leaves")
        let call = String(source[anchor.lowerBound...].prefix(220))
        #expect(call.contains("object: host"),
                "the resign observer watches the panel — it can never fire, since a window that cannot take key cannot resign it")
        #expect(!call.contains("object: panel"))
    }

    /// The helper the monitors install through must still install, and `dismiss()` must still drain
    /// them. Gutting `addMonitor`, or dropping `eventMonitors.append` or the drain, would leave the
    /// call-site scan above green.
    @Test func theMonitorHelperInstallsAndDismissDrainsThem() throws {
        let source = maskedCode(try Self.panelSource())
        let helper = try declarationBody(of: "private func addMonitor(matching mask:", in: source)
        #expect(helper.contains("NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)"),
                "addMonitor no longer calls AppKit — every monitor in this file is now a no-op")
        #expect(helper.contains("eventMonitors.append(monitor)"),
                "addMonitor no longer tracks the token, so dismiss() can never remove the monitor")

        let dismiss = try declarationBody(of: "func dismiss() {", in: source)
        #expect(dismiss.contains("eventMonitors.forEach(NSEvent.removeMonitor)"),
                "dismiss() no longer drains the monitors — they outlive the palette and fire app-wide")
        #expect(dismiss.contains("eventMonitors = []"),
                "dismiss() leaves stale tokens in the bag — the next dismiss() would remove them twice")
    }

    /// Every `return <expr>` in a block, as the expression's text, in source order. A
    /// `guard … else { return x }` counts, being a swallow just as a tail return is; a `return`
    /// sharing its line with its own closure brace (`filter { w in return w.isVisible }`) does not.
    /// Depth is computed from the current line only, so a `return` on its own line inside a
    /// multi-line nested closure still counts: it can false-fail, never miss a swallow. Pass an
    /// already-masked block.
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
                // At depth 0 the return is this block's. At depth 1 it depends on what opened the
                // brace: `guard … else { return event }` counts, `filter { w in return … }` is the
                // closure's and does not.
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

    /// Only `teardown` may order a window out. `theHostAndItsPanelStayOutOfSight` can't catch an
    /// `orderOut` re-added to `present`, since a window never ordered in satisfies it too, and
    /// every test would stay green until a run where a window holds key (see `makeHost`). Ordering
    /// out at teardown, after the assertions, is right: it keeps these windows from accumulating.
    @Test func onlyTeardownEverOrdersAWindowOut() throws {
        let source = maskedCode(try Self.fixtureSource())
        let teardown = try declarationBody(of: "private func teardown(", in: source)
        #expect(teardown.contains("orderOut"),
                "teardown no longer orders the host out, so this suite's windows stay in the app's window list for the rest of the process")
        // Counted over the whole masked file minus teardown's own block, so a new helper can't hide
        // one; comments and string bodies are blanked, so prose about the call doesn't count. Not a
        // total: teardown ordering out both windows would be a correct change.
        let total = source.components(separatedBy: "orderOut").count - 1
        let inTeardown = teardown.components(separatedBy: "orderOut").count - 1
        #expect(total - inTeardown == 0,
                "the fixture orders a window out \(total - inTeardown)× outside teardown, and only teardown may — an orderOut while a presentation is live is mechanism 11, and no other test in this suite can see it")
    }

    /// This file's own text, for the scans that are about the fixture rather than about the app.
    static func fixtureSource() throws -> String {
        let text = try #require(try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8),
                                "cannot read this fixture's own source — the scan would be vacuous")
        try #require(text.count > 500, "this fixture's own source is implausibly short")
        return text
    }

    /// Reads `CommandPalettePanel.swift` itself. Fails loudly when it cannot be found, so a rename
    /// cannot leave an empty haystack in which every `contains` quietly answers false.
    static func panelSource() throws -> String { try macAppFile("CommandPalettePanel.swift") }

    /// ...and a click on the palette must not dismiss it, or the list would close under the
    /// pointer before it could be used.
    @Test func aClickOnThePaletteItselfIsLeftAlone() {
        let panel = scratchPanel()
        // Never ordered in; closed for the reason `theWindowClassRefusesKeySoTheFieldKeepsTheCaret`
        // gives.
        defer { panel.close() }
        #expect(!CommandPalettePanelController.clickDismissesThePalette(clickedWindow: panel,
                                                                        palette: panel,
                                                                        at: nil, field: nil),
                "clicking the palette dismissed it — its own field and rows would be unusable")
    }

    /// A click on the Go-to field must not close the palette it is typing into. The palette is two
    /// objects, the panel and the field in the host's toolbar, so a click on the field is a click
    /// on the host; treated as click-away, moving the caret or pressing the field's clear button
    /// would dismiss the palette and wipe the query.
    ///
    /// Asked through the live presentation, because the field's rect exists only once the anchor
    /// has landed. All three directions, since sparing everything is as broken as sparing nothing:
    /// dropping the `field` clause must fail the first.
    @Test func aClickOnTheGoToFieldDoesNotCloseTheThingItIsTypingInto() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let field = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed, so the field's rect is known") {
            (host.childWindows?.first?.frame.width ?? 0) == field.width
        }

        #expect(!controller.clickDismissesThePalette(clickedWindow: host,
                                                     at: CGPoint(x: field.midX, y: field.midY)),
                "clicking the Go to field closes the palette and clears what was typed — its own clear button can never be used")
        // The corner a user aims at when they mean "the pane, not the palette", which must still go.
        #expect(controller.clickDismissesThePalette(clickedWindow: host,
                                                    at: CGPoint(x: host.frame.minX + 30,
                                                                y: host.frame.minY + 30)),
                "a click in the pane no longer dismisses — click-away is gone")
        // Just past the capsule's trailing edge: the spared area is the field, not the row.
        #expect(controller.clickDismissesThePalette(clickedWindow: host,
                                                    at: CGPoint(x: field.maxX + 4, y: field.midY)),
                "the spared area is wider than the field — the controls beside it cannot be clicked")
    }

    /// The spared area follows the field, not a rect captured when the palette opened. `fieldRect`
    /// is refreshed only on a move or resize, but the pill grows into the field over 120ms on ⌘K, so
    /// the first anchor can be a mid-animation frame. Placement can lag a frame; the click rule
    /// can't, or a click on the part of the field outside a stale rect closes the palette. No resize
    /// is posted, so this tests the live read, not the refresh.
    @Test func theSparedAreaFollowsTheFieldRatherThanARectCapturedAtOpen() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let opened = Self.fieldRect(in: host)
        var field = opened
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed") {
            (host.childWindows?.first?.frame.width ?? 0) == opened.width
        }

        // The control finishes growing: same row, wider, further left. Nothing posts a notification.
        field = CGRect(x: opened.minX - 200, y: opened.minY, width: opened.width + 200,
                       height: opened.height)
        #expect(!controller.clickDismissesThePalette(clickedWindow: host,
                                                     at: CGPoint(x: field.minX + 20, y: field.midY)),
                "a click on the part of the field that arrived after the anchor was captured closes the palette")
        #expect(controller.clickDismissesThePalette(clickedWindow: host,
                                                    at: CGPoint(x: field.maxX + 40, y: field.midY)),
                "the spared area is not the field's — click-away beside it is gone")
    }

    /// The rule is inert once nothing is up: a monitor that outlived its presentation must not
    /// answer for a panel that is gone.
    @Test func theClickRuleAnswersNothingWithNoPaletteUp() {
        let controller = CommandPalettePanelController()
        #expect(!controller.clickDismissesThePalette(clickedWindow: nil, at: .zero))
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

    /// The anchor keeps looking across run loop turns rather than spending its retries at once.
    /// Blocks queued with `DispatchQueue.main.async` from inside a main-queue drain run in that same
    /// drain, so every retry would come ahead of the SwiftUI update that mounts the toolbar item,
    /// and ⌘K would open an empty panel. The anchor has nothing for its first 100 ms; retrying with
    /// a bare `.async` must fail this.
    @Test func theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpendingEveryRetryAtOnce() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let field = CGRect(x: host.frame.minX + 60, y: host.frame.minY + 120, width: 420, height: 28)
        // The 100 ms starts at the first consultation, not before `present`: a date computed up
        // front races however long `present` takes, and on a loaded machine the first call would
        // already see the field. Starting at the first call makes it nil every time.
        var firstAsked: Date?
        let state = present(controller, over: host, anchor: {
            let now = Date()
            guard let first = firstAsked else { firstAsked = now; return nil }
            return now.timeIntervalSince(first) >= 0.1 ? field : nil
        })
        #expect(state.listWidth == 0, "anchored to a field that did not exist yet")
        // Bounded, generously: the budget under test is ~0.6s, and an unbounded wait would turn a
        // regression into a hung suite.
        let deadline = Date().addingTimeInterval(3)
        while state.listWidth == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.listWidth != 0,
                "every retry was spent inside one runloop turn — ⌘K opens an empty panel with no list")
    }

    /// A field that goes away takes its list off the screen, and brings it back. macOS folds a
    /// toolbar item behind the overflow chevron when the window is narrow, `goToFieldItemView`
    /// refuses a folded item's view, and the anchor answers nil; a list left at its last frame would
    /// hang under nothing.
    ///
    /// Hidden rather than dismissed: a field on screen but not measurable through `host` (the
    /// unverified full-screen case `goToFieldItemView` describes) would be closed too. Hiding is
    /// reversible, which the second half asserts.
    @Test func aFieldThatGoesAwayTakesItsListOffTheScreen() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        var field: CGRect? = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed while the field was still there") {
            (host.childWindows?.first?.frame.width ?? 0) == field?.width
        }
        let panel = try #require(host.childWindows?.first)
        #expect(panel.alphaValue == 1, "the fixture never got the list on screen — the hiding below proves nothing")

        // The item folds into the overflow menu.
        field = nil
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: host)
        await waitUntil("the list came off the screen once its field was unmeasurable") {
            panel.alphaValue == 0
        }
        #expect(panel.ignoresMouseEvents,
                "the hidden list still swallows clicks — an invisible window over the app is the defect this whole shape exists to avoid")
        #expect(controller.isPresented,
                "the palette closed on an anchor it merely could not measure; in full screen that would be \u{2318}K closing itself")

        // …and it comes back, which is what makes hiding the safe half of the choice.
        field = Self.fieldRect(in: host)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: host)
        await waitUntil("the list came back when its field did") { panel.alphaValue == 1 }
        #expect(panel.frame.width == field?.width, "the list came back at the wrong width")
    }

    /// Everything the toolbar field can do to the list: type, ↑ ↓, ↩. The field is in another
    /// window, so each is a call across that gap rather than a keystroke arriving at the view that
    /// owns the list.
    @Test func theToolbarFieldDrivesTheListAcrossTheGap() throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        var ran: [PaletteRoute] = []
        let state = present(controller, over: host, onRun: { ran.append($0) })

        controller.setQuery("legal")
        #expect(state.query == "legal", "typing in the toolbar never reached the list")

        let opened = state.selection
        controller.move(by: 1)
        #expect(state.selection != opened, "↓ from the field editor did not move the selection")
        let landed = try #require(state.selection)
        #expect(state.rows[landed].isAvailable,
                "↓ parked the highlight on a row that cannot be chosen — ↩ would do nothing")

        controller.runSelection()
        #expect(ran.count == 1, "↩ from the field editor ran nothing")
        #expect(!controller.isPresented,
                "↩ ran a route with the field still open — the route lands under a palette that is about to close")
    }

    /// After a dismiss the field's calls are inert rather than aimed at the presentation that
    /// replaced it. `dismiss()` drops the state, and every one of these reads it.
    @Test func theFieldsCallsAreInertOnceThePaletteHasClosed() {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        var ran = 0
        let state = present(controller, over: host, onRun: { _ in ran += 1 })
        let selected = state.selection
        controller.dismiss()

        controller.setQuery("legal")
        controller.move(by: 1)
        controller.runSelection()
        #expect(state.query.isEmpty, "a keystroke after the close still reached the retired list")
        #expect(state.selection == selected, "↓ after the close still moved a retired selection")
        #expect(ran == 0, "↩ after the close ran a route")
    }
}
