import Foundation
import Sync

/// Owns the single auto-dismiss timer for the operation banner. Every banner change cancels the
/// previous timer, so a replacement banner, even one with identical content, gets the full window,
/// and a stale timer can't dismiss a banner early.
///
/// Success and warning auto-dismiss after their delay (warnings later); errors stay until closed.
/// The toolbar capsule's own message gets `capsuleNanoseconds`; one it only mirrors from a pane
/// keeps the pane's. Hover pauses the timer, and hover exit restarts the full delay, not the
/// remainder: the user was just reading it.
///
/// Hover is kept per surface (`ResultMessageHome`), since a message can show in a pane and the
/// capsule at once. SwiftUI delivers no hover exit for a removed view, so a surface that stops
/// showing the message stops counting as hovered, or a message that moved away from a resting
/// pointer would never time out.
@MainActor
final class BannerDismissScheduler {
    /// Auto-dismiss delays per severity. Injectable so tests can run on short windows.
    struct Delays {
        var successNanoseconds: UInt64 = 5_000_000_000
        var warningNanoseconds: UInt64 = 10_000_000_000
        /// The toolbar capsule's own message, success or warning: a run ending after the reader
        /// moved on, so it is never where they look and never under the pointer that would hold
        /// it open. Five seconds there went unseen. A message the capsule mirrors from a pane keeps
        /// the pane's window.
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
    /// How the scheduler waits out a delay. Injected so a test can release the wait explicitly
    /// and assert "hasn't fired" and "has fired" exactly; a short real window only races a loaded
    /// runner. Defaults to a real sleep.
    private let sleep: @Sendable (UInt64) async -> Void
    private var dismissTask: Task<Void, Never>?
    /// The timer counting down, or nil. Exposed for tests: "no timer started" and "the cancelled
    /// timer finished without dismissing" are claims about this task, which `dismissCount` alone
    /// can't make, since a task nobody waited for hasn't run in a broken scheduler either.
    var currentTimerTask: Task<Void, Never>? { dismissTask }
    /// The full delay window for the currently shown banner; `nil` when there is no banner or it is sticky.
    private var currentDelay: UInt64?
    private var dismiss: (@MainActor () -> Void)?
    /// The surfaces the pointer is over, among those showing the message.
    private var hovered: Set<ResultMessageHome> = []
    /// Held open by something the message opened, such as "Save as rule…"'s popover, which takes
    /// the pointer off the message; hover alone would let it time out mid-choice.
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
            // SwiftUI delivers no onHover(false) for a removed view, and every ✕ click happens
            // while hovered. Without this reset the next banner would start paused and never
            // dismiss.
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

    /// Arms this scheduler for a banner already on screen when it was created. Call from the
    /// view's `onAppear`.
    ///
    /// The scheduler is view `@State`, but the sync manager owns the banner and outlives the
    /// window. A new scheduler (a rebuilt ContentView) is never told about a banner already showing,
    /// since `onChange(of:)` doesn't fire for an unchanged value, so that banner would never
    /// dismiss. macOS 27 keeps the same view across a close and Dock reopen
    /// (`SyncCloudApp.hasBootstrappedSession`), but SwiftUI doesn't promise it.
    ///
    /// A no-op unless this scheduler has never tracked anything (`dismissTask` and `currentDelay`
    /// both nil), so a second `onAppear` can't restart a running countdown or revive one for a
    /// banner the user dismissed.
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
