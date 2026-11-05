import AppKit
import Foundation
import Sync

/// The three facts about this Mac that decide whether a background survey should be reading:
/// whether the display is asleep, how hot it is, and whether Low Power Mode is on.
///
/// In `MacApp`, not `Sync`, like `ContentSignalExtractor` and `FilingArtifacts`: these come from
/// `ProcessInfo` and `NSWorkspace`, which would answer differently under `swift test`, and `Sync`
/// doesn't look at the machine. The manager takes a closure (`FileSyncManager.machineConditions`);
/// a host that installs none gets `MachineConditions.unknown`, a survey that never pauses.
///
/// Thermal and low-power are politeness: the survey could keep reading and chooses not to. The
/// display matters differently: **iCloud materialisation stalls with the display off**, so the
/// survey is stopped, not choosing to stop. Without this the card's count stops moving and reads as
/// a hang. A slow read and a stalled one look the same from inside the read, so no timer could tell.
@MainActor
final class MachineConditionsMonitor {

    /// From `NSWorkspace`'s screen-sleep notifications, not a `CGDisplay` poll: `CGDisplayIsAsleep`
    /// answers for one display, while the workspace pair answers "is anybody there", fires on wake
    /// and sleep, and costs nothing between. A process launched with the screens already asleep has
    /// seen no edge, so this starts at `false`.
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
        // The `.main` queue above is what makes `assumeIsolated` sound: these blocks arrive on the
        // main thread.
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    /// The current state, as one snapshot: three separate reads would be three instants, and a
    /// decision built from them couldn't be reproduced (the rule `DocumentSurveyConditions` states).
    func current() -> MachineConditions {
        MachineConditions(displayAsleep: screensAsleep,
                          heat: Self.heat(ProcessInfo.processInfo.thermalState),
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// `.fair` is not a reason to stop: a laptop doing anything reaches it, and a survey that paused
    /// there would sit idle for hours with nothing wrong. `.serious` is where the system already
    /// throttles, so a background PDF parse is taking something from the user.
    static func heat(_ state: ProcessInfo.ThermalState) -> DocumentSurveyConditions.Heat {
        switch state {
        case .nominal, .fair: return .nominal
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
