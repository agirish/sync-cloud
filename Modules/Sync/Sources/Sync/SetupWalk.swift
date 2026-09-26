import Events
import Foundation

/// One read of the folder tree, kept for the life of the setup sheet.
///
/// **This reverses a choice the deleted `proposePlaces`/`proposePeople` pair recorded.** Three
/// walks of the same tree were the cheaper mistake while each one sat behind a separate button: a
/// tree held across a user decision can go stale while they think. A guided sheet asks five
/// questions off one tree, and walking again per screen would mean the user waits four more times
/// for an answer the first walk already had — and could see the People chips and the Countries
/// chips disagree, because each list came from its own read of a tree that moved between them.
/// So: one ``FileSyncManager/walkForSetup(root:known:)``, and every screen after it is a pure
/// function of what it returned.
///
/// The cost is a few thousand `FileNode`s held for the couple of minutes the sheet is open, which
/// is the same tree a pane holds while it is on screen.
public struct SetupWalk: Sendable {
    /// The folder that was read.
    public let root: URL
    /// The root's children, in the shape ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)``
    /// wants — not a root node.
    public let tree: [FileNode]
    /// Folders below the root that the survey would give an entry to.
    public let folderCount: Int
    /// Files anywhere below the root that the survey would count.
    public let fileCount: Int
    /// Names of the files sitting directly in the root, sorted.
    ///
    /// Depth 0 only: these are the ones with no folder of their own yet, which is what the Structure
    /// screen offers to route.
    public let looseFileNames: [String]
    /// Household names the tree suggests, minus the ones already on the roster.
    public let people: [PersonCandidate]
    /// Place names the tree suggests, unconfirmed.
    public let places: [JurisdictionCandidate]
    /// How many documents a full document survey would have to read.
    public let documentCount: Int

    public init(root: URL, tree: [FileNode], folderCount: Int, fileCount: Int,
                looseFileNames: [String], people: [PersonCandidate],
                places: [JurisdictionCandidate], documentCount: Int) {
        self.root = root
        self.tree = tree
        self.folderCount = folderCount
        self.fileCount = fileCount
        self.looseFileNames = looseFileNames
        self.people = people
        self.places = places
        self.documentCount = documentCount
    }

    /// Counts, loose names, candidates and the document count, from a tree already in hand.
    ///
    /// Pure, and separate from the walk so the setup sheet's arithmetic can be tested against a
    /// fixture tree without a filesystem. `recordedRoot` is what the profile would record — the
    /// jurisdiction proposal takes it so its evidence reads in the same terms the profile will.
    public static func summarising(tree: [FileNode], root: URL, recordedRoot: String,
                                   known: Set<String>) -> SetupWalk {
        var folders = 0
        var files = 0
        func count(_ children: [FileNode]) {
            let (theseFiles, theseFolders) = FolderSurveyBuilder.partition(children)
            files += theseFiles.count
            for folder in theseFolders where FolderSurveyBuilder.isSurveyedFolder(folder) {
                folders += 1
                count(folder.children ?? [])
            }
        }
        count(tree)

        let loose = FolderSurveyBuilder.partition(tree).files
        let flattened = FilingSurvey.flatten(tree)
        return SetupWalk(
            root: root,
            tree: tree,
            folderCount: folders,
            fileCount: files,
            looseFileNames: loose,
            people: PersonCandidates.propose(tree: tree, known: known),
            places: JurisdictionCandidates.propose(tree: tree, root: recordedRoot),
            documentCount: FilingSurvey.documentsToRead(tree: flattened, corpus: nil).count)
    }
}

extension FileSyncManager {

    /// Reads `root` once and returns everything the setup sheet asks of it.
    ///
    /// Fails before touching the disk when there is nowhere to write a profile, the same first
    /// guard ``deriveFolderProfile(root:jurisdictionValues:registry:now:)`` makes — so the user
    /// learns that on the screen that offered to read, rather than at the end of the sheet with
    /// four screens of answers behind them.
    ///
    /// - Parameter known: names already on the roster, so somebody added is not offered back.
    public func walkForSetup(root: URL, known: Set<String> = []) async -> Result<SetupWalk, FolderWalkFailure> {
        guard filingProfilesDirectory != nil else {
            return .failure(.noProfilesDirectory)
        }

        // Asked of the filesystem before the walk, for the reason `deriveFolderProfile` gives:
        // `buildTree` on a path that is not there returns one node and nothing downstream can tell
        // that from a real one-folder tree.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
            Logger.shared.warning("Setup walk refused: \(root.path) is not a readable folder")
            return .failure(.rootUnreadable(root.path))
        }

        Logger.shared.info("Setup walk starting at \(root.path) — roster \(known.count) name(s)")
        let tree = await Self.buildTree(url: root, sortOption: .name)
        let recordedRoot = Self.recordedRoot(for: root)

        // Off the main actor: everything below is pure over the tree, and it is a few thousand
        // folders' worth of proposing and counting.
        let walk = await Task.detached(priority: .userInitiated) {
            SetupWalk.summarising(tree: tree, root: root, recordedRoot: recordedRoot, known: known)
        }.value

        // The same bar `deriveFolderProfile` applies at the end, applied here instead: a tree with
        // no folders below its root cannot produce a profile worth writing, and saying so at the
        // Learn screen is the difference between choosing another folder and finding out at Save.
        guard walk.folderCount > 0 else {
            Logger.shared.warning("Setup walk refused: \(root.path) is readable but holds no folders")
            return .failure(.nothingToLearn(root.path))
        }

        Logger.shared.info("Setup walk read \(walk.folderCount) folder(s), \(walk.fileCount) file(s), "
                           + "\(walk.people.count) household candidate(s), "
                           + "\(walk.places.count) place candidate(s), "
                           + "\(walk.documentCount) document(s) to read")
        return .success(walk)
    }
}
