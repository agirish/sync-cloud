import Foundation

/// The machine's state, as far as a document survey needs to care about it.
///
/// A snapshot, not live reads, so a decision isn't built from properties read at different
/// instants, and ``DocumentSurveyYield`` is a pure function tests can drive without a display, a
/// thermal sensor or a running scan.
public struct DocumentSurveyConditions: Sendable, Equatable {

    /// How hot the Mac is, in the three bands the survey acts on. `ProcessInfo.ThermalState`'s
    /// `.fair` is no reason to stop, so it folds into `.nominal`.
    public enum Heat: Sendable, Equatable {
        case nominal
        /// `.serious`: the fans are up and the system is already throttling.
        case serious
        /// `.critical`: thermal mitigation is aggressive; background PDF work stands down.
        case critical
    }

    /// A verification is running. `FileSyncManager.isVerifyAllRunning`.
    public var isVerifying: Bool
    /// File operations in flight — copies, moves, removals. `activeFileOperationsCount`.
    public var activeFileOperations: Int
    /// Scans running now, already named in the user's words ("Duplicates", "Storage", "Names"). The
    /// caller names them because the words belong to Organize's rail, which this module can't see.
    /// In rail order, so the reason shown is stable.
    public var runningScans: [String]
    /// The display is asleep. iCloud stops handing files over with the display off, so the survey
    /// names a stop it didn't choose.
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
/// Apart from ``DocumentSurveyConditions`` because the app supplies them: they come from AppKit
/// and `ProcessInfo`, which this module doesn't reach for, through a closure the app installs. The
/// rest is the manager's own state.
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

    /// What a host that can't see any of this reports, such as a test host or a preview. A survey
    /// then never pauses for the machine.
    public static let unknown = MachineConditions()
}

/// Whether a document survey should be reading right now, and what to say when it should not.
///
/// **Every one of these suspends; none cancels.** Waiting costs nothing, and stopping would cost
/// every document read so far. ``DocumentSurveyRun`` waits on the answer; only an explicit stop ends
/// a run.
public enum DocumentSurveyYield {

    /// Why the survey should stand down, or nil to carry on.
    ///
    /// Several conditions are often true at once, but the card shows one sentence, so the order
    /// is what the person would most want to know:
    ///
    /// 1. Work they started and are waiting on: a verification, file operations, a scan.
    /// 2. The display asleep, a stop the survey didn't choose; without it the stalled count reads
    ///    as a hang.
    /// 3. Heat, then Low Power Mode.
    ///
    /// The user's own Pause outranks all of these and is held inside the run.
    public static func pause(for conditions: DocumentSurveyConditions) -> DocumentSurveyPause? {
        reasons(for: conditions).first?.pause
    }

    /// What a pause is for, apart from the card's wording: what *Resume now* sets aside. Its own
    /// value because the sentence changes while the cause doesn't ("a file operation" becomes "2
    /// file operations"), and a waiver keyed on the sentence would pause again.
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

    /// Every reason in force, in ``pause(for:)``'s order (that function takes the head). *Resume
    /// now* needs them all: waiving only the head would leave the next reason standing behind it.
    public static func reasons(for conditions: DocumentSurveyConditions)
    -> [(cause: Cause, pause: DocumentSurveyPause)] {
        var out: [(cause: Cause, pause: DocumentSurveyPause)] = []
        if conditions.isVerifying { out.append((.verification, .yielding(to: "a verification"))) }
        if conditions.activeFileOperations > 0 {
            let n = conditions.activeFileOperations
            out.append((.fileOperations, .yielding(to: n == 1 ? "a file operation" : "\(n) file operations")))
        }
        // The card names only the first: in practice two scans never run at once (they share the
        // PDF lane). Each is still its own cause.
        for scan in conditions.runningScans { out.append((.scan(scan), .yielding(to: scan))) }
        if conditions.displayAsleep { out.append((.displayAsleep, .displayAsleep)) }
        if conditions.heat != .nominal { out.append((.heat, .thermal)) }
        if conditions.lowPowerMode { out.append((.lowPower, .lowPower)) }
        return out
    }
}

/// *Resume now*: the causes the person has told the survey to read through.
///
/// Every cause in force at the click is set aside until it clears; a cause not in force then still
/// pauses the run. A waived cause that clears and comes back is a new one: tomorrow's Duplicates
/// run is not the one somebody said to read through today.
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
