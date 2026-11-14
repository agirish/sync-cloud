import Foundation

/// "204 files in 30 subfolders. Scan them?": what To File offers when the picked folder is an
/// inbox whose files sit in subfolders (a statement fetcher's `TODO/Finance/<Bank>/<Account>/<Year>`,
/// a Downloads full of unzipped folders). Today's scan reads only the folder's own files, so such a
/// folder looked empty.
public struct FilingSubfolderOffer: Equatable, Sendable {
    /// The picked folder, absolute.
    public let folder: String
    /// Files below its subfolders, and how many subfolders hold them.
    public let files: Int
    public let folders: Int
    /// The folder also has loose files of its own, so the offer is "also scan", not "scan".
    public let hasLooseFiles: Bool

    public init(folder: String, files: Int, folders: Int, hasLooseFiles: Bool) {
        self.folder = folder
        self.files = files
        self.folders = folders
        self.hasLooseFiles = hasLooseFiles
    }

    /// "204 files in 30 subfolders".
    public var summary: String {
        "\(files) file\(files == 1 ? "" : "s") in \(folders) subfolder\(folders == 1 ? "" : "s")"
    }
}

extension FileSyncManager {

    /// Folders the user chose to scan with their subfolders, newest first and bounded like the
    /// auto-rescan targets, so an automatic rescan of the same folder repeats the choice.
    public static let filingRecursiveFoldersKey = "tidyFilingRecursiveFolders"

    /// Whether a scan of `folder` reads its subfolders too.
    func filingScansSubfolders(_ folder: String) -> Bool {
        if filingRecursiveFolders.contains(folder) { return true }
        guard let defaults = persistedUIStateDefaults else { return false }
        return (defaults.array(forKey: Self.filingRecursiveFoldersKey) as? [String] ?? []).contains(folder)
    }

    /// Takes the offer: the next scan of its folder, and every automatic rescan of it, reads the
    /// subfolders. The caller starts that scan; this only records the choice.
    public func acceptFilingSubfolderOffer() {
        guard let offer = filingSubfolderOffer else { return }
        setFilingScansSubfolders(true, for: offer.folder)
        filingSubfolderOffer = nil
    }

    /// Back to the folder's own files only.
    public func setFilingScansSubfolders(_ on: Bool, for folder: String) {
        if on { filingRecursiveFolders.insert(folder) } else { filingRecursiveFolders.remove(folder) }
        guard let defaults = persistedUIStateDefaults else { return }
        var recent = (defaults.array(forKey: Self.filingRecursiveFoldersKey) as? [String] ?? []).filter { $0 != folder }
        if on { recent.insert(folder, at: 0) }
        defaults.set(Array(recent.prefix(Self.maxRememberedScanTargets)), forKey: Self.filingRecursiveFoldersKey)
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
        guard let profile, let root = profile.recordedFolderPath else { return true }
        if PathBoundary.contains(root, under: folder) { return false }
        guard FilingSurveyInUse.isAtOrInsideSurvey(folder, root) else { return true }
        guard let relative = relativePath(folder, under: root) else { return false }
        if FolderProfile.isInboxPath(relative) { return true }
        // A folder that refuses new files for its own reason (a closed account) is still filed
        // into, so only the inbox role counts.
        guard let entry = profile.folders[relative] else { return true }
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

    /// The offer for `folder`, or nil when there is nothing below it or it isn't eligible. Walks
    /// the folder's subtree within a budget; a subtree past it is counted as far as it was read,
    /// since the offer's figure is an estimate the scan itself then confirms.
    func subfolderOffer(for folder: URL, looseFiles: Int, fileInto: URL, options: FilingOptions,
                        fileManager: FileManaging) async -> FilingSubfolderOffer? {
        guard Self.subfolderOfferEligible(folder: folder.path, profile: filingFolderProfile,
                                          fileInto: fileInto.path),
              !filingDeclinedSubfolderFolders.contains(folder.path) else { return nil }
        // A count, so a small budget: every scan of an eligible folder pays it. A tree past it is
        // counted as far as it was read; the recursive scan itself goes through the preflight.
        let budget = NodeBudget(Self.subfolderOfferProbeBudget)
        let tree = await Self.buildTree(url: folder, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil, budget: budget)
        let counted = await Task.detached(priority: .userInitiated) { () -> (files: Int, folders: Int) in
            let subfolders = tree.filter { $0.isDirectory }
            let files = Self.filesBelow(subfolders, ignoring: options.ignoredNames, isPackage: Self.isPackageDirectory)
                .filter { Self.isFilable($0, options: options) }
            return (files.count, Set(files.map { ($0.id as NSString).deletingLastPathComponent }).count)
        }.value
        guard counted.files > 0 else { return nil }
        return FilingSubfolderOffer(folder: folder.path, files: counted.files, folders: counted.folders,
                                    hasLooseFiles: looseFiles > 0)
    }

    static let subfolderOfferProbeBudget = 20_000

    /// "Not Now" on the strip: no offer for this folder again this session.
    public func declineFilingSubfolderOffer() {
        guard let offer = filingSubfolderOffer else { return }
        filingDeclinedSubfolderFolders.insert(offer.folder)
        filingSubfolderOffer = nil
    }

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
    /// landed inside it (rules resolve there), else the absolute folder, which acts anywhere. Never
    /// relative to a wider walked root, which the next scan would resolve under File Into again.
    public func ruleDestination(forFiledFolder path: String, scannedRoot: String?) -> String {
        if let into = filingLastFileInto, let rel = Self.relative(path, toRoot: into) { return rel }
        if filingRoutedRoot == nil, let root = scannedRoot, let rel = Self.relative(path, toRoot: root) { return rel }
        return path
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
