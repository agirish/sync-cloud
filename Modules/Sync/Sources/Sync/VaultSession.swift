import Foundation

/// The Vault's lock for as long as the app runs (VT7 a): the lock itself, the epoch every end of
/// access moves on, whether the panel is up, and whether a read holds the numbers past a lock.
/// A value that decides; ``VaultModel`` acts on what it decides (lets the numbers go, logs, asks
/// for a proof), so the rules are tested with no model.
struct VaultSession {
    var lock: VaultLock
    /// Moves on whenever access ends by hand or by the system (close, Lock Now, sleep, new
    /// settings, a restore), so a proof asked for before it cannot open the Vault after it.
    private(set) var epoch = 0
    /// Whether the panel is up: a closed Vault left open by its setting lets its numbers go once
    /// its idle limit passes, though no tick runs then.
    private(set) var panelUp = false
    /// The Vault locked while a read was going on: its numbers go once the read ends.
    private(set) var releaseAfterReading = false
    /// The last use of the panel taken (``panelActivity(at:)``).
    private var lastPanelActivity = Date.distantPast

    init(lock: VaultLock) { self.lock = lock }

    /// Access ends: Lock Now, the Mac locking or sleeping, a restore, new lock settings. Every
    /// proof given so far is spent, and one being asked for opens nothing.
    mutating func lockAll() {
        epoch &+= 1
        lock.lock()
    }

    /// The panel came up. A read that outlived the last close no longer lets the numbers go as
    /// it ends: the panel holds them now, under its lock.
    mutating func panelOpened() {
        panelUp = true
        releaseAfterReading = false
    }

    /// The panel went away: access ends, and the lock locks if its setting says closing does.
    mutating func panelClosed() {
        epoch &+= 1
        panelUp = false
        lock.closed()
    }

    /// A read was stopped along with the numbers: nothing waits for its end.
    mutating func readStopped() { releaseAfterReading = false }

    /// Whether the answer to a proof asked for at `asked` (``epoch`` then) still opens anything.
    func stands(_ asked: Int) -> Bool { asked == epoch }

    /// Whether the numbers go now, once the lock has locked: not while a read is going on, which
    /// needs what it has read so far to seal it, and lets them go as it ends.
    mutating func releasesNow(reading: Bool, at now: Date) -> Bool {
        guard lock.settings.requiresAuthentication, !lock.isOpen(at: now) else { return false }
        guard !reading else {
            releaseAfterReading = true
            return false
        }
        return true
    }

    /// As a read ends, whether what it held is let go (once the lock says so): the Vault closed
    /// while it went on, or it was read while the panel showed only its lock, with `sealed`
    /// something behind it.
    mutating func releasesAfterRead(sealed: Bool, at now: Date) -> Bool {
        guard releaseAfterReading || (panelUp && sealed && lock.hidesEverything(at: now)) else { return false }
        releaseAfterReading = false
        return true
    }

    /// Whether a use of the panel at `time` counts: taken at most once a second, so a moving
    /// pointer does not redraw the panel.
    mutating func panelActivity(at time: Date) -> Bool {
        guard time.timeIntervalSince(lastPanelActivity) >= 1 else { return false }
        lastPanelActivity = time
        return true
    }
}
