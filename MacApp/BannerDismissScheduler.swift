import Foundation
import Sync

/// Owns the single auto-dismiss timer for the operation banner.
/// Every banner change cancels the previous timer, so a replacement banner — even one with the
/// exact same content — always gets the full display window, and a banner cleared elsewhere cannot
/// be dismissed early by a stale timer that merely compares values.
///
/// Dismissal rules by severity: success and warning auto-dismiss after their configured delay
/// (warnings get a longer window); errors are sticky and stay until manually closed. A message
/// that is the toolbar capsule's own gets a longer window of its own (`capsuleNanoseconds`); a
/// run's ending the capsule only mirrors from a pane keeps the pane's.
/// Hovering the banner pauses the timer; on hover exit the FULL delay restarts (not the
/// remainder) — a deliberate simplification: the user was just reading the banner, so it earns
/// a fresh window.
///
/// Hover is kept per surface (`ResultMessageHome`): a message can show in a pane, the workspace,
/// the toolbar's capsule, or a pane and the capsule at once. SwiftUI delivers no hover exit for a
/// view that is removed, so a surface that stops showing the message stops counting as hovered —
/// or a message that moved from under a resting pointer to somewhere else would never time out.
@MainActor
final class BannerDismissScheduler {
    /// Auto-dismiss delays per severity. Injectable so tests can run on short windows.
    struct Delays {
        var successNanoseconds: UInt64 = 5_000_000_000
        var warningNanoseconds: UInt64 = 10_000_000_000
        /// **The toolbar capsule's own message, success or warning** (Run Room CG): a run's ending
        /// after the reader moved on from where it was started, so it is never where they are
        /// looking — and never under the pointer, which is what holds a pane's message open while
        /// it is read. Five seconds there came and went unseen. A run's ending the capsule mirrors
        /// from a pane is the pane's message, on the pane's window.
        var capsuleNanoseconds: UInt64 = 10_000_000_000

        static let standard = Delays()

        /// `nil` means the banner never auto-dismisses (sticky).
        func delayNanoseconds(for severity: OperationBanner.Severity, inCapsule: Bool = false) -> UInt64? {
            switch severity {
            case .success: return inCapsule ? capsuleNanoseconds : successNanoseconds
            case .warning: return inCapsule ? capsuleNanoseconds : warningNanoseconds
            case .error: return nil
            }
        }
    }

    private let delays: Delays
    /// How the scheduler waits out a delay. Injectable for the same reason `Delays` is — except
    /// that shortening the window does not make a test deterministic, it only makes the race
    /// tighter: asserting "not dismissed yet" after sleeping 300ms of a 500ms window fails a
    /// perfectly correct scheduler whenever a loaded runner turns that 300ms into 600ms. With the
    /// wait itself injected, a test releases it explicitly and both halves — "hasn't fired" and
    /// "has fired" — are exact. Defaults to a real sleep, so production behaviour is unchanged.
    private let sleep: @Sendable (UInt64) async -> Void
    private var dismissTask: Task<Void, Never>?
    /// The timer currently counting down, or nil when none is running. Exposed for tests, which
    /// otherwise have no sound way to state either half of this scheduler's contract: "no timer was
    /// started at all" and "the cancelled timer ran to completion without dismissing" are both
    /// claims about this task, and a test that infers them from `dismissCount` instead is really
    /// asserting that a task it never waited for has not run yet — which is true of a correct
    /// scheduler and a broken one alike.
    var currentTimerTask: Task<Void, Never>? { dismissTask }
    /// The full delay window for the currently shown banner; `nil` when there is no banner or it is sticky.
    private var currentDelay: UInt64?
    private var dismiss: (@MainActor () -> Void)?
    /// The surfaces the pointer is over, among those showing the message.
    private var hovered: Set<ResultMessageHome> = []
    /// Held open by something the message opened — "Save as rule…"'s offer, whose popover takes the
    /// pointer off the message, so hover alone would let the message (and the offer riding in it)
    /// time out under the reader mid-choice.
    private var isHeld = false

    init(delays: Delays = .standard,
         sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        self.delays = delays
        self.sleep = sleep
    }

    /// Call from the view's `onChange` whenever the banner changes.
    /// - Parameters:
    ///   - newValue: The new banner (`nil` when the banner was cleared).
    ///   - inCapsule: Whether the toolbar's capsule shows it rather than a pane or the workspace.
    ///   - surfaces: Every surface that shows it — two when the capsule mirrors a pane's.
    ///   - dismiss: Runs on the main actor after the severity's delay, unless superseded,
    ///     cancelled, or the banner is sticky.
    func bannerChanged(to newValue: OperationBanner?, inCapsule: Bool = false,
                       shownOn surfaces: Set<ResultMessageHome> = [.pane(isLeft: true)],
                       dismiss: @escaping @MainActor () -> Void) {
        cancelTimer()
        currentDelay = nil
        self.dismiss = nil
        guard let banner = newValue else {
            // The banner view is gone, so hover is definitionally over — but SwiftUI doesn't
            // deliver onHover(false) for a removed view, and every ✕ click happens while
            // hovered. Without this reset the next banner would start paused and never dismiss.
            hovered = []
            isHeld = false
            return
        }
        // A banner replaced while the pointer is over it stays paused until hover exit — on a
        // surface that shows it. One that does not (a pane's message replaced by the capsule's
        // own, the capsule's mirror by a click's result) delivers no exit.
        hovered.formIntersection(surfaces)
        guard let delay = delays.delayNanoseconds(for: banner.severity, inCapsule: inCapsule) else { return }
        currentDelay = delay
        self.dismiss = dismiss
        if hovered.isEmpty && !isHeld { startTimer(delay) }
    }

    /// Call when the same message moves to other surfaces — a workspace switch, which can take it
    /// from a pane to the lens or the other pane while the pointer rests where it was.
    func surfacesChanged(to surfaces: Set<ResultMessageHome>) {
        guard !hovered.isSubset(of: surfaces) else { return }
        hovered.formIntersection(surfaces)
        pausesChanged()
    }

    /// Arms this scheduler for a banner that was ALREADY on screen when it was created — call from
    /// the view's `onAppear`.
    ///
    /// The scheduler is view `@State` but the banner is owned by the sync manager, which outlives
    /// the window. A scheduler that comes into being with a banner already showing — a rebuilt
    /// ContentView, which is how a close + Dock reopen was understood when this was written — is
    /// never told about it, and `onChange(of:)` never fires for an unchanged value, so nothing else
    /// was ever going to tell it. The success banner then sat there forever, and its ✕ was the
    /// only way out. On macOS 27 a close + Dock reopen keeps the same view and scheduler (see
    /// `SyncCloudApp.hasBootstrappedSession`), but nothing in SwiftUI promises that, so the
    /// adoption stays.
    ///
    /// Deliberately a no-op unless this scheduler has never tracked anything (`dismissTask` and
    /// `currentDelay` both still nil), so an `onAppear` that fires a second time for the same
    /// instance cannot restart a countdown that is already running — or resurrect one for a banner
    /// the user has since dismissed.
    func adoptExistingBanner(_ banner: OperationBanner?, inCapsule: Bool = false,
                             shownOn surfaces: Set<ResultMessageHome> = [.pane(isLeft: true)],
                             dismiss: @escaping @MainActor () -> Void) {
        guard let banner, dismissTask == nil, currentDelay == nil else { return }
        bannerChanged(to: banner, inCapsule: inCapsule, shownOn: surfaces, dismiss: dismiss)
    }

    /// Call from the banner view's `onHover`. Entering pauses the auto-dismiss timer;
    /// exiting restarts it with the full delay window, unless the pointer is over another surface
    /// showing the message.
    func hoverChanged(isHovering: Bool, on surface: ResultMessageHome = .pane(isLeft: true)) {
        let wasPaused = !hovered.isEmpty
        if isHovering { hovered.insert(surface) } else { hovered.remove(surface) }
        guard hovered.isEmpty == wasPaused else { return }
        pausesChanged()
    }

    /// Call while something the message opened is in use. Holding pauses the timer as hovering
    /// does; letting go restarts the full window, unless the pointer is still over the message.
    func holdChanged(isHeld: Bool) {
        guard isHeld != self.isHeld else { return }
        self.isHeld = isHeld
        pausesChanged()
    }

    private func pausesChanged() {
        if !hovered.isEmpty || isHeld {
            cancelTimer()
        } else if let delay = currentDelay {
            startTimer(delay)
        }
    }

    private func startTimer(_ delayNanoseconds: UInt64) {
        let wait = sleep
        dismissTask = Task { @MainActor [weak self] in
            await wait(delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss?()
        }
    }

    private func cancelTimer() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
