import Events
import Foundation

/// "Scan TODO’s subfolders too?": what To File asks before a scan reads anything, when the picked
/// folder is a place files wait in (an inbox, Downloads) and its subfolders hold files too. A
/// statement fetcher's `TODO/Finance/<Bank>/<Account>/<Year>` keeps hundreds of files below one
/// loose one, and a scan of the loose one alone filled the list with it.
public struct FilingSubfolderQuestion: Hashable, Sendable {
    /// The picked folder, absolute.
    public let folder: String
    /// Files sitting directly in the folder, counted as the scan would offer them.
    public let looseFiles: Int
    /// Files below its subfolders, and how many subfolders hold them.
    public let files: Int
    public let folders: Int
    /// The count walk stopped at its cap, so `files` and `folders` are floors.
    public let atLeast: Bool
    /// The folders every subfolder file sits under (`["Finance"]`), and the largest folders one
    /// level below them by file count (`["Charles Schwab", "Chase", "Bank of America"]`), with how
    /// many more there are.
    public let commonPath: [String]
    public let largestGroups: [String]
    public let otherGroups: Int

    public init(folder: String, looseFiles: Int, files: Int, folders: Int, atLeast: Bool = false,
                commonPath: [String] = [], largestGroups: [String] = [], otherGroups: Int = 0) {
        self.folder = folder
        self.looseFiles = looseFiles
        self.files = files
        self.folders = folders
        self.atLeast = atLeast
        self.commonPath = commonPath
        self.largestGroups = largestGroups
        self.otherGroups = otherGroups
    }

    public var folderName: String { (folder as NSString).lastPathComponent }
    /// Every file a Scan All reads.
    public var total: Int { looseFiles + files }

    /// How many folders the question names below ``commonPath``.
    static let namedGroups = 3

    /// The common path and the largest groups for `parents`, each a file's folder relative to the
    /// picked folder (`Finance/Chase/Checking 1234/2026`), one entry per file.
    static func groups(_ parents: [String]) -> (common: [String], largest: [String], others: Int) {
        let split = parents.map { $0.split(separator: "/").map(String.init) }
        guard var common = split.first else { return ([], [], 0) }
        for parts in split.dropFirst() {
            common = Array(zip(common, parts).prefix { $0.0 == $0.1 }.map(\.0))
        }
        // Grouped one level below the common path; a file sitting in the common folder itself
        // counts toward the totals but names no group.
        var counts: [String: Int] = [:]
        for parts in split where parts.count > common.count { counts[parts[common.count], default: 0] += 1 }
        let ranked = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        return (common, Array(ranked.prefix(namedGroups)), max(0, ranked.count - namedGroups))
    }
}

/// How a scan treats the subfolder question.
public enum FilingSubfolderAsking: Sendable {
    /// A scan the user started (a folder pick, Rescan, Scan Again): asks every time.
    case always
    /// An automatic rescan (lens open, a changed File Into): keeps the scope already chosen for the
    /// folder this session, and asks only when none was, as after a launch.
    case unlessChosen
    /// The CLI and tests: never asks, and reads subfolders only as chosen or as the preference says.
    case never
}

extension FileSyncManager {

    /// "Always scan subfolders": every scan of a folder the question is for reads its subfolders,
    /// with no question. Set from the question's checkbox, the Rescan menu or Settings ▸ Organize ▸
    /// To File. In the settings store, like Filing's other switches.
    public static let alwaysScanSubfoldersDefaultsKey = "tidyFilingAlwaysScanSubfolders"

    public var filingAlwaysScansSubfolders: Bool {
        filingContentDefaults.bool(forKey: Self.alwaysScanSubfoldersDefaultsKey)
    }

    public func setFilingAlwaysScansSubfolders(_ on: Bool) {
        guard on != filingAlwaysScansSubfolders else { return }
        objectWillChange.send()
        filingContentDefaults.set(on, forKey: Self.alwaysScanSubfoldersDefaultsKey)
        // A change of mind about every folder retires the per-folder picks from Rescan ▾.
        filingPinnedSubfolderScopes = [:]
        Logger.shared.info("Filing: always scan subfolders turned \(on ? "on" : "off")")
    }

    /// Whether a scan of `folder` reads its subfolders: the preference, or the answer chosen for it
    /// this session. Never remembered past a launch (the per-folder `tidyFilingRecursiveFolders`
    /// list that did is no longer read): a new scan asks again.
    func filingScansSubfolders(_ folder: String) -> Bool {
        if let pinned = filingPinnedSubfolderScopes[folder] { return pinned }
        return filingAlwaysScansSubfolders || filingChosenSubfolderScopes[folder] == true
    }

    /// Records the scope chosen for `folder` this session, which automatic rescans keep.
    func setFilingScansSubfolders(_ on: Bool, for folder: String) {
        filingChosenSubfolderScopes[folder] = on
        filingPinnedSubfolderScopes[folder] = nil
    }

    /// Rescan ▾'s scope: the scanned folder's subfolders too, or its own files only, for this
    /// session. The rescan that follows doesn't ask, and "only" holds even with Always Scan
    /// Subfolders on (``filingScansSubfolders(_:)``).
    public func chooseFilingSubfolderScope(readsSubfolders: Bool) {
        guard let folder = filingScanFolder else { return }
        filingChosenSubfolderScopes[folder] = readsSubfolders
        filingPinnedSubfolderScopes[folder] = readsSubfolders
    }

    /// Scan All: reads the subfolders, and with `always` stops asking from now on.
    public func scanAllForFilingSubfolderQuestion(always: Bool) {
        guard let question = filingSubfolderQuestion else { return }
        if always { setFilingAlwaysScansSubfolders(true) }
        answerFilingSubfolderQuestion(question, readsSubfolders: true)
    }

    /// "Only the 1 in TODO": the folder's own files, this scan and its automatic rescans.
    public func scanFolderOnlyForFilingSubfolderQuestion() {
        guard let question = filingSubfolderQuestion else { return }
        answerFilingSubfolderQuestion(question, readsSubfolders: false)
    }

    /// Not Now, offered when the folder holds no loose files of its own: no scan.
    public func dismissFilingSubfolderQuestion() {
        guard let question = filingSubfolderQuestion else { return }
        Logger.shared.info("Filing: \(question.folderName) not scanned — the subfolder question was set aside")
        filingSubfolderQuestion = nil
        filingPendingScan = nil
    }

    private func answerFilingSubfolderQuestion(_ question: FilingSubfolderQuestion, readsSubfolders: Bool) {
        Logger.shared.info("Filing: \(question.folderName) — scanning "
            + (readsSubfolders ? "its subfolders too" : "its own files only"))
        setFilingScansSubfolders(readsSubfolders, for: question.folder)
        filingSubfolderQuestion = nil
        let scan = filingPendingScan
        filingPendingScan = nil
        scan?()
    }

    /// Whether a scan of `folder`, started as `asking` says, must ask first: the question, or nil
    /// to scan straight away. Records the scope when it settles one.
    func filingSubfolderQuestionBeforeScan(folder: URL, providerRoot: URL, asking: FilingSubfolderAsking,
                                           options: FilingOptions) async -> FilingSubfolderQuestion? {
        // A scope picked from Rescan ▾ is the answer already.
        guard asking != .never, filingPinnedSubfolderScopes[folder.path] == nil,
              !filingAlwaysScansSubfolders else { return nil }
        let fileInto = filingRouting(forFileInto: providerRoot).fileInto
        guard Self.subfolderOfferEligible(folder: folder.path, profile: filingFolderProfile,
                                          fileInto: fileInto.path) else { return nil }
        if asking == .unlessChosen, filingChosenSubfolderScopes[folder.path] != nil { return nil }
        let question = await subfolderQuestion(for: folder, options: options, fileManager: fileManager)
        // Nothing below: the folder's own files are all there is, so no question and no scope.
        if question == nil { filingChosenSubfolderScopes[folder.path] = false }
        return question
    }

    /// Whether subfolders of `folder` may be offered for scanning. Only for a place files wait in,
    /// never for a folder already filed into: scanning an account folder's subtree would offer its
    /// filed statements new homes. That is an inbox (the profile's role, its intake refusal, or the
    /// inbox name test), a folder outside the survey, or one the survey never saw.
    nonisolated static func subfolderOfferEligible(folder: String, profile: FolderProfile?,
                                                   fileInto: String? = nil) -> Bool {
        // Never a folder that holds the filed tree: picking `~` or the provider root would make
        // every filed document a loose file.
        if let fileInto, PathBoundary.contains(fileInto, under: folder) { return false }
        // With nothing to say otherwise, only a folder named as a place files wait (`TODO`,
        // `Inbox`, Downloads): `~/Documents/Taxes` holds filed documents, not loose ones.
        let waits = FolderProfile.isInboxPath(relativePath(folder, under: NSHomeDirectory()) ?? (folder as NSString).lastPathComponent)
            || (folder as NSString).lastPathComponent == "Downloads"
        guard let profile, let root = profile.recordedFolderPath else { return waits }
        if PathBoundary.contains(root, under: folder) { return false }
        guard FilingSurveyInUse.isAtOrInside(folder, root) else { return true }
        guard let relative = relativePath(folder, under: root) else { return false }
        if FolderProfile.isInboxPath(relative) { return true }
        // A folder that refuses new files for its own reason (a closed account) is still filed
        // into, so only the inbox role counts. One the survey never saw (an account folder made
        // since) only by its name.
        guard let entry = profile.folders[relative] else { return waits }
        return entry.role == .inbox
    }

    /// The files below `nodes`' subfolders, skipping packages (an app or a Photos library is one
    /// item, never a pile of files to file), symbolic links (a link can pull filed documents in),
    /// hidden entries (`.git`, `._*`, `.DS_Store`) and the names the scan ignores.
    nonisolated static func filesBelow(_ nodes: [FileNode], ignoring ignored: Set<String>,
                                       isPackage: (String) -> Bool) -> [FileNode] {
        var out: [FileNode] = []
        for n in nodes where !ignored.contains(n.name) && !n.name.hasPrefix(".") && n.isSymbolicLink != true {
            if n.isDirectory {
                if n.isPackage || isPackage(n.id) { continue }
                out.append(contentsOf: filesBelow(n.children ?? [], ignoring: ignored, isPackage: isPackage))
            } else {
                out.append(n)
            }
        }
        return out
    }

    /// A loose file the scan will actually offer a home for: not hidden, not ignored, not too small.
    nonisolated static func isFilable(_ n: FileNode, options: FilingOptions) -> Bool {
        !n.isDirectory && !n.name.hasPrefix(".") && !options.ignoredNames.contains(n.name)
            && (n.fileSize ?? 0) >= options.minFileSize
    }

    nonisolated static func isPackageDirectory(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// The question for `folder`, or nil when nothing below it is filable. Walks the subtree within
    /// a budget, so a huge Downloads costs a bounded walk before the scan; past it, the counts are
    /// floors and the question says "at least". The recursive scan then goes through the large-walk
    /// preflight as before.
    func subfolderQuestion(for folder: URL, options: FilingOptions, fileManager: FileManaging,
                           probeBudget: Int = subfolderOfferProbeBudget) async -> FilingSubfolderQuestion? {
        let budget = NodeBudget(probeBudget)
        let tree = await Self.buildTree(url: folder, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil, budget: budget)
        let atLeast = budget.didStopADescent
        let root = folder.path
        return await Task.detached(priority: .userInitiated) { () -> FilingSubfolderQuestion? in
            let loose = tree.filter { Self.isFilable($0, options: options) }.count
            let files = Self.filesBelow(tree.filter { $0.isDirectory }, ignoring: options.ignoredNames,
                                        isPackage: Self.isPackageDirectory)
                .filter { Self.isFilable($0, options: options) }
            guard !files.isEmpty else { return nil }
            let parents = files.map { Self.relativePath(($0.id as NSString).deletingLastPathComponent, under: root) ?? "" }
            let groups = FilingSubfolderQuestion.groups(parents)
            return FilingSubfolderQuestion(folder: root, looseFiles: loose, files: files.count,
                                           folders: Set(parents).count, atLeast: atLeast,
                                           commonPath: groups.common, largestGroups: groups.largest,
                                           otherGroups: groups.others)
        }.value
    }

    static let subfolderOfferProbeBudget = 20_000

    /// The folders between the scanned folder and a file found below it: `Finance/Schwab/IRA 7863/2026`
    /// for `TODO/Finance/Schwab/IRA 7863/2026/01. Jan 2026.pdf`. Empty for a file sitting directly
    /// in the scanned folder. A hint that adds weight, never a mapping.
    public nonisolated static func sourceHint(forFile path: String, scannedFolder: String?) -> String {
        guard let scannedFolder else { return "" }
        let parent = (path as NSString).deletingLastPathComponent
        return relativePath(parent, under: scannedFolder) ?? ""
    }

    // MARK: File Into as a preference

    /// The tree a scan filing into `fileInto` walks and ranks against: the primary survey's root
    /// when `fileInto` lies inside it, so the survey (keyed from that root) applies; otherwise
    /// `fileInto` itself. A profile that records no root keeps today's behaviour.
    func filingRoutingRoot(forFileInto fileInto: URL) -> URL { filingRouting(forFileInto: fileInto).root }

    /// The tree a scan filing into `fileInto` walks, and File Into spelled the way that tree is
    /// (`~/Documents/…` for a File Into reached through iCloud Drive's `Documents` link), so every
    /// later comparison between the two is a plain string one. Re-roots only when the survey's tree
    /// is small enough to walk without the large-walk question; past that, File Into is walked alone,
    /// as before.
    func filingRouting(forFileInto fileInto: URL) -> (root: URL, fileInto: URL) {
        guard let profile = filingFolderProfile, let root = profile.recordedFolderPath,
              let relative = Self.relative(fileInto.path, toRoot: root) else { return (fileInto, fileInto) }
        let respelled = URL(fileURLWithPath: relative.isEmpty ? root : root + "/" + relative)
        if relative.isEmpty { return (respelled, respelled) }
        let entries = profile.folders.count + profile.folders.values.reduce(0) { $0 + $1.fileCount }
        guard entries < wholeTreeProbeBudget else { return (fileInto, fileInto) }
        return (URL(fileURLWithPath: root), respelled)
    }

    /// The destination a rule offered after a filing names: relative to File Into when the file
    /// landed inside it, where rules resolve. nil for a folder outside it: rules act only inside
    /// File Into (`AutomationEvaluator.absoluteDestination`), so a rule saved there would never fire.
    public func ruleDestination(forFiledFolder path: String, scannedRoot: String?) -> String? {
        if let into = filingLastFileInto, let rel = Self.relative(path, toRoot: into) { return rel }
        if filingRoutedRoot == nil, let root = scannedRoot, let rel = Self.relative(path, toRoot: root) { return rel }
        return nil
    }

    /// The verdict cache's artifacts digest, with the walked root folded in when it isn't File
    /// Into, so entries recorded under the narrower root (paths relative to it) never resolve against
    /// the wider one. Unchanged for an ordinary scan, so its cached answers, paid ones included, stay.
    func filingVerdictArtifacts(_ artifacts: String) -> String {
        filingRoutedRoot.map { artifacts + "|root=" + $0 } ?? artifacts
    }

    /// File Into relative to the walked root, when the last scan walked a wider tree: the subtree
    /// whose folders lead a re-ask's ranking as they led the scan's.
    var filingPreferredSubtree: String? {
        guard let routed = filingRoutedRoot, let into = filingLastFileInto else { return nil }
        return Self.relativePath(into, under: routed)
    }

    /// The children of the folder at `path` in `nodes`, or nothing when it isn't there.
    nonisolated static func children(at path: String, in nodes: [FileNode]) -> [FileNode] {
        for n in nodes where n.isDirectory {
            if n.id == path { return n.children ?? [] }
            if path.hasPrefix(n.id + "/") { return children(at: path, in: n.children ?? []) }
        }
        return []
    }

    /// The capped folder list with `subtree`'s folders first, shallowest first, as many as the cap
    /// holds.
    nonisolated static func preferringSubtree(_ subtree: String, in capped: [String], all: Set<String>) -> [String] {
        let inside = all.filter { isAtOrUnder($0, subtree) }
            .sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        let cap = max(capped.count, 1)
        let chosen = Array(inside.prefix(cap))
        let rest = capped.filter { !isAtOrUnder($0, subtree) }
        return Array((chosen + rest).prefix(cap))
    }

    /// `nodes` without the folder at `path` and everything below it.
    nonisolated static func pruning(_ path: String, from nodes: [FileNode]) -> [FileNode] {
        nodes.compactMap { node -> FileNode? in
            if node.id == path { return nil }
            guard node.isDirectory, let children = node.children,
                  path.hasPrefix(node.id + "/") else { return node }
            var copy = node
            copy.children = pruning(path, from: children)
            return copy
        }
    }
}
