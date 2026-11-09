import Foundation

/// Where a store's unreadable file is kept when it is moved out of the way of a fresh write.
///
/// Shared by `PersonTagStore`, `FilingVerdictStore`, `StorageLensStore`, `SettingsChangeLog` and
/// the app's saved Ask Claude chat, which each rescue a file this build can't read by renaming it before writing beside it. One
/// implementation, so the stores can't drift apart.
///
/// **A set-aside is never read back**, so it is the only copy of what it holds: paid answers for the
/// verdict cache, the user's own judgements for the person tags. So each episode gets its own name,
/// and nothing removes anything first. A fixed slot cleared before the move would let a second
/// episode destroy the first one's rescue, and a failed move would then leave nothing.
///
/// Nothing sweeps these files either, for the same reason. They stay bounded because an episode
/// clears itself: the rescue frees the path and the next launch writes a readable file. A foreign
/// schema would not clear (old and new builds would set each other's file aside on every launch),
/// so `StorageLensStore.Read` and `FilingVerdictStore.load` never route one here. Most live in
/// `~/Library/Application Support/SyncCloud/`, which no pane or scan lists; the cost is disk.
/// `SettingsChangeLog`'s lives beside its file in the home folder, as the old fixed-name one did.
public enum UnreadableSetAside {

    /// How many numbered candidates are probed before the disambiguator stops asking. The loop must
    /// end on what the probe answers, or a manager that never says "absent" spins forever. Reaching
    /// the bound means a hundred rescues of one file in one second, which no real sequence produces.
    private static let probeLimit = 100

    /// `<file>.unreadable-<stamp>`, unique per episode so a later episode can never land on, and
    /// destroy, an earlier one.
    ///
    /// The stamp is ``FilingArtifactStamp``'s, colons swapped for dots for a file name. Two
    /// episodes in one second get a numeric disambiguator, probed with `attributesOfItem` rather
    /// than `fileExists`, which follows symlinks and would call a dangling link free. The caller
    /// injects `now` so a test can pin the disambiguation.
    public static func destination(for fileURL: URL, at now: Date, fileManager: FileManager) -> URL {
        let stamp = FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: ".")
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent + ".unreadable-" + stamp
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            // Past the bound, take a name nothing can already hold. Still return a destination:
            // nil would make the caller refuse every write on a probe's word. If the name really is
            // occupied, `moveItem` fails and the caller refuses then.
            guard n <= probeLimit else {
                return dir.appendingPathComponent(base + "-" + UUID().uuidString)
            }
            candidate = dir.appendingPathComponent(base + "-\(n)")
            n += 1
        }
        return candidate
    }
}
