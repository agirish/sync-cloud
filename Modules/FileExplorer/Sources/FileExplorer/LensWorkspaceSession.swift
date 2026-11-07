import Combine
import Events
import Foundation
import Sync

/// How the reader had Organize's results narrowed (the filter, parked queries, folds, landing,
/// tallies and session flags), kept somewhere that outlives the workspace.
///
/// Not `@State` on ``LensWorkspaceView``, because that view is mounted inside one arm of
/// `ContentView`'s layout switch: leaving Organize destroys the arm, and the reader would come back
/// to the same page with the narrowing silently gone.
///
/// Public type, internal properties: `ContentView` in `MacApp` holds and passes one, but nothing
/// outside this module reads a field, so `DuplicateMatchFilter`, `ReclaimTally`,
/// `PendingRememberPrompt` and `RuleOffer` stay internal.
///
/// Not here, because the reader didn't set them: sheet presentation (`showSpendHistory`,
/// `planningFinding`, `removalRequest`, `reviewingAutomationRule`), which should reopen shut; the
/// two `RenderMemo` caches; the spend figures, re-read on appear; and `railStyle`, a measurement.
@MainActor
public final class LensWorkspaceSession: ObservableObject {

    public init() {
        // **Nested `ObservableObject`s don't publish through their parent.** Without this re-emit a
        // view observing the session never hears `viewingResults` move, and the Automations lens
        // doesn't flip to its results until something else re-renders.
        automationsSubscription = automationsState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var automationsSubscription: AnyCancellable?

    // MARK: Duplicates

    /// The match-type narrowing. Reset by a new scan through `DuplicateScanReset`, which matters
    /// because this outlives the view (see ``filedThisSession``).
    @Published var filter: DuplicateMatchFilter = .all

    /// Each lens's parked query, kept apart because the grammars are per-lens: `kind:pdf >5mb` from
    /// Duplicates would degrade to free text in Rename, which has no size token, and match nothing.
    @Published var searchQueries: [WorkspaceLensKind: String] = [:]

    /// Which lenses have the search field revealed, per-lens for the same reason.
    @Published var searchExpandedLenses: Set<WorkspaceLensKind> = []

    /// Which duplicate groups are expanded.
    @Published var expanded: Set<UUID> = []

    /// Duplicate sections opened past their fold. Stored as the unfolded set, so a section that
    /// grows with the next scan folds by default instead of inheriting what the first render saw.
    @Published var unfoldedSections: Set<DuplicateMatchType.Kind> = []

    /// The group a "Find duplicates of this" handoff sent the reader to, marked until they look
    /// elsewhere.
    @Published var revealedGroupID: UUID?

    /// The named answer a handoff put on screen, with the query it describes.
    @Published var revealLanding: DuplicateReveal.Landing?

    /// The reveal request already acted on.
    ///
    /// Must survive the workspace switch: the request lives at the app level, so a round trip
    /// through Compare (the revealed card's "Compare copies") would otherwise find it standing and
    /// re-fire the whole plan, resetting the filter, overwriting the parked query and re-marking the
    /// group. `onRevealHandled` still retires it at the app level, which covers a request answered
    /// in a previous window.
    @Published var appliedRevealID: UUID?

    /// Bytes reclaimed so far this Duplicates session, behind the "… freed this session" caption.
    @Published var reclaim = ReclaimTally()

    /// Bumped per successful resolve to flash the reclaim pill once. A token, not a Bool, so
    /// back-to-back resolves each retrigger the fade.
    @Published var reclaimFlashToken = 0

    // MARK: Organize

    /// True once the reader has filed a loose file since the current scan finished, so the empty
    /// list can tell an earned "All filed" from "nothing was ever loose".
    ///
    /// **The scan-start resets are the only thing retiring it**, since it outlives the view. Every
    /// path that starts a scan switches the workspace first, so the handler is mounted when the flag
    /// flips (`OrganizeSessionPersistenceTests`).
    @Published var filedThisSession = false

    /// True once a suggestion has been dismissed this session without any being filed, so the empty
    /// state can say the scan's suggestions were cleared rather than that nothing was loose.
    @Published var dismissedThisSession = false

    /// A just-made override the reader can teach as a rule: they filed a loose file somewhere other
    /// than the suggested home. Held until taught or dismissed, or until the message it rides in
    /// leaves, and retired by a new scan.
    @Published var pendingRememberPrompt: PendingRememberPrompt?

    /// A learn-by-example rule offered after filing, turned into an editable Automation on save.
    @Published var pendingRuleOffer: RuleOffer?

    /// Which phrasing of the offered rule the reader picked.
    @Published var ruleVariantChoice: AutomationRuleProposer.Variant?

    /// A rule just saved or learned from the offer, for the lens to open in its editor: the offer is
    /// answered from the result message's popover, which can't present the lens's sheet. The lens
    /// takes it and clears it, so it is a hand-over, not presentation state.
    @Published var ruleAwaitingReview: AutomationRule?

    /// Whether a rule offer rides in the result message `bannerID`, as "Save as rule…" in the
    /// "Filed …" message. Inserted above the cards instead, it would push the next card's "File
    /// here" down under the pointer.
    public func offersRule(riding bannerID: UUID) -> Bool {
        if let offer = pendingRuleOffer { return offer.ridesOn == bannerID }
        return pendingRememberPrompt?.ridesOn == bannerID
    }

    /// An offer leaves with its message: ignored, it goes when the message is timed out, closed or
    /// replaced. Call whenever the shown message changes.
    public func retireRuleOffer(unlessRiding bannerID: UUID?) {
        if let offer = pendingRuleOffer, offer.ridesOn != bannerID { pendingRuleOffer = nil }
        if let prompt = pendingRememberPrompt, prompt.ridesOn != bannerID { pendingRememberPrompt = nil }
    }

    /// Saves the offered rule (with the chosen phrasing) as an Automation, retires the offer, and
    /// hands the saved rule to the lens to open for review while it's fresh.
    func saveOfferedRule(_ offer: RuleOffer, in syncManager: FileSyncManager) {
        var rule = offer.proposal.rule
        let variant = ruleVariantChoice ?? offer.proposal.defaultVariant
        rule.conditions = variant.conditions
        // A phrasing can redirect: the `{person}` fan-out files each person's copy into their own
        // folder. Taking only the conditions would save a rule for everyone's card that files them
        // all into this example's folder.
        rule.destinationTemplate = variant.destinationTemplate ?? offer.proposal.destinationTemplate
        syncManager.upsertAutomationRule(rule)
        syncManager.banner = .success("Rule saved — files matching “\(rule.name)” go to \(rule.destinationTemplate)")
        pendingRuleOffer = nil
        ruleAwaitingReview = rule
    }

    /// Learns the correction as an automation (a "mentions" rule), retires the prompt, and hands the
    /// learned rule to the lens for review. Gated at the call site by `FilingEngine.canRemember`, so
    /// it should succeed; a rare nil just dismisses, with no banner, but is logged so "I clicked
    /// Remember and no rule appeared" leaves a trace.
    func rememberOverride(_ prompt: PendingRememberPrompt, in syncManager: FileSyncManager) {
        if let rule = syncManager.rememberAutomationRule(fileName: prompt.fileName,
                                                         destinationPath: prompt.destinationPath) {
            let folderName = (prompt.destinationPath as NSString).lastPathComponent
            syncManager.banner = .success("Remembered — files like “\(prompt.fileName)” will go to \(folderName).")
            ruleAwaitingReview = rule
        } else {
            Logger.shared.warning(
                "Could not learn a rule from “\(prompt.fileName)” filed into \(prompt.destinationPath): "
                + "the name yields no distinctive words to key on. Prompt dismissed without remembering.")
        }
        pendingRememberPrompt = nil
    }

    // MARK: Automations

    /// The Automations lens's own state: whether its dry-run results are showing. Its own object
    /// because `AutomationsLens` observes it directly; the initializer re-emits its changes for
    /// views observing only this session.
    let automationsState = AutomationsLensState()
}

extension LensWorkspaceView {

    /// The session this view will use, and the one moment its seeded queries may be written.
    ///
    /// Called inside `StateObject(wrappedValue:)`'s autoclosure, so it runs on first mount only.
    /// `initialSearchQueries` is a test seam (SwiftUI can't be typed into from a unit test); applied
    /// on every init, the app's empty seed would clear a parked query on a later render. Only a
    /// non-empty seed is written, so a host session's existing queries are kept.
    static func startingSession(_ host: LensWorkspaceSession?,
                                seed: [WorkspaceLensKind: String]) -> LensWorkspaceSession {
        let session = host ?? LensWorkspaceSession()
        if !seed.isEmpty { session.searchQueries = seed }
        return session
    }
}
