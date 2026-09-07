import Foundation

/// Why a running survey is not reading right now.
///
/// **A typed value rather than a sentence, and that is decision 2.** The card greys its bar, swaps
/// its verb and changes its wording per reason; deciding any of that by asking whether a status
/// string starts with "Paused" would be the view parsing the app's own copy, which a later edit
/// breaks silently. `ScanLifecycle` carries `status` as a `String` and nothing else, which is
/// exactly why the survey does not use it for this.
public enum DocumentSurveyPause: Sendable, Equatable {
    /// The person pressed Pause. The only reason that does not clear itself.
    case user
    /// The display went to sleep. **Not politeness — iCloud materialisation stalls with the display
    /// off**, so without naming this the card shows a number that stopped moving, which reads as a
    /// hang. The survey is not the thing that stopped.
    case displayAsleep
    /// The Mac is running hot.
    case thermal
    /// Low Power Mode is on.
    case lowPower
    /// Something the user is waiting on needs the machine, or the PDF lane. `subject` is what to
    /// name on the card — "Duplicates", "a verification" — in the user's vocabulary, not the
    /// lifecycle's.
    case yielding(to: String)

    /// Whether this clears on its own. Only ``user`` does not, and the card's verb depends on it:
    /// *Resumes on its own · Resume now* against a plain *Resume*.
    public var resumesOnItsOwn: Bool {
        if case .user = self { return false }
        return true
    }

    /// The card's sentence. Here rather than in the view for the reason
    /// ``FileSyncManager/FilingSurveyReport/summary`` is: the words and the state they describe
    /// have to move together, and a test in this module can read them.
    public var sentence: String {
        switch self {
        case .user:
            return "Paused."
        case .displayAsleep:
            return "Paused — the display is asleep, so iCloud has stopped handing files over."
        case .thermal:
            return "Paused — the Mac is running hot."
        case .lowPower:
            return "Paused — Low Power Mode is on."
        case .yielding(let subject):
            return "Paused while \(subject) runs."
        }
    }
}

/// Where a document survey has got to, as something a card can draw.
///
/// **Its own type rather than fields on ``ScanLifecycle`` — decision 2, second half.** Six
/// lifecycles share that struct and five of them have nothing that can pause and no denominator to
/// count against; giving all six `isPaused`, `completed` and `total` would move every test that
/// constructs or compares one, for a feature that is not theirs. The lifecycle still owns
/// *running / has-completed / root*, which is what it has always meant. This owns the fraction.
///
/// **The counts are integers because ``ProgressPublishGate`` takes integers.** That is not a
/// convenience: a per-document write to a `@Published` property re-evaluates the window's whole
/// root view, so 7,558 documents is 7,558 full re-renders. The gate turns that into about 101, and
/// it can only do so given `completed` and `total` — which a status string does not have.
public struct DocumentSurveyProgress: Sendable, Equatable {

    public enum Phase: Sendable, Equatable {
        /// Opening documents.
        case reading
        /// Not reading, for a reason the card names.
        case paused(DocumentSurveyPause)
        /// Every document decided; merging, rebuilding the memory and writing.
        ///
        /// **Its own phase because it is minutes of work after the last document**, and a card
        /// reporting *7,558 of 7,558* that then sits there looks hung. The three steps it covers
        /// are the ones ``FilingSurvey/merge(corpus:tree:read:)``,
        /// ``FilingSurvey/buildMemory(corpus:folderModified:profileId:)`` and
        /// ``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)`` do.
        case finishing
    }

    public let completed: Int
    public let total: Int
    public let phase: Phase
    /// The folder the current document sits in, for the card's *reading Health/Medical/Kaiser*.
    /// Nil while finishing, and nil when there is nothing to name.
    public let currentFolder: String?
    /// When the run first started reading — the *original* start, carried across a resume, so the
    /// card can say how long this survey has taken rather than how long this sitting has.
    public let startedAt: Date
    /// Seconds actually spent reading, **excluding every pause**.
    ///
    /// **The ETA is derived from this and not from wall-clock elapsed, which is the whole reason
    /// the field exists.** A survey paused overnight has fourteen hours of elapsed time and eleven
    /// minutes of work; dividing the first by the documents read would tell the user the remaining
    /// 4,687 documents need eight days. The number that predicts is time spent reading.
    public let readingSeconds: TimeInterval

    public init(completed: Int, total: Int, phase: Phase, currentFolder: String? = nil,
                startedAt: Date, readingSeconds: TimeInterval) {
        self.completed = completed
        self.total = total
        self.phase = phase
        self.currentFolder = currentFolder
        self.startedAt = startedAt
        self.readingSeconds = readingSeconds
    }

    /// 0…1, and 0 rather than a division by zero for an empty plan.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    public var isPaused: Bool {
        if case .paused = phase { return true }
        return false
    }

    public var pause: DocumentSurveyPause? {
        if case .paused(let reason) = phase { return reason }
        return nil
    }

    /// Seconds still to go, or nil when there is not enough evidence to say.
    ///
    /// **Withheld rather than guessed for the first stretch.** A rate taken from three documents is
    /// noise, and an ETA that opens at "14 minutes", jumps to "4 hours" and settles at "1 h 50" is
    /// worse than no ETA at all — it teaches the reader that the number means nothing. The floor is
    /// deliberately generous: 50 documents is under a minute of a three-hour run.
    ///
    /// Nil also while finishing: that phase is not the reading rate's business and has no
    /// denominator of its own.
    public static let minimumSampleForETA = 50

    public var estimatedSecondsRemaining: TimeInterval? {
        guard case .finishing = phase else {
            guard completed >= Self.minimumSampleForETA, completed < total,
                  readingSeconds > 0 else { return nil }
            let perDocument = readingSeconds / Double(completed)
            return perDocument * Double(total - completed)
        }
        return nil
    }

    /// The starting value for a plan, before anything has been read.
    public static func starting(total: Int, at date: Date) -> Self {
        Self(completed: 0, total: total, phase: .reading, startedAt: date, readingSeconds: 0)
    }
}
