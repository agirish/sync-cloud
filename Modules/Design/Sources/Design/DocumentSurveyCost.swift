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

    /// `"About 3 h for 6,140 documents."`
    public static func phrase(documents: Int) -> String {
        "About 3 h for \(documents.formatted()) documents."
    }

    /// The same figure as the survey card's offer draws it, in the middle of its sentence.
    public static func offerClause(documents: Int) -> String {
        "About 3 h for \(documents.formatted()) documents, in the background."
    }
}
