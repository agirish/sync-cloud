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
/// **What it costs, said here because nothing else says it.** These files accumulate and nothing
/// sweeps them — deliberately, since a set-aside is never re-ingested and is therefore the only
/// copy of what it holds, so a sweeper would be a deleter of paid answers and the user's own
/// judgements. What makes that bounded in practice is that a genuine episode is self-clearing: the
/// rescue frees the path, the next launch writes a fresh readable file, and there is no second
/// episode until something goes wrong again. The one condition that did NOT self-clear was a file
/// written under a schema this build does not know — the steady state of an old/new build
/// ping-pong, which minted another dated file on every launch (measured: five rounds, five
/// set-asides; ~12 MB apiece for the verdict cache). That is why `StorageLensStore.Read` and
/// `FilingVerdictStore.load` now treat a foreign schema as its own case and never route it here.
/// They live in `~/Library/Application Support/SyncCloud/`, which nothing in the app enumerates,
/// so they cannot surface in a pane or a scan; the cost is disk, and the remedy is the user's.
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
    /// How many numbered candidates are probed before the disambiguator stops asking.
    ///
    /// **The loop has to terminate on what the probe answers, not on what a filesystem would.**
    /// It asked `attributesOfItem` for candidate after candidate until one came back absent, and a
    /// manager that never says absent is an infinite loop — measured: a test double answering
    /// "present" for every path spun the test host at 100% CPU for ten minutes before it was
    /// killed. Real filesystems terminate it; nothing in the loop did.
    ///
    /// The bound is generous because reaching it at all means a hundred rescues of one file inside
    /// one second, which no real sequence of episodes produces.
    private static let probeLimit = 100

    static func destination(for fileURL: URL, at now: Date, fileManager: FileManager) -> URL {
        let stamp = FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: ".")
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent + ".unreadable-" + stamp
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            // Past the bound, stop asking and take a name nothing can already be holding. A
            // destination is still RETURNED rather than the rescue being abandoned: a nil here
            // makes the caller refuse its write, and refusing every write on the strength of a
            // stat that keeps answering "yes" is the worse of the two failures. If the name really
            // is occupied the `moveItem` fails, and the caller refuses then — on the move's
            // evidence rather than the probe's.
            guard n <= probeLimit else {
                return dir.appendingPathComponent(base + "-" + UUID().uuidString)
            }
            candidate = dir.appendingPathComponent(base + "-\(n)")
            n += 1
        }
        return candidate
    }
}
