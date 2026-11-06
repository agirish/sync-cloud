import Events
import Foundation

/// One read of the folder tree, kept for the life of the setup sheet.
///
/// The sheet asks five questions of one tree: walking again per screen would make the user wait
/// each time, and could make the People and Countries chips disagree about a tree that moved in
/// between. So there is one ``FileSyncManager/walkForSetup(root:known:)``, and every screen after
/// it is a pure function of its result. The cost is a few thousand `FileNode`s held while the sheet
/// is open, about what a pane holds on screen.
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
    /// Names of the files sitting directly in the root, sorted: the ones with no folder yet, which
    /// the Structure screen offers to route.
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

    /// Counts, loose names, candidates and the document count, from a tree already in hand. Pure,
    /// so it can be tested on a fixture tree. `recordedRoot` is the root as the profile records it,
    /// so the place proposal's evidence reads in the profile's terms.
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
    /// Fails before touching the disk when there is nowhere to write a profile, as
    /// ``deriveFolderProfile(root:jurisdictionValues:registry:now:)`` does, so the user learns it
    /// here rather than at the end of the sheet.
    ///
    /// - Parameter known: names already on the roster, so somebody added is not offered back.
    public func walkForSetup(root: URL, known: Set<String> = []) async -> Result<SetupWalk, FolderWalkFailure> {
        guard filingProfilesDirectory != nil else {
            return .failure(.noProfilesDirectory)
        }

        // Checked before the walk: `buildTree` on a missing path returns one node, which nothing
        // downstream can tell from a real one-folder tree.
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

        // Off the main actor: pure over the tree, but a few thousand folders' worth of work.
        let walk = await Task.detached(priority: .userInitiated) {
            SetupWalk.summarising(tree: tree, root: root, recordedRoot: recordedRoot, known: known)
        }.value

        // `deriveFolderProfile`'s bar, applied early: a tree with no folders can't produce a
        // profile, and saying so at the Learn screen lets the user pick another folder before Save.
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
