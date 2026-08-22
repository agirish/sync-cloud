import Foundation

/// Where a store's unreadable file is kept when it is moved out of the way of a fresh write.
///
/// **One implementation, three stores.** `PersonTagStore`, `FilingVerdictStore` and
/// `StorageLensStore` each rescue an on-disk file this build cannot read by renaming it before
/// writing beside it. All three had their own spelling of the destination, and two of them still
/// carried the defects the third had already fixed: one fixed slot (`<name>.unreadable`) cleared by
/// an unconditional `removeItem` before the move. That shape loses data twice over —
///
/// - **a second episode destroys the first episode's rescue.** A set-aside is never read back into
///   the store, so it is the ONLY copy of what it holds; for the verdict cache that is paid
///   answers, and for the person tags it is the user's own judgements.
/// - **a move that then fails leaves nothing.** The remove has already run, so the earlier rescue
///   is gone AND the current file is still exposed — strictly worse than not attempting the
///   rescue at all.
///
/// A per-episode name removes both: no candidate is ever occupied by something worth keeping, so
/// there is no collision to handle and no remove to justify.
///
/// A copied pattern that drifts is a documented hazard in this repo, which is why this lives here
/// rather than in whichever store fixed it first.
enum UnreadableSetAside {

    /// `<file>.unreadable-<stamp>`, a name unique per episode so a later episode can never land
    /// on — and destroy — an earlier one.
    ///
    /// The stamp is ``FilingArtifactStamp``'s (the format every filing artifact dates itself
    /// with), colons swapped for dots because this one lives in a file NAME. Second precision
    /// means two episodes in one second would collide, so an occupied candidate gets a numeric
    /// disambiguator instead — probed with `attributesOfItem` rather than `fileExists`, which
    /// follows symlinks and would call a dangling-link occupant free. The caller injects the
    /// instant rather than this reading a clock, so a test can pin the disambiguation.
    static func destination(for fileURL: URL, at now: Date, fileManager: FileManager) -> URL {
        let stamp = FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: ".")
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent + ".unreadable-" + stamp
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = dir.appendingPathComponent(base + "-\(n)")
            n += 1
        }
        return candidate
    }
}
