import Events
import Foundation

/// Deriving a folder profile from a walk — the half of the filing artifacts the app could produce
/// but had no way to *run*.
///
/// ``FolderSurveyBuilder`` has been able to derive a profile since `d4280231`, and
/// ``FilingProfileStore/writeProfile(_:in:builtBy:now:)`` has been able to write one; what was
/// missing between them was anything that walked a tree and put the two together. Without it,
/// `resurveyFilingMemory` opens by requiring a `profileId` that only a profile carries, so a machine
/// that never ran the out-of-repo script got no routing, no rename proposals and no Restructure
/// findings — and nothing on screen said why.
///
/// **This is the walk, and only the walk.** It reads folder and file *names* and opens no document:
/// seconds on a 3,000-folder tree, against the hours the document survey needs. That split is
/// deliberate — a lens that can answer in seconds should not wait forty minutes for a corpus it does
/// not read.
extension FileSyncManager {

    /// What a walk produced, in the terms the user is shown.
    public struct FolderWalkReport: Sendable, Equatable {
        /// Folders the profile now describes.
        public let foldersProfiled: Int
        /// The id the profile was written under. Always fresh — a profile is never overwritten.
        public let profileId: String
        /// The tree it describes, as the profile records it.
        public let root: String
        /// Whether `profiles.json` now names this profile.
        ///
        /// **False is not failure, and it is the case worth reporting.** The store refuses to
        /// re-point away from a hand-built profile, so on a machine that has one the walk succeeds,
        /// the profile lands on disk, and nothing reads it. Saying so is the difference between
        /// "done" and "done, and it changed nothing you will notice".
        public let becameActive: Bool
        /// The jurisdiction values the profile was built with, as confirmed by the user.
        public let jurisdictions: [String]

        public var summary: String {
            let folders = "\(foldersProfiled.formatted()) folder\(foldersProfiled == 1 ? "" : "s")"
            guard becameActive else {
                return "Learned \(folders), but this Mac already has a folder profile it did not "
                    + "write, so that one is still in use."
            }
            return "Learned \(folders) in \(root)."
        }
    }

    /// Why a walk could not run at all.
    public enum FolderWalkFailure: Error, Equatable, CustomStringConvertible {
        /// No directory to write artifacts into — the app hands that in, and `Sync` never invents
        /// a home directory of its own.
        case noProfilesDirectory
        /// The root could not be read at all — missing, not a directory, or unlistable.
        case rootUnreadable(String)
        /// The root is readable and holds no folders to learn.
        ///
        /// **Its own case, because an empty profile is worse than no profile.** It decodes
        /// perfectly and reads as a surveyed tree everywhere downstream, so every routing question
        /// gets a confident "no destination" — and the user is told their tree was learned.
        case nothingToLearn(String)
        /// The store refused. Carries its own reason.
        case refused(String)

        public var description: String {
            switch self {
            case .noProfilesDirectory:
                return "no profiles directory was configured"
            case .rootUnreadable(let path):
                return "\(path) could not be read"
            case .nothingToLearn(let path):
                return "\(path) has no folders to learn from"
            case .refused(let why):
                return "the profile could not be written — \(why)"
            }
        }
    }

    /// Walks `root` and writes a folder profile describing it.
    ///
    /// - Parameters:
    ///   - root: the folder to learn. **A folder, not a source**: what the store records is a tree,
    ///     and on this machine the hand-built profile's is `~/Documents` rather than the whole of
    ///     iCloud Drive. Surveying a source root would pull in Desktop, Downloads and everything
    ///     else beside it.
    ///   - jurisdictionValues: the place names the user confirmed. Handed in rather than mined,
    ///     because the mining is only 83.2% right and every point of the gap is an invention —
    ///     `HPE`, `IT` and `PRD` are an employer, a department and a product stage. See
    ///     ``JurisdictionCandidates``.
    ///   - registry: the household, for the person axis and the `person-bucket` role. Nil is fine
    ///     and means both are simply absent; no folder is misattributed for want of a roster.
    ///
    /// Returns the report, or the reason it could not run. **Never throws for "there was already a
    /// profile"** — that is a successful walk whose result is not in use, and the report says so.
    public func deriveFolderProfile(root: URL,
                                    jurisdictionValues: Set<String> = [],
                                    registry: PersonRegistry? = nil,
                                    now: Date = Date()) async -> Result<FolderWalkReport, FolderWalkFailure> {
        guard let directory = filingProfilesDirectory else {
            return .failure(.noProfilesDirectory)
        }

        Logger.shared.info("Folder walk starting at \(root.path) — "
                           + "\(jurisdictionValues.count) confirmed place(s), "
                           + "roster \(registry?.people.count ?? 0) person(s)")

        // **Asked of the filesystem before the walk, not inferred from the walk's output.**
        // `buildTree` on a path that does not exist returns a tree of ONE node — the root itself —
        // so `tree.isEmpty` never fires for the case it was written for, and the walk cheerfully
        // recorded a one-folder profile of a directory that is not there. Same shape as
        // `enumerator(at:)` handing back a non-nil enumerator that yields nothing for an unlistable
        // directory, which made a `guard let` a dead branch one file over.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
            Logger.shared.warning("Folder walk refused: \(root.path) is not a readable folder")
            return .failure(.rootUnreadable(root.path))
        }

        // The same walk the panes do. Names and counts only — no document is opened.
        let tree = await Self.buildTree(url: root, sortOption: .name)

        let recordedRoot = Self.recordedRoot(for: root)
        let profileId = Self.walkProfileId(now: now)

        // **Hoisted off the main actor.** `FileSyncManager` is `@MainActor`, and
        // `FolderSurveyBuilder.build` is a pure function of its arguments — no `FileManager`, no
        // `Date()`, no defaults — precisely so it can run detached over a few thousand folders
        // without the window going unresponsive.
        let profile = await Task.detached(priority: .userInitiated) {
            FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: profileId,
                                      registry: registry, jurisdictionValues: jurisdictionValues)
        }.value

        // **`isEmpty` is never true, which is why this counts something else.** The builder always
        // emits an entry for the root itself under `"."`, so a walk of a folder with nothing in it
        // produces a profile of exactly one folder — and a guard on `folders.isEmpty` is a branch
        // that cannot be taken. What "nothing to learn" means is nothing *below* the root.
        guard profile.folders.keys.contains(where: { $0 != FolderSurveyBuilder.rootEntryPath }) else {
            Logger.shared.warning("Folder walk refused: \(root.path) is readable but holds no "
                                  + "folders, and an empty profile would read as a surveyed tree")
            return .failure(.nothingToLearn(root.path))
        }

        do {
            _ = try FilingProfileStore.writeProfile(profile, in: directory, now: now)
        } catch {
            Logger.shared.warning("Folder walk could not write its profile: \(error)")
            return .failure(.refused(String(describing: error)))
        }

        let becameActive = FilingProfileStore.activeProfileId(in: directory) == profileId
        let report = FolderWalkReport(foldersProfiled: profile.folders.count,
                                      profileId: profileId,
                                      root: recordedRoot,
                                      becameActive: becameActive,
                                      jurisdictions: jurisdictionValues.sorted())
        if becameActive {
            Logger.shared.info("Folder walk wrote profile '\(profileId)' — "
                               + "\(profile.folders.count) folder(s) from \(recordedRoot), and it "
                               + "is now the active profile")
        } else {
            // The one outcome that looks like success and is not useful, said plainly. The store
            // refuses to re-point away from a profile it did not write.
            Logger.shared.warning("Folder walk wrote profile '\(profileId)' with "
                                  + "\(profile.folders.count) folder(s), but this Mac's active "
                                  + "profile was not written by SyncCloud, so it was left in place "
                                  + "and the new one is not in use")
        }
        return .success(report)
    }

    /// Walks `root` and proposes the folder names that might be places, with their evidence.
    ///
    /// **A separate call from the derivation, and it walks again rather than holding the tree.** The
    /// proposals have to be *confirmed* before a profile is built — used as-is the rule agrees with
    /// the hand-built profile on 83.2% of folders, and every point of that gap is an invention
    /// (`HPE` is an employer, `IT` a department, `PRD` a product stage) — so the user sees the list
    /// between the two calls. A walk is seconds and a 3,000-folder tree held across a user decision
    /// is state that can go stale while they think; walking twice is the cheaper mistake.
    public func proposePlaces(root: URL) async -> [JurisdictionCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let tree = await Self.buildTree(url: root, sortOption: .name)
        let recordedRoot = Self.recordedRoot(for: root)
        let proposals = await Task.detached(priority: .userInitiated) {
            JurisdictionCandidates.propose(tree: tree, root: recordedRoot)
        }.value
        Logger.shared.info("Folder walk: \(proposals.count) place candidate(s) in \(root.path) — "
                           + "\(proposals.map(\.value).joined(separator: ", "))")
        return proposals
    }

    /// How the profile records the tree it describes.
    ///
    /// Folded to `~` when it is under the home directory, because that is how every hand-built
    /// profile on this machine spells it (`root: "~/Documents"`) and the field is compared against
    /// them. Nothing parses it — ``FolderSurveyBuilder`` never touches the root on disk — so this is
    /// about the file being readable by a person, and diffable against the offline builder's.
    static func recordedRoot(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A fresh id for each walk.
    ///
    /// **Always fresh, never reused.** A profile is written under its own id and `profiles.json` is
    /// re-pointed; nothing is ever overwritten in place, so the profile that was in use before a
    /// walk is still on disk afterwards and can be pointed back at by hand.
    static func walkProfileId(now: Date) -> String {
        "walk-" + FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
