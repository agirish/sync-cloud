import Foundation

/// What reading every document costs, in the one form the app says it.
///
/// **One sentence, two screens.** Organize's survey card offers the read and setup's Structure
/// screen offers it too; a figure worded differently in the two places is the same number arriving
/// as two different promises. It lives in `Design` rather than `Sync` because
/// `DocumentSurveyCard.swift` deliberately imports no domain module — what reaches it is counts,
/// seconds and already-worded sentences — and this is one of those sentences. The estimate itself is deliberately coarse and stated as a duration
/// rather than a rate — what a person weighs is "is this hours or minutes", and a per-document
/// figure invites arithmetic the estimate cannot support.
public enum DocumentSurveyCost {

    /// **Below this many documents the read takes minutes, not hours** (FC7), so the sentence says
    /// "A few minutes" — about six at `secondsPerDocument`, and too few to round to a figure.
    public static let fewMinutesBelow = 200

    /// **The measured cost of reading one document**: the owner's read of 6,140 documents took
    /// about three hours (`DocumentSurveyCard`'s "three hours of background reading"), about
    /// 1.76 s each. Every figure the sentence states is scaled from it, so 200 documents and
    /// 6,140 are no longer offered the same "About 3 h".
    static let secondsPerDocument: Double = 3 * 3_600 / 6_140

    /// `"About 3 h for 6,140 documents."` — or `"About 30 min for 1,000 documents."`, or, under
    /// `fewMinutesBelow`, `"A few minutes for 12 documents."`
    public static func phrase(documents: Int) -> String {
        "\(duration(documents)) for \(documentCount(documents))."
    }

    /// **Coarse on purpose**: tens of minutes below an hour, whole hours above it. A finer figure
    /// would claim a precision a rate over wildly uneven documents does not have.
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

    /// The same figure as the survey card's offer draws it, in the middle of its sentence.
    public static func offerClause(documents: Int) -> String {
        "\(duration(documents)) for \(documentCount(documents)), in the background."
    }
}
