import Foundation

/// The machine's state, as far as a document survey needs to care about it.
///
/// **A value, not a set of live reads.** The survey polls between documents, and a decision built
/// from six `@Published` properties read at six slightly different instants is a decision nobody
/// can reproduce. Snapshotting them into one struct makes the rule a pure function — which is what
/// lets ``DocumentSurveyYield`` be tested without a display, a thermal sensor, or a running scan.
public struct DocumentSurveyConditions: Sendable, Equatable {

    /// How hot the Mac is, in the three bands the survey acts on. `ProcessInfo.ThermalState` has
    /// four; `.fair` is not a reason to stop doing anything, so it folds into `.nominal` here
    /// rather than being carried and then ignored at the point of use.
    public enum Heat: Sendable, Equatable {
        case nominal
        /// `.serious` — the fans are up and the system is already throttling.
        case serious
        /// `.critical` — thermal mitigation is aggressive and a background PDF parse is exactly
        /// the sort of work that should stand down.
        case critical
    }

    /// A verification is running. `FileSyncManager.isVerifyAllRunning`.
    public var isVerifying: Bool
    /// File operations in flight — copies, moves, removals. `activeFileOperationsCount`.
    public var activeFileOperations: Int
    /// Scans running right now, **already named in the user's vocabulary** — "Duplicates",
    /// "Storage", "Names". The caller does the naming because the words belong to Organize's rail
    /// and this module cannot see it; passing lifecycles instead would put the app's copy in here.
    ///
    /// In rail order, so the reason shown is stable rather than dictionary-ordered.
    public var runningScans: [String]
    /// The display is asleep. **Not a politeness signal**: iCloud materialisation stalls with the
    /// display off, so this is the survey naming a stop it did not choose.
    public var displayAsleep: Bool
    public var heat: Heat
    public var lowPowerMode: Bool

    public init(isVerifying: Bool = false, activeFileOperations: Int = 0,
                runningScans: [String] = [], displayAsleep: Bool = false,
                heat: Heat = .nominal, lowPowerMode: Bool = false) {
        self.isVerifying = isVerifying
        self.activeFileOperations = activeFileOperations
        self.runningScans = runningScans
        self.displayAsleep = displayAsleep
        self.heat = heat
        self.lowPowerMode = lowPowerMode
    }

    /// Nothing in the way.
    public static let clear = DocumentSurveyConditions()
}

/// The three facts about the Mac itself that only the app can see.
///
/// **Split from ``DocumentSurveyConditions`` because of who supplies them.** The rest of that
/// struct is the manager's own state — lifecycles, operation counts — which `Sync` already holds.
/// These three come from AppKit and `ProcessInfo`, which this module deliberately does not reach
/// for, so they arrive through a closure the app installs. Keeping them in their own type means
/// that closure returns exactly what it knows and nothing it would have to invent.
public struct MachineConditions: Sendable, Equatable {
    public var displayAsleep: Bool
    public var heat: DocumentSurveyConditions.Heat
    public var lowPowerMode: Bool

    public init(displayAsleep: Bool = false,
                heat: DocumentSurveyConditions.Heat = .nominal,
                lowPowerMode: Bool = false) {
        self.displayAsleep = displayAsleep
        self.heat = heat
        self.lowPowerMode = lowPowerMode
    }

    /// What a host that cannot see any of this reports. A survey then never pauses for the
    /// machine — honest for a test host or a preview, and better than guessing.
    public static let unknown = MachineConditions()
}

/// Whether a document survey should be reading right now, and what to say when it should not.
///
/// **Every one of these suspends; none of them cancels.** The corpus is checkpointed, so waiting
/// costs nothing and stopping costs every document already read — which on a first survey is up to
/// three hours. ``DocumentSurveyRun`` treats the answer as a reason to wait, and only an explicit
/// stop ends a run.
public enum DocumentSurveyYield {

    /// Why the survey should stand down, or nil to carry on.
    ///
    /// ## The order is the answer, and it is not arbitrary
    ///
    /// Several conditions are true at once more often than not — a duplicate scan heats the Mac,
    /// and a Mac left alone puts its display to sleep — but the card shows **one** sentence, so
    /// something has to choose. The rule is *what the person would most want to know*:
    ///
    /// 1. **Work they started and are waiting on** — a verification, file operations, a scan. The
    ///    survey standing aside for their scan is the reassuring answer, and it is the only reason
    ///    that explains why their own work is not slower.
    /// 2. **The display being asleep**, because that one is not a choice the survey made. iCloud
    ///    stops handing files over, and the card must say so rather than showing a number that
    ///    stopped moving — which reads as a hang.
    /// 3. **Heat**, then **Low Power Mode** — real reasons, and the two a person is least
    ///    surprised by.
    ///
    /// The user's own Pause is not in this list: it outranks all of them and is held inside the
    /// run, because a card explaining away a button they just pressed is the app talking over them.
    public static func pause(for conditions: DocumentSurveyConditions) -> DocumentSurveyPause? {
        reasons(for: conditions).first?.pause
    }

    /// What a pause is *for*, apart from how the card words it — the thing *Resume now* sets aside.
    ///
    /// **Its own value because the sentence moves while the cause does not.** "Paused while a file
    /// operation runs" becomes "… 2 file operations …" when a second copy starts; a waiver keyed
    /// on the sentence would see a new reason there and pause again under the person who had just
    /// said to carry on.
    public enum Cause: Hashable, Sendable {
        case verification
        case fileOperations
        /// A scan, by its rail name.
        case scan(String)
        case displayAsleep
        /// Either band: serious and critical are one cause, so a waiver holds as the Mac warms.
        case heat
        case lowPower
    }

    /// **Every** reason in force, in ``pause(for:)``'s order — that function is this list's head.
    ///
    /// The card shows one sentence, but *Resume now* has to know them all: waiving only the head
    /// would leave the next reason down standing behind it, and a cause that arrives while a
    /// higher one is waived would be hidden by it rather than pausing the run.
    public static func reasons(for conditions: DocumentSurveyConditions)
    -> [(cause: Cause, pause: DocumentSurveyPause)] {
        var out: [(cause: Cause, pause: DocumentSurveyPause)] = []
        if conditions.isVerifying { out.append((.verification, .yielding(to: "a verification"))) }
        if conditions.activeFileOperations > 0 {
            let n = conditions.activeFileOperations
            out.append((.fileOperations, .yielding(to: n == 1 ? "a file operation" : "\(n) file operations")))
        }
        // The card names the first: two scans do not run at once in practice — they share the PDF
        // lane and each guards its own re-entrancy — and "paused while Duplicates and Storage run"
        // would be a sentence describing a state the app cannot reach. Each is still its own cause.
        for scan in conditions.runningScans { out.append((.scan(scan), .yielding(to: scan))) }
        if conditions.displayAsleep { out.append((.displayAsleep, .displayAsleep)) }
        if conditions.heat != .nominal { out.append((.heat, .thermal)) }
        if conditions.lowPowerMode { out.append((.lowPower, .lowPower)) }
        return out
    }
}

/// *Resume now*: the causes the person has told the survey to read through.
///
/// **A pause that clears on its own still had to be waited out**, because Resume only cleared the
/// user's own Pause and the next poll asked the machine again — so the button beside "Resumes on
/// its own" did nothing at all. This is what it does instead: every cause in force at the click is
/// set aside **until it clears**, and a cause that was not in force then pauses the run as before.
/// A waived cause that clears and comes back is a new one — Duplicates run again tomorrow is not
/// the run somebody said to read through today.
public struct DocumentSurveyOverride: Sendable, Equatable {
    public private(set) var waived: Set<DocumentSurveyYield.Cause> = []

    public init() {}

    /// Sets aside every cause in force now. A no-op when none is.
    public mutating func waive(_ conditions: DocumentSurveyConditions) {
        waived.formUnion(DocumentSurveyYield.reasons(for: conditions).map(\.cause))
    }

    /// The pause to honour now: the first reason in force that was not waived. A waived cause no
    /// longer in force is forgotten here, which is what makes its return pause again.
    public mutating func pause(for conditions: DocumentSurveyConditions) -> DocumentSurveyPause? {
        let inForce = DocumentSurveyYield.reasons(for: conditions)
        waived.formIntersection(inForce.map(\.cause))
        return inForce.first { !waived.contains($0.cause) }?.pause
    }
}
