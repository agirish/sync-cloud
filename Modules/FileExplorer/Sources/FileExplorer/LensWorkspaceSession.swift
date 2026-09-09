import Combine
import Foundation
import Sync

/// How the reader had Organize's results narrowed — the filter, the parked queries, the folds, the
/// landing, the tallies and the session flags — kept somewhere that outlives the workspace.
///
/// **The defect.** All of this was `@State` on ``LensWorkspaceView``, and that view is mounted by
/// `bottomPaneView` inside one arm of `ContentView`'s layout switch. Leaving Organize destroys the
/// arm, so every one of these went back to its default: the match filter to All, the search field
/// closed and its query gone, the unfolded sections re-folded, "freed this session" to zero, and the
/// filed/dismissed flags — which are what let the empty state say "all filed" rather than "nothing
/// was ever loose" — back to false. The rail item and the scope survived, being `@AppStorage`, which
/// is exactly what made the loss read as arbitrary rather than as a reset: you came back to the same
/// page with the narrowing silently gone.
///
/// The comment above the single `LensWorkspaceView(` construction site has always said this state
/// must not reset, and it was right about the case it was written for — lens to lens, one call site,
/// one identity. It simply does not reach across a workspace switch, because nothing about a single
/// call site survives its enclosing branch being torn down.
///
/// **Public type, internal properties.** `ContentView` lives in `MacApp` and has to be able to hold
/// and pass one of these, so the type and its initializer are public. Nothing outside this module
/// ever reads a field, so the fields stay internal — which is what keeps `DuplicateMatchFilter`,
/// `ReclaimTally`, `PendingRememberPrompt` and `RuleOffer` internal too. Hoisting state is not a
/// reason to widen a module's API.
///
/// **What is deliberately NOT here.** Sheet presentation (`showSpendHistory`, `planningFinding`,
/// `removalRequest`, `reviewingAutomationRule`), which should close when you leave and reopen shut;
/// the two `RenderMemo`s, which are caches whose whole design is that writing them is not a state
/// change; the spend figures, which are re-read from their store on appear; and `railStyle`, which
/// is a measurement of the width the rail currently has. None of those are things a reader set.
@MainActor
public final class LensWorkspaceSession: ObservableObject {

    public init() {
        // **Nested `ObservableObject`s do not publish through their parent**, so a view observing
        // this session would never hear `viewingResults` move and the Automations lens would not
        // flip into its results view until something else happened to re-render. Re-emitting is the
        // standard closure of that gap, and it is needed precisely because the state moved: as a
        // `@StateObject` on the view, `automationsState` was observed directly.
        automationsSubscription = automationsState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var automationsSubscription: AnyCancellable?

    // MARK: Duplicates

    /// The match-type narrowing. Reset by a new scan through `DuplicateScanReset` — see the note on
    /// ``filedThisSession`` for why those resets matter more now than they did.
    @Published var filter: DuplicateMatchFilter = .all

    /// Each lens's parked query, kept separately because the grammars are per-lens: `kind:pdf >5mb`
    /// typed in Duplicates means nothing in Rename, which declares no size token, so a shared field
    /// would silently degrade it to free text and match nothing.
    @Published var searchQueries: [WorkspaceLensKind: String] = [:]

    /// Which lenses currently have the search field revealed — per-lens for the same reason.
    @Published var searchExpandedLenses: Set<WorkspaceLensKind> = []

    /// Which duplicate groups are expanded.
    @Published var expanded: Set<UUID> = []

    /// Duplicate sections opened past their fold. Stored as the UNFOLDED set rather than the folded
    /// one, so a section that grows with the next scan folds by default instead of inheriting
    /// whatever the first render saw.
    @Published var unfoldedSections: Set<DuplicateMatchType.Kind> = []

    /// The group a "Find duplicates of this" handoff sent the reader to, marked until they look
    /// elsewhere.
    @Published var revealedGroupID: UUID?

    /// The named answer a handoff put on screen, with the query it describes.
    @Published var revealLanding: DuplicateReveal.Landing?

    /// The reveal request already acted on.
    ///
    /// **This surviving the switch is a fix in its own right, not a side effect.** It was `@State`,
    /// so it died with the view while the request itself lived at the app level and did not — and a
    /// round trip through Compare (which the revealed card's own "Compare copies" button takes you
    /// on) came back with the old request standing and no memory of having applied it. The whole
    /// plan then re-fired: filter reset, the reader's parked query overwritten, the old group
    /// re-marked, on every return for the rest of the session. `onRevealHandled` was added to close
    /// that from the other side and still should stay — a retirement at the app level is the only
    /// thing that covers a request answered in a previous window — but the guard now holds in
    /// process as well, which is where the replay actually happened.
    @Published var appliedRevealID: UUID?

    /// Bytes reclaimed so far this Duplicates session, behind the "… freed this session" caption.
    @Published var reclaim = ReclaimTally()

    /// Bumped per successful resolve to flash the reclaim pill once. A token rather than a Bool, so
    /// back-to-back resolves each retrigger the fade cleanly.
    @Published var reclaimFlashToken = 0

    // MARK: Organize

    /// True once the reader has filed at least one loose file since the current scan finished — what
    /// lets the empty list distinguish an earned "All filed" from "nothing was ever loose".
    ///
    /// **Now that this outlives the view, the scan-start resets are the only thing retiring it.**
    /// They always ran, but a fresh mount used to make them belt-and-braces; it is load-bearing now.
    /// Every path that starts a scan switches the workspace first, so the handler is mounted when
    /// the flag flips — `OrganizeSessionPersistenceTests` holds that rather than trusting it.
    @Published var filedThisSession = false

    /// True once a suggestion has been dismissed this session without any being filed, so the empty
    /// state can say the scan's suggestions were cleared rather than that nothing was loose.
    @Published var dismissedThisSession = false

    /// A just-made override the reader can teach as a rule: they filed a loose file somewhere other
    /// than the suggested home. Held until taught or dismissed, and retired by a new scan.
    @Published var pendingRememberPrompt: PendingRememberPrompt?

    /// A learn-by-example rule offered after filing, turned into an editable Automation on save.
    @Published var pendingRuleOffer: RuleOffer?

    /// Which phrasing of the offered rule the reader picked.
    @Published var ruleVariantChoice: AutomationRuleProposer.Variant?

    // MARK: Automations

    /// The Automations lens's own state — whether its dry-run results are showing.
    ///
    /// Held as its own object rather than folded in as a `Bool` because `AutomationsLens` observes
    /// it directly; the initializer above re-emits its changes so a view observing only this session
    /// still hears them.
    let automationsState = AutomationsLensState()
}

extension LensWorkspaceView {

    /// The session this view will use, and the one moment its seeded queries may be written.
    ///
    /// Called from inside `StateObject(wrappedValue:)`'s autoclosure, so it runs on first mount and
    /// never again — which is the whole point. `initialSearchQueries` is a test seam (the only way
    /// into a query without typing, since SwiftUI cannot be driven from a unit test), and applying
    /// it on every init would let the app's empty seed clear a parked query on any later render.
    ///
    /// Non-empty check rather than an unconditional assign for the same reason from the other side:
    /// a host session arriving with queries already in it must keep them.
    static func startingSession(_ host: LensWorkspaceSession?,
                                seed: [WorkspaceLensKind: String]) -> LensWorkspaceSession {
        let session = host ?? LensWorkspaceSession()
        if !seed.isEmpty { session.searchQueries = seed }
        return session
    }
}
