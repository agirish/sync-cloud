import Events
import Foundation

/// One document survey, from a work list to a set of read documents — pausably, resumably, and
/// without ever writing a partial corpus.
///
/// ## What it is and is not responsible for
///
/// **It turns a plan into tokens. It does not merge, rebuild or write a memory.** That seam is
/// deliberate and it is where the constraints live: the memory is a full rebuild whose bytes are
/// hashed into ``FilingProfileStore/fingerprint(id:in:)``, so it is written **once, at the end**,
/// from a complete corpus — a mid-survey write would not merely be wasted work, it would move the
/// fingerprint and discard every cached cloud verdict, once per checkpoint. Keeping that out of
/// here means this type can be driven entirely from injected closures, with no `FileSyncManager`,
/// no main actor and no disk beyond its own checkpoint.
///
/// ## One at a time, on purpose
///
/// `FileSyncManager.extractSnippets` reads four at a time and is right to: a scan reads a few
/// hundred files and wants them quickly. This reads one at a time, for two unrelated reasons that
/// happen to agree.
///
/// The first is that **concurrency buys nothing here and costs correctness**. Every PDFKit parse in
/// the process takes ``PDFKitSerialAccess``'s single lane, so extra workers queue rather than
/// overlap — and driving PDFKit concurrently *changes the text it returns*: 0.83% of documents came
/// back different six-at-a-time over a 10,286-document tree, and one statement produced 18 distinct
/// texts across 180 concurrent reads. A corpus built on unstable text is a corpus whose tokens
/// differ between runs, under a verdict key that cannot see the question changed.
///
/// The second is that **a batch cannot be stopped in the middle of itself.** Pause has to land
/// between documents, and every document in flight when the user presses Pause is work that carries
/// on regardless. One at a time makes "paused" mean what it says.
///
/// ## Cancel and pause are different, and the difference is hours
///
/// The corpus is checkpointed, so resuming costs nothing and cancelling costs everything already
/// read. Nothing in here cancels on a condition it could wait out: yielding to the duplicate scan,
/// a hot Mac, a sleeping display and the user's own Pause all suspend, and only an explicit stop or
/// task cancellation ends the run.
public actor DocumentSurveyRun {

    // MARK: - What the caller supplies

    /// Everything this run reaches outside itself. All closures, so the whole state machine is
    /// testable without a `FileSyncManager`, a display, a thermal sensor or a PDF.
    public struct Environment: Sendable {
        /// Page-1 text for an absolute path, or nil when there was nothing to read. The app hands
        /// over `ContentSignalExtractor.snippet(forFileAt:)`, which takes the PDFKit lane itself.
        public var readDocument: @Sendable (String) async -> String?
        /// Whether a path's content is actually on this disk. **Asked before the read and again
        /// after a blank one**, because a provider can evict a file in between and a blank stamp is
        /// permanent — see `readOne(at:)`.
        public var isAvailable: @Sendable (String) -> Bool
        /// Why the run should not be reading right now, or nil to carry on.
        ///
        /// **Async, and that is a correctness requirement rather than a convenience.** The real
        /// answer is assembled from `FileSyncManager`'s six lifecycles and two counters, which are
        /// `@MainActor` state; this run is its own actor, so reading them means a hop, and a hop
        /// means `await`. Making it synchronous would force the driver into
        /// `MainActor.assumeIsolated`, which from here does not hop — it traps.
        public var shouldPause: @Sendable () async -> DocumentSurveyPause?
        /// Awaited between polls while paused. The app sleeps; a test can clear its own signal here
        /// rather than racing a clock — `docs/flaky-tests.md` mechanism 5 is what this avoids.
        public var whilePaused: @Sendable () async -> Void
        /// Injected rather than read from a clock, for the same reason. Drives the ETA basis.
        public var now: @Sendable () -> Date
        /// Where progress goes. Called only for reports ``ProgressPublishGate`` admits, plus every
        /// phase change, so a 7,558-document run publishes about 101 times and not 7,558.
        public var publish: @Sendable (DocumentSurveyProgress) -> Void

        public init(readDocument: @escaping @Sendable (String) async -> String?,
                    isAvailable: @escaping @Sendable (String) -> Bool = { _ in true },
                    shouldPause: @escaping @Sendable () async -> DocumentSurveyPause? = { nil },
                    whilePaused: @escaping @Sendable () async -> Void = {},
                    now: @escaping @Sendable () -> Date = { Date() },
                    publish: @escaping @Sendable (DocumentSurveyProgress) -> Void = { _ in }) {
            self.readDocument = readDocument
            self.isAvailable = isAvailable
            self.shouldPause = shouldPause
            self.whilePaused = whilePaused
            self.now = now
            self.publish = publish
        }
    }

    // MARK: - What it produces

    /// What a run did, in the terms the completion summary reports.
    ///
    /// **Every count is of documents this run *decided*, and they sum to the plan.** A summary that
    /// reports only what it managed reads as complete when it was not — the rule
    /// ``FileSyncManager/FilingSurveyReport/summary`` already follows for unavailable documents,
    /// applied at the scale where it matters most.
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
    private let root: URL
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
    /// Seconds spent reading, pauses excluded — the ETA's basis. Accumulated per document rather
    /// than measured end to end, which is what makes excluding the pauses possible at all.
    private var readingSeconds: TimeInterval = 0
    /// The pause reason last published, so a reason that CHANGES mid-pause republishes while a
    /// steady one does not. Without it, "paused while Duplicates runs" would stay on the card after
    /// Duplicates finished and the display went to sleep — a true sentence about the wrong cause.
    private var lastPublishedPause: DocumentSurveyPause?
    private var userPaused = false
    private var stopRequested = false
    private var gate = ProgressPublishGate()

    /// How often progress reaches disk. **A count, not a timer** — the same reason
    /// ``ProgressPublishGate`` counts percent: a clock seam is a thing for a test to race, and
    /// `docs/flaky-tests.md` records what that costs here.
    public static let defaultCheckpointEvery = 25

    // MARK: - Starting

    /// A fresh run over `plan`, or one resumed from a checkpoint on disk.
    ///
    /// `directory` is where the checkpoint lives; pass nil for a run that keeps nothing (a test, a
    /// preview) — it then has no resume and no refusal, which is the honest behaviour for a run
    /// whose progress is not being kept.
    ///
    /// **`stamps` is the walk's answer, handed in.** A document's size and mtime are read during a
    /// walk that is happening anyway; re-`stat`ing 7,558 files to build the same dictionary would
    /// be work for nothing, and worse, would be reading them at a different instant from the walk
    /// the plan came from.
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
    /// **Called before `run()`, and its answer is the whole of decision 3.** A checkpoint that
    /// resumes is *offered*, never started: the offer card promises "nothing starts it but a
    /// click", and a background pass that restarts itself at the next launch makes that sentence
    /// false. What this does is establish that there is something to offer.
    ///
    /// Returns nil when there was nothing to adopt and nothing wrong — an ordinary first run.
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
            // Clamped through `progress`, which already refuses an index the plan cannot hold —
            // the file is on disk and can be hand-edited, and a crash on resume is a worse answer
            // than a survey that believes it is finished.
            nextIndex = checkpoint.progress.done
            startedAt = checkpoint.startedAt
            // **Carried, because the summary claims to be honest about exactly this number.**
            // `read` was adopted and this was not, so a resumed survey reported every
            // not-downloaded document from the first sitting as if it had never happened — the one
            // count `DocumentSurveyReport.summary` exists to state plainly.
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

    public func resume() {
        userPaused = false
    }

    /// Ends the run at the next document boundary, keeping the checkpoint.
    ///
    /// **Stop is not cancel and neither is destructive.** The checkpoint stays, so this is "stop for
    /// now" — the state decision 3 says the app returns to at the next launch, offering a Resume
    /// rather than taking one.
    public func stop() {
        stopRequested = true
    }

    // MARK: - The loop

    /// Reads the plan, from wherever the run currently stands.
    public func run() async -> Report {
        environment.publish(progressNow(phase: .reading))

        while nextIndex < plan.count {
            if Task.isCancelled { break }
            if stopRequested { break }

            // Pause is polled at the document boundary, which is the only place it can land: a
            // read already in flight finishes regardless, so checking mid-read would report a
            // pause the run is not yet honouring.
            var wasPaused = false
            while let reason = await effectivePause() {
                if !wasPaused || lastPublishedPause != reason {
                    environment.publish(progressNow(phase: .paused(reason)))
                    lastPublishedPause = reason
                }
                wasPaused = true
                await environment.whilePaused()
                if Task.isCancelled || stopRequested { break }
            }
            if Task.isCancelled || stopRequested { break }
            // **Published the instant the pause clears, ahead of the gate.** The gate admits on
            // whole percent, so without this the card kept saying "paused — the display is asleep"
            // until the count crossed the next percent — about 75 documents, over a minute, on a
            // 7,558-document run. A card that says paused under a survey that is reading is the
            // same failure as one that says reading under a survey that has stopped.
            if wasPaused {
                lastPublishedPause = nil
                environment.publish(progressNow(phase: .reading))
            }

            let path = plan[nextIndex]
            await readOne(at: path)
            nextIndex += 1

            if nextIndex % checkpointEvery == 0 { writeCheckpoint() }
            if gate.admits(completed: nextIndex, total: plan.count) {
                environment.publish(progressNow(phase: .reading, folder: folder(of: path)))
            }
        }

        let finished = nextIndex >= plan.count
        // The checkpoint is written on the way out either way. On a stop it is what a resume reads;
        // on completion it is deliberately left for the DRIVER to discard, after the corpus has
        // landed — a crash between the two leaves a resumable checkpoint beside a complete corpus,
        // and the next run finds the tree already covered. The other order leaves neither.
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
        // **Counted, not silently dropped.** The plan comes from the same walk as the stamps, so
        // this cannot fire today — but if it ever does, returning without counting would leave the
        // report's figures not summing to the plan, and `summary` states them as though they do.
        // Counted as unavailable because that is what it is: a document the survey did not read.
        guard let stamp = stamps[path] else {
            Logger.shared.warning("Document survey: \(path) is in the plan with no stamp from the "
                                  + "walk — not read, and counted as unavailable.")
            unavailable += 1
            return
        }
        let absolute = root.appendingPathComponent(path).path

        // Asked before the read: opening a cloud placeholder is what makes the provider fetch it,
        // and a survey must never download the user's offloaded library to look at page one.
        guard environment.isAvailable(absolute) else {
            unavailable += 1
            return
        }

        let began = environment.now()
        let text = await environment.readDocument(absolute) ?? ""
        readingSeconds += max(0, environment.now().timeIntervalSince(began))

        // **A blank stamp is permanent, so it is only earned by a file that was there.**
        // Availability was asked above and the read takes time; a file the provider evicts in
        // between extracts as "" — and the stamp recording that is keyed on size and mtime, neither
        // of which moves when the content comes back. The write-off would therefore never
        // invalidate: the exact outcome `isAvailable` exists to prevent, reached through a stale
        // answer. Re-asked only for the blanks, because a document that produced text plainly had
        // its content on disk.
        if text.isEmpty, !environment.isAvailable(absolute) {
            unavailable += 1
            return
        }

        read[path] = FilingSurvey.document(fromPage1: text, stamp: stamp, salt: salt)
    }

    // MARK: - Odds and ends

    private func effectivePause() async -> DocumentSurveyPause? {
        // The user's own Pause wins over an environmental one: they pressed a button, and a card
        // reading "paused while Duplicates runs" under a Pause they just pressed would be the app
        // explaining away their own action.
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

    /// Progress to disk. **Failure is logged, never thrown, and never stops the run.**
    /// A survey that cannot checkpoint has stopped being resumable, which is a real loss — but it
    /// is a smaller loss than abandoning two hours of reading that is otherwise going fine, and the
    /// tokens are still in memory and still land in the corpus at the end.
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
