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
/// **Key transfer here is real, and intermittent — which is not what this note used to say.** It
/// read "real key transfer is not observable in this test host … an `xcodebuild test` host is not
/// [active], and `isKeyWindow` stayed false through a five-second poll". Probed again on
/// 2026-08-16 from inside a running app-target suite, the opposite came back:
///
/// ```
/// isActive=true  keyWindow=CommandPaletteWindow  panelKey=true  hostVisible=true
/// ```
///
/// The app was active and the panel really was the key window. Both readings are presumably honest
/// about the moment they were taken — whether an `xcodebuild` host is frontmost depends on what
/// else is happening on the machine — and **that variability is the whole of mechanism 11**, which
/// `makeHost` sets out. The lesson is the general one: a single measurement of an environment is a
/// measurement of that environment *then*, and this suite built a standing rule on one.
///
/// The split this suite settled on is still the right one, and does not depend on which way that
/// reading goes. **AppKit's key machinery is not mine to test**; what is mine is (1) the window
/// class *permitting* key at all, which is the exact default that was broken, and (2) what this
/// controller does when key is lost, which is driven here by posting the notification AppKit would
/// post — deliberately, so the test does not depend on whether a transfer happens to occur. Both
/// mutations that matter — a panel that refuses key, a resign handler that does nothing — are still
/// killed by that pair.
///
/// `.serialized` because these build real windows, real child windows and the controller's app-wide
/// event monitors, all of which are process-wide state. (Everything they order in is parked past
/// every attached display rather than taken back off the screen list; see `makeHost`.)
@MainActor
@Suite(.serialized) struct CommandPalettePanelTests {

    /// A host to hang the panel on: **borderless, parked past every display, and never ordered out
    /// while the palette is up.** Ordered out and released at the end of each test rather than
    /// `close()`d — closing a window in a test host has ended runs with no verdict before.
    ///
    /// ## What this replaces, and why
    ///
    /// This suite used to build a `.titled` host, `makeKey()` it, and have `present` call
    /// `host.orderOut(nil)` immediately afterwards to keep it off the user's screen. That kept the
    /// windows invisible, and it cost five intermittent failures — `childWindows → []`,
    /// `panel → nil`, `isPresented → false`, every one of them in under 0.1s — which
    /// `docs/flaky-tests.md` carried as mechanism 11, cause unknown, for weeks.
    ///
    /// **That `orderOut` was the trigger, and it reproduces on demand.** Presenting the palette in
    /// this suite and then making the one call the old fixture made, from inside a running
    /// app-target run:
    ///
    /// ```
    /// before                     panelKey=true   isPresented=true    children=1
    /// after host.orderOut(nil)                   isPresented=false   children=0   dismissalsSeen=1
    /// ```
    ///
    /// One call, the whole failing signature. And the witness captures the stack, so the caller is
    /// **named rather than deduced** — reading the recorded frames bottom-up:
    ///
    /// ```
    /// present…Foundation12NotificationVYbcfU2_   <- the didResignKey observer closure
    /// MainActor.assumeIsolated                   <- its `assumeIsolated { self?.dismiss() }`
    /// CommandPalettePanelController.dismiss()
    /// ```
    ///
    /// So the chain is: ordering out a parent takes its key child with it, the child posts
    /// `didResignKey`, the controller answers that with `dismiss()` — correct behaviour, losing key
    /// is exactly when the palette should close — and `dismiss()` unparents the panel and clears
    /// `isPresented`. Every link is observed; none of it is "the only remaining possibility", which
    /// matters in a file whose own lesson is that a cause you have not measured is a cause you have
    /// guessed.
    ///
    /// Two supporting measurements explain why it could land *inside* `present`, before the first
    /// `#expect`. A `NotificationCenter` block observer registered with `queue: .main` runs
    /// **synchronously** when the post is on the main thread, so no runloop turn is needed — which
    /// is how three of the five failing tests could lose without ever awaiting. And `host.orderOut`
    /// does **not** by itself unparent anything (25/25), so the missing child was always the app's
    /// own `removeChildWindow`, never AppKit dropping a relationship.
    ///
    /// The chain needs the panel to have really been key, and **it is** — same probe:
    /// `isActive=true keyWindow=CommandPaletteWindow panelKey=true`. Whether an `xcodebuild` host is
    /// frontmost depends on what else the machine is doing, so the panel is key on some runs and not
    /// others, and that is exactly the burst pattern the flake had.
    ///
    /// That reproduction is deliberately **not** a shipped test: it only fires while the panel holds
    /// key, so as a permanent test it would be a new flake of precisely the kind this entry is
    /// about. Re-run it by hand if this ever needs re-establishing.
    ///
    /// An earlier probe of this same theory fired once in 21 runs and was written off as noise. It
    /// ran in a **standalone binary**, where `NSApp.keyWindow` is `nil` and no window is ever key —
    /// measured — so twenty of those runs could not have fired whatever the code did. The single
    /// firing was the signal. A null result only retires a hypothesis if the harness could have
    /// produced a positive.
    ///
    /// ## Parking, which the note this replaces said was not open to us
    ///
    /// It was not, for a **titled** window: one created at `(-2900, -2600)` came up at
    /// `(-860, -513)`, because `constrainFrameRect` runs on every frame change to a visible titled
    /// window, and overriding that constraint moved it to `(460, 728)` — squarely on the display —
    /// and desynchronised the panel from its host along the way. A **borderless** window is the case
    /// the constraint skips, which is how `DetailsWhereItLivesTests` in Dashboard has parked its
    /// window all along.
    ///
    /// Nothing here ever needed `.titled`. It was there "so it can take key the way the real window
    /// does", and no test reads the host's key state — the window that takes key is the *panel*, as
    /// the probe above shows, and the class that has to permit it is the panel's, which
    /// `theWindowClassCanBecomeKeyAtAll` holds. `makeKey()` goes with the style mask: a borderless
    /// `NSWindow` answers `canBecomeKey` **false** — measured here, `canBecomeKey=false` on this very
    /// host — so the call was already a no-op, and keeping one that does nothing would only suggest
    /// the host's key state here means something.
    ///
    /// `theHostAndItsPanelStayOutOfSight` is still the guard. It now accepts either remedy — not
    /// ordered in, *or* parked past every display — which the note this replaces already allowed for
    /// ("a window parked off every display would be just as acceptable"), and which keeps the guard
    /// about the user's screen rather than about whichever mechanism is currently in force.
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
    ///
    /// **Never empty, and that is deliberate** — the same fallback, for the same reason, as
    /// `DetailsWhereItLivesTests.displayBounds`. With no displays attached `NSScreen.screens` is
    /// itself empty and a union of nothing is null, so a guard written only as "intersects no
    /// screen" would be true of every frame including one at the origin, and an assertion that
    /// cannot fail is not a guard.
    static func displayBounds() -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return union.isNull ? CGRect(x: 0, y: 0, width: 4000, height: 4000) : union
    }

    /// An origin far enough below-left of every display that a window of `size` cannot reach one.
    static func offscreenOrigin(for size: CGSize) -> CGPoint {
        let bounds = displayBounds()
        return CGPoint(x: bounds.minX - size.width - 2000, y: bounds.minY - size.height - 2000)
    }

    /// **Every dismissal, and where it came from.**
    ///
    /// All five window tests here fail by reporting a *missing object* — `childWindows → []`,
    /// `panel → nil`, `isPresented → false` — and that shape is equally `present` never attaching
    /// the panel, which is a real regression in the app, and the panel being attached and then torn
    /// down afterwards, which is what the fixture used to cause. Nothing in the messages could tell
    /// those two apart, and that is most of why mechanism 11 took weeks to name: `docs/ci.md` says
    /// the app-target step is the only one that compiles `MacApp/` at all, so misreading it costs
    /// the one signal that surface has.
    ///
    /// `dismiss()` is what produces both readings, and the fixture owns `onDismiss`, so it sees
    /// every call to it. Recording the activation state and the app's own stack frames turns "no
    /// window" into a cause — including for the paths this fix does *not* close, since a stray
    /// mouse-down anywhere in the app still dismisses by design.
    @MainActor private final class DismissalWitness {
        private(set) var dismissals: [String] = []

        func record() {
            // Falling back to the unfiltered head matters: if the app's frames are ever unsymbolicated
            // the filter yields nothing, and an empty stack would quietly remove the most useful half
            // of this message while still looking like a report.
            let symbols = Thread.callStackSymbols
            let ours = symbols.filter { $0.contains("SyncCloud") }
            let frames = (ours.isEmpty ? symbols : ours).prefix(10).joined(separator: "\n        ")
            dismissals.append("app active=\(NSApp.isActive), key window="
                + "\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")\n        "
                + frames)
        }

        /// Read only into a failure message, so it can afford to be long.
        ///
        /// **`presented` is what makes the no-dismissal case say anything true.** The first version
        /// read "no dismissal was recorded, so the panel was never attached", which is a false
        /// inference: an empty `childWindows` with no `dismiss()` can also mean the panel was
        /// unparented behind the controller's back, and `isPresented` separates those.
        ///
        /// **The second version then over-corrected and named a cause it had not measured** — it
        /// blamed AppKit ordering a `hidesOnDeactivate` child out. Two measurements say otherwise:
        /// this panel reads `hidesOnDeactivate == false` (a `.nonactivatingPanel` ignores the
        /// setter), and deactivating the app *does* dismiss the palette through the resign observer,
        /// recording a dismissal — so deactivation is not a no-dismissal case at all. What remains
        /// true is only the mechanism, not any particular trigger for it: **ordering out a child
        /// detaches it from its parent** (measured, 5/5), so anything that orders the panel out
        /// without going through `dismiss()` produces exactly this reading. The message says that
        /// and stops, because a diagnostic that names the wrong cause confidently is how mechanism
        /// 11 stayed open.
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

    /// Presents the palette over `host`, and witnesses any dismissal the test did not ask for.
    ///
    /// **There is no `orderOut` here any more, and that is the fix for mechanism 11** — `makeHost`
    /// carries the deduction. The pair stays out of sight because the host is parked past every
    /// display and the panel is built at `host.frame`, not because it is taken back off the screen
    /// list. Production still raises the panel with a `makeKeyAndOrderFront` of its own, and
    /// **ordering a child window front orders its parent in too** — measured: a parent never ordered
    /// in reads `isVisible == false` right up until a borderless child of it is ordered front, and
    /// `true` immediately after. That measurement is why the old fixture needed an `orderOut` at
    /// all, and it is unchanged; what changed is that a window ordered in where nobody can see it
    /// costs nothing, while ordering the parent back out cost this suite its five tests.
    ///
    /// `onDismiss` is wrapped rather than passed straight through: it is the only seam from which an
    /// ambient teardown can be seen at all. See `DismissalWitness`.
    @discardableResult
    private func present(_ controller: CommandPalettePanelController, over host: NSWindow,
                         onRun: @escaping (PaletteRoute) -> Void = { _ in },
                         onDismiss: @escaping () -> Void = {}) -> CommandPaletteState {
        let state = CommandPaletteState(index: index)
        controller.present(over: host, state: state, accent: .blue, glassLevel: .frosted,
                           onRun: onRun,
                           onDismiss: { [witness] in witness.record(); onDismiss() })
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
        #expect(controller.isPresented, "the palette is not up — \(witness.report(presented: controller.isPresented))")
        let panel = try? #require(host.childWindows?.compactMap { $0 as? CommandPaletteWindow }.first)
        #expect(panel != nil,
                "the panel is not a child of the host — it will not move or order with it. \(witness.report(presented: controller.isPresented))")
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

    /// **Neither of the real windows this suite builds may appear on the user's screen.**
    ///
    /// The panel is checked as well as the host, and it is the one that could drift: the controller
    /// raises it with `makeKeyAndOrderFront` of its own, so "the host is not visible" alone would
    /// not settle it — a scrim sized to the host and shown anyway is exactly the 900×600 gray sheet
    /// this suite used to flash over whatever the user was doing.
    ///
    /// **The requirement is that the user cannot see them, and there are two ways to satisfy it** —
    /// not ordered in, or parked past every display. Each is checked as a disjunction so that
    /// neither is pinned: this suite has now used both remedies, and a guard that mandated the one
    /// in force would have to be rewritten to change it, which is how a guard comes to be about its
    /// own implementation rather than about the user's screen.
    ///
    /// As it stands both windows *are* visible — the panel's `makeKeyAndOrderFront` orders the host
    /// in with it — so it is the parking that carries them here. `makeHost` says why.
    ///
    /// Verified by mutation: give `makeHost` an on-screen origin (its old `(200, 200)`) and both
    /// halves fail, the panel's included — which is also the measurement that a child window takes
    /// its frame from its parent rather than needing to be parked on its own.
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
        #expect(controller.isPresented, "the palette is not up — \(witness.report(presented: controller.isPresented))")
        let panel = try #require(host.childWindows?.first, "no panel to resign key — \(witness.report(presented: controller.isPresented))")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        // Delivered on the main queue, so it lands on a later turn. Bounded, and it fails at the
        // deadline rather than passing on timeout.
        await waitUntil("the palette dismissed after resigning key") { !controller.isPresented }
        #expect(dismissed, "onDismiss did not fire, so the chord suspension stays stuck on")
    }

    /// Every exit path runs `onDismiss` exactly once. Six things call `dismiss()` and two can
    /// race — esc arriving as the panel is already resigning key — so a second call must be inert
    /// rather than re-firing the callback that clears the chord suspension.
    ///
    /// **This is also the only place `DismissalWitness` is bound to an assertion, and it has to be
    /// bound somewhere.** The witness is read solely into failure messages, so a green run never
    /// exercises it: delete `witness.record()` from `present` and all sixteen tests still pass, with
    /// every diagnostic in the suite silently gone — the same "extracted for testability, one revert
    /// from being unused" hazard `theMonitorActuallyInstallsTheClickAwayRule` exists to catch one
    /// level up. Asserting the count here kills that mutation, and this test is the right host for
    /// it because it is the one that dismisses deliberately and knows exactly how many to expect.
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
                "presenting twice left \(host.childWindows?.count ?? 0) panels parented to the host. \(witness.report(presented: controller.isPresented))")
        teardown(host, controller)
    }

    /// The new frame is parked too. Resizing to somewhere on the display would put a 1200×800 window
    /// over the user's desktop for the length of this test, which is the whole thing `makeHost` is
    /// arranged to avoid — and `theHostAndItsPanelStayOutOfSight` would not catch it, because it
    /// never resizes.
    @Test func thePanelFollowsTheHostWhenItResizes() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        present(controller, over: host)
        let grown = CGSize(width: 1200, height: 800)
        host.setFrame(CGRect(origin: Self.offscreenOrigin(for: grown), size: grown), display: true)
        await waitUntil("the panel followed the host's new frame") {
            host.childWindows?.first?.frame == host.frame
        }
        #expect(host.childWindows?.first?.frame == host.frame,
                "the scrim came adrift of the window it is dimming — \(witness.report(presented: controller.isPresented))")
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

    /// **Only `teardown` may order a window out, and this is the only thing that says so.**
    ///
    /// `theHostAndItsPanelStayOutOfSight` cannot catch a re-added `host.orderOut(nil)` in `present`:
    /// a window that was never ordered in satisfies that guard exactly as well as a parked one,
    /// which is the flexibility it is deliberately written to allow. So the single call that cost
    /// this suite five tests for weeks would otherwise have nothing standing over it — put it back
    /// and every test here stays green until the next run on which the panel happens to hold key,
    /// which is precisely the failure mode that took weeks to name the first time.
    ///
    /// The rule is narrow on purpose. Ordering out at *teardown*, after the assertions, is right and
    /// is what stops these windows accumulating in the app's window list. What is banned is ordering
    /// one out while a presentation is live, because that takes the panel's key away and the
    /// controller correctly answers that by dismissing the palette the assertions are about.
    @Test func onlyTeardownEverOrdersAWindowOut() throws {
        let source = Self.masked(try Self.fixtureSource())
        let teardown = try Self.braceBalancedBlock(after: "private func teardown(", in: source,
                                                   what: "the fixture's teardown")
        #expect(teardown.contains("orderOut"),
                "teardown no longer orders the host out, so this suite's windows stay in the app's window list for the rest of the process")
        // Counted over the whole masked file *minus* teardown's own block, so a new helper cannot
        // introduce one somewhere this scan was not looking. Comments and string bodies are blanked,
        // so the several places that merely *discuss* the call do not count.
        //
        // **Outside-the-block, not a total.** The first version asserted `total == 1`, which is a
        // different rule from the one this test is named for and a broader one: teardown ordering
        // out both windows is a perfectly correct change, and a total would have banned it while
        // claiming to be about where the call sits. A guard whose assertion is wider than its reason
        // is a guard that refuses the next correct fix.
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
