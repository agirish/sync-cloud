import Foundation
import Events
import Sync

/// **What the app knew about a volume while it was still mounted.**
///
/// It exists for one question, asked at the one moment it can no longer be answered: when
/// `NSWorkspace.didUnmountNotification` arrives, the volume is *gone*, so
/// `URL.resourceValues(forKeys:)` on its mount point returns nothing. The notification's `userInfo`
/// carries the path and the localized name and nothing else — not whether the thing that just
/// vanished was a memory card or a network share.
///
/// That distinction decides whether the sources on it are **gone or merely asleep**, which is the
/// whole of `isDetachable`. So the facts are recorded on the way in — at launch, on
/// `didMountNotification`, on `willUnmountNotification` while the volume is still there, and off
/// the sidebar's own mounted-volume walk — and read back on the way out.
///
/// **A volume this has never heard of is not assumed to be detachable.** The failure directions are
/// not symmetric: forgetting to remove a source leaves a dimmed row the user can remove by hand,
/// while removing one wrongly destroys a name override, a landing folder and an enabled flag that
/// nothing can hand back. Unknown therefore means "leave it alone", and the log says so rather than
/// staying silent about a decision that was made by absence.
@MainActor
public final class MountedVolumeMemory {

    public static let shared = MountedVolumeMemory()

    /// Keyed by the mount point, normalised the way `PathBoundary` spells a root so that a trailing
    /// slash or a `~` cannot make the same volume two entries.
    private var known: [String: Facts] = [:]

    /// The two things about a volume that survive it being unmounted.
    public struct Facts: Equatable, Sendable {
        /// Removable or ejectable — a card, a stick, an external disk, a mounted disk image.
        public let isRemovable: Bool
        /// **Local, as opposed to a network share.** This is the guard that earns the whole type.
        /// A share is `ejectable` too — Finder draws it an eject arrow — so a plain
        /// removable-or-ejectable test would treat a Wi-Fi drop as a card being pulled and delete
        /// the sources on it. A share that drops comes back; a card that is pulled does not.
        public let isLocal: Bool

        public init(isRemovable: Bool, isLocal: Bool) {
            self.isRemovable = isRemovable
            self.isLocal = isLocal
        }

        /// **Whether unmounting this volume means its sources are gone rather than asleep**, which
        /// is the one thing anything asks this type.
        public var isDetachable: Bool { isRemovable && isLocal }
    }

    public init() {}

    public func record(_ facts: Facts, forVolume path: String) {
        known[Self.key(path)] = facts
    }

    /// Records a whole walk at once — what the sidebar's `mountedVolumes()` already produces.
    public func record(_ volumes: [(path: String, facts: Facts)]) {
        for volume in volumes { record(volume.facts, forVolume: volume.path) }
    }

    public func facts(forVolume path: String) -> Facts? { known[Self.key(path)] }

    /// **Whether the sources on `path` should be forgotten now that it has unmounted.**
    ///
    /// Answers `false` for a volume never seen, and says so in the log — an absent record is a
    /// question this could not answer, not a verdict, and the two look identical afterwards.
    public func isDetachable(volume path: String) -> Bool {
        guard let facts = facts(forVolume: path) else {
            Logger.shared.info("Volume \(path) unmounted, but SyncCloud never saw it mounted — its sources are left in place")
            return false
        }
        return facts.isDetachable
    }

    /// Drops a volume's record. Called once the unmount has been acted on, so the map tracks what
    /// is mounted rather than growing for the life of the process.
    public func forget(volume path: String) {
        known.removeValue(forKey: Self.key(path))
    }

    /// How many volumes are remembered — for a test that would otherwise pass over an empty map.
    public var count: Int { known.count }

    /// The one spelling of a mount point, `FolderJumpStore.key(forRoot:)`'s rule, reached through
    /// the same shared member so the two cannot drift.
    static func key(_ path: String) -> String { PathBoundary.normalizedRoot(path) }
}
