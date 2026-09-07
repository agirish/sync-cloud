import AppKit
import Foundation
import Sync

/// The three facts about this Mac that decide whether a background survey should be reading:
/// whether the display is asleep, how hot it is, and whether Low Power Mode is on.
///
/// **In `MacApp` rather than in `Sync`, for the reason `ContentSignalExtractor` and
/// `FilingArtifacts` are.** Two of the three come from `ProcessInfo` and the third from
/// `NSWorkspace`; a library that reached for either would answer differently under `swift test`
/// than in the running app, and `Sync` deliberately does not go looking at the machine any more
/// than it goes looking at a home directory. The manager takes a closure
/// (`FileSyncManager.machineConditions`) and a host that installs none gets
/// `MachineConditions.unknown` — a survey that never pauses for the machine, which is the honest
/// answer for a host that cannot see it.
///
/// **All three were new surface.** Grepped 2026-08-13 and again 2026-09-07: nothing anywhere in
/// this repository read `ProcessInfo.thermalState` or `isLowPowerModeEnabled`, and nothing observed
/// the display's sleep state. There was no prior art to follow and no existing behaviour to match.
///
/// ## The display is the one that matters, and not for the reason it looks like
///
/// Thermal and low-power are politeness: the survey could keep reading and chooses not to. The
/// display is different — **iCloud materialisation stalls with the display off**, so files simply
/// stop being handed over. The survey is not deciding to stop; it is stopped. Without observing
/// this the card shows a count that quit moving, which reads as a hang, and the honest reading of
/// that state is a person force-quitting an app that was working correctly.
///
/// That is also why this is the one signal that cannot be inferred from a timer or a heuristic: a
/// slow read and a stalled one look identical from inside the read.
@MainActor
final class MachineConditionsMonitor {

    /// `NSWorkspace`'s screen-sleep notifications rather than a `CGDisplay` poll.
    ///
    /// **Notifications, because the state has no cheap synchronous read that means what we want.**
    /// `CGDisplayIsAsleep` answers about one display and this survey cares about "is anybody
    /// there"; the workspace pair is the system's own answer to that question, it fires for the
    /// wake as well as the sleep, and it costs nothing between edges. The trade is that a process
    /// launched while the screens are already asleep has not seen an edge — which is why the
    /// initial value is `false` and documented as such below rather than guessed at.
    private var screensAsleep = false

    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        })
        // The `.main` queue above is what makes `assumeIsolated` sound here, unlike in the run's
        // isolation: these blocks really do arrive on the main thread.
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    /// The current state, as one snapshot.
    ///
    /// **Read as a unit, on purpose.** Three separate reads would be three instants, and a decision
    /// assembled from them is one nobody can reproduce — the same rule `DocumentSurveyConditions`
    /// states one level up.
    func current() -> MachineConditions {
        MachineConditions(displayAsleep: screensAsleep,
                          heat: Self.heat(ProcessInfo.processInfo.thermalState),
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// **`.fair` is deliberately not a reason to stop.** `ProcessInfo` has four bands and the
    /// second one is ordinary — a laptop doing anything at all reaches it, and a survey that stood
    /// down there would spend a three-hour job paused for most of an afternoon while nothing was
    /// actually wrong. `.serious` is where the system is already throttling, which is the point at
    /// which a background PDF parse is taking something from the user.
    static func heat(_ state: ProcessInfo.ThermalState) -> DocumentSurveyConditions.Heat {
        switch state {
        case .nominal, .fair: return .nominal
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
