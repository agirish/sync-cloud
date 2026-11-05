import Foundation
import Events
import Sync

/// What the app knew about a volume while it was still mounted.
///
/// When `NSWorkspace.didUnmountNotification` arrives the volume is gone, so `resourceValues` on its
/// mount point returns nothing, and `userInfo` carries only the path and name. Whether the sources
/// on it are gone or merely asleep (`isDetachable`) has to come from facts recorded earlier: at
/// launch, on mount, on `willUnmountNotification`, and from the sidebar's mounted-volume walk.
///
/// A volume never seen is not assumed detachable. Keeping a source wrongly leaves a dimmed row the
/// user can remove; removing one wrongly destroys its name override, landing folder and enabled
/// flag for good. So unknown means "leave it alone", and the log says so.
@MainActor
public final class MountedVolumeMemory {

    public static let shared = MountedVolumeMemory()

    /// Keyed by the mount point, normalised like `PathBoundary` spells a root, so a trailing slash
    /// or `~` can't make one volume two entries.
    private var known: [String: Facts] = [:]

    /// The two things about a volume that survive it being unmounted.
    public struct Facts: Equatable, Sendable {
    /// Removable or ejectable: a card, a stick, an external disk, a mounted disk image.
        public let isRemovable: Bool
    /// Local, as opposed to a network share. A share is ejectable too, so without this a Wi-Fi drop
    /// would read as a card being pulled and delete its sources. A share that drops comes back.
        public let isLocal: Bool

        public init(isRemovable: Bool, isLocal: Bool) {
            self.isRemovable = isRemovable
            self.isLocal = isLocal
        }

    /// Whether unmounting this volume means its sources are gone rather than asleep.
        public var isDetachable: Bool { isRemovable && isLocal }
    }

    public init() {}

    public func record(_ facts: Facts, forVolume path: String) {
        known[Self.key(path)] = facts
    }

    /// Records a whole walk at once, as the sidebar's `mountedVolumes()` produces it.
    public func record(_ volumes: [(path: String, facts: Facts)]) {
        for volume in volumes { record(volume.facts, forVolume: volume.path) }
    }

    public func facts(forVolume path: String) -> Facts? { known[Self.key(path)] }

    /// Whether the sources on `path` should be forgotten now that it has unmounted. `false` for a
    /// volume never seen, logged, since an absent record is no verdict.
    public func isDetachable(volume path: String) -> Bool {
        guard let facts = facts(forVolume: path) else {
            Logger.shared.info("Volume \(path) unmounted, but SyncCloud never saw it mounted — its sources are left in place")
            return false
        }
        return facts.isDetachable
    }

    /// Drops a volume's record once the unmount has been acted on, so the map tracks what is
    /// mounted rather than growing for the life of the process.
    public func forget(volume path: String) {
        known.removeValue(forKey: Self.key(path))
    }

    /// How many volumes are remembered, so a test can't pass over an empty map.
    public var count: Int { known.count }

    /// The one spelling of a mount point, shared with `FolderJumpStore.key(forRoot:)` so the two
    /// can't drift.
    static func key(_ path: String) -> String { PathBoundary.normalizedRoot(path) }
}
