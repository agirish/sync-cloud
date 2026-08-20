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
///   app; it cannot cover a click over the host, which is already key. Since `963faf4b` the panel
///   is only its list, so those clicks land on the host and the mouse monitor dismisses on them —
///   **except over the Go-to field, which is the palette wearing the host's window.**
///   `CommandPalettePanelController.clickDismissesThePalette` carries that boundary in full, and
///   two earlier versions of this comment had it wrong.
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

    /// A stand-in for the toolbar field's screen rect, **measured from the parked host** so the
    /// list this anchors lands off every display too. Deliberately not centred and not square, so a
    /// transposed placement cannot come out right by accident.
    static func fieldRect(in host: NSWindow) -> CGRect {
        CGRect(x: host.frame.minX + 60, y: host.frame.maxY - 80, width: 420, height: 28)
    }

    /// Presents the palette over `host`, and witnesses any dismissal the test did not ask for.
    ///
    /// **There is no `orderOut` here any more, and that is the fix for mechanism 11** — `makeHost`
    /// carries the deduction. The pair stays out of sight because the host is parked past every
    /// display and every anchor this fixture hands out is measured from the parked host's frame,
    /// not because either is taken back off the screen list. Production raises the panel with an
    /// `orderFront` of its own, and **ordering a child window front orders its parent in too** — measured: a parent never ordered
    /// in reads `isVisible == false` right up until a borderless child of it is ordered front, and
    /// `true` immediately after. That measurement is why the old fixture needed an `orderOut` at
    /// all, and it is unchanged; what changed is that a window ordered in where nobody can see it
    /// costs nothing, while ordering the parent back out cost this suite its five tests.
    ///
    /// **The default anchor is derived from the host, and it has to be.** It was a literal
    /// `(100, 100, 400, 28)` — a rect on the user's actual display — and the panel is placed under
    /// whatever the anchor says, so every async test using the default put a live, fully opaque
    /// list over the desktop for its duration. `theHostAndItsPanelStayOutOfSight` could not catch
    /// it: that test never awaits, and placement needs a runloop turn, so it always measured the
    /// panel at its unplaced construction frame. Parking the host is only half of staying out of
    /// sight once the panel stopped being a copy of the host's frame.
    ///
    /// `onDismiss` is wrapped rather than passed straight through: it is the only seam from which an
    /// ambient teardown can be seen at all. See `DismissalWitness`.
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

    /// **The panel must REFUSE key, and this assertion was inverted on 2026-08-18.**
    ///
    /// While the palette carried its own field, refusing key was the whole defect — no key window,
    /// no first responder, keystrokes somewhere else. §7 moved the field into the host's toolbar,
    /// so the polarity inverts with it: a panel that takes key pulls the caret out of the field the
    /// user is typing into, mid-word. Measured before it was built — with the panel non-key the
    /// host stays key, the field editor keeps first responder, typed characters keep arriving, and
    /// the row highlight draws identically because it is this app's own fill.
    @Test func theWindowClassRefusesKeySoTheFieldKeepsTheCaret() {
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
        // **No longer sized to the host, and that is the point.** It was, because the scrim inside
        // it had to dim the whole window; with the dim gone that only meant the palette swallowed
        // every click over the app. It is sized to its own list now — see
        // `thePanelCoversItsListAndNotTheWindowUnderIt`, which owns that claim in full.
        #expect(panel?.frame != host.frame,
                "the panel is the whole window again — every click over the app will land on it")
        // Parented is what still has to hold: the list rides the window it hangs off.
        #expect(panel?.parent === host, "the list is not riding the host — it will not move with it")
        // The polarity, restated where the panel is a real presentation rather than a bare window:
        // `theWindowClassRefusesKeySoTheFieldKeepsTheCaret` holds the class, this holds what was
        // actually raised.
        #expect(panel?.canBecomeKey == false)
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
        _ = try #require(host.childWindows?.first, "no panel at all — \(witness.report(presented: controller.isPresented))")

        // **Posted for the HOST, not the panel.** The panel cannot become key any more, so it can
        // never resign it: an observer left on the panel would be a dismissal path that silently
        // never fires, and this test would have kept passing by posting a notification nothing in
        // the app can produce.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: host)
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
    @Test func thePanelFollowsTheFieldWhenTheHostResizes() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        // The field moves with the window, so the anchor is read live rather than captured.
        var field = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed under the field") {
            host.childWindows?.first.map { $0.frame.minX == field.minX && $0.frame.width == field.width } ?? false
        }
        // The field's new rect is set BEFORE the resize, so the anchor answers with the laid-out
        // toolbar rather than the one being replaced. That ordering is the real one: `didResize` is
        // posted from inside `setFrame`, and the controller reads again a frame later for exactly
        // the case where it is not — see the observer in `present`.
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

    /// **The panel is the list, and must not cover the window.**
    ///
    /// This is the regression the click-swallow fix is for, and it is the one thing about this
    /// surface a user notices immediately: while the panel was sized to the host, its content
    /// claimed a hit at the host's far corner (measured 2026-08-19, `hitTest → NSHostingView`), so
    /// every click over the app dismissed the palette *instead of* doing what the user meant. The
    /// dim that once justified it is gone; clicking away is the mouse monitor's job, and that
    /// monitor returns the event it dismisses on.
    ///
    /// **Verified by mutation, and the mutation has to be both halves of the revert.** Sizing the
    /// panel back to `host.frame` *alone* does not reproduce it: `NSHostingView` publishes the
    /// content's intrinsic size, and with the list taking its ideal height (`fixedSize`) AppKit
    /// shrinks the window straight back — the frame comes out the right size at the wrong origin,
    /// which the two placement tests catch and this one does not. Make the content flexible
    /// (`maxWidth/maxHeight: .infinity`, a scrim behind it) *and* size the panel to the host, which
    /// is what the code actually was, and this fails on `panel.frame.width → 900`.
    ///
    /// Worth knowing before "simplifying" either half: each is load-bearing only in the presence of
    /// the other, so either one alone reads as removable.
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
        // Placed means live: an unplaced panel is deliberately inert, so a passing frame check with
        // this still true would mean the list cannot be clicked either.
        #expect(panel.ignoresMouseEvents == false, "the panel never became live — its own rows are unclickable")
    }

    // MARK: Click-away

    /// **The rule for the half of click-away that is about another window.**
    ///
    /// Two earlier versions of this comment described a panel spanning the host's whole frame, so
    /// that a click anywhere over the app — content, toolbar band, title bar — was attributed to
    /// *the panel* and this rule answered `false` for all of it. `963faf4b` retired that panel;
    /// those clicks now land on the host and dismiss, returning the event, which is the click-away
    /// the user means. What is left for this half is another of this app's windows: Keyboard
    /// Shortcuts, Activity Log, Sync History, an open panel. See
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
        #expect(C.clickDismissesThePalette(clickedWindow: other, palette: panel, at: nil, field: nil),
                "a click in another of this app's windows left the palette up")
        // A click this app cannot attribute to a window of its own is outside by definition.
        #expect(C.clickDismissesThePalette(clickedWindow: nil, palette: panel, at: nil, field: nil))
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

        #expect(block.contains("self.clickDismissesThePalette(clickedWindow: event.window,"),
                "the click monitor no longer consults clickDismissesThePalette — the rule is extracted and unused")
        #expect(block.contains("at: Self.screenPoint(of: event))"),
                "the monitor asks the rule without a point — the Go to field stops being spared, so clicking it closes the palette")
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

    /// **There is no keyDown monitor any more, and that is the fix.**
    ///
    /// While the panel took key, the menu item could not fire — it reads a `@FocusedValue` from the
    /// window underneath — so a local monitor was the only path left and it made ⌘K *close* the
    /// palette. The host keeps key now, so the menu item works throughout, and ⌘K on an open field
    /// selects what is in it instead (decided 2026-08-18). A monitor left installed would swallow
    /// the chord before the menu item ever saw it, so its absence is asserted rather than assumed.
    @Test func thereIsNoKeyDownMonitorSwallowingTheChord() throws {
        let source = Self.masked(try Self.panelSource())
        #expect(!source.contains("addMonitor(matching: .keyDown"),
                "a keyDown monitor is back — ⌘K is being intercepted before the menu item sees it")
        #expect(!source.contains("closesThePalette"),
                "the retired chord rule is back in the file")
        // The click monitor is NOT retired with it: a right- or middle-click moves no key window,
        // so for two of its three masks it is still the only dismissal path.
        #expect(source.contains("addMonitor(matching: [.leftMouseDown"))
    }

    /// The dismissal that replaces it: **the observer is on the host**. On the panel it would never
    /// fire, since a window that cannot take key cannot resign it.
    @Test func theResignObserverWatchesTheHostRatherThanThePanel() throws {
        let source = Self.masked(try Self.panelSource())
        // The registration's ARGUMENTS, not its closure body: `braceBalancedBlock` starts at the
        // first brace, which is the handler — and `object:` is named before it. Reading the block
        // asked the wrong side of the call and failed on a correct file.
        let anchor = try #require(source.range(of: "resignObserver = NotificationCenter.default.addObserver"),
                                  "the resign observer is gone — nothing closes the palette when focus leaves")
        let call = String(source[anchor.lowerBound...].prefix(220))
        #expect(call.contains("object: host"),
                "the resign observer watches the panel — it can never fire, since a window that cannot take key cannot resign it")
        #expect(!call.contains("object: panel"))
    }

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
                                                                        palette: panel,
                                                                        at: nil, field: nil),
                "clicking the palette dismissed it — its own field and rows would be unusable")
    }

    /// **A click on the Go-to field must not close the thing it is typing into.**
    ///
    /// This is the regression `963faf4b` introduced and this pass fixes. The palette's surface is
    /// two objects — the panel, and the field in the HOST window's toolbar — and while the panel
    /// was sized to the host's whole frame the rule never had to know that: every click over the
    /// app was attributed to the panel. Sizing the panel to its list made a click on the field a
    /// click on the host, so `clickedWindow !== palette` answered `true` for the control the user
    /// was typing into: touching the field to move the caret, or pressing its own clear button,
    /// dismissed the palette and wiped the query. The clear button could not be used at all.
    ///
    /// Asked through the live presentation, because the field's rect is per-presentation state that
    /// exists only once the anchor has landed — a pure-rule test would pass whatever it liked in.
    ///
    /// **All three directions**, because sparing everything is as broken as sparing nothing: the
    /// mutation that matters (drop the `field` clause) leaves the other two green.
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

    /// **The spared area follows the field, rather than a rect captured when the palette opened.**
    ///
    /// `fieldRect` is refreshed only when the window moves or resizes, and the field moves without
    /// either: the pill grows into the field over 120ms on ⌘K, so the first anchor to answer can be
    /// a frame from the middle of that animation. Placement can be a frame behind and nobody dies;
    /// the click rule cannot, because the part of the real field outside a stale rect is exactly
    /// where a click closes the palette instead of moving the caret.
    ///
    /// No resize is posted here on purpose — that is what makes this about the LIVE read rather
    /// than about the refresh.
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

    /// **The list is placed under the field, at the field's width and left edge.**
    ///
    /// The panel is a window now, so this is arithmetic in one coordinate space rather than the
    /// AppKit→SwiftUI flip it replaced — but it is the same claim, and it is what a user sees as
    /// "the list belongs to that field". Deliberately not centred and not square, so a transposed
    /// placement cannot land on the right answer by accident.
    @Test func theListIsPlacedUnderTheFieldItHangsFrom() async throws {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let field = Self.fieldRect(in: host)
        present(controller, over: host, anchor: { field })
        await waitUntil("the panel was placed") { (host.childWindows?.first?.frame.width ?? 0) == field.width }
        let panel = try #require(host.childWindows?.first)

        #expect(panel.frame.minX == field.minX, "the list is not aligned with the field's left edge")
        #expect(panel.frame.width == field.width, "the list is not as wide as the field")
        #expect(panel.frame.maxY == field.minY - GoToResultsPanel.gapBelowField,
                "the list is not hanging just under the field — a gap of \(GoToResultsPanel.gapBelowField)pt is what makes the two read as one object")
        #expect(panel.frame.height > 0, "the list has no height — nothing is drawn")
    }

    /// **The anchor keeps looking across runloop turns rather than burning its retries at once.**
    ///
    /// This is the defect that shipped, measured in the running app on 2026-08-19: the retry was a
    /// bare `DispatchQueue.main.async`, and blocks queued from inside a main-queue drain run in
    /// that same drain — so all six "retries" were six calls in one turn, every one of them ahead
    /// of the SwiftUI update that mounts the toolbar item. ⌘K then put an invisible panel over the
    /// window with no list in it and logged `the Go to field never appeared`.
    ///
    /// Modelled the way the real thing behaves: an anchor with nothing to give for the first
    /// 100 ms. Under the shipped code every retry is spent inside the first millisecond and this
    /// fails; the mutation to confirm that is to put `.async` back.
    @Test func theAnchorKeepsLookingAcrossRunloopTurnsRatherThanSpendingEveryRetryAtOnce() async {
        let host = makeHost()
        let controller = CommandPalettePanelController()
        defer { teardown(host, controller) }
        let ready = Date().addingTimeInterval(0.1)
        let field = CGRect(x: host.frame.minX + 60, y: host.frame.minY + 120, width: 420, height: 28)
        let state = present(controller, over: host, anchor: { Date() >= ready ? field : nil })
        #expect(state.listWidth == 0, "anchored to a field that did not exist yet")
        // Bounded, and generously: the budget under test is ~0.6s, and a wait that cannot end is
        // how a regression here becomes a hung suite rather than a failing one.
        let deadline = Date().addingTimeInterval(3)
        while state.listWidth == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.listWidth != 0,
                "every retry was spent inside one runloop turn — ⌘K opens an empty panel with no list")
    }

    /// **A field that goes away takes its list off the screen — and brings it back.**
    ///
    /// macOS folds a toolbar item behind the overflow chevron when the window is dragged narrow,
    /// and `goToFieldItemView` refuses a folded item's view (it answers in its own bounds and hands
    /// back a plausible rect at the window's corner). The anchor then answers nil, and before this
    /// the panel simply stayed at its last frame: a list hanging under nothing, with the field it
    /// belongs to no longer on the row.
    ///
    /// **Hidden rather than dismissed, deliberately.** Closing the palette reads better for the two
    /// states this can see — the field folded away, the field never mounted — and it claims more
    /// than the anchor can know: a field that is on screen but not measurable through `host` would
    /// be closed too, which is the shape of the unverified full-screen case
    /// (`goToFieldItemView` carries it). Hiding is never worse than what shipped, and it is
    /// reversible, which is what the second half asserts.
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

    /// The whole of what the toolbar field can do to the list, which is everything the palette's
    /// own field used to do: type, ↑ ↓, ↩.
    ///
    /// **This is the seam §7 created**, and none of it existed before: the field is in another
    /// window now, so every one of these is a call across that gap rather than a keystroke arriving
    /// at the view that owns the list.
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

    @Test func theIndexIsSnapshottedRatherThanReReadPerKeystroke() {
        // A palette that re-indexed between a key and its character would be walking the folder
        // profile inside a keystroke. The state takes the index once, at init.
        let state = CommandPaletteState(index: index)
        state.setQuery("legal")
        #expect(state.index.folders == ["Legal"])
    }
}
