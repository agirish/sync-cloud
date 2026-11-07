import Events
import Foundation

/// One document survey, from a work list to a set of read documents: pausable, resumable, and
/// never writing a partial corpus.
///
/// **It turns a plan into tokens; it doesn't merge, rebuild or write a memory.** The memory's bytes
/// are hashed into ``FilingProfileStore/fingerprint(id:in:)``, so it is written once at the end; a
/// mid-survey write would move the fingerprint and discard every cached cloud verdict. That keeps
/// this type drivable from injected closures, with no `FileSyncManager`, main actor or disk beyond
/// its checkpoint.
///
/// **One document at a time, on purpose.** Every PDFKit parse takes ``PDFKitSerialAccess``'s single
/// lane, so extra workers only queue, and concurrent PDFKit can return different text for the same
/// document, giving tokens that differ between runs. And Pause must land between documents; a
/// batch in flight would carry on regardless.
///
/// Pause is not cancel: resuming costs nothing, cancelling costs everything read. Waiting for the
/// duplicate scan, a hot Mac, a sleeping display or the user's Pause all suspend; only an explicit
/// stop or task cancellation ends the run.
public actor DocumentSurveyRun {

    // MARK: - What the caller supplies

    /// Everything this run reaches outside itself. All closures, so the whole state machine is
    /// testable without a `FileSyncManager`, a display, a thermal sensor or a PDF.
    public struct Environment: Sendable {
        /// Page-1 text for an absolute path, or nil when there was nothing to read. The app hands
        /// over `ContentSignalExtractor.snippet(forFileAt:)`, which takes the PDFKit lane itself.
        public var readDocument: @Sendable (String) async -> String?
        /// Whether a path's content is actually on this disk. Asked before the read and again
        /// after a blank one, because a provider can evict a file in between and a blank stamp is
        /// permanent (`readOne(at:)`).
        public var isAvailable: @Sendable (String) -> Bool
        /// Downloads a document that isn't on this disk, returning once it is there or gives up;
        /// nil never fetches, as for the primary survey's tree. Set only for a source's own survey,
        /// where the person asked for cloud-only documents to be downloaded. Availability is asked
        /// again after, so a download that never lands counts as unavailable, not blank.
        public var fetch: (@Sendable (String) async -> Void)?
        /// Why the run should not be reading right now, or nil to carry on. **Must stay async**:
        /// the answer comes from `@MainActor` state, and a synchronous version would need
        /// `MainActor.assumeIsolated`, which traps from this actor instead of hopping.
        public var shouldPause: @Sendable () async -> DocumentSurveyPause?
        /// Awaited between polls while paused. The app sleeps; a test clears its own signal here
        /// rather than racing a clock ("Tests racing a real-time window", `docs/flaky-tests.md`).
        public var whilePaused: @Sendable () async -> Void
        /// Injected rather than read from a clock, for the same reason. Drives the ETA basis.
        public var now: @Sendable () -> Date
        /// Where progress goes. Called only for reports ``ProgressPublishGate`` admits, plus every
        /// phase change, so a run publishes about a hundred times, not once per document.
        public var publish: @Sendable (DocumentSurveyProgress) -> Void

        public init(readDocument: @escaping @Sendable (String) async -> String?,
                    isAvailable: @escaping @Sendable (String) -> Bool = { _ in true },
                    fetch: (@Sendable (String) async -> Void)? = nil,
                    shouldPause: @escaping @Sendable () async -> DocumentSurveyPause? = { nil },
                    whilePaused: @escaping @Sendable () async -> Void = {},
                    now: @escaping @Sendable () -> Date = { Date() },
                    publish: @escaping @Sendable (DocumentSurveyProgress) -> Void = { _ in }) {
            self.readDocument = readDocument
            self.isAvailable = isAvailable
            self.fetch = fetch
            self.shouldPause = shouldPause
            self.whilePaused = whilePaused
            self.now = now
            self.publish = publish
        }
    }

    // MARK: - What it produces

    /// What a run did, in the terms the completion summary reports.
    ///
    /// Every count is of documents this run decided, and they sum to the plan, so a summary can't
    /// read as complete when it wasn't (as ``FileSyncManager/FilingSurveyReport/summary`` reports).
    public struct Report: Sendable, Equatable {
        /// Tokens for every document that was opened and yielded something, plus the blank stamps.
        /// Keyed by path relative to the root, ready to hand to ``FilingSurvey/merge(corpus:tree:read:)``.
        public let read: [String: FilingCorpusDocument]
        /// Documents opened and stamped — including the blanks, which are a real outcome.
        public let documentsRead: Int
        /// Of those, the ones that yielded nothing usable and are stamped blank so they are never
        /// opened again.
        public let documentsBlank: Int
        /// Not downloaded, so nothing was learned and nothing was stamped. A later survey does them.
        public let documentsUnavailable: Int
        /// Where the run stopped, or nil when it reached the end of the plan.
        public let stoppedAt: Int?
        /// True when every document in the plan was decided.
        public var isComplete: Bool { stoppedAt == nil }
    }

    /// Why a run refused to start. Each one is a state where running would waste hours or destroy
    /// something, and none of them is an error the user caused.
    public enum Refusal: Sendable, Equatable {
        /// A checkpoint exists but describes a different profile, root or salt. Discarded rather
        /// than merged — see ``DocumentSurveyCheckpoint/resumes(profileId:rootPath:salt:)``.
        case checkpointIsForAnotherRun
        /// A checkpoint is on disk and could not be read. **Not the same as absent**: starting over
        /// would re-read hours of documents that a fixed permission bit would have resumed.
        case checkpointUnreadable
    }

    // MARK: - State

    private let profileId: String
    /// Internal so a stop made for a new profile can say which folder to carry on reading.
    let root: URL
    private let salt: String
    private let plan: [String]
    private let stamps: [String: FilingSurvey.Stamp]
    private let environment: Environment
    private let checkpointEvery: Int
    private let directory: URL?

    private var read: [String: FilingCorpusDocument]
    private var nextIndex: Int
    private var unavailable = 0
    private var startedAt: Date
    /// Seconds spent reading, pauses excluded: the ETA's basis. Accumulated per document, which is
    /// what lets pauses be excluded.
    private var readingSeconds: TimeInterval = 0
    /// The pause reason last published, so a reason that changes mid-pause republishes and a steady
    /// one doesn't. Otherwise the card could keep naming a cause that has already cleared.
    private var lastPublishedPause: DocumentSurveyPause?
    private var userPaused = false
    private var stopRequested = false
    private var gate = ProgressPublishGate()

    /// How often progress reaches disk, in documents. A count, not a timer, like
    /// ``ProgressPublishGate``'s percent: a clock is something for a test to race
    /// (`docs/flaky-tests.md`).
    public static let defaultCheckpointEvery = 25

    // MARK: - Starting

    /// A fresh run over `plan`, or one resumed from a checkpoint on disk.
    ///
    /// `directory` is where the checkpoint lives; nil for a run that keeps nothing (a test, a
    /// preview), which then has no resume and no refusal. `stamps` comes from the walk that made the
    /// plan, so sizes and mtimes match it and nothing is stat'ed twice.
    public init(profileId: String, root: URL, salt: String, plan: [String],
                stamps: [String: FilingSurvey.Stamp], environment: Environment,
                directory: URL? = nil,
                checkpointEvery: Int = DocumentSurveyRun.defaultCheckpointEvery) {
        self.profileId = profileId
        self.root = root
        self.salt = salt
        self.plan = plan
        self.stamps = stamps
        self.environment = environment
        self.directory = directory
        self.checkpointEvery = max(1, checkpointEvery)
        self.read = [:]
        self.nextIndex = 0
        self.startedAt = environment.now()
    }

    /// Adopts a checkpoint from disk, or says why it will not.
    ///
    /// Called before `run()`. A resumable checkpoint is offered, never started: the offer card
    /// promises "nothing starts it but a click". This only establishes that there is something to
    /// offer. Returns nil when there was nothing to adopt and nothing wrong.
    @discardableResult
    public func adoptCheckpoint() -> Refusal? {
        guard let directory else { return nil }
        switch DocumentSurveyCheckpointStore.read(id: profileId, in: directory) {
        case .absent:
            return nil
        case .unreadable:
            return .checkpointUnreadable
        case .loaded(let checkpoint):
            guard checkpoint.resumes(profileId: profileId, rootPath: root.path, salt: salt) else {
                return .checkpointIsForAnotherRun
            }
            read = checkpoint.read
            // **The index means something only against the plan it was counted in.** Between
            // sittings the tree changes, and an old index into a new plan would skip documents yet
            // report the run complete. The read documents are always kept, so a changed plan
            // restarts the index and relies on `run()` skipping what was already read.
            if checkpoint.plan == plan {
                // Clamped through `progress`: the file can be hand-edited, and an index past the
                // end must not crash the resume.
                nextIndex = checkpoint.progress.done
            } else {
                Logger.shared.info("Document survey: the tree changed since this survey was "
                                   + "interrupted (\(checkpoint.plan.count) documents then, "
                                   + "\(plan.count) now). Keeping what was read and walking the "
                                   + "new list, skipping anything already done.")
                nextIndex = 0
            }
            startedAt = checkpoint.startedAt
            // Carried, so a resumed survey's summary still counts the first sitting's unavailable
            // documents.
            unavailable = checkpoint.documentsUnavailable
            return nil
        }
    }

    /// What a resumed run would have left to do, for the card that offers it.
    public var resumableProgress: (done: Int, total: Int) { (nextIndex, plan.count) }

    // MARK: - Driving it from outside

    public func pause() {
        userPaused = true
    }

    /// Undoes ``pause()`` and nothing else: a reason the machine supplied is the environment's to
    /// clear, or *Resume now*'s to waive (``DocumentSurveyOverride``).
    public func resume() {
        userPaused = false
    }

    /// Whether the person's own Pause is holding the run — the pause a plain Resume undoes.
    public var isPausedByUser: Bool { userPaused }

    /// Ends the run at the next document boundary, keeping the checkpoint.
    ///
    /// Stop is not cancel, and neither is destructive: the checkpoint stays, so the next launch
    /// offers a Resume rather than taking one.
    public func stop() {
        stopRequested = true
    }

    /// ``stop()``, answering whether the person's own Pause was holding the run. One call, not
    /// ``isPausedByUser`` then ``stop()``: between two hops a run that had not read yet could
    /// resume from its pause check and read a document before the stop landed.
    public func stopReportingUserPause() -> Bool {
        stopRequested = true
        return userPaused
    }

    /// Takes back a ``stop()`` the run has not yet reached — for a profile write that gave up
    /// waiting for it. A stop already acted on stays acted on.
    public func withdrawStop() {
        stopRequested = false
    }

    // MARK: - The loop

    /// Reads the plan, from wherever the run currently stands.
    public func run() async -> Report {
        environment.publish(progressNow(phase: .reading))

        while nextIndex < plan.count {
            if Task.isCancelled { break }
            if stopRequested { break }

            // Pause is polled at the document boundary, the only place it can land: a read in
            // flight finishes regardless.
            var wasPaused = false
            while let reason = await effectivePause() {
                if !wasPaused || lastPublishedPause != reason {
                    environment.publish(progressNow(phase: .paused(reason)))
                    // Logged once per reason, not per poll, so the log can answer "why did it
                    // sit still all night?" in one line.
                    Logger.shared.info("Document survey: paused at \(nextIndex) of "
                                       + "\(plan.count) — \(reason.sentence)")
                    lastPublishedPause = reason
                }
                wasPaused = true
                await environment.whilePaused()
                if Task.isCancelled || stopRequested { break }
            }
            if Task.isCancelled || stopRequested { break }
            // Published as the pause clears, ahead of the gate, which admits only on whole
            // percent: otherwise the card would say "paused" until the next percent.
            if wasPaused {
                lastPublishedPause = nil
                Logger.shared.info("Document survey: reading again from \(nextIndex) of \(plan.count)")
                environment.publish(progressNow(phase: .reading))
            }

            let path = plan[nextIndex]
            // Already read in an earlier sitting. This check is what makes a restarted index safe.
            if read[path] == nil {
                await readOne(at: path)
            }
            nextIndex += 1

            if nextIndex % checkpointEvery == 0 { writeCheckpoint() }
            if gate.admits(completed: nextIndex, total: plan.count) {
                environment.publish(progressNow(phase: .reading, folder: folder(of: path)))
            }
        }

        let finished = nextIndex >= plan.count
        // The checkpoint is written on the way out either way. On a stop a resume reads it; on
        // completion the driver discards it only after the corpus lands, so a crash between the
        // two leaves a checkpoint beside a complete corpus rather than neither.
        writeCheckpoint()

        if finished { environment.publish(progressNow(phase: .finishing)) }

        return Report(read: read,
                      documentsRead: read.count,
                      documentsBlank: read.values.filter(\.isBlank).count,
                      documentsUnavailable: unavailable,
                      stoppedAt: finished ? nil : nextIndex)
    }

    // MARK: - One document

    private func readOne(at path: String) async {
        // Counted, not dropped, so the report still sums to the plan. Unreachable while the plan
        // and stamps come from one walk.
        guard let stamp = stamps[path] else {
            Logger.shared.warning("Document survey: \(path) is in the plan with no stamp from the "
                                  + "walk — not read, and counted as unavailable.")
            unavailable += 1
            return
        }
        let absolute = root.appendingPathComponent(path).path

        // Asked before the read: opening a cloud placeholder makes the provider download it, and a
        // survey must never download an offloaded library unless asked to (`fetch`), in which case
        // the download is timed with the read.
        var available = environment.isAvailable(absolute)
        var fetchBegan: Date?
        if !available, let fetch = environment.fetch {
            fetchBegan = environment.now()
            await fetch(absolute)
            available = environment.isAvailable(absolute)
        }
        guard available else {
            unavailable += 1
            return
        }

        let began = fetchBegan ?? environment.now()
        let text = await environment.readDocument(absolute) ?? ""
        readingSeconds += max(0, environment.now().timeIntervalSince(began))

        // **A blank stamp is permanent, so only a file that was there earns it.** A file evicted
        // during the read extracts as "", and its stamp (size and mtime) won't change when the
        // content returns, so it would be written off for good. Re-asked only for blanks.
        if text.isEmpty, !environment.isAvailable(absolute) {
            unavailable += 1
            return
        }

        read[path] = FilingSurvey.document(fromPage1: text, stamp: stamp, salt: salt)
    }

    // MARK: - Odds and ends

    private func effectivePause() async -> DocumentSurveyPause? {
        // The user's own Pause wins over an environmental one, so the card names the button they
        // pressed rather than another cause.
        if userPaused { return .user }
        return await environment.shouldPause()
    }

    private func progressNow(phase: DocumentSurveyProgress.Phase,
                             folder: String? = nil) -> DocumentSurveyProgress {
        DocumentSurveyProgress(completed: nextIndex, total: plan.count, phase: phase,
                               currentFolder: folder, startedAt: startedAt,
                               readingSeconds: readingSeconds)
    }

    private func folder(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// Progress to disk. Failure is logged, never thrown, and never stops the run: losing
    /// resumability is smaller than abandoning hours of reading, and the tokens still reach the
    /// corpus at the end.
    private func writeCheckpoint() {
        guard let directory else { return }
        let checkpoint = DocumentSurveyCheckpoint(
            profileId: profileId, rootPath: root.path, salt: salt, plan: plan,
            nextIndex: nextIndex, read: read, documentsUnavailable: unavailable,
            startedAt: startedAt, updatedAt: environment.now())
        do {
            try DocumentSurveyCheckpointStore.write(checkpoint, id: profileId, in: directory)
        } catch {
            Logger.shared.warning("Couldn't record survey progress at \(nextIndex) of "
                                  + "\(plan.count) — the survey is still running, but quitting now "
                                  + "would lose what it has read: \(error.localizedDescription)")
        }
    }
}
