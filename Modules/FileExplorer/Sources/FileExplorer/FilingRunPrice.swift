import Foundation
import Sync

/// What Organize's setup card can honestly say about cost *before* a scan has run.
///
/// The roadmap's rule is "if an action costs money, the price belongs on the button" — and the
/// hard part is that nothing here knows what this run will cost. A real estimate needs the file
/// count and the folder taxonomy, which means walking the provider before the user has decided
/// anything. So the card quotes the **last recorded run** instead: a figure that is certainly
/// true about something, rather than a projection dressed up as one.
///
/// That choice has two consequences this type exists to handle honestly.
///
/// **The figure is not about this folder.** `FilingSpendStore` records cost per API call and does
/// not record which folder the call was for, so "last run" is the last cloud call, wherever it
/// pointed. The detail line therefore always says so; the button carries only the short form, and
/// the words "last run" are what keep it from reading as a quote for the button beneath it.
///
/// **On a genuine first run there is no figure at all.** The card only appears when Organize has
/// no results, which after the first launch is a common state — so in practice the price is
/// present most of the time. But the very first run has nothing to quote, and the button stays
/// plain rather than inventing something.
enum FilingRunPrice {

    struct Readout: Equatable {
        /// Trailing clause for the trigger, e.g. `last run ~$0.18`. nil leaves the button plain.
        let buttonSuffix: String?
        /// The line under the card that gives the figure its context — which run, how big, on
        /// what model, and that this folder may differ. nil when there is nothing to say.
        let detail: String?
    }

    /// **Known imprecision, deliberately not plumbed:** `cloudEnabled` is what the two toggles
    /// say, and the real gate also requires a readable Keychain key and budget left under the
    /// caps. With cloud switched on but no key, every scan silently runs on-device while this
    /// still shows a figure. The error is in the safe direction — it over-states cost, so nobody
    /// is surprised by a bill — and the wording is past-tense throughout ("last run", "Last cloud
    /// run"), so it remains a true statement about a run that happened rather than a promise
    /// about this one. Closing it properly means the app answering the routing question, as
    /// `filingBackendIdentity` does for the verdict cache; querying the Keychain from a view that
    /// re-renders on every keystroke would be far worse than the imprecision.
    ///
    /// - Parameters:
    ///   - cloudEnabled: whether a scan would actually reach the paid backend. Both the AI toggle
    ///     and the cloud toggle have to be on: cloud rides on top of on-device AI, exactly as
    ///     `findFilingSuggestions` gates it.
    ///   - last: the most recent recorded cloud call, or nil if there has never been one.
    static func readout(cloudEnabled: Bool, last: FilingSpendEntry?) -> Readout {
        // The on-device backend is free. A price on the button would be answering a question the
        // user is not being asked, and "≈ $0.00" reads like a rounding error rather than "free".
        guard cloudEnabled else { return Readout(buttonSuffix: nil, detail: nil) }

        guard let last else {
            // Cloud is on and nothing has run yet. Say that the run costs money without naming a
            // number, which is the one thing that would be a guess.
            return Readout(buttonSuffix: nil,
                           detail: "Claude (cloud) is on — this run is billed to your API key. "
                                 + "Its cost appears here afterwards.")
        }

        let cost = FilingSpendFormat.cost(last.estimatedCostUSD)
        let files = last.fileCount == 1 ? "1 file" : "\(last.fileCount) files"
        return Readout(
            buttonSuffix: "last run \(cost)",
            detail: "Last cloud run: \(files) on \(FilingSpendFormat.model(last.model)) · \(cost). "
                  + "This folder may differ — files you've already had suggestions for aren't sent again.")
    }
}
