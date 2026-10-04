import Foundation
import Sync
import Dashboard

/// **Files handed to SyncCloud from outside it** — Finder's double-click or Open With, a file dropped
/// on the Dock icon, `open -a SyncCloud notes.md` — and where they go: into Edit, through
/// `ContentView.handOffToEditor`, the hand-off every "Open in Edit" inside the app already takes.
/// So a file from Finder settles the open document first, takes the left pane to its folder by tab
/// (see ``pane(workspace:isReviewing:atLaunch:)`` for where it does not), and logs however it ends,
/// exactly as ⌘O does.
///
/// **What Finder offers SyncCloud for is every kind of text macOS recognises** — the claim in
/// `project.yml` is the parent type `public.text` — and that is what keeps an install from taking a
/// kind of file away from the app that opens it: a claim on the specific type always outranks a
/// claim on its parent (see the measurement written there). A file outside the claim can still
/// arrive — Open With ▸ Other…, `open -a` — and is tried rather than refused: the editor's own read
/// turns away what it cannot show (binary, too large) with its usual message, and a dotfile or a
/// `Makefile` someone deliberately asked for opens. A file still in the cloud is fetched and then
/// opened — see `ContentView.fetchExternalOpenFromCloud`.
///
/// **One file in Edit, the rest in the file pane.** The first file of a batch opens; the others
/// wait in the folder on screen, in a tab already showing theirs, or in a new tab per folder with
/// its files selected — on whichever source holds it (``waitingFolders(_:)``). A folder is named in a banner rather than dropped without a word. **A launch from
/// Finder opens Edit wide** ("Just the text"), the way someone who double-clicked a document
/// expects to see it.
enum ExternalOpen {

    /// What one batch of handed-over items comes to.
    struct Plan: Equatable {
        /// The file Edit opens — the first file, in the order macOS handed them over.
        var opens: String?
        /// Files after it. Edit holds one document, so these wait in the file pane instead — see
        /// ``run(_:superseded:isFolder:handOff:placeRest:paneIsFolded:banner:setBanner:log:)``.
        var alsoAsked: [String] = []
        /// Folders, which Edit cannot open at all.
        var folders: [String] = []
        /// Anything that is not a file URL. Nothing in Info.plist claims a URL scheme, so this
        /// should stay empty; it is kept so the log can say so if it ever is not.
        var ignored: [String] = []
    }

    /// Sorts what arrived. Pure apart from `isFolder`, which the caller answers from the disk.
    ///
    /// **A path named twice is one item.** Finder hands a file over once per open, so a double-click
    /// repeated during a launch arrives as the same path twice — and planning both put "“a.md”
    /// wasn’t opened" on screen over `a.md`.
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

    /// The disk's answer for ``plan(_:isFolder:)``: a directory — a package such as `.rtfd` or
    /// `.app` included, which Edit cannot open either — or a link to one.
    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What is holding an arrival back. Each only defers: the arrival stays queued and the window
    /// asks again when the hold clears.
    enum Hold: Equatable {
        /// The launch bootstrap is still putting the panes on their landing folders and restoring
        /// their tabs — a hand-off before it ends has its pane move undone. ~40 ms on an ordinary
        /// launch; see ``LaunchBootstrap``.
        case launch
        /// A Move to… / Copy to… question is on screen and owns the panes; a workspace switch under
        /// it would move the pane the answer is being picked in.
        case destinationPick
        /// The divergence diff is on screen: the user is part-way through answering which version
        /// of the open file wins. Opening another file under it left the diff drawn over a document
        /// it does not describe.
        case divergenceQuestion

        /// For the log line — names what the user has to finish, since that is what a report of
        /// "I double-clicked and nothing happened" needs to find.
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

    /// What the hand-off does to the left pane.
    ///
    /// **It stays put in Compare**, for the reason Compare's list of differences already passes
    /// `.staysPut`: there the left pane is half of the comparison on screen, and re-rooting it
    /// re-scopes the comparison, re-runs its scan and clears the session's "Ignore in comparison"
    /// entries. A file double-clicked in Finder is not a request to do any of that. A guided review
    /// counts as Compare whichever workspace is showing, because its scope is that comparison.
    ///
    /// **From Organize it follows only on the pane's own source**, as Organize's own doors do
    /// (``EditorHandOffRun/pane(forDoorIn:isReviewing:)``): its results belong to that source.
    ///
    /// **Except at launch**, when the workspace is only the one restored from last time and there is
    /// no comparison yet worth keeping: a launch from Finder always goes to the file's folder.
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

    /// **The sidebar's own rule, so a file from Finder lands where the sidebar would take you.**
    /// `SidebarSourceModel.owningSource` over the sidebar's claims (each source's root plus the
    /// folders it links in — iCloud Drive's Desktop and Documents), longest root first; then the
    /// path relativized against the owner's resolved root, through the link's name where it went
    /// through one. Exactly what `openFolderSidebarShortcutInsideItsOwner` computes for a click.
    ///
    /// **A source over the whole disk (`/`, "Macintosh HD") is the last resort, asked separately.**
    /// `SidebarSourceModel.contains` cannot see inside `/` — it tests for a `"//"` prefix — and the
    /// sidebar never needed it to, because its Macintosh HD row IS that source rather than a place
    /// inside one. Widening `contains` would change which sidebar rows read "in Macintosh HD"; this
    /// falls back to it only when no deeper source owns the folder.
    ///
    /// - Returns: `nil` when no configured source contains the folder — the file still opens, and
    ///   the pane stays where it is. A source is never added for it: that is a configuration change
    ///   the sidebar makes only on a click, with a notice and a way back.
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

    /// **The files after the first, by folder** — first-seen order, each folder once whatever its
    /// case. A folder waits in ONE tab with all of its files selected, so two notes from one folder
    /// are two selected rows, not one selected and one forgotten. **The opened file's own folder is
    /// a group like any other**: whether the pane went there is the live pane's answer, not this
    /// one's — it stays put in Compare, and a folder in no source has nowhere to go.
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

    /// One line on receipt, written by the delegate before anything else can happen to the files —
    /// so the log shows an open arrived even when the window then has to wait for it. Paths spelled
    /// as ``plan(_:isFolder:)`` spells them, so one search finds both lines.
    static func receiptLine(_ urls: [URL], atLaunch: Bool = false) -> String {
        "[open] Handed \(urls.count) item(s) from outside the app\(atLaunch ? ", launching SyncCloud" : ""): "
            + urls.map { $0.isFileURL ? $0.standardizedFileURL.path : $0.absoluteString }.joined(separator: ", ")
    }

    /// One line per batch the window acts on, naming where each item went. **Worded as a decision**
    /// — it is written before the hand-off, and the hand-off writes its own line for what then
    /// happened (opened, read-only, refused or cancelled).
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
    /// - Parameter unplaced: files that could not be put anywhere — their folder is in no source.
    ///   Every other file after the first is in the file pane: in the open folder, or in a tab of its
    ///   own.
    static func banner(for plan: Plan, unplaced: [String] = [], paneIsFolded: Bool = false) -> OperationBanner? {
        let placed = plan.alsoAsked.filter { !unplaced.contains($0) }
        // Edit wide — a launch from Finder, or Just the text — folds the pane to its strip, and a
        // banner pointing at a pane that is not on screen has to say where it went.
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
        return unplaced.isEmpty && plan.folders.isEmpty ? .success(text) : .warning(text)
    }

    /// **The act, for one batch, in its order** — plan, log, hand off, then the banner — as one
    /// function a test can run, for the reason `EditorHandOffRun` is one: `ContentView` cannot be
    /// built in a test, and the order is where this went wrong.
    ///
    /// **The banner comes last and yields.** Set before the hand-off, it said "“b.md” wasn’t
    /// opened" over a Cancel that had opened nothing either; set after it unconditionally, it
    /// replaced the hand-off's own "Couldn't save …" — the one message about the user's work. So it
    /// is skipped on a Cancel, and skipped when the hand-off put up a banner of its own.
    ///
    /// **The rest are placed only after the first is open** — and not at all after a Cancel, which
    /// has to mean nothing happened: no file, no tabs.
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

    /// Fetches a file that is still in the cloud, by reading one byte of it — the read that makes
    /// any File Provider (iCloud Drive, Dropbox, OneDrive, Google Drive) download it, where the
    /// download API covers iCloud alone. Returns whether the content is local afterwards.
    ///
    /// **Bounded, and off the main thread.** The read blocks until the provider delivers, and a
    /// provider that never answers must not keep the window waiting; after `timeout` this answers
    /// `false` and the read is left to finish on its own.
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
                answer.give(isCloudOnly(path) == false)
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

/// **Where the app delegate leaves what macOS handed over, until the window can act on it.**
///
/// The two are not alive at the same moments, which is why this exists: a cold launch from Finder
/// delivers the files before the launch bootstrap has put the panes anywhere. So the delegate
/// queues and the window takes, whenever it next may (``ExternalOpen/hold(launchIsFinished:isPickingDestination:isAnsweringDivergence:)``).
///
/// Owned by the delegate — the one object that outlives every window — and handed to `ContentView`
/// by the App, as the editor document is.
@MainActor
final class ExternalOpenQueue: ObservableObject {

    /// Bumped on every arrival — the value the window's `.onChange` watches, so that a second
    /// arrival of the very same file still registers as a change.
    @Published private(set) var arrivals = 0

    /// One entry per open, oldest first. Kept apart rather than flattened: a batch is one request.
    /// `atLaunch`: it arrived before the app finished launching — the app was launched to open it.
    private var batches: [(urls: [URL], atLaunch: Bool)] = []

    /// Set while the window is acting on a batch. The hand-off can stop on a modal question about
    /// the open document, and an arrival announced during it must wait for the answer rather than
    /// start a second hand-off — and a second question — underneath the first.
    var isOpening = false

    var isEmpty: Bool { batches.isEmpty }

    func receive(_ urls: [URL], atLaunch: Bool = false) {
        guard !urls.isEmpty else { return }
        batches.append((urls, atLaunch))
        arrivals &+= 1
    }

    /// The newest batch, and how many older ones it replaces; the queue is emptied.
    ///
    /// **The newest wins, because that is what an open the window could act on at once would have
    /// done.** Opened one after another, `a.md` then `b.md` leave `b.md` in Edit; queued behind a
    /// launch they used to leave `a.md` and a banner calling `b.md` unopened. Taking the newest gives
    /// the same end state either way, and asks at most one unsaved-changes question, not two.
    ///
    /// `atLaunch` is true when ANY of them arrived during launch: the newest can be a second
    /// double-click made while the first was still launching the app, and the launch is still the
    /// one the user is looking at.
    func takeNewest() -> (batch: [URL], superseded: Int, atLaunch: Bool)? {
        guard let newest = batches.last else { return nil }
        defer { batches.removeAll() }
        return (newest.urls, batches.count - 1, batches.contains { $0.atLaunch })
    }
}
