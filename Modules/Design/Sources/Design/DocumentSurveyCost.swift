import Foundation

/// What reading every document costs, in the one form the app says it, so Organize's survey card
/// and setup's Structure screen make the same promise. In `Design`, not `Sync`, because
/// `DocumentSurveyCard.swift` imports no domain module and takes already-worded sentences. Coarse,
/// and a duration rather than a rate: a person weighs hours against minutes, and a per-document
/// figure invites arithmetic the estimate can't support.
public enum DocumentSurveyCost {

    /// Below this many documents the read takes minutes, so the sentence says "A few minutes":
    /// about six at `secondsPerDocument`, too few to round to a figure.
    public static let fewMinutesBelow = 200

    /// The measured cost of reading one document: a read of 6,140 documents took about three hours
    /// (`DocumentSurveyCard`'s "three hours of background reading"), about 1.76 s each. Every
    /// figure the sentence states is scaled from it.
    static let secondsPerDocument: Double = 3 * 3_600 / 6_140

    /// `"About 3 h for 6,140 documents."` — or `"About 30 min for 1,000 documents."`, or, under
    /// `fewMinutesBelow`, `"A few minutes for 12 documents."`
    public static func phrase(documents: Int) -> String {
        "\(duration(documents)) for \(documentCount(documents))."
    }

    /// Coarse on purpose: tens of minutes below an hour, whole hours above. A finer figure would
    /// claim a precision a rate over uneven documents doesn't have.
    private static func duration(_ n: Int) -> String {
        guard n >= fewMinutesBelow else { return "A few minutes" }
        let seconds = Double(n) * secondsPerDocument
        let minutes = Int((seconds / 600).rounded()) * 10
        if minutes < 60 { return "About \(max(10, minutes)) min" }
        return "About \(max(1, Int((seconds / 3_600).rounded())).formatted()) h"
    }

    private static func documentCount(_ n: Int) -> String {
        n == 1 ? "1 document" : "\(n.formatted()) documents"
    }

    /// The duration alone (`"About 3 h"`, `"A few minutes"`), for a sentence that states the count
    /// itself (Read Documents for a source).
    public static func duration(documents: Int) -> String { duration(documents) }

    /// The same figure as the survey card's offer draws it, in the middle of its sentence.
    public static func offerClause(documents: Int) -> String {
        "\(duration(documents)) for \(documentCount(documents)), in the background."
    }
}
