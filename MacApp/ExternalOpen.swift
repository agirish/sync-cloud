import Foundation
import Sync
import Dashboard

/// Files handed to SyncCloud from outside it (Finder's double-click or Open With, a drop on the
/// Dock icon, `open -a SyncCloud notes.md`) and where they go: into Edit, through
/// `ContentView.handOffToEditor`, the hand-off every in-app "Open in Edit" takes. So it settles the
/// open document, takes the left pane to the file's folder by tab (except as
/// ``pane(workspace:isReviewing:atLaunch:)`` says), and logs however it ends, as ⌘O does.
///
/// `project.yml` claims the parent type `public.text`, so an install never takes a kind of file
/// from the app that claims its specific type (see the note there). A file outside the claim (Open
/// With ▸ Other…, `open -a`) is tried, not refused: the editor's read turns away what it can't
/// show. A file still in the cloud is fetched first (`ContentView.fetchExternalOpenFromCloud`).
///
/// The first file of a batch opens in Edit; the rest wait in the file pane, by folder and selected
/// (``waitingFolders(_:)``). A folder is named in a banner, not dropped silently. A launch from
/// Finder opens Edit wide ("Just the text"), as a double-clicked document should.
enum ExternalOpen {

    /// What one batch of handed-over items comes to.
    struct Plan: Equatable {
        /// The file Edit opens: the first file, in the order macOS handed them over.
        var opens: String?
        /// Files after it. Edit holds one document, so these wait in the file pane instead; see
        /// ``run(_:superseded:isFolder:handOff:placeRest:paneIsFolded:banner:setBanner:log:)``.
        var alsoAsked: [String] = []
        /// Folders, which Edit cannot open at all.
        var folders: [String] = []
        /// Anything that is not a file URL. Nothing in Info.plist claims a URL scheme, so this
        /// should stay empty; it is kept so the log can say so if it ever is not.
        var ignored: [String] = []
    }

    /// Sorts what arrived. Pure apart from `isFolder`, which the caller answers from the disk. A
    /// path named twice is one item: a double-click repeated during a launch arrives twice, and
    /// planning both would report the open file as not opened.
    static func plan(_ urls: [URL], isFolder: (String) -> Bool) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for url in urls {
            guard url.isFileURL else { plan.ignored.append(url.absoluteString); continue }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if isFolder(path) {
                plan.folders.append(path)
            } else if plan.opens == nil {
                plan.opens = path
            } else {
                plan.alsoAsked.append(path)
            }
        }
        return plan
    }

    /// The disk's answer for ``plan(_:isFolder:)``: a directory (including a package such as
    /// `.rtfd` or `.app`, which Edit can't open either) or a link to one.
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What is holding an arrival back. Each only defers: the arrival stays queued and the window
    /// asks again when the hold clears.
    enum Hold: Equatable {
        /// The launch bootstrap is still putting the panes on their landing folders and restoring
        /// their tabs, and would undo a hand-off's pane move. About 40 ms on an ordinary launch;
        /// see ``LaunchBootstrap``.
        case launch
        /// A Move to… / Copy to… question is on screen and owns the panes; a workspace switch under
        /// it would move the pane the answer is being picked in.
        case destinationPick
        /// The divergence diff is on screen, mid-answer about which version of the open file wins.
        /// Opening another file would leave the diff over a document it doesn't describe.
        case divergenceQuestion

        /// For the log line: names what the user has to finish, which is what "I double-clicked
        /// and nothing happened" needs to find.
        var reason: String {
            switch self {
            case .launch: return "waiting for launch to finish"
            case .destinationPick: return "waiting for the destination question to be answered"
            case .divergenceQuestion: return "waiting for the question about the open file's two versions to be answered"
            }
        }
    }

    /// The first thing holding an arrival back, or `nil` when the window may act on it now.
    static func hold(launchIsFinished: Bool, isPickingDestination: Bool,
                     isAnsweringDivergence: Bool) -> Hold? {
        if !launchIsFinished { return .launch }
        if isAnsweringDivergence { return .divergenceQuestion }
        if isPickingDestination { return .destinationPick }
        return nil
    }

    /// What the hand-off does to the left pane. It stays put in Compare, where the left pane is half
    /// the comparison and re-rooting it would re-run the scan and clear the session's ignores; a
    /// guided review counts as Compare in any workspace. From Organize it follows only on the
    /// pane's own source (``EditorHandOffRun/pane(forDoorIn:isReviewing:)``). At launch there is no
    /// comparison worth keeping yet, so it always goes to the file's folder.
    static func pane(workspace: Workspace, isReviewing: Bool, atLaunch: Bool) -> EditorHandOffRun.Pane {
        if atLaunch { return .followsTheFile }
        if workspace == .compare || isReviewing { return .staysPut }
        return EditorHandOffRun.pane(forDoorIn: workspace, isReviewing: false)
    }

    /// Where a folder lives among the configured sources: which one owns it, and the path inside it.
    struct SourceRoute: Equatable {
        var providerId: String
        var relativePath: String
    }

    /// The sidebar's own rule, so a file from Finder lands where the sidebar would take you:
    /// `SidebarSourceModel.owningSource` over the sidebar's claims (each root plus its linked
    /// folders, such as iCloud Drive's Desktop and Documents), longest root first, then the path
    /// relativized against the owner's resolved root, as `openFolderSidebarShortcutInsideItsOwner`
    /// does for a click.
    ///
    /// A whole-disk source (`/`, "Macintosh HD") is a separate last resort:
    /// `SidebarSourceModel.contains` can't see inside `/` (it tests for a `"//"` prefix), and
    /// widening it would change which sidebar rows read "in Macintosh HD".
    ///
    /// - Returns: `nil` when no configured source contains the folder; the file still opens and the
    ///   pane stays. A source is never added for it: the sidebar does that only on a click, with a
    ///   notice and a way back.
    static func route(toFolder folder: String,
                      claims: [(id: String, name: String, path: String)],
                      roots: [String: String],
                      resolve: (String) -> String) -> SourceRoute? {
        let wholeDisk = claims.first { resolve($0.path) == "/" }.map { (id: $0.id, name: $0.name) }
        guard let owner = SidebarSourceModel.owningSource(of: folder, among: claims, resolve: resolve) ?? wholeDisk,
              let root = roots[owner.id],
              let relative = PathBoundary.relativize(resolve(folder), under: resolve(root)) else { return nil }
        return SourceRoute(providerId: owner.id, relativePath: relative)
    }

    /// The files after the first, by folder: first-seen order, each folder once whatever its case.
    /// A folder waits in one tab with all its files selected. The opened file's own folder is a
    /// group like any other, since whether the pane went there is the live pane's answer.
    static func waitingFolders(_ files: [String]) -> [(folder: String, files: [String])] {
        var groups: [(folder: String, files: [String])] = []
        var index: [String: Int] = [:]
        for file in files {
            let folder = (file as NSString).deletingLastPathComponent
            let key = folder.lowercased()
            if let at = index[key] {
                groups[at].files.append(file)
            } else {
                index[key] = groups.count
                groups.append((folder, [file]))
            }
        }
        return groups
    }

    /// The lines on receipt, written by the delegate first, so the log shows an open arrived even
    /// when the window has to wait. Paths are spelled as ``plan(_:isFolder:)`` spells them, so one
    /// search finds both lines. Every path, sorted, split by ``LogNames`` (at most 200 or 16 KB a
    /// line), so a drop of thousands is several readable lines and never loses a name. `note`
    /// follows the count, before the paths.
    static func receiptLines(_ urls: [URL], atLaunch: Bool = false, droppedOnEdit: Bool = false,
                             note: String = "") -> [String] {
        let how = droppedOnEdit ? "Dropped \(urls.count) item(s) on Edit's empty page"
            : "Handed \(urls.count) item(s) from outside the app"
        return LogNames.lines("[open] \(how)\(atLaunch ? ", launching SyncCloud" : "")\(note)",
                              urls.map { $0.isFileURL ? $0.standardizedFileURL.path : $0.absoluteString })
    }

    /// One line per batch the window acts on, naming where each item went. Worded as a decision,
    /// since it comes before the hand-off, which logs what then happened.
    static func logLine(for plan: Plan, superseded: Int = 0) -> String {
        var parts: [String] = []
        if let opens = plan.opens { parts.append("handing \(opens) to Edit") }
        if !plan.alsoAsked.isEmpty {
            parts.append("\(plan.alsoAsked.count) more file(s) to the file pane, Edit holds one: "
                         + plan.alsoAsked.joined(separator: ", "))
        }
        if !plan.folders.isEmpty {
            parts.append("not opening \(plan.folders.count) folder(s): "
                         + plan.folders.joined(separator: ", "))
        }
        if !plan.ignored.isEmpty {
            parts.append("ignoring \(plan.ignored.count) non-file URL(s): "
                         + plan.ignored.joined(separator: ", "))
        }
        if superseded > 0 {
            parts.append("\(superseded) earlier open(s) made while the window waited were replaced by this one")
        }
        return "[open] From outside the app — "
            + (parts.isEmpty ? "nothing to open" : parts.joined(separator: "; "))
    }

    /// What the window says about everything after the first file, or `nil` when there was nothing
    /// after it. Names a single item and counts several, the way the app's other banners do.
    ///
    /// - Parameter unplaced: files that couldn't be put anywhere because their folder is in no
    ///   source. Every other file after the first is in the file pane.
    static func banner(for plan: Plan, unplaced: [String] = [], paneIsFolded: Bool = false) -> OperationBanner? {
        let placed = plan.alsoAsked.filter { !unplaced.contains($0) }
        // Edit wide (a launch from Finder, or Just the text) folds the pane to its strip, so the
        // banner says where the pane went.
        let pane = paneIsFolded ? "the file pane, folded to the strip at the left edge" : "the file pane"
        var sentences: [String] = []
        switch placed.count {
        case 0: break
        case 1: sentences.append("“\(name(placed[0]))” is waiting in \(pane) — Edit holds one file at a time.")
        case let n: sentences.append("The other \(n) files are waiting in \(pane) — Edit holds one file at a time.")
        }
        switch unplaced.count {
        case 0: break
        case 1: sentences.append("“\(name(unplaced[0]))” wasn’t opened — no source SyncCloud has contains it.")
        case let n: sentences.append("\(n) files weren’t opened — no source SyncCloud has contains them.")
        }
        switch plan.folders.count {
        case 0: break
        case 1: sentences.append("“\(name(plan.folders[0]))” is a folder, and Edit opens files.")
        case let n: sentences.append("\(n) folders weren’t opened — Edit opens files.")
        }
        guard !sentences.isEmpty else { return nil }
        let text = sentences.joined(separator: " ")
        return unplaced.isEmpty && plan.folders.isEmpty ? .success(text) : .warning(text, log: .warn)
    }

    /// The act for one batch, in order (plan, log, hand off, banner), as one function a test can
    /// run.
    ///
    /// The banner comes last and yields: skipped on a Cancel, and when the hand-off posted its own
    /// (such as "Couldn't save …", which must not be covered). The rest are placed only after the
    /// first is open, and not after a Cancel, which must mean nothing happened.
    ///
    /// - Parameters:
    ///   - placeRest: puts the files after the first in the file pane, against the pane as the
    ///     hand-off left it; returns the ones it could not place.
    ///   - paneIsFolded: whether the file pane will be folded to its strip — see ``banner(for:unplaced:paneIsFolded:)``.
    /// - Returns: what was planned, what the hand-off did (`nil` when there was no file), and the
    ///   files that could not be placed.
    @MainActor
    @discardableResult
    static func run(_ batch: [URL], superseded: Int = 0,
                    isFolder: (String) -> Bool,
                    handOff: (String) -> EditorHandOffRun.Outcome,
                    placeRest: (_ rest: [String]) -> [String] = { $0 },
                    paneIsFolded: Bool = false,
                    banner currentBanner: () -> OperationBanner?,
                    setBanner: (OperationBanner) -> Void,
                    log: (String) -> Void) -> (plan: Plan, outcome: EditorHandOffRun.Outcome?, unplaced: [String]) {
        let plan = plan(batch, isFolder: isFolder)
        log(logLine(for: plan, superseded: superseded))
        let before = currentBanner()?.id
        let outcome = plan.opens.map(handOff)
        var unplaced = plan.alsoAsked
        if plan.opens != nil, outcome != .cancelled, !plan.alsoAsked.isEmpty {
            unplaced = placeRest(plan.alsoAsked)
        }
        if outcome != .cancelled, currentBanner()?.id == before,
           let note = banner(for: plan, unplaced: unplaced, paneIsFolded: paneIsFolded) {
            setBanner(note)
        }
        return (plan, outcome, unplaced)
    }

    /// Fetches a file still in the cloud by reading one byte of it, which makes any File Provider
    /// download it. The download API works for iCloud and Google Drive but isn't known to for
    /// Dropbox or OneDrive; this read works everywhere. Returns whether the content is local after.
    ///
    /// Bounded and off the main thread: the read blocks until the provider delivers, so after
    /// `timeout` this answers `false` and leaves the read to finish on its own.
    nonisolated static func fetch(
        _ path: String, timeout: Duration = .seconds(60),
        read: @escaping @Sendable (String) -> Void = { path in
            _ = FileHandle(forReadingAtPath: path)?.readData(ofLength: 1)
        },
        isCloudOnly: @escaping @Sendable (String) -> Bool? = { path in
            MaterializationStatus.isCloudOnlyIfKnown(atPath: path)
        }
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let answer = AnswerOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                read(path)
                // Ask about the file a link points to, which the read fetched: the link itself is
                // never in the cloud, so it would always answer "landed".
                answer.give(isCloudOnly(MaterializationStatus.linkTarget(of: path)) == false)
            }
            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { answer.give(false) }
        }
    }

    /// Resumes a continuation with whichever answer comes first, and ignores the other.
    private final class AnswerOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func give(_ value: Bool) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Where the app delegate leaves what macOS handed over until the window can act on it: a cold
/// launch delivers files before the bootstrap has put the panes anywhere. The delegate queues; the
/// window takes when it may (``ExternalOpen/hold(launchIsFinished:isPickingDestination:isAnsweringDivergence:)``).
/// Owned by the delegate, which outlives every window, and handed to `ContentView` by the App.
@MainActor
final class ExternalOpenQueue: ObservableObject {

    /// Bumped on every arrival: the value the window's `.onChange` watches, so a second arrival of
    /// the same file still registers as a change.
    @Published private(set) var arrivals = 0

    /// One entry per open, oldest first. Kept apart rather than flattened: a batch is one request.
    /// `atLaunch`: it arrived before the app finished launching, so the app was launched to open it.
    private var batches: [(urls: [URL], atLaunch: Bool)] = []

    /// Set while the window is acting on a batch. The hand-off can stop on a modal question, and an
    /// arrival meanwhile must wait rather than start a second hand-off and question underneath it.
    var isOpening = false

    var isEmpty: Bool { batches.isEmpty }

    func receive(_ urls: [URL], atLaunch: Bool = false) {
        guard !urls.isEmpty else { return }
        batches.append((urls, atLaunch))
        arrivals &+= 1
    }

    /// The newest batch, and how many older ones it replaces; the queue is emptied.
    ///
    /// The newest wins, as if each had been acted on at once: `a.md` then `b.md` leave `b.md` in
    /// Edit, and at most one unsaved-changes question is asked. `atLaunch` is true when any arrived
    /// during launch, since the newest may be a second double-click made while the app launched.
    func takeNewest() -> (batch: [URL], superseded: Int, atLaunch: Bool)? {
        guard let newest = batches.last else { return nil }
        defer { batches.removeAll() }
        return (newest.urls, batches.count - 1, batches.contains { $0.atLaunch })
    }
}
