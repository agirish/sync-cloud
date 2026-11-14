import Foundation

/// Why a running survey is not reading right now. A typed value, not a status string: the card
/// greys its bar and changes its verb and wording per reason, and parsing the app's own copy would
/// break silently on the next edit. That is why the survey doesn't use `ScanLifecycle`'s `status`.
public enum DocumentSurveyPause: Sendable, Equatable {
    /// The person pressed Pause. The only reason that does not clear itself.
    case user
    /// The display went to sleep. **iCloud stops handing files over with the display off**, so
    /// without this the card's count would stall and read as a hang.
    case displayAsleep
    /// The Mac is running hot.
    case thermal
    /// Low Power Mode is on.
    case lowPower
    /// Something the user is waiting on needs the machine or the PDF lane. `subject` is what the
    /// card names ("Duplicates", "a verification"), in the user's words.
    case yielding(to: String)

    /// Whether this clears on its own. Only ``user`` does not, and the card's verb depends on it:
    /// *Resumes on its own · Resume now* against a plain *Resume*.
    public var resumesOnItsOwn: Bool {
        if case .user = self { return false }
        return true
    }

    /// The card's sentence. Here rather than in the view, as for
    /// ``FileSyncManager/FilingSurveyReport/summary``, so the words move with the state and tests
    /// can read them.
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
/// Its own type, not fields on ``ScanLifecycle``: the other lifecycles sharing that struct can't
/// pause and have no denominator. The lifecycle keeps running, has-completed and root; this owns
/// the fraction.
///
/// The counts are integers because ``ProgressPublishGate`` needs them: each write to a `@Published`
/// property re-renders the window's root view, so a per-document write would re-render once per
/// document. The gate cuts that to about a hundred.
public struct DocumentSurveyProgress: Sendable, Equatable {

    public enum Phase: Sendable, Equatable {
        /// Opening documents.
        case reading
        /// Not reading, for a reason the card names.
        case paused(DocumentSurveyPause)
        /// Every document decided; merging, rebuilding the memory and writing. Its own phase
        /// because that takes minutes, and a card sitting at *7,558 of 7,558* looks hung. Covers
        /// ``FilingSurvey/merge(corpus:tree:read:)``,
        /// ``FilingSurvey/buildMemory(corpus:folderModified:profileId:)`` and
        /// ``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)``.
        case finishing
    }

    public let completed: Int
    public let total: Int
    public let phase: Phase
    /// The folder the current document sits in, for the card's *reading Health/Medical/Kaiser*.
    /// Nil while finishing, and nil when there is nothing to name.
    public let currentFolder: String?
    /// When the run first started reading, carried across a resume, so the card can say how long
    /// the survey has taken, not this sitting.
    public let startedAt: Date
    /// Seconds actually spent reading, excluding every pause. The ETA comes from this, not wall-clock
    /// time: after a pause overnight, elapsed time would predict days for minutes of work.
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
    /// Withheld for the first stretch: a rate from a few documents is noise, and an ETA that jumps
    /// around teaches the reader it means nothing. 50 documents is under a minute of a long run.
    /// Also nil while finishing, which the reading rate can't predict.
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
}
