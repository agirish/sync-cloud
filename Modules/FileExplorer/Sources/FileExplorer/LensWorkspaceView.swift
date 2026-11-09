import SwiftUI
import AppKit
import Events
import Sync
import Design

// MARK: - Lens / filter / match styling

/// The lenses shown in the right-hand slot. Public so the host can map its selected workspace
/// onto one; the workspace bar makes the choice, not this view. Its own type rather than part of
/// `Workspace` because the per-lens search grammars, query parking and expansion state in
/// `LensWorkspaceView` are keyed by it, and none of them mean anything for Compare.
public enum WorkspaceLensKind: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    case filing = "Filing"
    case automations = "Automations"
    /// The read-only Storage lens (treemap + largest / stale / reclaim lists). Sits last, after the
    /// action lenses.
    case storage = "Storage"
    public var id: String { rawValue }

    /// The lens's name, shown in the header card. Kept separate from `rawValue` so it can be
    /// reworded without breaking a stored id (Filing shows as "Organize").
    public var title: String {
        switch self {
        case .filing: return "Organize"
        default: return rawValue
        }
    }
}

/// Filter over the match type of duplicate groups.
enum DuplicateMatchFilter: String, CaseIterable, Identifiable {
    case all, needsReview, identical, sameText, overlapping, versions
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .identical: return "Identical"
        case .sameText: return "Same text"
        case .overlapping: return "Overlapping"
        case .needsReview: return "Needs review"
        case .versions: return "Versions"
        }
    }

    func matches(_ group: DuplicateGroup) -> Bool {
        switch self {
        case .all: return true
        case .identical: return group.matchType.kind == .identical
        case .sameText: return group.matchType.kind == .sameText
        case .overlapping: return group.matchType.kind == .overlapping
        // Everything that is not byte-identical, which is what the pill beside it counts: the
        // kinds "Apply recommended" will not touch.
        case .needsReview: return group.matchType.kind != .identical
        case .versions: return group.matchType.kind == .versions
        }
    }
}

/// The symbol/color/label vocabulary for a match type — reuses SyncCloud's difference palette
/// (green seal = certain, orange = attention, yellow = name conflict, purple = versions).
enum DuplicateMatchStyle {
    static func symbol(_ type: DuplicateMatchType) -> String {
        switch type {
        case .identical: return "checkmark.seal.fill"
        // A seal, like `identical`, but unfilled: the same claim made with less certainty behind
        // it. The glyph pair is the vocabulary — nothing here relies on the colour alone.
        case .sameText: return "checkmark.seal"
        case .overlapping: return "square.on.square"
        case .versions: return "clock.arrow.circlepath"
        }
    }
    static func color(_ type: DuplicateMatchType) -> Color {
        switch type {
        case .identical: return SemanticColor.success
        case .sameText: return SemanticColor.caution
        case .overlapping: return SemanticColor.warning
        case .versions: return .purple
        }
    }
    static func label(_ type: DuplicateMatchType) -> String {
        switch type {
        case .identical: return "Identical"
        case .sameText: return "Same text"
        case .overlapping(let f): return "Overlapping · \(Int((f * 100).rounded()))%"
        case .versions: return "Versions"
        }
    }

    /// What the row's badge says: the want, not the category. nil for `identical`, the majority
    /// case, whose certainty shows in the green reclaim figure instead. The exceptions say what
    /// they need from a person; the subtitle already names the category.
    static func badgeLabel(_ type: DuplicateMatchType) -> String? {
        switch type {
        case .identical: return nil
        case .sameText, .overlapping, .versions: return "needs review"
        }
    }
}

// MARK: - Scan-start session reset

/// Everything a fresh Duplicates scan retires, as one named list instead of loose assignments
/// inside `.onChange`. The type filter belongs here with the search query: a filter picked against
/// the previous results would otherwise survive into the new scan and show a partial list, or a
/// "Nothing matches" state that blames a search that isn't there. Both narrowings are one to the
/// user, so neither may outlive the results they were aimed at.
enum DuplicateScanReset {
    static func duplicatesScanStarted(filter: inout DuplicateMatchFilter,
                                      searchQuery: inout String,
                                      reclaim: inout ReclaimTally) {
        filter = .all
        searchQuery = ""
        reclaim.reset()
    }
}

// MARK: - LensWorkspaceView

/// A single-source lens workspace (Duplicates, Rename, Organize, Automations, or the read-only
/// Storage), rendered in the right-hand slot with the source rail docked beside it. The workspace
/// bar in the window toolbar picks the lens; this view is handed the result.
public struct LensWorkspaceView: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    // The model Refine runs on is Ask Claude's: the chat's menu and Settings write the same key. Read
    // here so the tooltip and the Refine Names button re-render the moment it changes.
    @AppStorage(AskClaudeModels.defaultsKey)
    private var askClaudeModel: String = AskClaudeModels.defaultModel.id

    /// Honors Reduce motion: when true, the row-exit slides and the reclaim glow give way to an
    /// instant swap. The numeric count-up stays; it is acceptable under Reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.selectionLensAppearance) private var lensAppearance
    /// The part of Organize's rail on screen, for its selection lens; see
    /// `SelectionLensVisibleRegion`.
    @State private var railVisibleRegion = SelectionLensVisibleRegion()
    /// The app's text size, for the provider name — a `Menu` label that must stay a `Text`.
    @Environment(\.appFontScale) private var appFontScale

    /// The active lens, resolved by the host from the selected workspace. A value, not a binding:
    /// nothing in here selects a lens, so a binding would be a write path with no writer.
    private let lens: WorkspaceLensKind
    /// Everything on this screen the reader set, kept where it outlives the workspace; see
    /// ``LensWorkspaceSession``. Every member below forwards onto it.
    ///
    /// `@StateObject`, with the host's object as its initial value. The app hands one down from
    /// `ContentView`, mounted once for the window's life; a caller that hands none (tests that
    /// mount this view for something else) gets a fresh one per mount. The autoclosure runs only
    /// on first mount, so the identity is stable for the life of this view.
    @StateObject private var session: LensWorkspaceSession

    private var filter: DuplicateMatchFilter {
        get { session.filter }
        nonmutating set { session.filter = newValue }
    }
    /// Each lens's live query, kept separately. The grammars are per-lens, so a query carried
    /// across a switch would change meaning silently: `kind:pdf >5mb` from Duplicates lands in
    /// Rename, which has no size token, so `>5mb` becomes free text and matches nothing.
    private var searchQueries: [WorkspaceLensKind: String] {
        get { session.searchQueries }
        nonmutating set { session.searchQueries = newValue }
    }
    /// Which lenses currently have the field revealed — per-lens for the same reason.
    private var searchExpandedLenses: Set<WorkspaceLensKind> {
        get { session.searchExpandedLenses }
        nonmutating set { session.searchExpandedLenses = newValue }
    }
    private var expanded: Set<UUID> {
        get { session.expanded }
        nonmutating set { session.expanded = newValue }
    }
    /// Duplicate sections the user has opened past their fold; see `duplicateTileRows`. Stores the
    /// unfolded set, not the folded one, so a section that grows with the next scan folds by
    /// default (the same reasoning as `RenameCategories`' toggled set).
    private var unfoldedSections: Set<DuplicateMatchType.Kind> {
        get { session.unfoldedSections }
        nonmutating set { session.unfoldedSections = newValue }
    }
    /// The group a "Find duplicates of this" handoff sent the user to, marked until they look
    /// somewhere else. A landing, not a scroll: without a mark, a reveal into a list of similar
    /// cards leaves the user to work out which one they were sent to.
    private var revealedGroupID: UUID? {
        get { session.revealedGroupID }
        nonmutating set { session.revealedGroupID = newValue }
    }
    /// The named answer a handoff put on screen, with the query it describes, so a reveal never
    /// shows a silently filtered-to-nothing list. Not cleared by the paths that could invalidate
    /// it but gated on still applying, by `DuplicateReveal.namedAnswer`: clearing would need a rule
    /// at every write path (typing, the ✕, chip removal, a scan reset, the next handoff).
    private var revealLanding: DuplicateReveal.Landing? {
        get { session.revealLanding }
        nonmutating set { session.revealLanding = newValue }
    }
    /// The reveal request this view has already acted on, so re-resolving on a groups change (or
    /// on any other re-render) does not re-clear a search the user has since typed.
    private var appliedRevealID: UUID? {
        get { session.appliedRevealID }
        nonmutating set { session.appliedRevealID = newValue }
    }
    /// Bytes reclaimed so far this Duplicates session (view-level only; see ``ReclaimTally``).
    /// Drives the "… freed this session" count-up caption on the reclaim pill.
    private var reclaim: ReclaimTally {
        get { session.reclaim }
        nonmutating set { session.reclaim = newValue }
    }
    /// Bumped on every successful resolve to flash the reclaim pill's green glow once. A token,
    /// not a Bool, so back-to-back resolves each retrigger the fade.
    private var reclaimFlashToken: Int {
        get { session.reclaimFlashToken }
        nonmutating set { session.reclaimFlashToken = newValue }
    }
    /// True once the user has filed a loose file since the current Filing scan finished, so the
    /// empty state can tell an earned "All filed" from "nothing was ever loose". Reset when a new
    /// scan starts (see `.onChange(of: isSuggestingFiles)`).
    private var filedThisSession: Bool {
        get { session.filedThisSession }
        nonmutating set { session.filedThisSession = newValue }
    }
    /// True once the user has dismissed ("Not here") a suggestion this session without filing
    /// any, so the empty state says the suggestions were cleared rather than claiming the scan
    /// found nothing. Reset when a new scan starts.
    private var dismissedThisSession: Bool {
        get { session.dismissedThisSession }
        nonmutating set { session.dismissedThisSession = newValue }
    }
    /// A just-made override the user can teach as a rule: they filed a loose file somewhere other
    /// than the suggested home, the best moment to learn. Held until they Remember or dismiss it;
    /// cleared when a new scan starts.
    private var pendingRememberPrompt: PendingRememberPrompt? {
        get { session.pendingRememberPrompt }
        nonmutating set { session.pendingRememberPrompt = newValue }
    }

    /// The shape finding whose plan sheet is open. Sheet presentation state, so it clears itself
    /// when the sheet closes.
    @State private var planningFinding: StructureFinding?

    /// What this body computed last time, and from what.
    ///
    /// The parent hands this view about thirty fresh closures, so nothing about it is `Equatable`
    /// and SwiftUI re-runs `body` on every publish, several a second during a scan. Without these
    /// memos each pass would redo the rail's counts (four scoped passes over the lists) and the
    /// scope's folder count. The key is the published arrays themselves: `Array ==` short-circuits
    /// on shared storage, so an untouched list costs a pointer compare. Keying on something
    /// cheaper (a count) would key on less than the answer depends on.
    @State private var railMemo = RenderMemo<RailCountsKey, RailCounts>()
    @State private var scopeFolderMemo = RenderMemo<ScopeFolderKey, Int?>()

    /// Everything ``railCounts`` reads.
    struct RailCountsKey: Equatable {
        let suggestions: [FilingSuggestion]
        let duplicates: [DuplicateGroup]
        let risky: [RiskyName]
        let renames: [RenamePlan]
        let structure: [StructureFinding]
        let rules: Int
        let profileRoot: String
        /// One entry per rail item, in `OrganizeLens.railItems` order: each item asks for its own
        /// applied scope, so one scope value would not be the key.
        let scopes: [OrganizeScope?]
        let hasSuggestedFiling: Bool
        let hasFoundDuplicates: Bool
        let hasScannedNames: Bool
        let hasProfile: Bool
        let filingScanFolder: String?
        let duplicateScanRoot: String?
    }

    /// Everything ``scopeFolderCount`` reads.
    struct ScopeFolderKey: Equatable {
        let scope: OrganizeScope?
        let root: String?
        /// The folder set's identity. `[String: FolderProfileEntry]` is `Equatable`, and a
        /// dictionary compare short-circuits on shared storage the way an array's does.
        let folders: [String: FolderProfileEntry]
    }

    /// One remembered answer and the inputs it was computed from. A reference type in `@State`
    /// because `body` both reads and fills it, and neither may count as a state change. Holds
    /// exactly one answer, replaced the moment its inputs differ.
    @MainActor
    final class RenderMemo<Key: Equatable, Value> {
        private var key: Key?
        private var value: Value?

        func value(for key: Key, _ make: () -> Value) -> Value {
            if let stored = value, self.key == key { return stored }
            let made = make()
            self.key = key
            value = made
            return made
        }
    }

    /// The removal step, requested for one ledger record. Candidates are resolved (and re-probed
    /// for emptiness) at request time, so the sheet opens on the truth.
    struct RemovalRequest: Identifiable {
        /// Which folders these are and how the landing is identified: the landing that drained
        /// them, or the standing empties.
        let origin: RestructureRemoval.Origin
        let family: String
        let candidates: [RestructureRemovalSheet.Candidate]
        /// The sheet's presentation id. Distinct per origin so opening the standing sheet while
        /// a landing's sheet id is remembered cannot re-present the wrong list.
        var id: String {
            switch origin {
            case .landing(let manifestId): return manifestId
            case .standing: return "standing-empties"
            }
        }
        var isStanding: Bool { origin == .standing }
    }
    @State private var removalRequest: RemovalRequest?
    /// What the last *Update the survey now* refused with, and which card asked. Shown on that
    /// card alone; cleared when any of them is pressed again.
    @State private var refreshSurveyRefusal: (subject: String, sentence: String)?
    /// A learn-by-example rule offered after the user files a loose file, turned into an editable
    /// Automation on Save. Rides in the move's result message as "Save as rule…" until saved,
    /// dismissed or the message leaves; cleared when a new scan starts.
    private var pendingRuleOffer: RuleOffer? {
        get { session.pendingRuleOffer }
        nonmutating set { session.pendingRuleOffer = newValue }
    }
    /// Which phrasing of the offered rule (narrower / balanced / broader) the user has selected.
    private var ruleVariantChoice: AutomationRuleProposer.Variant? {
        get { session.ruleVariantChoice }
        nonmutating set { session.ruleVariantChoice = newValue }
    }
    /// The just-created rule ("Remember" or "Save rule"), opened in the editor for a review pass
    /// (Cancel keeps it as created). Also backs the header card's "New rule", so a blank rule and
    /// a taught one share one editor.
    @State private var reviewingAutomationRule: AutomationRule?
    /// The Automations lens's host-owned view state. Lives here because "Preview all" rides the
    /// shared header card this view renders, and has to flip the lens into its results view.
    private var automationsState: AutomationsLensState { session.automationsState }

    private let providerName: String?
    /// The folder a rescan would target: the focused pane's current directory. Lets the lenses
    /// name the folder up front and offer a rescan when the user has navigated away from the
    /// folder the results came from.
    private let scanTargetFolder: String?
    private let onFindDuplicates: () -> Void
    private let onFindFilingSuggestions: () -> Void
    /// The same scan, ignoring saved suggestions; see `rescanFilingButton`.
    private let onFindFilingSuggestionsFresh: () -> Void
    /// Re-derives the folder memory from the tree as it stands now; see `rescanFilingButton`. nil
    /// when this machine has no filing profile, which withholds the item.
    private let onUpdateFolderMemory: (() -> Void)?
    /// Opens the app's Help overlay at a named topic.
    private let onOpenHelp: ((String) -> Void)?
    /// A menu verb aimed at a finding, waiting to be carried out here. **The menu never presents a
    /// sheet:** the request arrives as a value and this view opens its own surface, because a
    /// sheet presented from the menu would live outside the anchor that keeps it alive across a
    /// lens switch.
    @Binding private var restructureVerbRequest: RestructureVerbRequest?
    /// Opens Settings ▸ Organize's Suggestions page, where Refine is set up. nil (previews, tests)
    /// withholds the "Refine with Claude…" invitation, the honest outcome for a host with no
    /// Settings to open.
    private let onConfigureCloudRefine: (() -> Void)?
    /// Refine's click: opens its plan in the Ask Claude chat, where Send is (TE335). nil (a host with
    /// no chat) runs the pass here in one go, as before.
    private let onRefineInChat: (([FilingSuggestion]) -> Void)?
    /// Opens Settings ▸ Ask Claude ▸ Key & Spending, for a limit Refine Names would pass.
    private let onChangeLimit: (() -> Void)?
    /// The way from Organize's refined results to the chat card that holds the pass.
    private let refineChatLink: LensRefineChatLink?
    /// Applies the safe rename to the given risky names as one undoable batch.
    private let onNormalizeNames: ([RiskyName]) -> Void
    /// Applies whole folder rename plans. Takes the plans explicitly for the same reason
    /// `onNormalizeNames` does: the button's label counts what the action receives.
    private let onApplyRenames: ([RenamePlan]) -> Void
    /// Starts an Automations dry-run preview of the focused folder (the host derives the root).
    /// nil = all enabled rules; a rule id = just that rule.
    private let onPreviewAutomations: (UUID?) -> Void
    /// The provider root every lens here anchors at: the source's landing folder, not its
    /// root. The taxonomy every lens files against, scans and measures coverage from.
    ///
    /// Its consumers must not drift apart. Automations resolve destinations against it, so Browse…
    /// anchors where the preview does, and ``scope`` normalizes against it. Mixing it up with the
    /// root double-nests destinations (`Documents/Invoices` applied at `…/Documents/Documents/…`)
    /// and makes `looseFileScanCovers`, which compares by equality, never see a complete scan as
    /// covering. The root arrives separately, as ``providerRoot``.
    private let providerAnchor: String?

    /// The source's root: everything it covers, and the only thing that can bound Organize's
    /// scope. Not folded into ``providerAnchor``: a pane can sit above the landing folder, and
    /// bounding the scope at the anchor would normalize such a folder to nil, clearing the chip and
    /// turning the coverage subject into the whole tree. Only the fallback, what the surface
    /// describes when no scope is set, is the anchor, because that is what an unscoped scan
    /// enumerates.
    private let providerRoot: String?
    /// The loose-files inbox's absolute path, when the folder exists, for the offer on Organize's
    /// overview. nil hides the offer rather than showing one that points nowhere.
    private let filingInboxFolder: String?
    /// Where To File files into, with the choices for changing it. nil hides the menu: a host with
    /// no sources to offer, and tests that mount this view without one.
    private let fileInto: FileIntoChoice?
    /// Presents a Quick Look preview for a file (the same `quickLookPreview` binding the spacebar
    /// uses). nil disables the per-card Preview button.
    private let onQuickLook: ((URL) -> Void)?
    /// Builds (or rebuilds) the read-only storage picture for the focused folder. The host derives
    /// the root.
    private let onBuildStorage: () -> Void
    /// The document survey's verbs. Optional for `onUpdateFolderMemory`'s reason: a host that
    /// cannot run a survey (the CLI-driven and preview hosts) gets a card that states the position
    /// rather than a button that does nothing.
    private let onStartDocumentSurvey: (() -> Void)?
    private let onStartDocumentSurveyOver: (() -> Void)?
    private let onResumeDocumentSurvey: (() -> Void)?
    private let onPauseDocumentSurvey: (() -> Void)?
    private let onStopDocumentSurvey: (() -> Void)?
    /// What the survey card should show, worked out by the host, where `Sync` lives. nil hides the
    /// card: no profile to survey against, or a corpus already covers the tree.
    private let documentSurveyCard: DocumentSurveyCardState?
    /// Whether to show the source bar (provider dropdown + folder) above the lens. True only when
    /// the source rail is collapsed; otherwise the rail header names the provider.
    private let showSourcePicker: Bool
    /// Whether the source pane beside this column draws its tab strip (two tabs, or View ▸ Tab
    /// Bar). The strip pushes the pane's toolbar card down by ``PaneTabStripLadder/slotHeight(_:)``,
    /// so the column leaves the same slot empty above ``lensHeaderCard`` to keep the header's bottom
    /// edge on the pane's header↔list line, as `EditorWorkspaceView.paneShowsTabStrip` does.
    /// `false` whenever the rail is collapsed: there is no pane to line up with.
    private let paneShowsTabStrip: Bool
    /// The enabled providers the source can switch between, and the current one (no Left/Right).
    private let providers: [CloudProvider]
    private let currentProviderId: String
    private let onSelectProvider: (String) -> Void
    private let onManageProviders: () -> Void
    /// Picks a folder and points the lens at it as a source. nil hides "Choose Folder…".
    private let onChooseFolder: (() -> Void)?
    /// Raises the destination picker. Owned by the window, because the single-source rail asks
    /// for the same sheet and two sheets would be two pickers to keep in step. Defaults to a no-op
    /// so previews and tests can build a lens without a host.
    private let onRequestDestination: (PendingDestination) -> Void
    /// Opens two copies of a duplicate folder group in the Compare tab (keeper left, redundant
    /// right). Files go to `onCompareFilePair` instead; see `compareCopies(keep:other:in:)`.
    private let onCompareCopies: (DuplicateCopy, DuplicateCopy) -> Void
    /// Opens two copies of a duplicate FILE group in the in-window Compare Copies surface.
    private let onCompareFilePair: (DuplicateComparePair) -> Void
    /// "Open in Edit" from a duplicate copy's row menu: the app's `handOffToEditor`. nil (tests,
    /// previews) withholds the item, by `DuplicateGroupCard`'s own rule; this view only forwards it.
    private let onOpenInEditor: ((String) -> Void)?
    /// A "Find duplicates of this" handoff from a pane row: the file whose group to reveal. nil
    /// when nobody has asked. `DuplicateReveal` owns every decision this view makes about it.
    private let revealRequest: DuplicateRevealRequest?
    /// Called with a request's id once it has been answered (any non-waiting outcome), so the host
    /// can retire it. The cross-mount half of the applied-id guard: `appliedRevealID` dies with
    /// this view but the request lives at app level, so without this a round trip through Compare
    /// would remount the view with the old request standing and re-fire it, resetting the filter,
    /// overwriting the parked query and re-marking the old group on every return.
    private let onRevealHandled: ((UUID) -> Void)?
    /// "Find duplicates of `path`", the pane row's context-menu entry, for the `notScanned` empty
    /// state's recovery button. See `namedRevealState`.
    private let onFindDuplicatesOf: ((String) -> Void)?

    public init(
        syncManager: FileSyncManager,
        lens: WorkspaceLensKind,
        providerName: String? = nil,
        scanTargetFolder: String? = nil,
        onFindDuplicates: @escaping () -> Void,
        onFindFilingSuggestions: @escaping () -> Void = {},
        onFindFilingSuggestionsFresh: @escaping () -> Void = {},
        onUpdateFolderMemory: (() -> Void)? = nil,
        onConfigureCloudRefine: (() -> Void)? = nil,
        onRefineInChat: (([FilingSuggestion]) -> Void)? = nil,
        refineChatLink: LensRefineChatLink? = nil,
        onChangeLimit: (() -> Void)? = nil,
        onOpenHelp: ((String) -> Void)? = nil,
        restructureVerbRequest: Binding<RestructureVerbRequest?> = .constant(nil),
        onNormalizeNames: @escaping ([RiskyName]) -> Void = { _ in },
        onApplyRenames: @escaping ([RenamePlan]) -> Void = { _ in },
        onPreviewAutomations: @escaping (UUID?) -> Void = { _ in },
        providerAnchor: String? = nil,
        providerRoot: String? = nil,
        filingInboxFolder: String? = nil,
        fileInto: FileIntoChoice? = nil,
        onQuickLook: ((URL) -> Void)? = nil,
        onBuildStorage: @escaping () -> Void = {},
        documentSurveyCard: DocumentSurveyCardState? = nil,
        onStartDocumentSurvey: (() -> Void)? = nil,
        onStartDocumentSurveyOver: (() -> Void)? = nil,
        onResumeDocumentSurvey: (() -> Void)? = nil,
        onPauseDocumentSurvey: (() -> Void)? = nil,
        onStopDocumentSurvey: (() -> Void)? = nil,
        showSourcePicker: Bool = false,
        paneShowsTabStrip: Bool = false,
        providers: [CloudProvider] = [],
        currentProviderId: String = "",
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        onChooseFolder: (() -> Void)? = nil,
        onCompareCopies: @escaping (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in },
        onCompareFilePair: @escaping (DuplicateComparePair) -> Void = { _ in },
        onOpenInEditor: ((String) -> Void)? = nil,
        onRequestDestination: @escaping (PendingDestination) -> Void = { _ in },
        revealRequest: DuplicateRevealRequest? = nil,
        onRevealHandled: ((UUID) -> Void)? = nil,
        onFindDuplicatesOf: ((String) -> Void)? = nil,
        initialSearchQueries: [WorkspaceLensKind: String] = [:],
        session: LensWorkspaceSession? = nil
    ) {
        self.syncManager = syncManager
        // The one seam into `searchQueries`, which is otherwise seeded empty and reachable only by
        // typing. It lets tests drive what depends on a live query: what the header counts, what
        // the field shows, which page answers. The app passes nothing. Same shape as
        // `SettingsRail.versionText`.
        //
        // Seeded inside the `@StateObject` autoclosure, so it runs once, on first mount. Outside
        // it, a host-supplied session would have its live queries overwritten by the (empty) seed
        // on every re-render, silently clearing a parked query.
        _session = StateObject(wrappedValue: Self.startingSession(session, seed: initialSearchQueries))
        self.lens = lens
        self.providerName = providerName
        self.scanTargetFolder = scanTargetFolder
        self.onFindDuplicates = onFindDuplicates
        self.onFindFilingSuggestions = onFindFilingSuggestions
        self.onFindFilingSuggestionsFresh = onFindFilingSuggestionsFresh
        self.onUpdateFolderMemory = onUpdateFolderMemory
        self.onOpenHelp = onOpenHelp
        self._restructureVerbRequest = restructureVerbRequest
        self.onConfigureCloudRefine = onConfigureCloudRefine
        self.onRefineInChat = onRefineInChat
        self.refineChatLink = refineChatLink
        self.onChangeLimit = onChangeLimit
        self.onNormalizeNames = onNormalizeNames
        self.onApplyRenames = onApplyRenames
        self.onPreviewAutomations = onPreviewAutomations
        // The anchor falls back to the root, and only the anchor: a caller naming one folder means
        // root and landing folder are the same place (iCloud, every folder source, single-root
        // fixtures). The app passes both, pinned by
        // `theLensWorkspaceGetsTheAnchorAndTheRootSeparately`.
        self.providerAnchor = providerAnchor ?? providerRoot
        self.providerRoot = providerRoot
        self.filingInboxFolder = filingInboxFolder
        self.fileInto = fileInto
        self.onQuickLook = onQuickLook
        self.onBuildStorage = onBuildStorage
        self.documentSurveyCard = documentSurveyCard
        self.onStartDocumentSurvey = onStartDocumentSurvey
        self.onStartDocumentSurveyOver = onStartDocumentSurveyOver
        self.onResumeDocumentSurvey = onResumeDocumentSurvey
        self.onPauseDocumentSurvey = onPauseDocumentSurvey
        self.onStopDocumentSurvey = onStopDocumentSurvey
        self.showSourcePicker = showSourcePicker
        self.paneShowsTabStrip = paneShowsTabStrip
        self.providers = providers
        self.currentProviderId = currentProviderId
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self.onChooseFolder = onChooseFolder
        self.onCompareCopies = onCompareCopies
        self.onCompareFilePair = onCompareFilePair
        self.onOpenInEditor = onOpenInEditor
        self.onRequestDestination = onRequestDestination
        self.revealRequest = revealRequest
        self.onRevealHandled = onRevealHandled
        self.onFindDuplicatesOf = onFindDuplicatesOf
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    /// Which of Organize's lenses is on screen; `nil` for the overview. Persisted, because a rail
    /// item is a place the user chose. See ``OrganizeLens`` for why the items are permanent while
    /// their badges are not.
    @AppStorage(OrganizeLens.defaultsKey) private var railLens: OrganizeLens?

    /// The scope's stored path. Empty is the global view, the default. Persisted like the rail
    /// lens: scoping to the `TODO` inbox once should survive the next launch.
    ///
    /// Stored as a bare path, not an encoded ``OrganizeScope``, because the provider root it is
    /// validated against isn't known at decode time. ``scope`` re-resolves on every access, so a
    /// stale path from another provider degrades to the global view instead of emptying every lens.
    @AppStorage(OrganizeScopeDefaults.pathKey) private var scopePathRaw: String = ""

    /// The subtree the user has pointed Organize at, whether or not the lens on screen applies
    /// it. Every writer and readout of the chip goes through this; the lists go through
    /// ``scope``. Re-resolved, not stored: `init?` rejects the provider root and anything outside
    /// it, so a scope left over from another provider becomes nil here.
    private var storedScope: OrganizeScope? {
        guard let providerRoot, !providerRoot.isEmpty, !scopePathRaw.isEmpty else { return nil }
        return OrganizeScope(path: scopePathRaw, providerRoot: providerRoot)
    }

    /// The scope one named lens applies: the stored one, or nil where ``OrganizeLens/isScoped``
    /// says the lens is not narrowed by a folder. Per-lens because the rail draws all six badges at
    /// once (see ``railCounts``); `nil` (the overview) is scoped, as it summarises the five.
    ///
    /// The suspension is a read, not a write: `scopePathRaw` is untouched, so leaving Rules puts the
    /// scope back with no restore step to forget.
    private func appliedScope(for item: OrganizeLens?) -> OrganizeScope? {
        (item?.isScoped ?? true) ? storedScope : nil
    }

    /// The subtree the lists on screen are narrowed by, or nil for the global view.
    private var scope: OrganizeScope? { appliedScope(for: organizeLens) }

    /// Whether a scope is set and the lens on screen deliberately isn't applying it: the chip's
    /// suspended state.
    private var scopeIsSuspended: Bool { scope == nil && storedScope != nil }

    /// Points Organize at a folder, or clears the scope, from this workspace's entry points: the
    /// "Scan '<folder>'" re-aim, the inbox shortcut, the chip's ✕, the scoped empty state's
    /// "Organize Everything", and the duplicate-reveal handoff.
    ///
    /// Normalizing lives in ``OrganizeScope/normalizedPath(_:providerRoot:)``, not here, because
    /// the folder context menu and ⌘K write the same persisted ``OrganizeScopeDefaults/pathKey``
    /// through `ContentView.setOrganizeScope(_:)`. One rule keeps the global view from having two
    /// encodings. A nil and an empty `providerRoot` both mean no scope (`""`).
    private func setScope(_ path: String?) {
        scopePathRaw = OrganizeScope.normalizedPath(path, providerRoot: providerRoot)
    }

    /// The Restructure → To File hand-off: a backlog or loose-files finding's per-file half goes
    /// to the lens that judges files one at a time, scoped to the finding's subject and no wider.
    private func handOffToToFile(_ finding: StructureFinding) {
        guard let root = syncManager.filingFolderProfile?.root else { return }
        let expanded = (root as NSString).expandingTildeInPath
        setScope((expanded as NSString).appendingPathComponent(finding.subject))
        railLens = .toFile
    }

    /// The rail selection. Read unguarded: Storage is a rail item, so `railLens == .storage` is the
    /// selection, not a value parked by another workspace.
    private var organizeLens: OrganizeLens? {
        railLens
    }

    /// Whether the rail can spell its items out at this width; see ``OrganizeRailMetrics``. Stored
    /// as the answer, not a width, so state is written only when the answer flips during a resize.
    @State private var railStyle: OrganizeRailStyle = .full
    /// The workspace is too narrow for row 2's buttons side by side: Rescan and Refine go into one ⋯
    /// menu and File All stays. Measured on the probe below, with the text size.
    @State private var rowTwoCompact = false
    /// Where row 2's buttons stop fitting at the default text size, scaled by it.
    private static let compactActionsWidth: CGFloat = 520

    /// Which of Storage's ranked lists the rail is showing, or absent for all three. Optional
    /// for ``OrganizeLens/defaultsKey``'s reason: there is no value to write for "none picked".
    @AppStorage(StorageSection.defaultsKey) private var storageSection: StorageSection?


    /// Whether Organize is showing its overview: every lens's answer for the scope, on one page.
    /// The rail's unselected state rather than a seventh item, so it is where you land, not a tab
    /// you forget to visit.
    private var showingOverview: Bool {
        railLens == nil
    }

    /// Whether the content card is drawing the overview, which differs from ``showingOverview``.
    /// That one means no rail item is selected; the overview is drawn only from `contentCard`'s
    /// `.filing` arm, so a `.duplicates` view with no rail selection draws a group list. Asked
    /// once here so the rows, the query and the readout answer it the same way.
    private var overviewIsOnScreen: Bool { showingOverview && effectiveLens == .filing }

    /// The lens whose grammar, pills, actions and content are on screen right now.
    ///
    /// `lens` is where you are (the workspace); this is what you are looking at (the rail item).
    /// Search grammars, parked queries and scroll state key on this, and three rail items share
    /// `.filing`'s because their rows are filing rows. The header title stays Organize.
    private var effectiveLens: WorkspaceLensKind {
        organizeLens?.searchLens ?? lens
    }

    /// True when Organize is showing the rename backlog rather than the queue. Not a
    /// `WorkspaceLensKind` of its own: its rows are folder plans, so it borrows `.filing`'s query
    /// slot and the content card branches on it.
    private var showingRenameBacklog: Bool {
        organizeLens == .renames
    }

    // MARK: Search state

    /// This lens's query, written through to `searchQueries` so a lens switch parks it rather than
    /// carrying it into a grammar that reads it differently. Reads ``query``, so the overview reads
    /// back the empty string it answers with, and drops writes: nothing there may edit a query
    /// belonging to a list it isn't showing.
    private var searchText: Binding<String> {
        Binding(get: { query },
                set: { text in
                    guard !overviewIsOnScreen else { return }
                    searchQueries[effectiveLens] = text
                })
    }

    /// Whether the search field is open, per lens. False on the overview, which answers no query
    /// (see ``query``): it shares `.filing`'s key, so a field left open on To File would otherwise
    /// reappear over a page that filters nothing. `LensHeaderCard` takes `showsSearch:` and this
    /// header passes false for the overview and for Storage before a report, so there is no toggle
    /// there to click.
    private var isSearchExpanded: Binding<Bool> {
        Binding(
            get: { !overviewIsOnScreen && searchExpandedLenses.contains(effectiveLens) },
            set: { expanded in
                if expanded { searchExpandedLenses.insert(effectiveLens) } else { searchExpandedLenses.remove(effectiveLens) }
            }
        )
    }

    /// What this page is narrowed by, empty whenever the page answers no query.
    ///
    /// The overview is that page: it filters nothing, and borrows `.filing`'s slot, which belongs
    /// to To File. Returning empty removes its chips (``searchChips``), its field (``searchText``)
    /// and its "N of M" (``isFiltered``). The parked query is not cleared: it is To File's, and
    /// is waiting there when you go back.
    private var query: String { overviewIsOnScreen ? "" : (searchQueries[effectiveLens] ?? "") }
    /// True when this lens's list is narrowed by anything: the cue for the "N of M" readout.
    private var isFiltered: Bool {
        !query.isEmpty || filterIsNarrowing
    }

    /// True when the type filter, as opposed to a query, is narrowing this lens's list. Its own
    /// member so the three places that ask, including `noMatchesState` choosing which cause to
    /// name, can't get out of step.
    private var filterIsNarrowing: Bool { effectiveLens == .duplicates && filter != .all }

    /// The parsed tokens of this lens's query, as chips. Each lens's own grammar answers, so a
    /// chip is only ever offered for a token that lens can actually bind.
    private var searchChips: [TokenChipsRow.Item] {
        func items<C: DimmableTokenChip>(_ chips: [C], label: (C) -> String, word: (C) -> String) -> [TokenChipsRow.Item] {
            chips.map { TokenChipsRow.Item(label: label($0), word: word($0), isActive: $0.isActive) }
        }
        switch effectiveLens {
        case .duplicates:
            return items(DuplicateSearch.chips(query), label: \.label, word: \.raw)
        case .filing where showingRenameBacklog:
            return []      // free text only — see `RenameBacklogSearch`
        case .filing:
            return items(FilingSearch.chips(query), label: \.label, word: \.raw)
        case .automations:
            return items(AutomationSearch.chips(query), label: \.label, word: \.raw)
        case .storage:
            return items(StorageSearch.chips(query), label: \.label, word: \.raw)
        }
    }

    /// A chip's ✕ edits its exact word back out of this lens's raw query. Keyed on `effectiveLens`,
    /// not `lens`: inside Organize `lens` is `.filing` whatever the rail shows, so read and write
    /// must name the same slot or the ✕ removes nothing and corrupts a query the user can't see.
    private func removeSearchChip(_ word: String) {
        searchQueries[effectiveLens] = TokenQuery.removing(query, word: word)
    }

    // MARK: Filtered rows

    /// One lens's rows after its own search, resolved once per render in `body` and handed to both
    /// the header card and the content below. A safety property, not an optimization: the header
    /// labels a destructive button with the count ("Trash all 3") and the action iterates this same
    /// array. Recomputing either from an unfiltered source would destroy items the user can't see.
    private struct FilteredRows {
        var duplicates: [DuplicateGroup] = []
        var risky: [RiskyName] = []
        var filing: [FilingSuggestion] = []
        var rules: [AutomationRule] = []
        var renames: [RenamePlan] = []
        /// Restructure's findings, split by how they relate to the scope. Two arrays because its
        /// rows have two honest kinds and the second must not be silently dropped; see
        /// ``ScopeRelation``.
        var structure: [StructureFinding] = []
        var structureAboutAncestor: [StructureFinding] = []
    }

    /// Resolves only the active lens's rows; each of these parses a query and walks a collection.
    /// The scope is applied here, ahead of the search, so header counts, destructive button
    /// labels and the action that iterates them all see one narrowed set. Applying it downstream
    /// would put the count and the list out of step.
    private var filteredRows: FilteredRows {
        var rows = FilteredRows()
        let scope = scope
        // The overview reads none of these (it renders `overviewSections`), so skip the work. Guard
        // on ``overviewIsOnScreen``, not `showingOverview`: a `.duplicates` view with no rail
        // selection still draws its group list and needs these rows, and an empty `FilteredRows`
        // would paint nothing.
        guard !overviewIsOnScreen else { return rows }
        switch effectiveLens {
        case .duplicates:
            let q = DuplicateSearch.parse(query)
            rows.duplicates = syncManager.duplicateGroups.filter {
                OrganizeScopeFilter.matches($0, scope: scope) && filter.matches($0) && q.matches($0)
            }
        case .filing where showingRenameBacklog:
            rows.renames = syncManager.renamePlans.filter {
                OrganizeScopeFilter.matches($0, scope: scope)
                    && RenameBacklogSearch.matches(query, $0)
            }
            // The to-fix rows are part of this list, so they go through the same filter: one list
            // narrowed two ways would put the badge, the readout and the rows on screen out of step.
            rows.risky = syncManager.riskyNames.filter {
                OrganizeScopeFilter.matches($0, scope: scope)
                    && RenameBacklogSearch.matches(query, $0)
            }
        case .filing where organizeLens == .restructure:
            // Restructure has no search grammar of its own (it parks in `.filing`'s slot; see
            // `OrganizeLens.searchLens`), so the scope is the only narrowing here.
            let root = syncManager.filingFolderProfile?.root ?? ""
            for finding in structureFindings {
                switch OrganizeScopeFilter.relation(of: finding, profileRoot: root, scope: scope) {
                case .inside: rows.structure.append(finding)
                case .aboutAncestor: rows.structureAboutAncestor.append(finding)
                case .outside: break
                }
            }
        case .filing:
            let q = FilingSearch.parse(query)
            // Filtered upstream of FilingSuggestionGrouping: the sections derive from these rows,
            // so an emptied tier's header falls away with it.
            rows.filing = syncManager.filingSuggestions.filter {
                OrganizeScopeFilter.matches($0, scope: scope) && q.matches($0)
            }
        case .automations:
            let q = AutomationSearch.parse(query)
            // The query narrows this list and the scope does not: `scope` is already nil here,
            // because Rules are configuration (`OrganizeLens.isScoped` is false), so a scope test
            // would be an inert call that reads like a live rule.
            rows.rules = syncManager.automationRules.filter { q.matches($0) }
        case .storage:
            break   // StorageLensView filters its own three lists from `storageQuery`
        }
        return rows
    }

    /// Storage's parsed query. Its report holds three ranked lists and `StorageLensView` brings its
    /// own content card, so the query goes down and the lists are filtered there; see
    /// `StorageSearch` for why the treemap stays whole.
    private var storageQuery: StorageSearch.Query { StorageSearch.parse(query) }

    /// "N of M" for Storage, over the lists the body is showing, and nil before there is a report.
    ///
    /// Nil, not `(0, 0)`: a storage lens that hasn't run can't claim there are no large files.
    /// The rail selection narrows which lists count and the query narrows within them, so N is the
    /// rows on screen and M the selected section before the query; summing all three lists would
    /// give a denominator from lists not on screen.
    private var storageCounts: (filtered: Int, total: Int)? {
        guard let report = syncManager.storageLensReport else { return nil }
        let q = storageQuery
        return StorageSection.counts(in: report, section: storageSection) { q.matches($0) }
    }

    /// Per-filter group counts for the filter menu's badges, in one pass over the groups.
    ///
    /// Counted over all groups, not the search-narrowed ones, so a badge never reads zero for a
    /// filter that would reveal rows. But counted within the scope, which decides which list this
    /// is: a global count would offer "Identical (620)" beside a lens holding 27. The scope test
    /// folds into the same pass, because this runs on every render (see `filterMenu`).
    private static func filterCounts(_ groups: [DuplicateGroup],
                                     scope: OrganizeScope?) -> [DuplicateMatchFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: DuplicateMatchFilter.allCases.map { ($0, 0) })
        for group in groups where OrganizeScopeFilter.matches(group, scope: scope) {
            for f in DuplicateMatchFilter.allCases where f.matches(group) { counts[f, default: 0] += 1 }
        }
        return counts
    }
    private var hasResults: Bool { !syncManager.duplicateGroups.isEmpty }

    public var body: some View {
        // Resolve this lens's rows once and hand the same value to the header and the content;
        // see `FilteredRows`.
        let rows = filteredRows
        // The rail's six counts, resolved once (see `RailCounts`) for both the width arithmetic
        // below and each rail item's badge.
        let counts = railCounts
        // Resolved here, not in the chip, so the header pays one walk of the profile's folder list
        // per render rather than one per redraw of row 2.
        let scopeFolders = scopeFolderCount
        // Measured once per body: this reads type metrics, while the geometry transform below runs
        // on every width the card is handed. It is everything row 1's leading half must seat (the
        // rail alone today); anything put beside it must be counted in `leadingWidth` too.
        let railLeading = OrganizeRailMetrics.leadingWidth(scale: appFontScale, state: counts.state)
        let compactBelow = Self.compactActionsWidth * appFontScale
        return VStack(spacing: 0) {
            // The shedding rule is measured here, on a zero-height probe, not on the card. A card
            // whose row can't compress draws at the width it needs and overflows, and
            // `.onGeometryChange` reports that width, not the one offered
            // (`theCardReportsTheWidthItDrewAtNotTheWidthItWasOffered`), so the rail would never
            // shed. A zero-height `Color.clear` takes the width the VStack was proposed, the
            // workspace column, and no sibling can widen it. That is why `style(columnWidth:)`
            // charges the card's own inset and padding on top of the search toggle.
            Color.clear
                .frame(height: 0)
                // The style, not the width: `.onGeometryChange` calls its action only when the
                // transformed value changes, so a live resize writes state once each way. The
                // workspace bar resolves its shedding the same way.
                .onGeometryChange(for: OrganizeRailStyle.self) { proxy in
                    OrganizeRailMetrics.style(columnWidth: proxy.size.width,
                                              leadingWidth: railLeading)
                } action: { railStyle = $0 }
                .onGeometryChange(for: Bool.self) { $0.size.width < compactBelow } action: { rowTwoCompact = $0 }
            // The header card heads the workspace in every lens and state, so its bottom edge lands
            // on 83.5, the file pane's header/list boundary. The `sourceBar` sits below it, and
            // appears only when the source rail is collapsed.
            //
            // Under the pane's tab strip, the strip's slot is left empty (`paneShowsTabStrip`) so
            // that edge stays on the pane's line, as Edit's document column does. In `.cards` it is
            // a gap above the header card; in `.unified` a clear band inside this column's region
            // (`PaneTabStripLadder.slotHeight`).
            Color.clear.frame(height: paneShowsTabStrip ? PaneTabStripLadder.slotHeight(surfaceStyle) : 0)
            lensHeaderCard(rows: rows, counts: counts, scopeFolders: scopeFolders)
            // The reading is a long background job and its card lives on one lens; the strip is
            // how the other five show it running. Padded like `sourceBar`, below the header card,
            // whose 81pt this must not touch.
            if let documentSurveyCard, DocumentSurveyStrip.isShown(for: documentSurveyCard) {
                DocumentSurveyStrip(state: documentSurveyCard,
                                    accent: glassHue.accentColor,
                                    onResume: onResumeDocumentSurvey,
                                    onPause: onPauseDocumentSurvey,
                                    onStop: onStopDocumentSurvey)
                    // The source bar's own inset, so the strip lines up with the row below it.
                    .padding(.horizontal, sectionInset + 12)
                    .padding(.top, stripGap)
            }
            // A tree placed by name, or one whose folders are being learned.
            if effectiveLens == .filing, organizeLens == .toFile, !syncManager.isSuggestingFiles,
               FilingSurveyStrip.isShown(syncManager) {
                FilingSurveyStrip(syncManager: syncManager, sources: filingSurveySources,
                                  accent: glassHue.accentColor, onRescan: onFindFilingSuggestions)
                    .padding(.horizontal, sectionInset + 12)
                    .padding(.top, stripGap)
            }
            if showSourcePicker { sourceBar }
            lensBody(rows: rows, counts: counts, scopeFolders: scopeFolders)
        }
        // One region in Unified, two cards in Cards, the rule every workspace column follows (see
        // `columnSectionCard`). In Unified the content starts flush under the header's hairline at
        // the same 83.5 the file pane's list does.
        .columnRegionFrame(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        // Review-after-create: a rule just learned from "Remember" (or saved from "Save rule")
        // opens in its editor. Cancel keeps it as created; the review is an offer, not a gate.
        // The offer is answered from the result message's popover, which hands the rule over here.
        .onReceive(session.$ruleAwaitingReview) { rule in
            guard let rule else { return }
            reviewingAutomationRule = rule
            session.ruleAwaitingReview = nil
        }
        .sheet(item: $reviewingAutomationRule) { rule in
            AutomationRuleEditor(
                rule: rule,
                accent: glassHue.accentColor,
                browseRoot: providerAnchor.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                people: syncManager.filingPeopleStore?.people ?? [],
                onSave: { saved in
                    syncManager.upsertAutomationRule(saved)
                    reviewingAutomationRule = nil
                },
                onCancel: { reviewingAutomationRule = nil }
            )
            .presentedNativeControlAccent()
        }
        // A fresh filing scan starts a fresh session: forget files filed against the previous
        // results, so "All filed" is earned only by this scan's work. The search resets in the
        // same `isSuggestingFiles` handler below, not a second one, so there is one scan-start
        // handler to find.
        .onChange(of: syncManager.isSuggestingFiles) { _, isScanning in
            if isScanning {
                filedThisSession = false
                dismissedThisSession = false
                pendingRememberPrompt = nil   // a new scan retires any dangling teach prompt
                pendingRuleOffer = nil
                searchQueries[.filing] = ""
                // The rail selection is not moved. A rail item can't vanish, so standing on
                // Renames while its scan re-runs is fine: the list says it is scanning, then
                // refills. Moving it would be wrong, because the auto-rescan fires as Organize
                // appears and would yank a restored selection to To File on every launch. Only the
                // parked query goes, because it described the previous scan's rows.
            }
        }
        // A fresh Duplicates scan starts a fresh reclaim session, so "… freed this session" counts
        // only the current results' work. The search and the type filter reset too, since either
        // one left over would silently pre-filter the new groups. The list lives in
        // ``DuplicateScanReset`` so it can be tested.
        .onChange(of: syncManager.isFindingDuplicates) { _, isScanning in
            if isScanning {
                DuplicateScanReset.duplicatesScanStarted(filter: &filter,
                                                    searchQuery: &searchQueries[.duplicates, default: ""],
                                                    reclaim: &reclaim)
                // A landing belongs to the results it landed in. Both of these name a group or file
                // from the previous scan, so they retire with it rather than marking a card nobody
                // was sent to, or claiming "no duplicates of X" about an answer being recomputed.
                revealedGroupID = nil
                revealLanding = nil
            }
        }
        // The handoff from a pane row's "Find duplicates of this".
        //
        // `.task(id:)`, not `.onChange`: the switch into Duplicates mounts this view, so for the
        // request that caused it there is no change to observe, and `.onChange` would miss the
        // first reveal. The key carries the scan state too, so a request made mid-scan resolves
        // when the results land (`DuplicateReveal.outcome` answers `.waiting` until then).
        // `groupCount` and `scanRoot` stand in for the results; re-resolving is harmless because
        // `appliedRevealID` makes applying a plan idempotent.
        .task(id: revealKey) { applyRevealRequest() }
        // Storage keeps its own reset. Names have none here: the Filing scan produces them, so the
        // reset rides `isSuggestingFiles` above with the rest of that scan's session state.
        .onChange(of: syncManager.isBuildingStorageLens) { _, isBuilding in
            if isBuilding { searchQueries[.storage] = "" }
        }
    }

    // MARK: Header card

    /// The one header of this workspace: the rail on row 1, what the lens found and its controls on
    /// row 2, and the search below. 81pt at rest, in every lens and every state, including intro,
    /// scanning, empty and clean, so the rail never moves when a scan lands.
    private func lensHeaderCard(rows: FilteredRows, counts: RailCounts,
                                scopeFolders: Int?) -> some View {
        LensHeaderCard(
            searchText: searchText,
            isSearchExpanded: isSearchExpanded,
            // The backlog borrows `.filing`'s lens but not its grammar, so not its placeholder
            // either: that one advertises `confidence:` and `to:` tokens this list doesn't bind.
            searchPlaceholder: showingRenameBacklog
                ? "Search folders and names — PG&E, 2021…"
                : LensSearch.placeholder(for: effectiveLens),
            searchHelp: showingRenameBacklog
                ? "Search the rename backlog by folder or by file name"
                : LensSearch.help(for: effectiveLens),
            // The two pages that answer no query don't offer the control: the overview filters
            // nothing (see ``query``), and Storage before its analysis has no lists to narrow.
            // Storage's test is `hasStorageReport`, the same one ``storageCounts`` asks before it
            // will report "N of M".
            showsSearch: !overviewIsOnScreen
                && !(effectiveLens == .storage && !hasStorageReport),
            chips: searchChips,
            onRemoveChip: removeSearchChip,
            accent: glassHue.accentColor,
            surfaceStyle: surfaceStyle,
            level: glassLevel,
            hue: glassHue,
            tint: surfaceTint,
            title: { lensTitle(counts) },
            // Row 1's trailing half is empty on purpose: the lens's controls live on row 2 (see
            // ``lensTrailing``). `LensHeaderCard` appends the search toggle itself, so row 1 is the
            // rail and one 30pt button.
            actions: { EmptyView() },
            summary: { lensSummary(rows: rows, counts: counts, scopeFolders: scopeFolders) },
            trailing: { lensTrailing(rows: rows, counts: counts) }
        )
    }

    /// Row 1 of the header card: navigation, not a name. The workspace bar already says
    /// "Organize", and a fixed 81pt header can't afford to repeat it, so the row goes to the rail,
    /// which names where you are more precisely (the ringed item is the lens, not just the
    /// workspace).
    @ViewBuilder
    private func lensTitle(_ counts: RailCounts) -> some View {
        // Scrolls only when even the glyph rung doesn't fit, which is reachable: the column's
        // floor is 340pt (`singleSourceLayout`), the source pane is draggable, and an icon-only rail
        // with six three-digit badges measures about 475pt at the largest text size. An `HStack`
        // out of room draws over its neighbours. `.basedOnSize` keeps it still wherever the rail
        // fits; the indicator is off because a 27pt row can't spare it.
        //
        // The second half of a pair: the probe in `body` decides which rung to draw, and this keeps
        // the drawn rung from overflowing whatever that decision was. With no indicator, the
        // selected rung is scrolled into view whenever it changes, so the chosen item is never the
        // one cut in half. An edge fade mask is not an option: it dims the leading item ("All",
        // usually selected) and throws `OrganizeRailTests`' leading model off the drawn row.
        ScrollViewReader { rail in
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
            // One rail. Storage is a rail item, and its sections live in the content card as a
            // capsule (`StorageSectionBar`); two rails shedding by different rules is what
            // `OrganizeRailMetrics` warns against. Storage's readout stays off row 1: it is prose
            // whose width depends on the data, and it truncates to a bare glyph there.
            organizeRail(counts)
            }
            // Frosted and Clear: the selected item's wash and ring as one glass lens that glides
            // between items. Inside the scroll view, so it scrolls with them.
            .selectionLensHost(Self.railLensChannel, selected: selectedRailItemID, style: railLensStyle,
                               visibleRegion: railVisibleRegion)
            // Frosted and Clear: a count arrives rather than appears whenever which items report
            // changes on screen (a scan finishing, the scope moving). Keyed on the row, so the item
            // and the neighbours it pushes move together, and outside the lens's host, so the lens
            // rides the same spring as its item instead of snapping. Only a change animates: a rail
            // drawn already reporting shows its badges at rest.
            .transaction(value: Self.reportingItems(counts)) { transaction in
                guard railCountsArrive else { return }
                transaction.animation = SelectionLensArrival.change(reduceMotion: reduceMotion)
            }
        }
        .selectionLensTracksVisibleRegion(railVisibleRegion)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .onChange(of: selectedRailItemID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.18)) { rail.scrollTo(id, anchor: .center) }
        }
        .onAppear {
            guard let id = selectedRailItemID else { return }
            rail.scrollTo(id, anchor: .center)
        }
        }
    }

    /// The rail's selection lens in Frosted and Clear; see `SelectionLens`.
    static let railLensChannel = SelectionLensChannel("organize.rail")

    /// Whether a count arrives rather than appears: the glass levels, where the rail draws a lens.
    /// The same answer the rail's host gives its items, so a badge's transition and its animation
    /// can't disagree.
    private var railCountsArrive: Bool {
        SelectionLensRule.material(for: lensAppearance, reduceTransparency: reduceTransparency) != .today
    }

    /// The rail items that wear a count, in rail order: what a count arriving or leaving changes.
    static func reportingItems(_ counts: RailCounts) -> [Bool] {
        OrganizeLens.railItems.map {
            if case .reporting = counts.state($0) { return true }
            return false
        }
    }

    /// What the selected item wears today, as a lens: its wash and its 2pt ring.
    private var railLensStyle: SelectionLensStyle {
        SelectionLensStyle(shape: .capsule, color: glassHue.accentColor,
                           markerOpacity: RailItemLabel.selectedWash,
                           ring: .init(color: glassHue.accentColor, width: RailItemLabel.ringWidth))
    }

    /// The scroll handle for one rail item, and the identity `selectedRailItemID` names. One
    /// expression for both ends of the lookup, so a handle and what scrolls to it can't come to
    /// mean different items.
    static func railItemID(organizeLens: OrganizeLens?) -> String {
        "rail-organize-\(organizeLens?.id ?? "all")"
    }

    /// The source bar shown above the lens while the rail is collapsed: the provider dropdown (the
    /// one provider choice the lens workspace needs) and the folder being tidied.
    private var sourceBar: some View {
        let provider = providers.first(where: { $0.id == currentProviderId })
        return HStack(spacing: 8) {
            Text("Source")
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // Logo outside the Menu label: a resizable image inside one balloons under fixedSize.
                if let provider {
                    ProviderLogo(provider.imageName, size: 16)
                }
                ProviderMenu(providers: providers, currentId: currentProviderId,
                             onSelect: onSelectProvider, onManage: onManageProviders,
                             onChooseFolder: onChooseFolder) {
                    Text(provider?.displayName ?? "Provider")
                        // `Text.scaledFont(_:scale:)`, not the View modifier: a `Menu` label is
                        // drawn by AppKit, which reads a Text's own font but ignores the
                        // environment one a modifier would set. See `PaneHeader.providerCapsule`.
                        .scaledFont(.system(size: 12, weight: .semibold), scale: appFontScale)
                        .contentShape(Rectangle())
                }
                .help("Switch which cloud you’re organizing")
            }
            .pillSurface(.mini, tint: .secondary)
            // Frosted and Clear: glass under the pill's wash, as under the breadcrumb's source
            // pill. The pill strokes its own hairline, so Clear adds no rim.
            .chromeGlassGround(.capsule, rim: false)
            if let folder = scanTargetFolder, !folder.isEmpty {
                Image(systemName: "chevron.right").scaledFont(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text((folder as NSString).lastPathComponent)
                    .scaledFont(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Line this strip up with the card content below: a card sits `cardInset` in from the
        // region edge and pads its contents by 12, so matching both puts the text on the same
        // vertical rule. In Unified there is no card to sit in from (`sectionInset` is 0).
        .padding(.horizontal, sectionInset + 12)
        .padding(.top, stripGap)
        // Half a gutter in Cards, where the card below insets by the other half, so the gap comes
        // to exactly `cardGutter`. A whole one in Unified, where nothing below insets (`stripGap`).
        .padding(.bottom, stripGap)
    }

    /// How far a section's edge sits in from the column's: `cardInset` in Cards, where each
    /// section is a card that insets itself, and 0 in Unified, where the column is one area and
    /// its sections run edge to edge inside it (`columnSectionCard`).
    private var sectionInset: CGFloat {
        surfaceStyle == .cards ? LiquidGlass.cardInset : 0
    }

    /// The air above and below the strips between the header and the content. Half a gutter in
    /// Cards, where the neighbouring card's inset is the other half; the whole gutter in Unified,
    /// where there is no card inset and the strip sits under the header's hairline.
    private var stripGap: CGFloat {
        surfaceStyle == .cards ? LiquidGlass.cardInset : LiquidGlass.cardGutter
    }

    /// This lens's action controls, in the order the deck draws them. Each lens's controls are
    /// gated on having something to act on, but the card is not, so an empty row keeps the rail
    /// and the height where they are.
    @ViewBuilder
    private func lensActions(rows: FilteredRows) -> some View {
        switch effectiveLens {
        case .duplicates:
            if hasResults, !syncManager.isFindingDuplicates {
                filterMenu
                rescanDuplicatesButton
                applyAllButton(rows.duplicates)
            }
        // Both of Organize's states, through one path.
        case .filing:
            if !syncManager.isSuggestingFiles {
                // Rescan belongs to the scan, not to any one of its answers, so it survives an
                // emptied queue: file everything and Organize still offers a way to look again.
                // Gated on the filing scan having finished once, the condition under which
                // rescanning means anything; before that the intro state owns the invitation.
                // Two buttons behind one name: see ``showsFilingControl`` for Rescan's gate and
                // where the moved branch stands down.
                if rowTwoCompact, organizeLens == .toFile, !filingTargetMoved {
                    // Narrow: one ⋯ menu for Rescan and Refine, and File All beside it.
                    compactToFileActions(rows.filing)
                } else {
                if showsFilingControl {
                    rescanFilingButton
                }
                // The apply actions stay with their own list: each acts on the rows on screen, so
                // each is gated on there being some and handed the filtered rows, for the reason
                // `applyAllButton` gives: the label counts what the action receives.
                switch organizeLens {
                case .toFile:
                    if hasFilingResults {
                        refineButton(rows.filing)
                        fileAllButton(rows.filing)
                    }
                case .renames:
                    // Gated on the backlog existing, handed what is showing: a query leaving 3 of
                    // 129 folders on screen must rename exactly those 3.
                    if !syncManager.renamePlans.isEmpty { renameAllButton(rows.renames) }
                // The overview has no apply-all: up here it would have to mean one of six things.
                // Each section's own button is one click away. Storage has none either: no verb of
                // its touches a file, and its one action, Rescan, is on row 2.
                case .none, .duplicates, .restructure, .rules, .storage:
                    EmptyView()
                }
                }
            }
        case .automations:
            if !syncManager.automationRules.isEmpty {
                newRuleButton
                previewAllButton
            }
        case .storage:
            if hasStorageReport, !syncManager.isBuildingStorageLens {
                reanalyzeStorageButton
            }
        }
    }

    /// Row 2's leading content: the folder these results are for, then what this lens found.
    /// While a query is live that is the filter's readout (12 groups → 3 as you type), which is
    /// why the search field grows the card rather than covering this row.
    ///
    /// Organize draws its readout as text rather than pills (``SummaryRun``), because its row also
    /// carries controls and the two must stay distinguishable. The other lenses have nothing
    /// clickable here, so pills are fine.
    @ViewBuilder
    private func lensSummary(rows: FilteredRows, counts: RailCounts, scopeFolders: Int?) -> some View {
        // The scope chip draws for every Organize lens, so it sits ahead of the switch rather than
        // inside one arm: one subject for all six lenses is the premise, and a lens missing the
        // chip would claim to answer about the whole tree. Storage honours it by re-analysing at
        // the scope root, never by filtering its report. The rail is on row 1 (see `lensTitle`),
        // not here, and row 2 has no leading divider: it is purely the readout.
        scopeChip(folderCount: scopeFolders)
        switch effectiveLens {
        case .duplicates:
            if hasResults {
                duplicatesSummary(rows.duplicates)
            }
        // Both of Organize's states, through one path.
        case .filing:
            organizeSummary(rows: rows, counts: counts)
        case .automations:
            if !syncManager.automationRules.isEmpty {
                automationsSummary(rows.rules)
            }
        case .storage:
            if let report = syncManager.storageLensReport { storageSummary(report) }
        }
    }

    /// Organize's summary row: the pills that describe whichever list is on screen.
    ///
    /// Nothing here renders while a scan runs. Organize's lists are published on completion:
    /// `filingSuggestions`, `filingScanFolder` and `riskyNames` still hold the previous answer
    /// mid-scan, so a cancelled rescan leaves the old results intact. A row drawn from them during
    /// a scan would put last scan's numbers beside this scan's spinner.
    @ViewBuilder
    private func organizeSummary(rows: FilteredRows, counts: RailCounts) -> some View {
        // Readout only: the scope chip is drawn by ``lensSummary``, above every lens. What is left
        // here are the numbers, which belong to the selected lens. Nothing renders mid-scan for the
        // lenses the filing scan republishes; see ``OrganizeLens/goesStaleDuringFilingScan``.
        //
        // The overview is tested for on its own, not reached through the `else` of the guard
        // below: an `else` would catch both arms of the compound condition, so a stale lens would
        // fall through and draw the overview's readout under its own selection. Suppressing a
        // stale readout must leave the row empty.
        if organizeLens == nil {
            // The overview's own readout: "All" is a place you can point at, and an empty readout
            // row looks like a page that failed to load. It says what the rail says, in words,
            // including how many lenses haven't run, the reason `RailItemState` keeps clean and
            // unscanned apart.
            overviewSummary(counts)
        } else if let organizeLens,
                  !(organizeLens.goesStaleDuringFilingScan && syncManager.isSuggestingFiles) {
            switch organizeLens {
            case .toFile:
                if hasFilingResults { filingSummary(rows.filing) }
                // Which tree these files go into, then whose survey reads it.
                if let fileInto { FileIntoMenu(choice: fileInto) }
                if hasFilingResults {
                    FilingSurveyMenu(syncManager: syncManager, sources: filingSurveySources,
                                     onRescan: onFindFilingSuggestions)
                }
                downloadAndReadButton(rows.filing)
            case .renames:
                // The filtered plans, like the queue's readout and unlike the rail badge: a badge
                // counts its whole list, a readout describes the rows on screen, so typing `PG&E`
                // shows the count fall to what is left.
                renameBacklogSummary(rows.renames)
            // Duplicates, rules and storage reach `lensSummary` through their own apparatus arms,
            // so they never arrive here; restructure has no readout of its own.
            case .duplicates, .restructure, .rules, .storage:
                EmptyView()
            }
        }
    }

    /// The sources, by name and root, that name a tree in To File's survey menu and strip.
    private var filingSurveySources: [(name: String, root: String)] {
        providers.map { ($0.displayName, $0.rootPath) }
    }

    /// "3 reporting · 2 clean · 1 not scanned": the rail, said in prose. Absent parts rather than
    /// zeroes, as the badge does: "0 not scanned" is noise.
    @ViewBuilder
    private func overviewSummary(_ counts: RailCounts) -> some View {
        let states = OrganizeLens.railItems.map(counts.state)
        let reporting = states.count { if case .reporting = $0 { return true } else { return false } }
        let clean = states.count { $0 == .clean }
        let unscanned = states.count { $0 == .notScanned }
        let parts = [
            reporting > 0 ? "\(reporting) reporting" : nil,
            clean > 0 ? "\(clean) clean" : nil,
            unscanned > 0 ? "\(unscanned) not scanned" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .scaledFont(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The one chip naming what Organize is answering about.
    ///
    /// Absent in the global view, which is the absence of a scope, not a chip reading
    /// "Everything". It names the subtree and its folder count, so "0 findings" reads as a real
    /// answer rather than a broken lens. The ✕ is the way back to the global view.
    ///
    /// Draws from ``storedScope``, not the applied ``scope``, which is what lets Rules suspend the
    /// scope safely: a chip that vanished on Rules would look like a lost scope and invite setting
    /// it again. Suspended, it keeps naming the folder and says in its tooltip that it comes back.
    @ViewBuilder
    private func scopeChip(folderCount: Int?) -> some View {
        if let storedScope {
            let suspended = scopeIsSuspended
            ScopeChipLabel(name: storedScope.name,
                           folderCount: folderCount,
                           accent: glassHue.accentColor,
                           isSuspended: suspended,
                           // No ✕ while suspended: there is nothing to clear here, and a ✕ would
                           // throw away a scope this lens isn't even using.
                           onClear: suspended ? nil : { withAnimation(listSettle) { setScope(nil) } })
                .help(suspended
                      ? "Rules are configuration, not findings, so they are not narrowed by a "
                        + "folder — they file into destinations all over the source. “"
                        + "\(storedScope.relativePath)” comes back when you leave Rules."
                      : "Every lens below is answering about “\(storedScope.relativePath)”. "
                        + "✕ goes back to the whole tree.")
        }
    }

    /// How many of the profile's folders sit inside the scope, or nil when that is unknown: no
    /// profile, or a folder the survey has never seen.
    ///
    /// Zero can only mean unsurveyed, since a known scope always counts itself
    /// (`PathBoundary.contains(p, under: p)`). "Legal · 0 folders" would read as empty, so nil
    /// makes `ScopeChipLabel` say just "Legal". Counted from the in-memory profile, never the disk,
    /// because a header chip must not touch the filesystem. Counted against ``storedScope``, like
    /// the chip, so the count doesn't blink out while Rules suspends the scope.
    private var scopeFolderCount: Int? {
        // Memoised on its inputs (see `scopeFolderMemo`): it walks every folder in the profile, a
        // path join and containment test each, and body runs on every publish.
        let profile = syncManager.filingFolderProfile
        return scopeFolderMemo.value(for: ScopeFolderKey(scope: storedScope, root: profile?.root,
                                                         folders: profile?.folders ?? [:])) {
            guard let scope = storedScope, let profile else { return nil }
            let root = (profile.root as NSString).expandingTildeInPath
            let inside = profile.folders.keys.count {
                let absolute = $0 == "." ? root : (root as NSString).appendingPathComponent($0)
                return scope.contains(absolute)
            }
            return inside > 0 ? inside : nil
        }
    }

    /// Organize's lens rail: six permanent places, each wearing a badge only when it has something
    /// to report. The places are permanent because "Organize this folder" has to land somewhere
    /// before any scan has run; the badges stay absent at zero (``OrganizeLens/badge(count:)``).
    ///
    /// Selection is a ring, as on the focused pane's provider capsule: an `.overlay`, which takes
    /// its size from the host and can't push this row out of the header's pinned height. The
    /// overview draws no ring on any lens.
    @ViewBuilder
    private func organizeRail(_ counts: RailCounts) -> some View {
        // "All" first, because the overview needs a place that exists at zero. It adds no state; it
        // gives the unselected state a place you can point at.
        organizeOverviewRailItem(counts)
        railSeparator
        ForEach(OrganizeLens.railItems.filter(\.carriesBadge)) { item in
            organizeRailItem(item, counts)
        }
        // Rules sits behind a second separator because it is configuration, not a finding. In a
        // row of peers its missing badge would read as "a lens that found nothing".
        railSeparator
        ForEach(OrganizeLens.railItems.filter { !$0.carriesBadge }) { item in
            organizeRailItem(item, counts)
        }
    }

    /// Which rung the rail keeps in view: the selected one. The rail scrolls with no indicator (a
    /// 27pt row can't spare it), so the selection is moved into view rather than drawn cut in half
    /// at the search toggle.
    private var selectedRailItemID: String? {
        Self.railItemID(organizeLens: organizeLens)
    }

    /// The hairline between the rail's three groups.
    private var railSeparator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }

    /// The overview's own rail item. Selected exactly when no lens is, and carries no count: a
    /// number here would have to sum six different kinds of thing.
    private func organizeOverviewRailItem(_ counts: RailCounts) -> some View {
        let isSelected = organizeLens == nil
        return Button {
            railLens = nil
        } label: {
            RailItemLabel(title: OrganizeRailMetrics.overviewTitle,
                          systemImage: OrganizeRailMetrics.overviewSymbol,
                          state: .configuration, isSelected: isSelected,
                          accent: glassHue.accentColor, style: railStyle)
                .selectionLensStop(Self.railLensChannel, id: Self.railItemID(organizeLens: nil))
        }
        .buttonStyle(.plain)
        // The chosen item sits on the rail's lens in Frosted and Clear, and doesn't lift off it.
        .chromeHover(onLens: isSelected)
        .help("Every lens’s answer for what Organize is pointed at, on one page.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The handle `scrollTo` aims at; see `selectedRailItemID`.
        .id(Self.railItemID(organizeLens: nil))
    }

    /// One rail item.
    @ViewBuilder
    private func organizeRailItem(_ item: OrganizeLens, _ counts: RailCounts) -> some View {
        // The badge reaches the label through `counts.state(_:)`, which calls `counts.badge(_:)`:
        // the same call the width model makes. If the two reached the answer down separate paths,
        // a later rule (suppress a badge past four digits, say) could move one and not the other,
        // and the arithmetic would size a rail nobody draws.
        let isSelected = organizeLens == item
        Button {
            // Clicking the selected item widens back out to the overview; "All" gives the same
            // state a place you can point at.
            railLens = isSelected ? nil : item
        } label: {
            RailItemLabel(title: item.title, systemImage: item.symbol, state: counts.state(item),
                          isSelected: isSelected, accent: glassHue.accentColor, style: railStyle)
                .selectionLensStop(Self.railLensChannel, id: Self.railItemID(organizeLens: item))
        }
        .buttonStyle(.plain)
        .chromeHover(onLens: isSelected)
        .help(item.help(state: counts.state(item)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .id(Self.railItemID(organizeLens: item))
    }

    /// The number each rail item's badge would carry: the whole list it names, never the
    /// filtered view of it, but counted within the scope. A badge is a signpost to its list's
    /// size; one that renumbered as you typed would be filtered by a query you can't see. The scope
    /// is different: it decides which list this is, so a global "126" on Renames beside a list
    /// showing three would be dishonest.
    ///
    /// ## Resolved once per render, like `FilteredRows`
    ///
    /// Scoping turns each count into a filtering pass with path math, over lists in the hundreds or
    /// thousands, and both the width arithmetic and every rail item need the answer. Resolve once
    /// and hand the same value to both, as for rows.
    struct RailCounts: Equatable {
        var toFile = 0, duplicates = 0, names = 0, renames = 0, restructure = 0, rules = 0
        /// Whether the names half of the file pass has run: the risky-name detector, which that
        /// walk runs only when a name ruleset is supplied. A flag of its own, not a member of
        /// ``scanned``, because Names has no lens case, and `.renames` may claim to be clean only
        /// when both halves have run.
        var namesScanned = false

        /// Which lenses have actually run here. Without it a zero means two things, ran and found
        /// nothing or never looked; the rail and the overview keep them apart the same way.
        var scanned: Set<OrganizeLens> = []

        subscript(item: OrganizeLens) -> Int {
            switch item {
            case .toFile: return toFile
            case .duplicates: return duplicates
            // The to-fix rows share this list, and a badge encodes list size.
            case .renames: return renames + names
            case .restructure: return restructure
            case .rules: return rules
            // Neither counts work: `badge(count:)` discards this anyway, since `carriesBadge` is
            // false. Zero rather than a fatal, so the subscript stays total.
            case .storage: return 0
            }
        }

        /// The badge an item is carrying, or nil: the value, not just the fact of one, because
        /// ``OrganizeRailMetrics/badgeWidth(_:scale:)`` measures the digits it is handed. A
        /// three-digit badge costs more width than a two-digit one.
        func badge(_ item: OrganizeLens) -> Int? {
            item.badge(count: self[item])
        }

        /// What this item has to say, in the vocabulary ``RailItemState`` and
        /// ``OrganizeOverviewState`` share. Rules and Storage answer `.configuration` first: neither
        /// reports nor goes quiet, because both of those describe a scan ending in a count that
        /// means "something needs you". It is the distinction ``OrganizeLens/carriesBadge`` draws.
        func state(_ item: OrganizeLens) -> RailItemState {
            guard item.carriesBadge else { return .configuration }
            if let badge = badge(item) { return .reporting(badge) }
            return hasScanned(item) ? .clean : .notScanned
        }

        /// Whether "clean" is an honest claim for this item, folded the same way the badge is.
        /// `.renames` sums rename plans (from the filing walk, `hasSuggestedFiling`) and risky
        /// names (`hasScannedNames`, run only with a name ruleset), so "scanned" for it means
        /// both halves ran. It may underclaim, never overclaim a clean bill.
        ///
        /// This gate decides what a zero means; it never hides findings, because `state(_:)` answers
        /// `.reporting` first. That ordering matters: `findFilingSuggestions` publishes risky names
        /// and plans partway through its walk and sets `hasSuggestedFiling` only at the end, so
        /// mid-scan (or after a cancel) the fold holds real findings while this is false.
        ///
        /// `overviewModel`'s Renames arm asks the same flags in the same order, so the rail and the
        /// overview can't disagree; `OrganizeOverviewWiringTests` checks both surfaces in one test.
        private func hasScanned(_ item: OrganizeLens) -> Bool {
            item == .renames
                ? scanned.contains(.renames) && namesScanned
                : scanned.contains(item)
        }
    }

    /// Whether each pass can answer about the subject `scope` describes. One member, so the rail
    /// and the overview can't disagree about it.
    ///
    /// The subject is what the surface claims to describe: the scope when set, the provider
    /// anchor otherwise. Never the scanned root, which would ask whether a scan covered itself.
    ///
    /// Names and Renames are absent on purpose: `detectRiskyNames` and `detectRenamePlans` get the
    /// provider-wide taxonomy, so their findings cover any subject inside the provider, and a gate
    /// would only hide real work. See ``overviewModel``.
    func passCoverage(for scope: OrganizeScope?) -> (filing: Bool, duplicates: Bool) {
        let subject = scope?.path ?? providerAnchor
        return (filing: OrganizeScopeFilter.looseFileScanCovers(
                    subject: subject, scannedFolder: syncManager.filingScanFolder),
                duplicates: OrganizeScopeFilter.scanCovers(
                    subject: subject, scannedRoot: syncManager.duplicateScanRoot))
    }

    /// Internal, not private, like ``overviewModel``: `OrganizeOverviewWiringTests` asserts what
    /// this hands the rail, and the render suite is handed its values rather than computing them.
    var railCounts: RailCounts {
        // The stored scope, not the applied one: `scope` is nil while Rules is selected, but the
        // rail draws all six badges whatever is selected, so reading it would lift the scope off
        // five lenses because a sixth doesn't use it. Each item asks for its own scope, through
        // the `isScoped` rule the content card obeys. Restructure counts `inside` only: an
        // ancestor finding is shown in the lens but must not swell a badge that promises work here.
        let profileRoot = syncManager.filingFolderProfile?.root ?? ""
        // Memoised on everything below (see `railMemo`): five scoped passes over the manager's
        // published lists, and body runs on every publish.
        let key = RailCountsKey(
            suggestions: syncManager.filingSuggestions,
            duplicates: syncManager.duplicateGroups,
            risky: syncManager.riskyNames,
            renames: syncManager.renamePlans,
            structure: structureFindings,
            rules: syncManager.automationRules.count,
            profileRoot: profileRoot,
            scopes: OrganizeLens.railItems.map { appliedScope(for: $0) },
            hasSuggestedFiling: syncManager.hasSuggestedFiling,
            hasFoundDuplicates: syncManager.hasFoundDuplicates,
            hasScannedNames: syncManager.hasScannedNames,
            hasProfile: syncManager.filingFolderProfile != nil,
            filingScanFolder: syncManager.filingScanFolder,
            duplicateScanRoot: syncManager.duplicateScanRoot)
        return railMemo.value(for: key) { RailCounts(
            toFile: syncManager.filingSuggestions.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .toFile)) },
            duplicates: syncManager.duplicateGroups.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .duplicates)) },
            names: syncManager.riskyNames.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) },
            renames: syncManager.renamePlans.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) },
            // Plan-bearing kinds only: a badge you can't drive to zero is one people stop reading,
            // so an Ask, the crowding classes and the To File hand-off kinds don't count. The
            // finding still renders.
            restructure: structureFindings.count {
                $0.kind.carriesPlan
                    && OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,
                                                    scope: appliedScope(for: .restructure)) == .inside
            },
            // No scope test, because `appliedScope(for: .rules)` is always nil; a call here would
            // read like a live narrowing that can never fire.
            rules: syncManager.automationRules.count,
            // Not a member of `scanned` below: the names half has no lens of its own, and
            // `hasScanned` needs both halves before Renames may claim to be clean.
            namesScanned: syncManager.hasScannedNames,
            // The same conditions ``overviewModel`` uses, so the rail and the overview can't
            // disagree about whether a lens has run here. Rules is absent because it never scans.
            // "Has run" is not "has run where this badge points": a pass over another folder leaves
            // the flags true, so each item's own applied scope decides its subject.
            scanned: {
                var ran: Set<OrganizeLens> = []
                // Provider-wide walks: their findings cover any subject inside the provider.
                if syncManager.hasSuggestedFiling { ran.insert(.renames) }
                if syncManager.hasSuggestedFiling,
                   passCoverage(for: appliedScope(for: .toFile)).filing { ran.insert(.toFile) }
                if syncManager.hasFoundDuplicates,
                   passCoverage(for: appliedScope(for: .duplicates)).duplicates {
                    ran.insert(.duplicates)
                }
                if syncManager.filingFolderProfile != nil { ran.insert(.restructure) }
                return ran
            }())
        }
    }

    /// Organize's readout while the rename backlog is on screen: what the listed plans would do,
    /// in files, since nothing renames a folder. A large backlog is mostly zero-padding, and
    /// "1,192 renames · 1,134 to pad" says so at a glance. The headline is a `SummaryRun` and the
    /// kinds behind it are prose; see ``RenameBacklogTally/breakdown`` for why.
    @ViewBuilder
    private func renameBacklogSummary(_ plans: [RenamePlan]) -> some View {
        let tally = RenameBacklogTally(plans)
        SummaryRun(count: tally.renames, label: tally.renames == 1 ? "rename" : "renames",
                   color: SemanticColor.info, systemImage: "pencil")
            .help("Every file the listed folders would rename — one undoable change per folder.")
        // ``RenameBacklogTally/headerBreakdown``, the header's shorter form: `breakdown` is the
        // folder rows' string, and too wide for this row beside a readout, a divider and two
        // buttons.
        if !tally.headerBreakdown.isEmpty {
            Text(tally.headerBreakdown)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                // The tooltip carries the full census: the visible run merges "to name" and "to
                // reshuffle" and drops the skips, so this is the one place all four numbers show
                // without opening a folder.
                .help(tally.breakdown + ". "
                      + "“To pad” only adds a leading zero — “4. Apr 2021.pdf” becomes "
                      + "“04. Apr 2021.pdf”. “To name” gives a raw name a slot it did not have. "
                      + "“To reshuffle” moves an already-correct name to make room for one of them, "
                      + "and is the only kind here that touches a file that was already right. "
                      + "“Left alone” is what the pass declined to rename; open a folder to read why.")
                // VoiceOver gets the census too: the merged clause is a width compromise, and a
                // screen reader is not short of width.
                .accessibilityLabel(tally.breakdown)
        }
    }


    /// Row 2's trailing edge: a folder-memory survey's progress while one is running, "N of M"
    /// whenever this lens's list is narrowed, then this lens's controls. The survey's progress is
    /// prose, so it is here, not among row 1's fixed-width controls; its finished report lives
    /// above its Rescan-menu item (``lastFolderSurveyNote``).
    ///
    /// M is the scoped list, not the whole tree: `counts`, the same scoped-but-unsearched
    /// tally the rail badges use. N is the rows on screen, M the list before the transient
    /// narrowing.
    @ViewBuilder
    private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {
        // The gate the Rescan menu is drawn under: the filing apparatus, once a scan has finished,
        // and not while one runs. The status describes an action reachable only from that menu.
        if effectiveLens == .filing,
           !syncManager.isSuggestingFiles, syncManager.hasSuggestedFiling {
            folderMemoryStatus
        }
        if isFiltered {
            switch effectiveLens {
            case .duplicates: ofMLabel(rows.duplicates.count, counts.duplicates)
            case .filing where showingRenameBacklog:
                // Over the whole backlog: the list draws folder plans and the folded to-fix names,
                // and the badge counts both (`RailCounts.subscript`). So N is every row on screen
                // and M is `counts[.renames]`, the badge's own number by the same expression.
                ofMLabel(rows.renames.count + rows.risky.count, counts[.renames])
            case .filing: ofMLabel(rows.filing.count, counts.toFile)
            case .automations: ofMLabel(rows.rules.count, counts.rules)
            case .storage:
                // Absent before a report (see ``storageCounts``): there is no honest N or M until
                // the analysis has run.
                if let storage = storageCounts { ofMLabel(storage.filtered, storage.total) }
            }
        }
        // This lens's controls, at the end of row 2. On row 1 they competed with the rail, which
        // needs 693pt to spell out against To File's 490pt of controls, so most windows would get
        // the glyph-only rail. Row 1's reserve is just the search toggle, and the shed threshold
        // with it; see ``OrganizeRailMetrics/searchToggleWidth``. The divider keeps prose on the
        // leading side and controls on the trailing side, so the two stay distinguishable.
        if hasRowTwoActions {
            summaryZoneDivider
            lensActions(rows: rows)
        }
    }

    /// Whether this lens draws any control on row 2: the gate on the divider, so a lens with no
    /// actions draws no rule against nothing. Mirrors ``lensActions``'s gates, because a
    /// `@ViewBuilder` can't be asked whether it produced anything.
    private var hasRowTwoActions: Bool {
        switch effectiveLens {
        case .duplicates:
            return hasResults && !syncManager.isFindingDuplicates
        case .filing:
            guard !syncManager.isSuggestingFiles else { return false }
            // The same member ``lensActions`` draws from, not a copy of its condition: a copied
            // compound condition is how a divider ends up beside a control that isn't there. On
            // the overview this clause is the only one that can be true.
            if showsFilingControl { return true }
            switch organizeLens {
            case .toFile: return hasFilingResults
            // Both halves: the to-fix rows are part of this list, so a backlog of nothing but
            // risky names still has a row-two action.
            case .renames:
                return !syncManager.renamePlans.isEmpty || !syncManager.riskyNames.isEmpty
            // `.storage` is unreachable here: its `searchLens` is `.storage`, so it leaves the
            // outer switch one arm down. Written out because the arm must exist.
            case .none, .duplicates, .restructure, .rules, .storage: return false
            }
        case .automations:
            return !syncManager.automationRules.isEmpty
        case .storage:
            return hasStorageReport && !syncManager.isBuildingStorageLens
        }
    }

    /// The hairline between row 2's prose and row 2's controls.
    private var summaryZoneDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func ofMLabel(_ shown: Int, _ total: Int) -> some View {
        Text("\(shown) of \(total)")
            .scaledFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("Showing \(shown) of \(total)")
    }

    /// When an analysis ran, in the receipt's words: a day, not a duration. A named day
    /// ("Tuesday") is what someone matches against their memory of when they last looked; past a
    /// week it falls back to a date.
    ///
    /// Both formatters are cached: `DateFormatter` is expensive to build and this runs from
    /// `overviewModel`, on a per-`body` path. Both re-check the system zone on every use (see
    /// `ZoneRefreshedFormatter`). The weekday goes through `template`, not a literal `EEEE`, so
    /// the name follows the reader's locale.
    private static let receiptWeekday = ZoneRefreshedFormatter.template("EEEE")
    private static let receiptDate = ZoneRefreshedFormatter.localized(date: .medium, time: .none)

    /// Storage's Overview headline: the whole tree's numbers, never the lists' lengths. The ranked
    /// lists are capped at 20 rows, so counting them would read "20 large · 20 untouched" for
    /// nearly every tree; the report carries totals counted before the cap. "Files", not "large":
    /// the largest-files list has no threshold, so its only true count is how many files there are.
    ///
    /// An older saved report has no totals, so this gives the size it knows and asks for a rescan.
    static func storageReceiptHeadline(_ report: StorageLensReport) -> String {
        let total = "\(FileSyncManager.formatBytes(report.totalBytes)) total"
        guard let files = report.fileCount, let untouched = report.staleCount,
              let reclaimable = report.reclaimableBytes else {
            return total + " · rescan for the counts"
        }
        return total + " · "
            + "\(files.formatted()) file\(files == 1 ? "" : "s") · "
            + "\(untouched.formatted()) untouched · "
            + "\(FileSyncManager.formatBytes(reclaimable)) reclaimable"
    }

    static func receiptDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        // Every comparison is against the injected `now`, including today and yesterday:
        // `Calendar.isDateInToday` reads the system clock and would ignore the parameter.
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if (2...6).contains(days) { return receiptWeekday.string(from: date) }
        return "on " + receiptDate.string(from: date)
    }

    @ViewBuilder
    private func lensBody(rows: FilteredRows, counts: RailCounts, scopeFolders: Int?) -> some View {
        Group {
            // Keyed on the rail, not the workspace's apparatus: inside Organize `lens` is always
            // `.filing`, so `lens == .storage` would never be true here.
            if organizeLens == .storage {
                // Storage, as a read-only lens: it brings its own content card (the shared header
                // above stands in for its toolbar), so it renders in place of the lens content card.
                StorageLensView(
                    syncManager: syncManager,
                    providerName: providerName,
                    query: storageQuery,
                    onBuild: onBuildStorage,
                    onReveal: { path in
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    },
                    onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } },
                    section: $storageSection
                )
            } else {
                contentCard(rows: rows, counts: counts, scopeFolders: scopeFolders)
            }
        }
    }

    // MARK: Row-exit motion (H4)

    /// The removal transition for the card lists: rows slide out to the leading edge and fade, so a
    /// destructive or moving action reads as something that happened, not a silent swap. Insertion
    /// stays `.identity`: freshly scanned cards should just be there.
    private var cardRemoval: AnyTransition {
        .asymmetric(insertion: .identity,
                    removal: .opacity.combined(with: .move(edge: .leading)))
    }

    /// The animation that settles the list as a row leaves. nil under Reduce motion, for an instant
    /// swap (the `.transition` only fires inside an animated transaction).
    private var listSettle: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    /// The membership token the card lists animate on: they animate when row identities change,
    /// not when a keeper pick or an expand/collapse rewrites a row in place. Compares the ids of
    /// the array the view already holds, so nothing is allocated per render, and the count check
    /// settles the common case first.
    struct RowIdentities<Row: Identifiable>: Equatable where Row.ID: Equatable {
        let rows: [Row]

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.rows.count == rhs.rows.count else { return false }
            for (a, b) in zip(lhs.rows, rhs.rows) where a.id != b.id { return false }
            return true
        }
    }

    // MARK: Filing toolbar

    private var hasFilingResults: Bool { !syncManager.filingSuggestions.isEmpty }

    /// "File all N confident", scoped to the filtered rows. `batch` comes from the rows on screen
    /// and is both the label's count and what `applyRecommendedFiling` files, so a query leaving
    /// 3 of 12 reads "File all 3 confident" and files exactly those.
    @ViewBuilder
    private func fileAllButton(_ filing: [FilingSuggestion]) -> some View {
        let batch = filing.filter { $0.isBatchEligible }
        if !batch.isEmpty {
            Button { applyRecommendedFiling(batch) } label: {
                Label("File All \(batch.count) Confident", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accentedProminent(glassHue)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isSuggestingFiles)
            .lockedDuringRun()
            .help("Files the \(batch.count) name-matched suggestion\(batch.count == 1 ? "" : "s") with a confident home"
                  + (isFiltered ? " among the \(filing.count) your search left showing" : "")
                  + ". Content- and AI-based picks stay for you to review; every move undoes with ⌘Z.")
        }
    }

    /// "Refine N with Opus", Organize's opt-in second pass. The scan was free and on-device; this
    /// is the only control in the lens that can spend money, so it names the model and the file
    /// count, and the click raises the spend pre-flight with a real estimate. No price here: the
    /// estimate needs the taxonomy and the token count, which only the pre-flight has.
    ///
    /// `scope` is the filtered rows and the count comes from it, as in `fileAllButton`: a paid
    /// action must send exactly what it counted.
    ///
    /// Without cloud set up the button becomes the invitation, in the same slot, opening Settings.
    /// The branch is `filingCloudRefineAvailable` (is a key stored), not the cloud toggle, which
    /// with no key would label an on-device rerun "with Opus"; and not the resolved route, which
    /// costs a Keychain decrypt on every render. Shown only when it could run
    /// (`canRefineFilingSuggestions`) or while a pass is in flight, so switching off on-device AI
    /// doesn't leave a permanently disabled button.
    @ViewBuilder
    private func refineButton(_ scope: [FilingSuggestion]) -> some View {
        let canRun = syncManager.canRefineFilingSuggestions || syncManager.isRefiningFilingSuggestions
        if syncManager.filingCloudRefineAvailable, canRun {
            let batch = syncManager.filingSuggestionsEligibleForRefine(scope)
            if !batch.isEmpty || syncManager.isRefiningFilingSuggestions {
                // `scope`, not `batch`: the pass filters it the same way, and only the whole scope
                // lets it count the files hidden from Claude for its banner and pill.
                Button {
                    // While a pass runs the button is its Stop: it ends the request and keeps what
                    // had arrived.
                    if syncManager.isRefiningFilingSuggestions { syncManager.stopFilingRefine() }
                    else if let onRefineInChat { onRefineInChat(scope) }
                    else { refineFilingSuggestions(scope) }
                } label: {
                    if syncManager.isRefiningFilingSuggestions {
                        Label("Stop Refining", systemImage: "stop.circle")
                    } else {
                        Label("Refine \(batch.count) with Claude…", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .chromeHover()
                .controlSize(.small)
                // `canRefineFilingSuggestions` is false while a pass runs (it reads the same
                // in-flight token), and a running pass is exactly when the button is Stop.
                .disabled(!syncManager.canRefineFilingSuggestions && !syncManager.isRefiningFilingSuggestions)
                .help(syncManager.isRefiningFilingSuggestions
                      ? "Stop waiting for Claude. Answers that already arrived are kept; a request already sent may still bill."
                      : refineButtonHelp(count: batch.count))
            } else if syncManager.filingSuggestionsHiddenFromClaude(scope) > 0 {
                // Every file here is hidden from Claude: say so rather than drop the control.
                Button {} label: {
                    Label("Refine with Claude…", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .help(Self.allHiddenFromClaudeHelp)
            }
        } else if syncManager.canRefineFilingSuggestions, let configure = onConfigureCloudRefine {
            Button(action: configure) {
                Label("Refine with Claude…", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .chromeHover()
            .controlSize(.small)
            .help("These suggestions came from the free on-device pass. Add your Claude key in the "
                  + "Ask Claude panel to re-ask a stronger model about them — billed to your "
                  + "own API key, and never used by a scan.")
        }
    }

    /// The short name of the model a refine pass runs on: the chat's, "Opus 5.5".
    private var refineModelName: String {
        AskClaudeModels.option(for: askClaudeModel).name
    }

    /// Split out of the `.help` modifier because inline, the interpolation, pluralization and
    /// `isFiltered` branch push the `Button` expression past what the type-checker solves in
    /// reasonable time, and the build fails with no other diagnostic.
    private func refineButtonHelp(count: Int) -> String {
        let model = refineModelName
        let files = count == 1 ? "1 suggestion" : "\(count) suggestions"
        let scope = isFiltered ? " — the ones your search left showing" : ""
        return "Opens a plan in the Ask Claude chat for \(files)\(scope), to ask Claude (\(model)) about them. "
            + "It is billed to your API key, and the plan shows what goes and what it costs; nothing is "
            + "sent until you click Send. Suggestions your own rules steered are left alone, files "
            + "hidden from Claude aren’t sent, and files already answered aren’t sent again."
    }

    /// The disabled Refine button's tooltip when every file listed is hidden from Claude.
    static let allHiddenFromClaudeHelp = "Every file listed is hidden from Claude, so Refine has "
        + "nothing it may send. Settings ▸ Ask Claude holds the Hidden from Claude list."

    /// Runs the refine pass over `scope`, which the pass filters itself. An unstructured Task on
    /// purpose: the round trip must survive the view re-rendering underneath it (the manager
    /// republishes the suggestions when it lands), and the manager's in-flight token, not this
    /// Task, makes a second click a no-op.
    private func refineFilingSuggestions(_ scope: [FilingSuggestion]) {
        guard !scope.isEmpty else { return }
        Task {
            await syncManager.refineFilingSuggestions(scope)
        }
    }

    /// The folder a rescan would walk (the focused pane's current directory), by leaf name.
    private var scanTargetName: String {
        guard let f = scanTargetFolder, !f.isEmpty else { return "this folder" }
        return (f as NSString).lastPathComponent
    }

    private func standardizedPath(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path
    }

    /// True once the focused pane has moved away from the subject: the cue to offer re-aiming
    /// at the new folder. The subject is the scope when there is one, else the lens's scanned root,
    /// because with a scope set the scan root is just how the answer was computed. Storage follows
    /// the same rule.
    ///
    /// Browsing never moves the scope on its own: this only decides whether to offer.
    /// `rootFallback` is the third rung of ``OrganizeAim/subject(scope:scannedRoot:providerRoot:)``;
    /// see there for why an unscoped, unscanned Organize answers about the provider root.
    private func targetMoved(from scannedRoot: String?, rootFallback: String? = nil) -> Bool {
        OrganizeAim.paneMovedAway(paneFolder: scanTargetFolder,
                                  scope: scope,
                                  scannedRoot: scannedRoot,
                                  providerRoot: rootFallback)
    }

    /// A rescan button that becomes a prominent "Organize '<folder>'" once the user has navigated
    /// away, so navigate-then-re-aim is one click. Shared by the lenses.
    ///
    /// The two branches are different verbs with different actions. Rescan re-runs the current
    /// subject's scan and must leave the scope where it is; the moved branch points somewhere new
    /// through `reaim`, which sets the scope first. One shared action would let a plain Rescan drag
    /// the scope to wherever the pane happens to be.
    ///
    /// `movedTitle` overrides the moved branch's Organize wording, and with it the
    /// ``reaimClearsScope`` swap, whose label and help describe scope semantics. Storage passes one
    /// because its `reaim` is a plain re-analyze that touches no scope.
    @ViewBuilder
    private func rescanButton(moved: Bool, movedIcon: String, disabled: Bool,
                              action: @escaping () -> Void, reaim: @escaping () -> Void,
                              movedHelp: String, movedTitle: String? = nil) -> some View {
        if moved {
            Button(action: reaim) {
                if let movedTitle {
                    Label(movedTitle, systemImage: movedIcon)
                } else {
                    Label(reaimClearsScope ? "Organize Everything" : "Organize “\(scanTargetName)”",
                          systemImage: reaimClearsScope ? "square.stack.3d.up.slash" : movedIcon)
                }
            }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue).controlSize(.small)
                .chromeHover()
                .disabled(disabled)
                .help(movedTitle == nil && reaimClearsScope
                      ? "The pane is at the top of the tree, so this clears the scope and answers "
                        + "about everything again."
                      : movedHelp)
        } else {
            Button(action: action) { Label("Rescan", systemImage: "arrow.clockwise") }
                .chromeButtonStyle(glassLevel).controlSize(.small)
                .chromeHover()
                .disabled(disabled).help("Scan this folder again")
        }
    }

    /// Whether re-aiming at the pane's folder would clear the scope rather than set one: true
    /// exactly when the pane sits at the provider root, which
    /// ``OrganizeScope/init(path:providerRoot:)`` normalizes to the global view. Without it the
    /// button would read `Organize "Documents"` and promise to narrow while the click widens.
    private var reaimClearsScope: Bool {
        guard let target = scanTargetFolder, !target.isEmpty,
              let providerRoot, !providerRoot.isEmpty else { return false }
        return OrganizeScope(path: target, providerRoot: providerRoot) == nil
    }

    /// Re-aims Organize at the focused pane's folder: set the scope, then scan. Routed through
    /// ``setScope(_:)``, so at the provider root it clears the scope, which is also how you get
    /// back to the global view. ``reaimClearsScope`` makes the button say so.
    private func reaimAtScanTarget(then scan: @escaping () -> Void) {
        setScope(scanTargetFolder)
        scan()
    }

    /// What the folder-memory re-survey is doing while it is doing it, on row 2 (see
    /// ``lensTrailing(rows:counts:)``). The commonest outcome is that nothing changed, so without
    /// a spinner that appears, names the work and stops, the menu item would look broken.
    ///
    /// The finished report lives at the control it describes (``lastFolderSurveyNote``), not here:
    /// it is long prose, it would stay all session, and it isn't about the list on screen.
    ///
    /// `lineLimit(1)` and `layoutPriority(-1)` are insurance. Row 2's fixed 22pt height
    /// (``LensHeaderMetrics/summaryRow``) and its `.fixedSize()` siblings make both inert today;
    /// they keep this line truncating first if the row grows or a sibling stops being fixed-size.
    @ViewBuilder
    private var folderMemoryStatus: some View {
        if let status = syncManager.filingSurveyLifecycle.status,
           syncManager.filingSurveyLifecycle.isRunning {
            HStack(spacing: 5) {
                InlineSpinner()
                // `scaledFont`, not `font`: row 2's other tenants scale, so an unscaled caption
                // beside them would stay small at `.extraLarge` while the numbers grow.
                Text(status).scaledFont(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .layoutPriority(-1)
        }
    }

    /// The last folder-memory survey's result, as the note above the menu item that produces it,
    /// so "did that do anything, and should I run it?" is answered where it is asked. A `Section`
    /// header rather than a disabled row, so it reads as that control's state, not something to
    /// click. `foldersLearned` rides along: it is the standing fact the survey maintains.
    private var lastFolderSurveyNote: String? {
        syncManager.filingSurveyReport.map(FolderSurveyNote.text(for:))
    }

    /// Whether the pane sits somewhere other than what Organize is answering about. Read by
    /// ``rescanFilingButton`` to pick its branch and by ``showsFilingControl`` to decide whether to
    /// draw the control at all; one expression so the two can't drift apart.
    private var filingTargetMoved: Bool {
        targetMoved(from: syncManager.filingScanFolder, rootFallback: providerAnchor)
    }

    /// Whether To File's setup card is on screen: the pre-scan state with its own folder-named
    /// invitation ("File loose files in Insurance", with a Start button). Only To File has one;
    /// `contentCard` sends the overview, Restructure and Renames (`RenamePassLens`, with its own
    /// setup card) elsewhere.
    private var filingIntroOwnsInvitation: Bool {
        organizeLens == .toFile && !syncManager.hasSuggestedFiling
    }

    /// Whether the filing control is drawn at all: the one gate both ``lensActions`` and
    /// ``hasRowTwoActions`` read. Two clauses, for two different buttons:
    ///
    /// - `hasSuggestedFiling` is Rescan's: a rescan with nothing to re-scan makes no sense.
    /// - `filingTargetMoved` is the moved branch's, which aims Organize at the browsed folder and
    ///   then scans. Someone who has never scanned wants that, so it can't share Rescan's gate.
    ///
    /// The moved branch stands down where To File's intro card already invites a scan of the same
    /// folder: two invitations to one place, only one of which moves the scope, would disagree.
    /// The overview, Renames and Restructure have no intro, so they keep it. Duplicates and Rules
    /// never read this.
    private var showsFilingControl: Bool {
        guard !syncManager.isSuggestingFiles else { return false }
        return syncManager.hasSuggestedFiling || (filingTargetMoved && !filingIntroOwnsInvitation)
    }

    /// To File's row 2 in a narrow workspace: Rescan and Refine behind one ⋯ menu, with File All
    /// Confident beside it. The same actions and gates as the wide row, which reaches them as
    /// buttons.
    @ViewBuilder
    private func compactToFileActions(_ filing: [FilingSuggestion]) -> some View {
        if showsFilingControl || hasFilingResults {
            Menu {
                if showsFilingControl {
                    Button { onFindFilingSuggestions() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    rescanMenuItems
                }
                if hasFilingResults {
                    Divider()
                    refineButton(filing)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .chromeButtonStyle(glassLevel)
            .controlSize(.small)
            .fixedSize()
            .help("More: Rescan, and Refine with Claude")
            .accessibilityLabel("More actions")
        }
        if hasFilingResults { fileAllButton(filing) }
    }

    /// The Rescan menu's items below its primary action: Ignore Saved Suggestions, and Refresh What’s
    /// Learned. A property so the split button and the narrow ⋯ menu offer the same ones.
    @ViewBuilder
    private var rescanMenuItems: some View {
        Button {
            onFindFilingSuggestionsFresh()
        } label: {
            Label("Ignore Saved Suggestions", systemImage: "arrow.clockwise.circle")
        }
        .help("Ask the model about every file again, even the ones that haven’t changed. With Claude selected this re-runs the paid classification for the whole folder.")
        if let onUpdateFolderMemory {
            Divider()
            // The last survey's result sits above the item that produced it; see
            // ``lastFolderSurveyNote``. Absent before the first survey.
            Section {
                Button {
                    onUpdateFolderMemory()
                } label: {
                    // The object stays in the title: in a menu beside "Ignore saved
                    // suggestions", a bare "Refresh" names nothing. Same rule
                    // `rescanAccessibilityLabel` applies for VoiceOver.
                    Label("Refresh What’s Learned", systemImage: "brain")
                }
                .disabled(syncManager.filingSurveyLifecycle.isRunning)
                .help("Learn what your folders have been given since the last survey, so folders "
                      + "you have added recently can be suggested. Reads only the documents that changed.")
            } header: {
                if let note = lastFolderSurveyNote { Text(note) }
            }
        }
    }

    /// Organize's rescan, with the ignore-saved-suggestions variant hung off it. A split control,
    /// because asking afresh is the exception and, on the cloud backend, the one that spends money:
    /// it shouldn't look identical to the free one. When the user has navigated away it becomes the
    /// prominent "Scan '<folder>'" instead; a folder not yet scanned has no saved suggestions.
    @ViewBuilder
    private var rescanFilingButton: some View {
        if filingTargetMoved {
            rescanButton(moved: true, movedIcon: FilingGlyph.lens,
                         disabled: syncManager.isSuggestingFiles,
                         action: onFindFilingSuggestions,
                         reaim: { reaimAtScanTarget(then: onFindFilingSuggestions) },
                         movedHelp: "Point Organize at “\(scanTargetName)” — the folder now focused "
                             + "above. Every lens narrows to it.")
        } else {
            Menu {
                rescanMenuItems
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            } primaryAction: {
                onFindFilingSuggestions()
            }
            .menuStyle(.button)
            .chromeButtonStyle(glassLevel)
            .controlSize(.small)
            .chromeHover()
            .fixedSize()
            .disabled(syncManager.isSuggestingFiles)
            .help("Scan this folder again, reusing suggestions for files that haven’t changed")
        }
    }

    private var rescanDuplicatesButton: some View {
        // This button re-aims the whole workspace too, so it takes the same third rung. Inert in
        // practice (it is gated on `hasResults`, and groups come with `duplicateScanRoot`); it keeps
        // the rule consistent. It can't make the two Organize buttons agree on a subject: this
        // one's second rung is `duplicateScanRoot` and filing's is `filingScanFolder`, which is
        // what the scope exists to override.
        rescanButton(moved: targetMoved(from: syncManager.duplicateScanRoot,
                                        rootFallback: providerAnchor),
                     movedIcon: "wand.and.stars", disabled: syncManager.isFindingDuplicates,
                     action: onFindDuplicates,
                     reaim: { reaimAtScanTarget(then: onFindDuplicates) },
                     movedHelp: "Point Organize at “\(scanTargetName)” and hash it — the folder now "
                         + "focused above. Every lens narrows to it.")
    }

    /// A leading chip naming the folder a lens's current results were scanned from. Distinct
    /// from the scope chip: the scope is the subject the user chose, this is the root a scan
    /// walked. Call sites draw it only when the two differ or it says something the scope can't.
    /// `help` is required so no call site leaves two folder chips on a row explaining nothing.
    @ViewBuilder
    private func scannedFolderChip(_ root: String?, help: String) -> some View {
        if let root {
            let name = (root as NSString).lastPathComponent
            Label(name, systemImage: "folder")
                .scaledFont(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // A provenance claim you can't read is worse than one that pushes a readout, so
                // readouts yield first (the workspace-bar shedding rule).
                .layoutPriority(1)
                .fixedSize()
                .help(help)
        }
    }

    /// Duplicates' scanned root, shown only when it is not the scope. Duplicates needs a scan
    /// of its own, so its root can disagree with the subject: scoped to `Legal` after hashing only
    /// `Finance`, the lens has never looked where you're pointing. When the two agree, a second
    /// chip would just repeat the folder name.
    @ViewBuilder
    private var duplicateScanRootChip: some View {
        if let root = syncManager.duplicateScanRoot {
            let name = (root as NSString).lastPathComponent
            // No scope: the chip alone names what was hashed, so it always draws. With a scope:
            // only when the two differ.
            if let scope {
                if standardizedPath(root) != standardizedPath(scope.path) {
                    scannedFolderChip(root, help: "Scanned from “\(name)”, which is not the folder "
                        + "Organize is scoped to — these results may not cover all of “\(scope.name)”.")
                }
            } else {
                scannedFolderChip(root, help: "These duplicate results were scanned from “\(name)”")
            }
        }
    }

    /// Organize's readout: the queue's breakdown over the rows on screen. This is the filter's
    /// readout: watching 24 → 3 as you type is most of the point, which is why the search field
    /// grows the card rather than covering this row. Drawn as `SummaryRun`s, not pills, because
    /// none of them is clickable; see ``SummaryRun``.
    private func filingSummary(_ filing: [FilingSuggestion]) -> some View {
        let ready = filing.filter { $0.hasConfidentHome }.count
        let newFolders = filing.filter { $0.best?.isNew == true }.count
        let unsure = filing.count - ready
        return Group {
            // "ready" = the showing files with a confident home.
            SummaryRun(count: ready, label: "ready", color: SemanticColor.success, systemImage: "checkmark.circle")
            if newFolders > 0 {
                SummaryRun(count: newFolders, label: newFolders == 1 ? "new folder" : "new folders",
                           color: glassHue.accentColor, systemImage: "folder.badge.plus")
            }
            if unsure > 0 {
                SummaryRun(count: unsure, label: "unsure", color: SemanticColor.caution, systemImage: "questionmark.circle")
            }
            // A scan-level fact, like Duplicates' `need review` / `skipped`, so not recounted over
            // the filtered rows: narrowing the search doesn't change how many files the model was
            // asked about.
            if let reuse = syncManager.filingLastCacheReuse, reuse.reused > 0 {
                SummaryRun(count: reuse.reused, label: "reused", color: .secondary,
                           systemImage: "clock.arrow.circlepath")
                    .help(Self.reuseHelp(reuse))
            }
            // Durable evidence that the paid pass ran and what it bought; the banner goes away,
            // this stays with the rows. Pass-level like `reused`, for the same reason.
            if let refine = syncManager.filingLastRefine {
                SummaryRun(count: refine.changed, label: "refined", color: glassHue.accentColor,
                           systemImage: "sparkles")
                    .help(Self.refineHelp(refine))
                // Undo is here as well as on the chat's card: the chat restarts after an hour, and
                // Organize's own results are where the pass is felt (TE335).
                if syncManager.canUndoFilingRefine {
                    Button("Undo Refine") { syncManager.undoFilingRefine() }
                        .buttonStyle(.link).controlSize(.small)
                        .help("Puts back the on-device suggestions this Refine replaced. Homes you chose since stay as you chose them.")
                }
                if let link = refineChatLink, link.isAvailable() {
                    Button("In Chat ↗") { link.show() }
                        .buttonStyle(.link).controlSize(.small)
                        .help("Shows this Refine’s answers in the Ask Claude chat.")
                }
            }
        }
    }

    /// What the refine pass did, in the terms that matter: how many were sent (the billed part),
    /// how many came back free from the cache, and how many homes it moved. The pill counts
    /// `changed`, not `asked`, because that is what the spend should be judged by: "refined 40"
    /// with nothing moved would read as forty improvements.
    ///
    /// `static`, like ``reuseHelp(_:)``, because both are pure functions of their summary, which
    /// lets `FilingSpendWordingTests` check the wording without mounting a view. Same as
    /// ``OrganizeLens/help(state:)``.
    static func refineHelp(_ refine: FileSyncManager.FilingRefineSummary) -> String {
        // Asked of the outcome, not inferred from the count: `classified == 0` has three causes
        // (all cached, the charge declined, Claude's key unreadable so the pass ran on-device),
        // and this durable pill must not tell someone who pressed Cancel that every answer came
        // from the cache. See `FilingRefineSummary.Outcome`.
        let sent: String
        switch (refine.outcome, refine.classified) {
        case (.failed, _):
            sent = "Claude didn’t finish, so only the answers that arrived were used."
        case (.stopped, _):
            sent = "You stopped it, so only the answers that arrived were used."
        case (.declined, _):
            sent = "Nothing was sent — the cloud pass was declined, so nothing was billed."
        case (.downgraded, _):
            sent = "Nothing was sent to Claude — its saved key couldn’t be read, so these answers "
                 + "were worked out on this Mac."
        case (.ran, 0):
            sent = "Nothing needed sending — every answer came from the cache."
        case (.ran, 1):
            sent = "1 file was sent to Claude."
        case (.ran, _):
            sent = "\(refine.classified) files were sent to Claude."
        }
        // Singular at one, as in ``reuseHelp(_:)``: the two tooltips describe the same cache from
        // two pills, so their grammar should agree.
        let reused: String
        switch refine.reused {
        case 0: reused = ""
        case 1: reused = " 1 had already been answered by this model, so it cost nothing."
        default: reused = " \(refine.reused) had already been answered by this model, so they cost nothing."
        }
        // A declined pass got no answer back, so it can't claim "the free pass had already found
        // the same homes". The sentence above already says nothing was asked; this states the fact.
        let changed: String
        switch (refine.changed, refine.outcome) {
        case (0, .declined), (0, .failed), (0, .stopped): changed = "No suggestion changed."
        case (0, _):         changed = "No suggestion changed — the free pass had already found the same homes."
        case (1, _):         changed = "1 suggestion moved to a better home."
        default:             changed = "\(refine.changed) suggestions moved to better homes."
        }
        return "Asked about \(refine.asked). \(sent)\(reused) \(changed)"
            + FileSyncManager.hiddenFromClaudeNote(refine.hiddenFromClaude)
    }

    /// Spells out what "reused" bought: the model wasn't asked, so with Claude selected it wasn't
    /// billed. Kept out of the pill, whose number is the glanceable part.
    static func reuseHelp(_ reuse: FileSyncManager.FilingCacheReuse) -> String {
        // Both halves of the first sentence agree in number: "1 file … its suggestion was",
        // "N files … their suggestions were".
        let reused = reuse.reused == 1
            ? "1 file hadn’t changed since the last scan, so its suggestion was reused"
            : "\(reuse.reused) files hadn’t changed since the last scan, so their suggestions were reused"
        let classified = reuse.classified == 0
            ? "Nothing needed a fresh answer."
            : (reuse.classified == 1 ? "1 file was newly classified."
                                     : "\(reuse.classified) files were newly classified.")
        return "\(reused) instead of asking the "
            + "model again — with Claude selected, that part of the scan cost nothing. \(classified) "
            + "Use Rescan ▸ Ignore Saved Suggestions to ask afresh."
    }

    /// Duplicates' pills. `groups` / `redundant` / `reclaimable` recount over the filtered rows, so
    /// typing `kind:pdf` visibly rolls 12 groups → 3 and 2.1 GB → 840 MB. `need review` and
    /// `skipped` stay scan-level facts: they describe what the scan did, not what the query kept.
    private func duplicatesSummary(_ groups: [DuplicateGroup]) -> some View {
        let reclaimable = groups.filter { $0.isRecommendedForBatch }.reduce(0) { $0 + $1.reclaimableBytes }
        // Scan-level, not the filtered rows: this pill is the needs-review filter's toggle, and
        // counted over the filtered rows it would vanish when a menu filter excluded its groups,
        // taking the way into the filter with it.
        let needsReview = syncManager.duplicateGroups
            .filter { $0.matchType.kind != .identical }.count
        return Group {
            duplicateScanRootChip
            // The pill reading a count is the control that narrows to it. `groups` selects All
            // (its click is the way back), `need review` toggles the needs-review filter, and while
            // any filter is active the unselected pills dim so the selected one reads as the state.
            filteringPill(selects: .all,
                          help: "Show every group. Click a narrower pill to filter; this one is "
                              + "the way back.") {
                StatPill(count: groups.count, label: "groups", color: SemanticColor.info, systemImage: "square.on.square")
            }
            // The reclaimable figure is not a subset, so it is not a filter: it is plain trailing
            // text, not a capsule, so the header never teaches that clicking a pill sometimes does
            // nothing. The number still rolls and the resolve-glow rides on the text.
            ReclaimPill(reclaimableBytes: reclaimable,
                        freedCaption: reclaim.freedCaption(FileSyncManager.formatBytes(reclaim.totalBytes)),
                        flashToken: reclaimFlashToken,
                        reduceMotion: reduceMotion)
                .opacity(filter == .all ? 1 : 0.55)
            if needsReview > 0 {
                filteringPill(selects: .needsReview, ring: SemanticColor.caution,
                              help: "Everything “Apply recommended” will not touch — the groups "
                                  + "that need a person. Click to show only these.") {
                    StatPill(count: needsReview, label: "need review", color: SemanticColor.caution, systemImage: "exclamationmark.triangle")
                }
            }
            // Scan-level counterpart to the per-group unverified note (DuplicateUnverifiedNote):
            // files the scan never content-verified, so identical copies among them are missing
            // from every group below, and without this pill the scan would be silently blind to
            // them. These files aren't rows, so no query can include or exclude them; it stays
            // visibly inert (no button, and it dims with the rest).
            if let skipNote = DuplicateScanSkipNote.text(syncManager.duplicateScanSkips) {
                StatPill(count: syncManager.duplicateScanSkips.total, label: "skipped",
                         color: SemanticColor.warning, systemImage: "eye.slash")
                    .help(skipNote)
                    .accessibilityLabel(skipNote)
                    .opacity(filter == .all ? 1 : 0.55)
            }
        }
    }

    /// One filtering pill: a `StatPill` that is also the control narrowing the list to what it
    /// counts. Selected wears a ring in the pill's colour family; the rest dim while any filter is
    /// active. The `.all` pill never rings: the default state is not a selection.
    private func filteringPill(selects target: DuplicateMatchFilter, ring: Color = .clear,
                               help: String,
                               @ViewBuilder content: () -> some View) -> some View {
        let isSelected = filter == target
        return Button {
            filter = (isSelected && target != .all) ? .all : target
        } label: {
            content()
                .overlay {
                    if isSelected && target != .all {
                        Capsule(style: .continuous)
                            .strokeBorder(ring.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .opacity(filter == .all || isSelected ? 1 : 0.55)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        // The selected state otherwise lives only in a 1.5pt ring and the neighbours' dimming,
        // which VoiceOver can't see.
        .accessibilityAddTraits(isSelected && target != .all ? [.isSelected] : [])
        .accessibilityHint(help)
    }

    /// The risky-names pills, over the rows on screen. No count pill, because the rail badge
    /// carries it, and no root of its own: the scope chip names the subject for every lens.
    private func renameSummary(_ risky: [RiskyName]) -> some View {
        let folders = risky.filter(\.isDirectory).count
        return Group {
            if folders > 0 {
                SummaryRun(count: folders, label: folders == 1 ? "folder" : "folders",
                           color: .secondary, systemImage: "folder")
            }
        }
    }

    /// Automations' pills, over the filtered rules. The folder chip names the focused folder, the
    /// one a preview would run over, since rules aren't scanned from anywhere.
    private func automationsSummary(_ rules: [AutomationRule]) -> some View {
        let enabled = rules.filter(\.enabled).count
        return Group {
            // Not the scope: Rules is the one lens that isn't scoped, and the scope chip is
            // suspended here (`OrganizeLens.isScoped`). This chip names the folder a preview would
            // actually walk.
            scannedFolderChip(scanTargetFolder,
                              help: "A preview would run these rules over “\(scanTargetName)”")
            // One pill for one fact and its subset ("1 of 1 enabled"), since capsules on this row
            // are controls. The green only shows while something is on.
            StatPill(count: enabled, label: "of \(rules.count) enabled",
                     color: enabled > 0 ? SemanticColor.success : .secondary,
                     systemImage: "checkmark.circle")
        }
    }

    /// Storage's pills: what belongs to the whole report rather than one list, namely the folder
    /// it is about, the total and how old the numbers are. The total is the whole scanned tree's;
    /// a query filters the ranked lists, never the tree's size, so it must not move when you type.
    /// Each section's count sits on its own section header, and `StorageSection.allCases` keeps
    /// every section the body draws counted (`everySectionIsOnTheRail`).
    private func storageSummary(_ report: StorageLensReport) -> some View {
        Group {
            scannedFolderChip(syncManager.storageLensRoot?.path,
                              help: "This storage picture is for “\(((syncManager.storageLensRoot?.path ?? "") as NSString).lastPathComponent)”")
            Pill(.standard, tint: glassHue.accentColor, systemImage: "externaldrive",
                 text: "\(FileSyncManager.formatBytes(report.totalBytes)) total")
            // The three counts are on the section headers, over the lists they describe; the
            // section capsule carries none, because a switcher is for choosing a list, not sizing
            // one.
            storageFreshnessPill
        }
    }

    /// How old the numbers are, shown only for a report restored from disk. After a launch the
    /// first figures you see were produced earlier and may have moved since, so restoring is
    /// honest only if it says so; a report scanned this session needs no marker. `ScanFreshness`
    /// supplies the wording, the one-hour stale threshold and the spoken form, which says "may be
    /// out of date" outright rather than leaving the warning to colour.
    @ViewBuilder
    private var storageFreshnessPill: some View {
        if syncManager.storageLensLifecycle.isRestored,
           let completedAt = syncManager.storageLensLifecycle.completedAt {
            // Scoped tightly to the pill: a `TimelineView` re-runs the closure it wraps, so wrapping
            // more of the header would re-render the whole row every 30 seconds for nothing.
            TimelineView(.periodic(from: completedAt, by: 30)) { context in
                freshnessPill(ScanFreshness.describe(scanDate: completedAt, now: context.date))
            }
        }
    }

    private func freshnessPill(_ freshness: ScanFreshness.Result) -> some View {
        Pill(.standard,
             tint: freshness.isStale ? SemanticColor.warning : .secondary,
             systemImage: "clock.arrow.circlepath",
             text: freshness.text)
            // "Rescan", because that is the label of the control beside this pill.
            .help("These are the numbers from your last analysis of this folder, not a live reading. Rescan for current ones.")
            .accessibilityLabel("Saved report, \(freshness.spoken)")
    }

    /// Credits a completed resolve to the session tally and flashes the reclaim pill. Called only
    /// on success, with the bytes actually reclaimed, so the count-up is honest.
    private func creditReclaim(_ bytes: Int) {
        guard bytes > 0 else { return }
        reclaim.credit(bytes)
        reclaimFlashToken &+= 1
    }

    private var filterMenu: some View {
        Menu {
            // A Menu's content builder is not lazy: it runs on every render, including those a
            // merge's progress publishes trigger. Accepted: groups number in the tens to hundreds
            // and each check is a flag test (unlike the Compare header's counts, memoized in
            // DisplayRows). Counts cover all groups in scope, not the search-narrowed `dupGroups`,
            // so a badge never reads zero for a filter that would reveal rows; see `filterCounts`.
            let counts = Self.filterCounts(syncManager.duplicateGroups, scope: scope)
            Picker("Filter", selection: $session.filter) {
                ForEach(DuplicateMatchFilter.allCases) { f in
                    Text("\(f.label) (\(counts[f] ?? 0))").tag(f)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(filter.label, systemImage: "line.3.horizontal.decrease.circle")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter the groups — showing \(filter.label)")
        // Frosted and Clear: a glass capsule like every bar button (`ChromeGlass`), outside the
        // menu where AppKit lets a background paint; 4pt past the label so it reads as a button.
        .chromeGlassGround(.capsule, outset: 4)
    }

    /// "Apply N recommended", scoped to the filtered groups. **The dangerous button:** `batch` is
    /// one value that the label counts and `applyRecommended` iterates, so a query leaving 3 of 8
    /// eligible groups trashes exactly those 3. A label saying 3 while the action recomputed 8
    /// from `duplicateGroups` would trash copies the user never saw, which is why
    /// `applyRecommendedDuplicates` requires the scope.
    @ViewBuilder
    private func applyAllButton(_ groups: [DuplicateGroup]) -> some View {
        let batch = groups.filter { $0.isRecommendedForBatch }
        if !batch.isEmpty {
            Button { applyRecommended(batch) } label: {
                Label("Apply \(batch.count) Recommended", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accentedProminent(glassHue)
            .chromeHover()
            .controlSize(.small)
            // The row sheds its readouts before its controls (the workspace-bar shedding rule), so
            // priority keeps this label whole.
            .layoutPriority(1)
            .fixedSize()
            .disabled(syncManager.isFindingDuplicates)
            .lockedDuringRun()
            .help("Moves the redundant copies of \(batch.count) byte-identical group\(batch.count == 1 ? "" : "s")"
                  + (isFiltered ? (query.isEmpty ? " — the ones the filter left showing —"
                                       : " — the ones your search left showing —") : "")
                  + " to the Trash. Undo with ⌘Z.")
        }
    }

    /// "Rename N files", over the plans on screen: the same value the label counts and the action
    /// applies, as in `applyAllButton`.
    ///
    /// Gated on there being some, like `fixAllButton`, `fileAllButton` and `applyAllButton`: the
    /// caller's gate reads the global backlog while these rows are narrowed, so a scope with no
    /// drifted folders would otherwise show an enabled "Rename 0 files". The gate counts files,
    /// not plans: a plan whose steps have all been applied is still a plan.
    @ViewBuilder
    private func renameAllButton(_ plans: [RenamePlan]) -> some View {
        let files = plans.reduce(0) { $0 + $1.steps.count }
        if files > 0 {
            Button { onApplyRenames(plans) } label: {
                Label("Rename \(files) File\(files == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accentedProminent(glassHue)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
            .lockedDuringRun()
            .help("Renames \(files) file\(files == 1 ? "" : "s") across \(plans.count) "
                  + "folder\(plans.count == 1 ? "" : "s") to match each folder’s own convention. "
                  + "One undoable change — ⌘Z puts every name back.")
        }
    }

    /// "Fix all N", scoped to the filtered risky names. `onNormalize` takes its rows explicitly,
    /// so this is safe by construction given the filtered array.
    @ViewBuilder
    private func fixAllButton(_ risky: [RiskyName]) -> some View {
        if !risky.isEmpty {
            // Built as a value, not concatenated inside `.help`: a ternary with two interpolations
            // joined by `+` to two more literals exceeds the type-checker's budget, which depends
            // on the deployment target's overload sets.
            let scope = isFiltered
                ? "the \(risky.count) name\(risky.count == 1 ? "" : "s") your search left showing"
                : "every risky name above"
            let help = "Renames \(scope) to its cloud-safe form. Never overwrites an existing "
                + "file, and the whole pass undoes with a single ⌘Z."
            Button { onNormalizeNames(risky) } label: {
                Label("Fix All \(risky.count)", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accentedProminent(glassHue)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isNormalizingNames)
            .lockedDuringRun()
            .help(help)
        }
    }

    private var hasStorageReport: Bool { syncManager.storageLensReport != nil }

    private var reanalyzeStorageButton: some View {
        // `reaim` is the plain action here: Rescan rebuilds Storage's report where it is aimed. It
        // doesn't move the scope; accepting the moved offer re-analyses the focused folder, as the
        // words say, rather than re-aiming the other five lenses as Organize's rescan would.
        rescanButton(moved: targetMoved(from: syncManager.storageLensRoot?.path),
                     movedIcon: "chart.pie.fill", disabled: syncManager.isBuildingStorageLens,
                     action: onBuildStorage,
                     reaim: onBuildStorage,
                     movedHelp: "Analyze “\(scanTargetName)” — the folder now focused above",
                     movedTitle: "Analyze “\(scanTargetName)”")
    }

    private var newRuleButton: some View {
        // The host's existing rule-editor sheet (the one "Remember" opens a learned rule in), so a
        // blank rule and a taught rule share one editor.
        Button { reviewingAutomationRule = AutomationRule(name: "") } label: {
            Label("New Rule", systemImage: AutomationsGlyph.newRule)
        }
        .chromeButtonStyle(glassLevel)
        .controlSize(.small)
        .chromeHover()
        .help("Write a plain-words rule for where loose files belong")
    }

    /// How many rules would actually act: what "Preview all" is gated on, and what the user reads
    /// as "how many of my rules do something". Asked of ``AutomationRuleSet/eligible(_:)`` rather
    /// than spelled `enabled && isRunnable` here, so the count and the engine can't drift apart.
    private var runnableRuleCount: Int {
        AutomationRuleSet.eligible(syncManager.automationRules).rules.count
    }

    private var previewAllButton: some View {
        Button {
            automationsState.viewingResults = true
            onPreviewAutomations(nil)
        } label: {
            Label("Preview All", systemImage: AutomationsGlyph.preview)
        }
        .buttonStyle(.borderedProminent)
        .accentedProminent(glassHue)
        .chromeHover()
        .controlSize(.small)
        .disabled(runnableRuleCount == 0 || providerAnchor == nil)
        // Name the actual blocker: with no provider root there is nothing to preview over, and
        // asking for conditions on already-complete rules would be a dead end.
        .help(providerAnchor == nil
              ? "Focus a provider folder first — the preview runs over the focused folder."
              : runnableRuleCount == 0
              ? "Add a rule with a condition and a destination to preview it."
              : "Dry-run the enabled rules over the focused folder. A preview — nothing moves until you confirm.")
    }

    // MARK: Content card

    @ViewBuilder
    private func contentCard(rows: FilteredRows, counts: RailCounts,
                             scopeFolders: Int?) -> some View {
        VStack(spacing: 0) {
            switch effectiveLens {
            case .duplicates: duplicatesContent(dupGroups: rows.duplicates, counts: counts)
            // Four rail items share `.filing`'s apparatus, so this arm is where the rail decides
            // what you see. The overview leads, because it is what you land on.
            case .filing:
                if showingOverview {
                    organizeOverview(rows: rows, scopeFolders: scopeFolders)
                } else if organizeLens == .restructure {
                    restructureContent(rows: rows, scopeFolders: scopeFolders)
                } else if showingRenameBacklog {
                    // The to-fix rows (the folded Names lens) come from `FilteredRows` like every
                    // other list here, so the list is narrowed one way. See the backlog arm of
                    // ``filteredRows``.
                    let fixRows = rows.risky
                    // Findings first, as the rail badge and the overview card do: the completion
                    // flags decide what an empty backlog means, never whether a full one is drawn.
                    // The filing walk publishes rename plans and risky names before it sets
                    // `hasSuggestedFiling`, so gating on the flag alone would show the never-scanned
                    // pitch over real findings, and keep showing it after a cancel. Both flags, like
                    // `RailCounts.hasScanned`: one half not having run is no clean bill for the
                    // other.
                    if syncManager.renamePlans.isEmpty, syncManager.riskyNames.isEmpty,
                       !syncManager.hasSuggestedFiling || !syncManager.hasScannedNames {
                        // Never scanned: the setup card, named for the provider, because the rename
                        // detectors read the provider-wide taxonomy and a folder name would promise
                        // a narrower answer.
                        renameSetupState
                    } else if syncManager.renamePlans.isEmpty, syncManager.riskyNames.isEmpty {
                        // Ran and found nothing: the earned state, never the pitch.
                        EmptyStateView(
                            icon: "checkmark.seal.fill",
                            tint: SemanticColor.success,
                            title: "Nothing to rename",
                            message: "Every name follows the convention its folder keeps, and none carries a character a cloud would mangle.",
                            secondary: .init("Scan Again", systemImage: "arrow.clockwise",
                                             handler: onFindFilingSuggestions)
                        )
                    } else if rows.renames.isEmpty, fixRows.isEmpty {
                        // The folded totals and noun: `counts[.renames]` is the badge's number over
                        // the same list this state stands in for; `counts.renames` alone would miss
                        // hidden to-fix rows.
                        noMatchesState(scopedTotal: counts[.renames],
                                       globalTotal: syncManager.renamePlans.count
                                           + syncManager.riskyNames.count,
                                       noun: "rename")
                    } else {
                        RenamePassLens(syncManager: syncManager, plans: rows.renames,
                                       riskyNames: fixRows,
                                       accent: glassHue.accentColor,
                                       onApply: onApplyRenames,
                                       onFix: onNormalizeNames,
                                       onReveal: { path in
                                           NSWorkspace.shared.activateFileViewerSelecting(
                                               [URL(fileURLWithPath: path)])
                                       })
                    }
                } else {
                    filingContent(filing: rows.filing, counts: counts)
                }
            case .automations: automationsContent(rules: rows.rules, counts: counts)
            case .storage: EmptyView()   // rendered by `body` as StorageLensView, never through here
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .columnSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        // The Restructure sheets anchor here, not inside the `.restructure` branch. A sheet hangs
        // off its anchor view, so in the branch a lens switch (a pill, or a View ▸ Organize item:
        // macOS menus stay live over a window-modal sheet) would tear the sheet down mid-apply.
        // The landing would finish silently, and coming back would re-present the sheet over
        // stale state: the plan sheet reseeded to all-keep, the removal sheet re-armed over
        // folders already in the Trash.
        .sheet(item: $planningFinding) { finding in
            planSheet(for: finding).presentedNativeControlAccent()
        }
        // A menu verb, carried out here. Resolved against the findings as they stand now: a menu
        // item is enabled at draw time and clicked later, and a landing in between can retire the
        // finding it named.
        .onChange(of: restructureVerbRequest) { _, request in
            guard let request else { return }
            restructureVerbRequest = nil
            carryOut(request)
        }
        .sheet(item: $removalRequest) { request in
            RestructureRemovalSheet(
                candidates: request.candidates,
                accent: glassHue.accentColor,
                isStanding: request.isStanding,
                onRemove: { paths in await removeEmptied(paths, for: request) },
                onClose: { removalRequest = nil })
            .presentedNativeControlAccent()
        }
    }

    // MARK: Restructure

    /// Where the tree disagrees with its own habits. Cached on the manager; see
    /// ``FileSyncManager/structureFindings`` for why a view body must not run the detector. The
    /// visible set: suppressions apply at this one accessor, so the lens, the overview section and
    /// the rail badge agree on what "never suggest this again" meant.
    private var structureFindings: [StructureFinding] { syncManager.visibleStructureFindings }

    /// The findings inside the current scope (`inside` only), matching the badge and the
    /// overview's own Restructure count. Everything on the overview is narrowed this way, so a
    /// nudge read from here can't point at, or create folders in, a gap outside the subtree.
    private var scopedStructureFindings: [StructureFinding] {
        let profileRoot = syncManager.filingFolderProfile?.root ?? ""
        guard let scope = appliedScope(for: .restructure) else { return structureFindings }
        return structureFindings.filter {
            OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot, scope: scope) == .inside
        }
    }

    /// The crowding classification, narrowed to Restructure's scope at render: the profile-keyed
    /// cache filtered to the scope prefix, as the findings are scoped above. No store, no second
    /// cache.
    private var scopedDeadWeight: [String: DeadWeightClass] {
        let all = syncManager.structureReport.deadWeight
        guard let scope = appliedScope(for: .restructure),
              let root = syncManager.filingFolderProfile?.root else { return all }
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard !expandedRoot.isEmpty else { return [:] }
        return all.filter { path, _ in
            scope.relation(of: (expandedRoot as NSString).appendingPathComponent(path)) == .inside
        }
    }

    /// Restructure's rows, from `FilteredRows` like every other lens, so its count and its list
    /// can't disagree.
    @ViewBuilder
    private func restructureContent(rows: FilteredRows, scopeFolders: Int?) -> some View {
        RestructureLens(findings: rows.structure,
                        aboutAncestor: rows.structureAboutAncestor,
                        hasProfile: syncManager.filingFolderProfile != nil,
                        // The scoped count, not the whole survey's: "Checked 3,013 folders" beside
                        // a narrowed answer would claim a tree the lens didn't look at. nil when
                        // unknown; see `scopeFolderCount`.
                        folderCount: scope == nil
                            ? syncManager.filingFolderProfile?.folders.count
                            : scopeFolders,
                        // When the survey last looked: the corpus stamp, seeded at attach and
                        // republished the moment a re-survey finishes.
                        surveyedAt: syncManager.filingSurveyedAt,
                        // Staleness: groups on hand mean the taxonomy detector had something to
                        // read this session.
                        hasDuplicateScan: syncManager.duplicateScanCoversSurvey,
                        isScoped: scope != nil,
                        // The provider, like Renames: the detectors compare sibling families across
                        // the surveyed tree, so a folder-named setup card would promise a narrower
                        // answer than this lens gives.
                        providerName: providerName,
                        // The crowding classification, narrowed to the findings' scope: strip
                        // counts beside a scoped list must count the same subtree (the counts are
                        // scope-dependent, the cache is not).
                        deadWeight: scopedDeadWeight,
                        accent: glassHue.accentColor,
                        onReveal: { relative in
                            guard let root = syncManager.filingFolderProfile?.root else { return }
                            let full = (root as NSString).appendingPathComponent(relative)
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                        },
                        // *Never suggest this again*: the store write, with ⌘Z and an undoable
                        // banner. The manager republishes, `visibleStructureFindings` drops the
                        // row, and the badge follows, since all three read one accessor. nil before
                        // the store exists (no profile), which withholds the item. `hiddenCount`
                        // and Show them again are the way back for findings hidden earlier.
                        onSuppress: syncManager.restructureStore.map { _ in
                            { syncManager.suppressStructureFinding($0) }
                        },
                        // The hidden findings the detector still produces, within this lens's
                        // scope. Not every key ever written: that would count findings whose folder
                        // is gone or outside the scope, promising a Show them again that brings
                        // back what this list can't show.
                        hiddenCount: syncManager.hiddenStructureFindings(
                            in: appliedScope(for: .restructure)).count,
                        onShowHidden: syncManager.restructureStore.map { _ in
                            { syncManager.showHiddenStructureFindings(
                                in: appliedScope(for: .restructure)) }
                        },
                        // The scaffold: one guarded, ledgered, ⌘Z-able landing of create-dirs,
                        // then the hand-off the button below offers on its own. A refusal shows as
                        // a banner sentence, never a silent no-op.
                        onScaffold: { finding in
                            Task { @MainActor in
                                let outcome = await syncManager.applyScaffold(for: finding)
                                if let refusal = outcome.refusal {
                                    syncManager.banner = .warning(refusal, log: .warn)
                                } else {
                                    handOffToToFile(finding)
                                }
                            }
                        },
                        // To File, scoped to the finding's subject: the surface that already makes
                        // per-file judgements with a verdict, a shortlist and Undo.
                        onHandOff: handOffToToFile,
                        // The plan surface, offered only when there is a store the draft can
                        // persist into: with no store, or one refusing writes over an unreadable
                        // file, a plan would silently not survive a quit. applyScaffold enforces
                        // the same gate for its ledger.
                        onPlan: syncManager.restructureStore?.isUnreadable == false
                            ? { planningFinding = $0 }
                            : nil,
                        // Planned-not-applied, from the store's drafts: the count for the trigger's
                        // words, the ledger sentence for the inline line.
                        plannedPlans: Dictionary(uniqueKeysWithValues:
                            (syncManager.restructureStore?.drafts ?? [:]).map { key, draft in
                                (key.findingId, Self.plannedInfo(of: draft.manifest))
                            }),
                        // Landed scaffolds, from the ledger: their card says the survey hasn't
                        // caught up instead of offering the landing twice. The subject is the
                        // created folders' parent. Probed against the disk, not the ledger alone:
                        // a scaffold's ⌘Z removes the folders without marking the record, and a
                        // "Scaffolded" card over missing folders would hide the one button that
                        // could bring them back. A few existence checks per backlog record.
                        scaffoldedSubjects: scaffoldedSubjects(),
                        // The launch gate. Restructure is the only lens whose answer exists before
                        // anyone asks; see `FileSyncManager.hasReviewedStructure` for why it needs
                        // a flag the others get from their scan lifecycle.
                        hasReviewed: syncManager.hasReviewedStructure,
                        onReview: { syncManager.hasReviewedStructure = true },
                        // The refresh: `refreshDerivedProfile`, not the document re-survey.
                        // Restructure reads the folder profile, and `onUpdateFolderMemory` only
                        // re-reads documents and stamps the date, so it would clear the staleness
                        // warning while every finding stayed the same. Both outcomes are reported,
                        // so a several-second tree walk never finishes in silence.
                        onUpdateSurvey: {
                            Task { @MainActor in
                                refreshSurveyRefusal = nil
                                let outcome = await syncManager.refreshDerivedProfile()
                                syncManager.banner = outcome.refusal == nil
                                    ? .success(outcome.sentence)
                                    : .warning(outcome.sentence, log: .warn)
                            }
                        },
                        // The engine's own guard, as the enabled state, so a running landing
                        // disables the control instead of refusing the press.
                        isRefreshing: syncManager.restructureLandingInProgress,
                        // The Applied/Undone cards: every plan landing in the ledger, newest
                        // first. Scaffolds keep their own card sentence and stay out.
                        reorganisations: reorganisationDisplays,
            // Nil-when-too-short is the chart's rule, not the host's, so one place decides whether
            // a line is worth drawing.
            trend: RestructureTrendChart.points(
                from: syncManager.restructureStore?.trend ?? []) ?? [],
                        onUndoReorganisation: { manifestId in
                            Task { @MainActor in
                                await ReorganisationUndo.run(manifestId: manifestId,
                                                             on: syncManager)
                            }
                        },
                        onRemoveEmptied: requestRemoval,
                        // The Scaffolded card, made resolvable: the re-derive a landing already
                        // runs, with a manifest that moves nothing.
                        onOpenHelp: onOpenHelp.map { open in
                            { open(RestructureLens.helpTopicID) }
                        },
                        onRefreshSurvey: { subject in
                            Task { @MainActor in
                                refreshSurveyRefusal = nil
                                let outcome = await syncManager.refreshDerivedProfile()
                                // A refusal stays on the card that asked; a success is a
                                // window-level event and goes in the banner, like the setup
                                // card's own.
                                if let refusal = outcome.refusal {
                                    refreshSurveyRefusal = (subject: subject, sentence: refusal)
                                } else {
                                    syncManager.banner = .success(outcome.sentence)
                                }
                            }
                        },
                        refreshSurveyRefusal: refreshSurveyRefusal,
                        // The Trash route for folders that were already empty.
                        onRemoveStandingEmpties: standingEmptiesRemover)
    }

    /// The ledger's plan landings as the lens renders them: every record `applyPlan` wrote
    /// (`appliedUnderProfileId` is set at its step 2; scaffolds never carry one). Not filtered to
    /// the fully finalised: a landing whose re-derive failed still moved files, and a hidden card
    /// is a landing nobody can ask about. Which one is undoable is the store's
    /// `undoableReorganisation`, the predicate the Organize menu and the engine use, so the menu
    /// can't enable an undo whose card shows no button.
    private var reorganisationDisplays: [ReorganisationDisplay] {
        ReorganisationDisplay.rows(
            from: syncManager.restructureStore?.applied ?? [],
            undoableId: syncManager.restructureStore?.undoableReorganisation(
                currentProfileId: syncManager.filingProfileDirectoryId)?.manifest.manifestId,
            stillHasEmptiedFolders: { anyEmptiedFolderStillStands(of: $0) })
    }

    /// Subjects whose scaffold landed and still stands: `FileSyncManager`'s answer, not a second
    /// copy. See ``FileSyncManager/scaffoldedSubjects()``.
    private func scaffoldedSubjects() -> Set<String> { syncManager.scaffoldedSubjects() }

    /// What a card says about a drafted plan: the trigger's count, the ledger's sentence, and the
    /// blast radius as numbers. All derived from the manifest in one place, so the chips and
    /// the sentence can't disagree about the same plan.
    ///
    /// A "merge" is a source folder the plan drains, which the ledger counts as *folders
    /// emptied*. Whole-folder carries count as renames: the folder keeps its contents and identity.
    static func plannedInfo(of manifest: RestructureManifest) -> PlannedPlanInfo {
        let ledger = RestructureLedger(of: manifest)
        return PlannedPlanInfo(
            // `operationCount`, not `actions.count`: keeps are the signature block, and counting
            // them would overstate the card's "Review N operations", as on the Apply button.
            operations: manifest.operationCount,
            summary: ledger.summary,
            // Each count is the ledger's own, spelled its way: the sentence beneath the chips is
            // `RestructureLedger.summary`, and a chip redefining one of its words would disagree
            // with it one line apart.
            renames: ledger.foldersRenamed,
            carried: ledger.foldersMovedWhole,
            merges: ledger.foldersEmptied,
            filesMove: ledger.filesMoved)
    }

    /// The plan sheet's disk root. `FolderProfile.root` is stored tilde-abbreviated (the survey's
    /// `recordedRoot` folds home to `"~"`), and `URL(fileURLWithPath:)` does **not** expand tildes:
    /// it resolves them against cwd. The sheet's one spelling, pinned by test.
    static func planDiskRoot(_ root: String) -> URL {
        URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
    }

    /// Whether any folder this landing emptied still stands on disk: the removal button's licence.
    /// On the manager, like `scaffoldedSubjects`: it is a disk probe a view body runs per applied
    /// record per render, and the caching that keeps it from being dozens of `stat`s a second
    /// belongs where every caller can reach it.
    private func anyEmptiedFolderStillStands(of manifest: RestructureManifest) -> Bool {
        syncManager.emptiedFoldersStillStanding(of: manifest)
    }

    /// Opens the removal sheet on one landing's emptied folders, re-probed now, so a folder that
    /// gained a file since the landing shows as "no longer empty" rather than vanishing.
    private func requestRemoval(manifestId: String) {
        guard let record = syncManager.restructureStore?.applied
                .first(where: { $0.manifest.manifestId == manifestId }) else { return }
        openRemovalSheet(paths: RestructureLedger.emptiedFolders(of: record.manifest),
                         family: record.manifest.family,
                         origin: .landing(manifestId: manifestId))
    }

    /// The Trash route for folders that were already empty, or nil when there is no profile root:
    /// without one there is no absolute path to re-probe or trash.
    private var standingEmptiesRemover: (() -> Void)? {
        syncManager.filingFolderProfile == nil ? nil : { requestStandingRemoval() }
    }

    /// Opens the same sheet on the pre-existing empties, the crowding strip's third filter. Scoped
    /// like the strip that offered them (`scopedDeadWeight`), so a narrowed Organize removes what
    /// it showed and nothing outside it.
    private func requestStandingRemoval() {
        let paths = Self.standingEmptyPaths(in: scopedDeadWeight)
        openRemovalSheet(paths: paths,
                         family: RestructureRemoval.commonAncestor(of: paths),
                         origin: .standing)
    }

    /// The folders the standing-removal sheet may offer: only the wholly empty ones. A
    /// single-file leaf holds a file, and a "Remove empty folders" sheet must never list a folder
    /// with contents. Sorted so the sheet and the chip's list read in one order.
    static func standingEmptyPaths(in deadWeight: [String: DeadWeightClass]) -> [String] {
        deadWeight.filter { $0.value == .empty }.map(\.key).sorted()
    }

    /// Re-probes a list of profile-relative folders and opens the sheet on the result, so a folder
    /// that gained a file since the survey (or the landing) shows as "no longer empty" rather than
    /// vanishing from the list.
    ///
    /// **Off the main actor**: each probe is a full recursive walk, and a candidate refilled with a
    /// large subtree would otherwise be walked on the main thread in a button handler. The engine
    /// runs the same probe off-main.
    private func openRemovalSheet(paths: [String], family: String,
                                  origin: RestructureRemoval.Origin) {
        guard let root = syncManager.filingFolderProfile?.root, !paths.isEmpty else { return }
        let expandedRoot = (root as NSString).expandingTildeInPath
        Task { @MainActor in
            let candidates = await Task.detached(priority: .userInitiated) {
                paths.map { path -> RestructureRemovalSheet.Candidate in
                    let absolute = (expandedRoot as NSString).appendingPathComponent(path)
                    // Recursive, matching the engine's own remove guard: a drained folder whose
                    // only remainder is an equally drained subfolder is still "empty", or both
                    // would be stranded behind "no longer empty".
                    let exists = FileManager.default.fileExists(atPath: absolute)
                    // nil (the walk couldn't see everything) reads as not empty, the engine's rule.
                    let isEmptyNow = exists
                        && FileSyncManager.visibleFileCount(atPath: absolute,
                                                            fm: FileManager.default) == 0
                    return RestructureRemovalSheet.Candidate(path: path,
                                                             isStillEmpty: isEmptyNow,
                                                             exists: exists)
                }
            }.value
            removalRequest = RemovalRequest(origin: origin, family: family,
                                            candidates: candidates)
        }
    }

    /// The removal landing: its own manifest through the same eight-step apply, so it gets the
    /// ledger, ⌘Z, the re-derive and the log line like any landing. Returns the refusal, or the
    /// landed result.
    private func removeEmptied(_ paths: [String], for request: RemovalRequest) async
        -> RestructureRemovalSheet.RemovalResult {
        let stamp = RestructurePlanSheet.nowStamp()
        guard let manifest = RestructureRemoval.manifest(
            paths: paths,
            family: request.family,
            origin: request.origin,
            profileId: syncManager.filingProfileDirectoryId
                ?? syncManager.filingFolderProfile?.profileId ?? "unknown",
            createdAt: stamp) else { return .refused("Nothing is ticked.") }
        let outcome = await syncManager.applyPlan(manifest)
        if let refusal = outcome.refusal { return .refused(refusal) }
        // Landed: whatever was trashed is in the Trash whether or not profiles.json rewrote. The
        // engine's counts ride along, because it can skip ticked folders (one gained a file, or
        // the parent landing was undone), and an all-skip run must not be announced as "Moved to
        // the Trash". A survey-refresh failure rides as the caveat, so the sheet can retire its
        // button (the landing happened) and still print the sentence.
        return .landed(removed: outcome.removedEmpty, skippedCount: outcome.skipped.count,
                       caveat: outcome.surveyRefreshFailure)
    }

    /// The overview's backlog nudge, or nil. The rule decides; this only carries the effects. Reads
    /// `visibleStructureFindings`, so a finding the user suppressed can't nudge.
    private func backlogNudge() -> OrganizeOverview.BacklogNudge? {
        // An unreadable store can't remember the dismissal, and a ✕ that seems to work but
        // doesn't would bring the same nudge back every launch. Every other Restructure control
        // refuses out loud in this state, so this one withholds itself.
        guard let store = syncManager.restructureStore, !store.isUnreadable else { return nil }
        let due = RestructureNudge.due(in: scopedStructureFindings,
                                       now: Date(),
                                       acknowledged: store.nudgesAcknowledged,
                                       alreadyScaffolded: scaffoldedSubjects())
        guard let sentence = RestructureNudge.sentence(for: due), let first = due.first else {
            return nil
        }
        return OrganizeOverview.BacklogNudge(
            sentence: sentence,
            setUp: {
                // The menu verbs' route: show Restructure, then ask the workspace to carry out the
                // scaffold, so a nudge can't reach a state the menu couldn't.
                syncManager.hasReviewedStructure = true
                railLens = .restructure
                restructureVerbRequest = RestructureVerbRequest(
                    verb: .setUp, folder: Self.absolutePath(of: first.finding.subject,
                                                            under: syncManager
                                                                .filingFolderProfile?.root))
            },
            dismiss: {
                // Every finding the sentence covered, not just the one it named: a line saying
                // "and 3 more" that comes back naming the rest would be a nag.
                for item in due {
                    store.acknowledgeNudge(
                        RestructureKey(kind: item.finding.kind, path: item.finding.subject),
                        year: item.year)
                }
            })
    }

    /// A profile-relative subject as an absolute path: the spelling the verb request carries. The
    /// resolver converts back and accepts both spellings of the root.
    static func absolutePath(of subject: String, under root: String?) -> String {
        guard let root, !root.isEmpty else { return subject }
        return ((root as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(subject)
    }

    /// Carries out a menu verb: resolve the folder to a finding, then open the surface the card
    /// itself would open. A miss is a banner, not silence: the item was enabled when drawn, so the
    /// honest report is that the answer moved.
    private func carryOut(_ request: RestructureVerbRequest) {
        guard let root = syncManager.filingFolderProfile?.root else { return }
        // The same answer the menu's availability read: two copies of this decision would let an
        // item be enabled over a handler that refuses. `unavailable` here means the survey moved
        // between the menu opening and the press, which gets a sentence of its own.
        let resolution = RestructureVerbResolver.resolve(
            request.verb, folder: request.folder, root: root,
            in: syncManager.visibleStructureFindings,
            storeIsReadable: syncManager.restructureStore?.isUnreadable == false,
            alreadyScaffolded: scaffoldedSubjects())
        let finding: StructureFinding
        switch resolution {
        case .run(let resolved):
            finding = resolved
        case .refuse(let sentence):
            syncManager.banner = .warning(sentence, log: .warn)
            return
        case .unavailable:
            syncManager.banner = .warning(
                "There is no longer a finding for that folder — the survey may have been "
                + "updated since the menu was opened.", log: .warn)
            return
        }
        // A deliberate arrival: the user asked about this folder, so the reveal card would charge
        // one intent twice.
        syncManager.hasReviewedStructure = true
        switch request.verb {
        case .plan:
            planningFinding = finding
        case .setUp:
            Task { @MainActor in
                let outcome = await syncManager.applyScaffold(for: finding)
                if let refusal = outcome.refusal {
                    syncManager.banner = .warning(refusal, log: .warn)
                } else {
                    handOffToToFile(finding)
                }
            }
        }
    }

    /// The plan surface, modal over the lens, chosen by geometry. A pair under one parent is
    /// one row of a family mapping, so it opens the seeded mapping sheet and its drafts, Export and
    /// Apply. A pair across parents can't be a mapping row and gets the confirm sheet over its
    /// derived operations. ``RestructurePlanRouting`` is the one place that decides.
    @ViewBuilder
    private func planSheet(for finding: StructureFinding) -> some View {
        if let profile = syncManager.filingFolderProfile,
           let store = syncManager.restructureStore,
           let route = RestructurePlanRouting.route(for: finding) {
            let key = RestructureKey(finding)
            switch route {
            case .familyMapping(let family):
                // Every member, both drop paths included: drift most needs housing, and the
                // mapping applies to all of them.
                mappingPlanSheet(
                    finding: finding, family: family,
                    members: finding.schemes.flatMap(\.members) + finding.drift
                        + finding.shapeless,
                    seeded: nil, profile: profile, store: store, key: key)
            case .seededMapping(let family, let member, let source, let target):
                mappingPlanSheet(
                    finding: finding, family: family, members: [member],
                    seeded: RestructureMapping.Row(source: source, target: target),
                    profile: profile, store: store, key: key)
            case .pairMerge(let source, let destination):
                pairMergeSheet(finding: finding, source: source, destination: destination,
                               profile: profile, store: store, key: key)
            }
        }
    }

    /// The mapping sheet. The tree view is disk-backed: a plan is derived against the tree as it
    /// stands now, and merges need file names the profile never stores.
    @ViewBuilder
    private func mappingPlanSheet(finding: StructureFinding, family: String, members: [String],
                                  seeded: RestructureMapping.Row?, profile: FolderProfile,
                                  store: RestructureStore, key: RestructureKey) -> some View {
            RestructurePlanSheet(
                finding: finding,
                family: family,
                members: members,
                // `planDiskRoot`, not a bare URL: `profile.root` is tilde-abbreviated
                // ("~/Documents") and `URL(fileURLWithPath:)` would resolve it against cwd, so the
                // tree view would read nothing and Plan… would refuse with "Every row is keep".
                // Memoized because the sheet re-derives the whole manifest per edit; one
                // presentation reads each directory once.
                tree: .fromDisk(root: Self.planDiskRoot(profile.root)).memoized(),
                // The folder the artifacts were read from, not the field inside them: the field
                // decodes to "default" when a hand-built profile omits it, which is why every
                // store and the scaffold key on the directory id.
                profileId: syncManager.filingProfileDirectoryId ?? profile.profileId,
                accent: glassHue.accentColor,
                // A saved draft wins over the seed: it is the plan as the user left it, and
                // re-seeding would discard their edits. The seed is what a pair opens with the
                // first time.
                initialRows: store.draft(for: key)?.manifest.mapping ?? seeded.map { [$0] },
                initialVocabulary: store.draft(for: key)?.vocabulary
                    ?? seeded?.target.map { [$0] },
                onExport: { manifest, vocabulary in
                    // The file first, then the draft: the export is reviewable even when the store
                    // refuses writes, and the draft keeps the Planned state across a quit.
                    do {
                        let name = try store.exportPlan(manifest)
                        store.saveDraft(.init(manifest: manifest,
                                              savedAt: manifest.createdAt,
                                              exportedTo: name,
                                              vocabulary: vocabulary), for: key)
                        return .saved(filename: name)
                    } catch {
                        return .failed("The plan could not be written beside the folder survey: "
                            + error.localizedDescription)
                    }
                },
                // A draft is written whenever the sheet closes with a plan, not only on Export,
                // so a hand-built mapping survives an Esc.
                onKeepDraft: { manifest, vocabulary in
                    store.saveDraft(.init(manifest: manifest, savedAt: manifest.createdAt,
                                          vocabulary: vocabulary), for: key)
                },
                // Discard Plan, and a close after every row went back to keep: the ways to drop a
                // draft without landing it.
                hasSavedDraft: store.draft(for: key) != nil,
                onDiscardDraft: { store.removeDraft(for: key) },
                // The landing, from the same sheet that derived the plan: the review above the
                // button is the review being applied.
                onApply: { manifest in
                    let outcome = await syncManager.applyPlan(manifest)
                    if let refusal = outcome.refusal { return .refused(refusal) }
                    // The draft became a ledger record. The store was swapped to the new profile's
                    // during the apply and the draft rode along, so drop it there.
                    syncManager.restructureStore?.removeDraft(
                        for: key, consumedBy: outcome.landedManifest ?? manifest)
                    var summary = outcome.summary
                    if let failure = outcome.surveyRefreshFailure {
                        summary += " — " + failure
                    }
                    if !outcome.verifierMismatches.isEmpty {
                        let n = outcome.verifierMismatches.count
                        summary += " — the verifier found \(n) mismatch\(n == 1 ? "" : "es"); "
                            + "the log has each one"
                    }
                    return .applied(summary: summary)
                },
                // The paid pass on the mapping: the app's transport, offered when a key is stored,
                // with the model label resolved the way the transport resolves it, all as the
                // filing refine does. The profile root, so a mapping naming a folder hidden from
                // Claude is refused.
                onRefineMapping: { await syncManager.refineMapping($0, under: Self.planDiskRoot(profile.root).path) },
                refineOffered: syncManager.filingCloudRefineAvailable,
                refineModelLabel: refineModelName,
                refineQuote: { syncManager.mappingRefineQuote(for: $0) },
                onChangeLimit: onChangeLimit,
                onConfigureRefine: onConfigureCloudRefine,
                // Straight from the manager: the checklist shows only stages the engine actually
                // reached, and clears itself when the landing ends either way.
                applyProgress: syncManager.restructureApplyProgress,
                onClose: { planningFinding = nil })
    }

    /// The cross-parent pair's confirm sheet. Same store, key and landing: a pair merge exports
    /// and drafts like a mapped plan, so the *Planned, not applied* card state and the *Review N
    /// operations* trigger work without a second mechanism.
    @ViewBuilder
    private func pairMergeSheet(finding: StructureFinding, source: String, destination: String,
                                profile: FolderProfile, store: RestructureStore,
                                key: RestructureKey) -> some View {
        RestructurePairMergeSheet(
            source: source,
            destination: destination,
            kind: finding.kind,
            tree: .fromDisk(root: Self.planDiskRoot(profile.root)).memoized(),
            profileId: syncManager.filingProfileDirectoryId ?? profile.profileId,
            accent: glassHue.accentColor,
            // The card's own sentence about this pair, so the review opens on the claim it was
            // opened from rather than restating it.
            rationale: RestructureLens.blastRadius(for: finding)
                ?? RestructureLens.subtitle(for: finding),
            applyProgress: syncManager.restructureApplyProgress,
            onExport: { manifest in
                do {
                    let name = try store.exportPlan(manifest)
                    // No vocabulary: there is no picker here to restore. The draft exists for the
                    // card's Planned state and its operation count.
                    store.saveDraft(.init(manifest: manifest, savedAt: manifest.createdAt,
                                          exportedTo: name, vocabulary: []), for: key)
                    return .saved(filename: name)
                } catch {
                    return .failed("The plan could not be written beside the folder survey: "
                        + error.localizedDescription)
                }
            },
            onApply: { manifest in
                let outcome = await syncManager.applyPlan(manifest)
                if let refusal = outcome.refusal { return .refused(refusal) }
                syncManager.restructureStore?.removeDraft(
                    for: key, consumedBy: outcome.landedManifest ?? manifest)
                var summary = outcome.summary
                if let failure = outcome.surveyRefreshFailure {
                    summary += " — " + failure
                }
                if !outcome.verifierMismatches.isEmpty {
                    let n = outcome.verifierMismatches.count
                    summary += " — the verifier found \(n) mismatch\(n == 1 ? "" : "es"); "
                        + "the log has each one"
                }
                return .applied(summary: summary)
            },
            hasSavedDraft: store.draft(for: key) != nil,
            onDiscardDraft: { store.removeDraft(for: key) },
            onClose: { planningFinding = nil })
    }

    // MARK: Overview

    /// Organize's landing: every lens's answer for the current scope, and the passes that would
    /// produce the answers it doesn't have. Each pass card states its own cost and its button runs
    /// the pass (`onRun`, over ``OrganizePass``'s three), rather than navigating to a lens.
    @ViewBuilder
    private func organizeOverview(rows: FilteredRows, scopeFolders: Int?) -> some View {
        let model = overviewModel
        OrganizeOverview(
            sections: model.sections,
            // The scope, not the last scan's folder: the overview's "Nothing to do in X" describes
            // every lens's answer, and must name nothing when no scope is set.
            scopeLabel: scope?.name,
            accent: glassHue.accentColor,
            inboxShortcut: inboxShortcut,
            backlogNudge: backlogNudge(),
            ledger: overviewLedger(model, scopeFolders: scopeFolders),
            runnablePasses: runnablePasses,
            onOpen: { item in
                // Arriving from a reporting card's "Open Restructure" skips the reveal card: the
                // card's pill already stated the count, and a second card whose button says "Show
                // 12 findings" would charge one intent twice. The launch gate is for opening the
                // lens cold.
                if item == .restructure { syncManager.hasReviewedStructure = true }
                railLens = item
            },
            onRun: runPass,
            // Storage's own verb, not `onRun`: it is in no `OrganizePass`, so `rescanControl` has
            // nothing to build a button from. Gated as the header's button is.
            onBuildStorage: onBuildStorage,
            isBuildingStorage: syncManager.isBuildingStorageLens,
            documentSurvey: documentSurveyCard,
            onStartDocumentSurvey: onStartDocumentSurvey,
            onStartDocumentSurveyOver: onStartDocumentSurveyOver,
            onResumeDocumentSurvey: onResumeDocumentSurvey,
            onPauseDocumentSurvey: onPauseDocumentSurvey,
            onStopDocumentSurvey: onStopDocumentSurvey,
            // The privacy line's pointer, through the app's one Help entry point, shaped like
            // `RestructureLens.helpPointer`, down to the glyph.
            onOpenSurveyHelp: onOpenHelp.map { open in
                { open(OrganizeHelpTopics.onDeviceReading) }
            },
            // The receipt's Refresh is `Refresh what’s learned`: the same incremental pass as the
            // item in To File's rescan menu.
            onUpdateDocumentSurvey: onUpdateFolderMemory
        )
    }

    /// Starts a pass from the overview. The plain scan, not the re-aim: `reaimAtScanTarget` moves
    /// the scope to the focused pane's folder, right for `Organize “X”` but wrong for
    /// `Run the file pass`, which is about the subject the overview already describes. Keeping
    /// those apart is what ``rescanButton``'s two branches are for.
    private func runPass(_ pass: OrganizePass) {
        switch pass {
        case .file: onFindFilingSuggestions()
        case .duplicates: onFindDuplicates()
        // Optional at the host boundary, which is why `runnablePasses` exists rather than a card
        // whose button does nothing.
        case .folderMemory: onUpdateFolderMemory?()
        }
    }

    /// The passes this host can start. Folder memory is the only conditional one: its handler is
    /// optional, and a host passing none gets a card that explains the state, not a no-op button.
    ///
    /// The other two are asserted, not detected: `onFindFilingSuggestions` and `onFindDuplicates`
    /// have `= {}` defaults, so a host omitting one would get a live button over a closure that
    /// does nothing. `ContentView`, the only host, passes both; a new host should make those
    /// handlers optional rather than add a flag here.
    private var runnablePasses: Set<OrganizePass> {
        var passes: Set<OrganizePass> = [.file, .duplicates]
        if onUpdateFolderMemory != nil { passes.insert(.folderMemory) }
        return passes
    }

    /// The overview's cross-lens facts. The counting lives on ``OrganizeOverview/Ledger``, where it
    /// can be asserted without a view; this adds the two figures that need `Sync`.
    private func overviewLedger(_ model: OverviewModel,
                                scopeFolders: Int?) -> OrganizeOverview.Ledger {
        .derived(
            from: model.sections,
            // The ratio is over the checks this host can start, not every lens with a badge (see
            // `Ledger.countedLenses`). The pass cards use the same predicate, so the two agree on
            // which checks are real on this machine.
            runnablePasses: runnablePasses,
            // Absent rather than "0 bytes" when there is nothing to reclaim: before a duplicate scan
            // a zero would read as a measured claim. The rail badges and `inboxSubtitle` follow the
            // same rule.
            reclaimable: model.reclaimableBytes > 0
                ? FileSyncManager.formatBytes(model.reclaimableBytes) : nil,
            // The scoped count when scoped, the whole survey when not, exactly as
            // `restructureContent` does, so both folder counts agree.
            scopeFolders: scope == nil
                ? syncManager.filingFolderProfile?.folders.count : scopeFolders)
    }

    /// The inbox offered as a scope, or nil when there is no inbox, or when it is already the scope
    /// and the offer would change nothing.
    private var inboxShortcut: OrganizeOverview.InboxShortcut? {
        guard let inbox = filingInboxFolder, !inbox.isEmpty else { return nil }
        if let scope, standardizedPath(scope.path) == standardizedPath(inbox) { return nil }

        // The count is claimed only when the last scan covered the inbox. `filingSuggestions` holds
        // one scan's output, so under another scope or folder, or before any scan, it has nothing
        // under `TODO`, and "Inbox (TODO) — 0 loose files" while the inbox holds fifty would talk
        // the user out of the click. A header can't walk the disk on every render, so
        // `looseFileCount` stays nil and the offer just names the inbox: absent beats a wrong zero.
        //
        // Equality, not ancestry: `looseFileScanCovers`. The filing scan enumerates one folder's
        // direct files, so a scan of any folder above the inbox says nothing about it.
        let scanned = syncManager.filingScanFolder
        let covered = OrganizeScopeFilter.looseFileScanCovers(subject: inbox, scannedFolder: scanned)
        let loose = covered
            ? syncManager.filingSuggestions.count { PathBoundary.contains($0.filePath, under: inbox) }
            : nil
        return .init(name: (inbox as NSString).lastPathComponent,
                     looseFileCount: loose,
                     apply: { withAnimation(listSettle) { setScope(inbox) } })
    }

    /// What each lens has to say for the current scope, in rail order. Three states: a lens that
    /// never ran says so, one that ran clean says that, and only one with findings takes a section,
    /// so absence is never ambiguous. Resolved per scope: *"0 under Legal" must never render as
    /// "0 anywhere"*. `notScanned` is a fact about the provider-wide pass; `clean` under a scope
    /// means this subtree is clean, and `OrganizeOverview` names the scope around it.
    ///
    /// ## Why this returns a struct
    ///
    /// The ledger needs the scoped reclaimable total, and `FileSyncManager.duplicateSummary`
    /// computes the global one. Returning both from one walk avoids a second pass over the groups
    /// on every render, as ``RailCounts`` does.
    struct OverviewModel {
        var sections: [OrganizeOverviewSection] = []
        /// Scoped, and batch-eligible groups only, mirroring `duplicateSummary`, so the ledger's
        /// figure is what "Apply recommended" would deliver. Overlapping groups never inflate it.
        var reclaimableBytes = 0
    }

    /// Internal, not private, so `OrganizeOverviewWiringTests` can assert what this hands the view.
    /// The render suite mounts ``OrganizeOverview`` directly with its sections, so it can't check
    /// what this produces (the per-lens `isScanning` flags, say).
    var overviewModel: OverviewModel {
        let scope = scope
        let profileRoot = syncManager.filingFolderProfile?.root ?? ""
        var model = OverviewModel()
        // A zero under a scope the scan never covered is not "clean", it is "unasked": it falls
        // back to `notScanned`, which also puts the run offer back. The inbox shortcut, Open on a
        // single-source row and ⌘K all reach a scope without scanning.
        //
        // The passes have different shapes, so they take different predicates:
        //
        // - To File enumerates one folder's direct files, so only that exact folder is
        //   covered. Ancestry would call a provider-root scan "covering" `Legal`.
        // - Duplicates hashes a whole subtree, so any ancestor of the scope covers it.
        // - Names and Renames are not gated: `detectRiskyNames` and `detectRenamePlans` get the
        //   provider-wide taxonomy (`root: providerRoot`, `maxDepth: nil`), so their findings cover
        //   every scope in the provider. If either detector is ever narrowed to a subtree, it needs
        //   a gate here against its own root.
        let covers = passCoverage(for: scope)
        let filingCovers = covers.filing
        let duplicatesCover = covers.duplicates
        // Hoisted out of the loop because the ledger needs it too; see the type's note.
        let scopedDuplicates = syncManager.duplicateGroups.filter {
            OrganizeScopeFilter.matches($0, scope: scope)
        }
        model.reclaimableBytes = scopedDuplicates
            .filter(\.isRecommendedForBatch)
            .reduce(0) { $0 + $1.reclaimableBytes }
        model.sections = OrganizeLens.allCases.compactMap { item -> OrganizeOverviewSection? in
            switch item {
            case .storage:
                // A receipt, on Storage's own clock. The other arms answer "what did the current
                // scan find in the current scope"; Storage answers "what did the last analysis
                // find, when, and of what", a report restored at launch. `.receipt` says that
                // instead of reading as a backlog nobody can discharge.
                //
                // Not scope-filtered: a treemap can't be narrowed without misstating its
                // proportions, so this reports what the analysis covered and names its root. On
                // the Storage lens `restoreStorageLensIfShowing` keeps report and scope in step; on
                // this page the card may describe another root, and says which.
                guard let report = syncManager.storageLensReport else {
                    return OrganizeOverviewSection(
                        lens: item,
                        blurb: "Where the space goes — the largest files, the untouched ones, and what could be reclaimed.",
                        state: .notScanned,
                        isScanning: syncManager.isBuildingStorageLens)
                }
                let where_ = syncManager.storageLensRoot
                    .map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "this folder"
                let when = syncManager.storageLensLifecycle.completedAt
                    .map { Self.receiptDay($0) } ?? "previously"
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Where the space goes.",
                    state: .receipt(headline: Self.storageReceiptHeadline(report),
                                    detail: "Analyzed \(when) · \(where_)"),
                    isScanning: syncManager.isBuildingStorageLens)
            case .toFile:
                let scoped = syncManager.filingSuggestions.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                let n = scoped.count
                let ready = scoped.filter(\.hasConfidentHome).count
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: n > 0
                        ? "Loose files and where they belong — \(ready) ready, \(n - ready) unsure."
                        : "Loose files and where they belong.",
                    // Findings first: coverage decides what a zero means, never whether real
                    // findings show. A duplicate scan of `Legal/2024` while scoped to `Legal` finds
                    // groups that really are in `Legal`, and gating first would bury them.
                    state: n > 0 ? .findings(count: n, headline: "\(n) file\(n == 1 ? "" : "s")",
                                    // `lazy` before `prefix`, so the limit bounds the suggestions
                                    // examined, not just those kept: `scoped.prefix(3).compactMap`
                                    // over three homeless files would show nothing while the
                                    // fourth had a home.
                                    examples: Array(scoped.lazy.compactMap { s in
                                        s.best.map { "\(s.fileName) → \(($0.path as NSString).lastPathComponent)" }
                                    }.prefix(OrganizeOverview.exampleLimit)))
                        : !syncManager.hasSuggestedFiling || !filingCovers ? .notScanned
                        : .clean,
                    isScanning: syncManager.isSuggestingFiles)
            case .duplicates:
                let scoped = scopedDuplicates
                let n = scoped.count
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Identical content under different names or folders.",
                    // Findings first, as on To File above.
                    state: n > 0 ? .findings(count: n, headline: "\(n) group\(n == 1 ? "" : "s")",
                                    examples: scoped.prefix(OrganizeOverview.exampleLimit).map {
                                        "\($0.name) — \(DuplicateGroupCard.memberCount($0.copies.count, isDirectory: $0.isDirectory, matchType: $0.matchType))"
                                    })
                        : !syncManager.hasFoundDuplicates || !duplicatesCover ? .notScanned
                        : .clean,
                    isScanning: syncManager.isFindingDuplicates)
            case .renames:
                let scoped = syncManager.renamePlans.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                // The backlog's list opens with the to-fix section, so this card counts and
                // previews it too: one list, one card, one number.
                let scopedRisky = syncManager.riskyNames.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                let n = scoped.count + scopedRisky.count
                // The tally is rebuilt from the scoped plans, not the whole backlog: its breakdown
                // is the section's example line, and a global one under a narrow scope would lie.
                let tally = RenameBacklogTally(scoped)
                // The breakdown goes in the blurb, not the detail slot: that slot is monospaced for
                // filenames and paths (`Invoice.pdf → Finance`, `clip.mp4 — 2 copies`), and prose
                // looks wrong there. Restructure's arm does the same.
                //
                // It replaces the generic triple ("to sync, to convention, to order") rather than
                // joining it, which would say the same list twice; the generic version stays for
                // when there is nothing to count. To File's shape ("… — 31 ready, 11 unsure").
                //
                // `headerBreakdown`, not `breakdown`: it drops "N left alone", which aren't "names
                // worth changing", and it is what the Renames lens's own header draws, so the two
                // summaries of one backlog can't differ.
                let riskyClause = scopedRisky.isEmpty ? nil
                    // Not "this provider will not accept": an iCloud or folder source has no naming
                    // rules of its own and still reports here, because the invisible-hazard half of
                    // the check runs on every provider.
                    : "\(scopedRisky.count) name\(scopedRisky.count == 1 ? "" : "s") that won’t store cleanly"
                let renameParts = [riskyClause,
                                   tally.headerBreakdown.isEmpty ? nil : tally.headerBreakdown]
                    .compactMap { $0 }
                return OrganizeOverviewSection(
                    lens: item,
                    // All three categories in one line, in the order the list draws them: the list
                    // carries provider-hostile names, files ignoring their folder's convention and
                    // numbering to pad, not just folders that drifted from their numbering.
                    blurb: renameParts.isEmpty
                        ? "Names worth changing — to sync, to convention, to order."
                        : "Names worth changing — \(renameParts.joined(separator: " · ")).",
                    // Ungated by coverage, like Names: `detectRenamePlans` reads the provider-wide
                    // taxonomy. But "clean" vouches for both of the card's lists, the rename plans
                    // (filing walk) and the risky names (`detectRiskyNames`, run only with a name
                    // ruleset), so both completion flags gate it, as `RailCounts.state` does.
                    //
                    // Findings first, like every arm above: the flags decide what a zero means and
                    // nothing else. The filing walk publishes plans and risky names before it sets
                    // `hasSuggestedFiling`, so mid-scan (and after a cancel) the card must still
                    // show what the badge beside it counts.
                    //
                    // No detail rows: the evidence is the breakdown, a summary of the whole list,
                    // which reads as a clause of the blurb above. The headline's unit is "folders"
                    // while the list is folders, and the neutral "to change" once to-fix rows share
                    // it, because folders plus names has no single honest noun.
                    state: n > 0
                        ? .findings(count: n,
                                    headline: scopedRisky.isEmpty
                                        ? "\(n) folder\(n == 1 ? "" : "s")"
                                        : "\(n) to change",
                                    examples: [])
                        : !syncManager.hasSuggestedFiling || !syncManager.hasScannedNames ? .notScanned
                        : .clean,
                    // `isScanningNames` too: this card hosts the folded Names findings, so a
                    // standalone name scan must mark it.
                    isScanning: syncManager.isSuggestingFiles || syncManager.isScanningNames)
            case .restructure:
                // `inside` only, matching the badge: a finding about the folder above the scope is
                // shown in the lens and labelled there, but it isn't work in this subtree.
                let scoped = structureFindings.filter {
                    OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,
                                                 scope: scope) == .inside
                }
                // The breakdown goes in the blurb and the detail rows go away: this lens's rows are
                // deep paths that repeat their parents, so three of them would show one subtree's
                // shared prefix three times and say only that the list isn't empty. See
                // ``StructureBacklogTally``. To File and Duplicates keep their rows, which are
                // short distinct filenames, what the monospaced slot is for.
                let structureBlurb = StructureBacklogTally(scoped).breakdown
                let blurb = structureBlurb.isEmpty
                    ? "Where the tree disagrees with its own habits."
                    : "Where the tree disagrees with its own habits — \(structureBlurb)."
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: blurb,
                    // No profile means the detectors have nothing to read: "cannot run", a
                    // different sentence from "clean".
                    state: syncManager.filingFolderProfile == nil ? .notScanned
                        : scoped.isEmpty ? .clean
                        : .findings(count: scoped.count,
                                    headline: "\(scoped.count) finding\(scoped.count == 1 ? "" : "s")",
                                    examples: []),
                    // The folder survey, which is this lens's pass: its Refresh button and bold
                    // count must go quiet while the survey runs, as the menu item for the same
                    // action does.
                    isScanning: syncManager.filingSurveyLifecycle.isRunning)
            // Configuration, not a result: nothing to report and no scan to run, so no section,
            // no pass card and no footer line.
            case .rules:
                return nil
            }
        }
        return model
    }

    @ViewBuilder
    private func duplicatesContent(dupGroups: [DuplicateGroup], counts: RailCounts) -> some View {
        if syncManager.isFindingDuplicates {
            scanningState
        } else if !syncManager.hasFoundDuplicates {
            introState
        // Ahead of `cleanState`: a scan that found no groups at all is still an answer about the
        // folder, and the user asked about a file, so name it. Reached only when the visible list
        // is empty, so a name query that does surface other groups still shows them.
        } else if let landing = revealLanding,
                  let answer = DuplicateReveal.namedAnswer(for: landing,
                                                           currentQuery: query,
                                                           listIsEmpty: dupGroups.isEmpty) {
            namedRevealState(answer, path: landing.path)
        } else if syncManager.duplicateGroups.isEmpty {
            cleanState
        } else if dupGroups.isEmpty {
            noMatchesState(scopedTotal: counts.duplicates,
                           globalTotal: syncManager.duplicateGroups.count,
                           noun: "duplicate group")
        } else {
            groupList(dupGroups: dupGroups)
        }
    }

    /// The honest end of a "Find duplicates of this", in one of two answers depending on whether
    /// the scan looked at the file at all. A handoff writes the query itself, so the generic
    /// "Nothing matches" would answer about the filter when the user asked about a file.
    ///
    /// The two answers are different claims: "no other copy of this file" is a finding, "this file
    /// wasn't in the scanned folder" is the absence of one. Merging them would be false confidence;
    /// see `DuplicateReveal.outcome`. `path` comes from the landing because the request is consumed
    /// by now, and the `notScanned` recovery button needs a folder to scan.
    @ViewBuilder
    private func namedRevealState(_ answer: DuplicateReveal.NamedEmptyState, path: String) -> some View {
        switch answer {
        case .noDuplicates(let name):
            EmptyStateView(
                icon: "doc.on.doc",
                title: "No duplicates of “\(name)”",
                message: syncManager.duplicateScanRoot.map { root in
                    "Nothing else in “\((root as NSString).lastPathComponent)” has the same content as this file."
                } ?? "Nothing else in the scanned folder has the same content as this file.",
                caption: "Copies outside the folder that was scanned aren’t detected.",
                primary: .init("Clear Search", systemImage: "xmark.circle") { clearRevealAnswer() }
            )
        case .notScanned(let name):
            // Claims nothing about the file: the last scan covered somewhere else (or was
            // cancelled), so the only true statement is that it didn't look here.
            EmptyStateView(
                icon: "questionmark.folder",
                title: "“\(name)” wasn’t in the last scan",
                message: syncManager.duplicateScanRoot.map { root in
                    "These results were scanned from “\((root as NSString).lastPathComponent)”, which doesn’t contain this file — so they say nothing about it either way."
                } ?? "No completed scan covers this file, so there is nothing to say about it yet.",
                caption: "Scan the folder this file is in to get an answer about it.",
                primary: .init("Find Duplicates", systemImage: "wand.and.stars",
                               help: "Scan the folder this file is in for duplicates") {
                    // The context menu's route, with the file's path, so the host scans a folder
                    // that contains it and hands back a fresh request, which re-fires the reveal.
                    // `onFindDuplicates` would rescan the lens's focused root, which for a handoff
                    // from the other pane still can't contain the file: a loop, not a recovery.
                    if let onFindDuplicatesOf {
                        onFindDuplicatesOf(path)
                    } else {
                        // No host wiring (previews, tests): rescan the focused root, re-armed so the
                        // standing request resolves against whatever the scan finds.
                        appliedRevealID = nil
                        onFindDuplicates()
                    }
                }
            )
        }
    }

    /// Puts the lens back to showing everything, and retires the named answer with the query it
    /// described.
    private func clearRevealAnswer() {
        searchQueries[.duplicates] = ""
        searchExpandedLenses.remove(.duplicates)
        revealLanding = nil
        filter = .all
    }

    /// The empty list when something is hiding rows, naming which something, with one click out
    /// instead of a blank list that reads as "found nothing" (like the Activity Log's "No matching
    /// entries"). The cause is resolved before the words: a live query or type filter, else the
    /// scope.
    /// - Parameters:
    ///   - scopedTotal: how many this lens holds within the scope: the denominator a search
    ///     hides.
    ///   - globalTotal: how many exist in the whole tree, for the scope's own message.
    @ViewBuilder
    private func noMatchesState(scopedTotal: Int, globalTotal: Int, noun: String) -> some View {
        // Nothing in the scope means the scope owns the emptiness, whatever else is set: a query
        // or type filter can only hide rows that are there, and over an empty scope their sentence
        // would read "hides all 0 …" with a button that changes nothing. `scopedTotal` sees neither
        // the query nor the filter, so it is the right question. Otherwise a query or the filter is
        // hiding rows, and `searchHidesAllState` names which.
        if scopedTotal == 0, let scope {
            // Reached only when the scoped list is empty, so everything there is is elsewhere.
            scopeHidesAllState(total: globalTotal - scopedTotal, noun: noun, scope: scope)
        } else {
            searchHidesAllState(total: scopedTotal, noun: noun)
        }
    }

    /// - Note: Everything here keys on `effectiveLens`. Inside Organize `lens` is always
    ///   `.filing`, so keying on it would clear To File's parked query and leave the one actually
    ///   hiding the rows, redrawing the same empty state on every click.
    ///
    ///   The narrowing can be the type filter alone, with no query, so the wording follows the
    ///   cause. The button clears both whichever it names, so one press ends the dead end; it is
    ///   labelled for the cause.
    private func searchHidesAllState(total: Int, noun: String) -> some View {
        let plural = "\(total) \(noun)\(total == 1 ? "" : "s")"
        // `total > 0`: this state is also reachable with no scope, and "hides all 0" is not a
        // sentence either way.
        let filterOnly = query.isEmpty && filterIsNarrowing && total > 0
        return EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "Nothing matches",
            message: filterOnly
                ? "The “\(filter.label)” filter hides all \(plural). Switch it to “All” to see them again."
                : "The current search hides all \(plural). Clear it to see the results again.",
            primary: .init(filterOnly ? "Show All" : "Clear Search", systemImage: "xmark.circle") {
                searchQueries[effectiveLens] = ""
                searchExpandedLenses.remove(effectiveLens)
                if effectiveLens == .duplicates { filter = .all }
            }
        )
    }

    /// Nothing here, but something elsewhere: the sentence a scoped zero owes the reader. Names
    /// the scope, states the total outside it, and offers the one action that changes the answer.
    /// Not phrased as "clean": finding nothing under `Legal` says nothing about the tree, and
    /// `cleanState`'s words would blur *clean* with *not looked here*.
    private func scopeHidesAllState(total: Int, noun: String, scope: OrganizeScope) -> some View {
        EmptyStateView(
            icon: "scope",
            title: "Nothing in “\(scope.name)”",
            message: "Organize is scoped to “\(scope.relativePath)”. "
                + "\(total) \(noun)\(total == 1 ? "" : "s") elsewhere in the tree \(total == 1 ? "is" : "are") not shown.",
            primary: .init("Organize Everything", systemImage: "xmark.circle",
                           help: "Clear the “\(scope.name)” scope and show the whole tree") {
                withAnimation(listSettle) { setScope(nil) }
            }
        )
    }
    /// Below this a collapsed duplicates tile stops holding its own content. A tile is a badge
    /// and figure, then a name, then a ~24-character subtitle with a chevron; the subtitle, about
    /// 155pt of 10.5pt monospace plus chevron and padding, puts the floor near 220, and 250 leaves
    /// the name some room. Smaller than `RenamePassLens.minimumCardWidth` (340), whose card carries
    /// a two-column table rather than a caption. Not `private`, so tests read the shipped value
    /// rather than restating it.
    static let duplicateTileMinimumWidth: CGFloat = 250

    private func groupList(dupGroups: [DuplicateGroup]) -> some View {
        let sections = DuplicateSections.sections(dupGroups)
        // Read here, once per list, not in the GeometryReader below: that closure re-runs on every
        // frame of a window drag, and this is a defaults read and a filter of every key.
        let kept = keptSeparateCount
        return ScrollViewReader { proxy in
        GeometryReader { geo in
        let chrome = densityMetrics.cardListPadding * 2
        let columns = LensCardGrid.columns(
            forWidth: geo.size.width,
            minimumCardWidth: Self.duplicateTileMinimumWidth,
            // This lens is a `ScrollView` with its own padding, not the renames `List`; see
            // `LensCardGrid.listHorizontalPadding`.
            horizontalPadding: chrome)
        // What one card actually gets, which decides its header; see
        // `DuplicateCardHeaderLayout.forCard(width:isExpanded:)`. A column count can't answer it:
        // one column at the window floor is narrower than two on a wide display.
        let cardWidth = LensCardGrid.cardWidth(forWidth: geo.size.width, columns: columns,
                                               horizontalPadding: chrome)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                // Sectioned by what each finding asks of you (see `DuplicateSections`, and
                // `RenameCategories`), so the few groups that need a person aren't lost in a wall
                // of equal tiles. Sectioned once per group list, not per frame of a window drag:
                // the width doesn't change the answer.
                ForEach(sections, id: \.kind) { section in
                    duplicateSectionHeader(section, columns: columns)
                    duplicateTileRows(section, columns: columns, cardWidth: cardWidth,
                                      fullWidth: geo.size.width - chrome)
                }
                keptSeparateRow(kept: kept)
            }
            .padding(densityMetrics.cardListPadding)
            // Animate the list settling when a resolved or merged group leaves. Keyed on the
            // visible ids so only membership changes animate; expand/collapse and keeper picks
            // stay instant.
            .designAnimation(listSettle, value: RowIdentities(rows: dupGroups))
        }
        .scrollContentBackground(.hidden)
        // Scrolling is the last step of a landing, and the only one that can fail silently: the
        // card is already expanded and marked, so a missed scroll leaves a correct answer off
        // screen. Keyed on the marked group, not the request, because a group is scrollable only
        // once it is in `dupGroups`, after the plan's filter and query changes take effect.
        .onChange(of: revealedGroupID) { _, id in
            guard let id else { return }
            unfoldSection(holding: id, in: dupGroups)
            // The hop is for the fold: `unfoldSection` writes `@State`, and until the body
            // re-evaluates the card is absent from the view tree (`shown` is a `prefix`). A
            // `scrollTo` in the same turn would be silently dropped, never retried. The same
            // reason `FileTreeView`'s and `PaneColumnsView`'s reveals hop.
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        // The reveal that mounts this list (the workspace switch) sets `revealedGroupID` before
        // there is a proxy to scroll with, so `onChange` never sees it move. This handles that.
        .onAppear {
            guard let id = revealedGroupID else { return }
            unfoldSection(holding: id, in: dupGroups)
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        }
        }
        }
    }

    /// Opens the fold over a revealed group, so a landing can't aim at a card the fold hides. A
    /// target past "Show 48 more" isn't in the view tree, so `scrollTo` would find nothing and the
    /// reveal would end wherever the list happened to be.
    private func unfoldSection(holding id: DuplicateGroup.ID, in groups: [DuplicateGroup]) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        unfoldedSections.insert(group.matchType.kind)
    }

    /// A section's heading: the count, what the section asks for, and its one-line definition. No
    /// bulk button: only `identical` is batchable (`DuplicateGroup.isRecommendedForBatch`), and the
    /// header's "Apply N recommended" is already that section's action. A second control three rows
    /// lower would make a reader wonder which one is scoped differently.
    private func duplicateSectionHeader(_ section: DuplicateSections.Section,
                                        columns: Int) -> some View {
        let tint = DuplicateSections.tint(section.kind)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Pill(.standard, tint: tint, count: section.groups.count,
                     label: DuplicateSections.label(section.kind))
                if section.reclaimableBytes > 0 {
                    // The verb, and the `~` on an overlap. An overlap reports "shared", not
                    // "reclaim", because no button would reclaim it, and approximates it because
                    // the per-copy share is an average. A bare byte count would make a merge
                    // section look like free space.
                    let isOverlap = section.kind == .overlapping
                    Text((isOverlap ? "~" : "")
                         + FileSyncManager.formatBytes(section.reclaimableBytes)
                         + (isOverlap ? " shared" : " reclaimable"))
                        .scaledFont(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 8)
            }
            Text(DuplicateSections.definition(section.kind))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .padding(.horizontal, 2)
    }

    /// A section's tiles, folded after four rows: enough to see what the section holds, short
    /// enough that the next heading is on screen. Whole rows, so the button never sits under a
    /// half-row.
    @ViewBuilder
    private func duplicateTileRows(_ section: DuplicateSections.Section,
                                   columns: Int, cardWidth: CGFloat,
                                   fullWidth: CGFloat) -> some View {
        let fold = LensCardGrid.itemsBeforeFold(columns: columns)
        let showsAll = unfoldedSections.contains(section.kind)
        let shown = showsAll ? section.groups : Array(section.groups.prefix(fold))
        ForEach(LensCardGrid.identifiedRows(shown, columns: columns,
                                            spansFullWidth: { expanded.contains($0.id) })) { gridRow in
            let row = gridRow.items
            // One expanded card is a full-width row on purpose: it must not be padded out to a
            // third of the pane by the spacers a short row needs.
            let isFullWidthRow = row.count == 1 && expanded.contains(row[0].id)
            HStack(alignment: .top, spacing: LensCardGrid.gutter) {
                ForEach(row) { group in
                    duplicateCard(group, cardWidth: isFullWidthRow ? fullWidth : cardWidth)
                }
                // A short last row must not stretch its tiles over the width the missing ones
                // would have held.
                if !isFullWidthRow && row.count < columns {
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
        if section.groups.count > fold {
            Button {
                if showsAll { unfoldedSections.remove(section.kind) }
                else { unfoldedSections.insert(section.kind) }
            } label: {
                Text(showsAll ? "Show fewer"
                              : "Show \(section.groups.count - fold) more")
                    .scaledFont(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(glassHue.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            // `.segment`, not `chromeHover()`: this draws no chrome, and `chromeHover` is for
            // controls that keep system chrome. On a bare accent label it adds two shadows and a
            // 1pt lift, and its `hoverTint` does nothing. `.segment` is what the other groundless
            // controls in the app wear.
            .buttonStyle(.hoverAffordance(.segment, tint: glassHue.accentColor))
            // The padding-compensation idiom: the 6/2 above pads inside the label to give the
            // hover capsule something to fill, and must be cancelled here or the resting footprint
            // grows by 12pt across and 4pt down and shoves the section below. Always move the two
            // pairs together.
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
            .padding(.top, 2)
            .padding(.horizontal, 2)
        }
    }

    /// The card has one compare closure; the branch is here. A folder pair goes to the
    /// Compare-workspace hand-off, which relativizes both paths against provider roots and re-pins
    /// the panes: right for two folders, wrong for two files. A file pair opens the in-window
    /// Compare Copies surface. The card would otherwise need to know two hosts, and `ContentView`
    /// doesn't know which kind of group a click came from.
    ///
    /// The payload carries copy values and paths, never `group.id`: a rescan mints fresh UUIDs, so
    /// a captured id soon names nothing. The surface re-looks-up the live group by path at click
    /// time. Internal and named, like `keeperAction(for:)`, so the branch is testable: swapped
    /// arms would send a file pair down the folder path.
    func compareCopies(keep: DuplicateCopy, other: DuplicateCopy, in group: DuplicateGroup) {
        if group.isDirectory {
            onCompareCopies(keep, other)
        } else {
            // Logged like the folder hand-off, so the log records file comparisons too, and any
            // trash that follows has its two paths' origin on record.
            Logger.shared.info(
                "Comparing duplicate copies — keep \(keep.path) · other \(other.path)")
            onCompareFilePair(DuplicateComparePair(keeper: keep, other: other,
                                                   matchType: group.matchType,
                                                   groupName: group.name))
        }
    }

    /// One group's card, with the two things drawn from outside it: the landing mark and the scroll
    /// anchor. The `.id` is what `proxy.scrollTo` finds: the grid's `ForEach` is over rows, so
    /// without it the reveal would mark the right card and then scroll to nothing.
    private func duplicateCard(_ group: DuplicateGroup, cardWidth: CGFloat) -> some View {
        DuplicateGroupCard(
            group: group,
            isExpanded: expanded.contains(group.id),
            providerName: providerName,
            scanRoot: syncManager.duplicateScanRoot,
            densityMetrics: densityMetrics,
            onToggle: { toggle(group.id) },
            onApply: { apply(group) },
            onReveal: { reveal(group) },
            onKeepSeparate: { syncManager.keepDuplicateGroupSeparate(group) },
            onChooseKeeper: { syncManager.setKeeper(for: group.id, to: $0) },
            onMerge: { merge(group) },
            onCompareCopies: { keep, other in compareCopies(keep: keep, other: other, in: group) },
            isMerging: syncManager.mergingGroupIDs.contains(group.id),
            onOpenInEditor: onOpenInEditor,
            headerLayout: .forCard(width: cardWidth, isExpanded: expanded.contains(group.id))
        )
        .id(group.id)
        // The landing mark, drawn from outside the card: "you were sent here" is a fact about this
        // session's navigation, not about the group.
        .overlay {
            if revealedGroupID == group.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(glassHue.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
                    // The card announces the mark (below); the ring is its paint.
                    .accessibilityHidden(true)
            }
        }
        // The spoken form of the ring: a VoiceOver user has no ring, so without this the card
        // that answers their question sounds like its neighbours. `.isSelected` rather than our
        // own words, because "selected" is how assistive tech already says "this one".
        .accessibilityAddTraits(revealedGroupID == group.id ? .isSelected : [])
        .transition(cardRemoval)
    }

    // MARK: Empty / scanning states

    private var introState: some View {
        // The setup card: the job, the safety contract, one trigger, and sample rows in the shape
        // real groups take, so the first real list isn't the first sight of its layout. Named for
        // the focused folder, which is what the scan hashes.
        LensSetupCard(
            intro: LensIntros.duplicates(targetName: scanTargetName),
            accent: glassHue.accentColor,
            triggerTitle: "Find Duplicates",
            triggerSymbol: "wand.and.stars",
            triggerHelp: "Hash “\(scanTargetName)” and group identical content. Free, on this Mac — the slow part is reading every file once.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: "Example of the duplicate-group format: the common name, "
                + "how many copies and how they match, and what removing the extras reclaims. "
                + "These are samples, not files on your disk.",
            onStart: onFindDuplicates
        ) {
            // The real card's header at sample scale: name, the card's own subtitle, then the
            // verb and figure, with the green pill only on an identical group, as the card draws
            // it. No match badges: the section headings carry the kind.
            LensSetupSampleRow {
                Text("Wedding Gifts.pdf").scaledFont(.caption).lineLimit(1)
                Spacer(minLength: 6)
                Text("2 copies · byte-for-byte").scaledFont(.caption.monospaced())
                    .foregroundStyle(.tertiary).lineLimit(1)
                Text("reclaim").scaledFont(.caption).foregroundStyle(.secondary)
                Text("71 KB").scaledFont(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
                    .pillSurface(.mini, tint: SemanticColor.success)
            }
            LensSetupSampleRow {
                Text("Passport - All Pages.pdf").scaledFont(.caption).lineLimit(1)
                Spacer(minLength: 6)
                Text("2 copies · bytes differ").scaledFont(.caption.monospaced())
                    .foregroundStyle(.tertiary).lineLimit(1)
                Text("reclaim").scaledFont(.caption).foregroundStyle(.secondary)
                Text("26 MB").scaledFont(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(SemanticColor.success)
            }
            LensSetupSampleRow {
                // A finding the scan can actually produce: an overlap needs a person, and its
                // figure is approximate and shared rather than reclaimed, as the section header and
                // the card both say.
                Text("Petition").scaledFont(.caption).lineLimit(1)
                Spacer(minLength: 6)
                Text("2 folders · 92% shared").scaledFont(.caption.monospaced())
                    .foregroundStyle(.tertiary).lineLimit(1)
                Text("shared").scaledFont(.caption).foregroundStyle(.secondary)
                Text("~1.1 MB").scaledFont(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            // Determinate bar once hashing knows exact counts (like the Differences
            // syncProgressRow); an indeterminate spinner during the walk.
            if let progress = syncManager.duplicateScanProgress, progress.total > 0 {
                let completed = min(progress.completed, progress.total)
                ProgressView(value: Double(completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                    .accessibilityValue("\(completed.formatted()) of \(progress.total.formatted())")
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(syncManager.duplicateScanLifecycle.status ?? "Analyzing…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelFindDuplicates() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        // No backing: on an empty surface a material has nothing to blur and paints a flat gray
        // slab. The file pane's busy chip follows the same rule; see `PaneBusyIndicator`.
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The clean state's message, as a value so the scope claim can be checked without pixels.
    /// The subject is the folder the scan covered, as the named-reveal states phrase it via
    /// `duplicateScanRoot`: a clean claim must never be wider than the scan behind it.
    nonisolated static func duplicatesCleanMessage(scanRootName: String?, providerName: String?) -> String {
        if let scanRootName {
            return "Nothing repeats in “\(scanRootName)”. Scan again after adding files."
        }
        return "Nothing repeats across \(providerName ?? "this provider"). Scan again after adding files."
    }

    private var cleanState: some View {
        let kept = keptSeparateCount
        return EmptyStateView(
            icon: "checkmark.seal.fill",
            tint: SemanticColor.success,
            title: "No duplicates found",
            message: Self.duplicatesCleanMessage(
                scanRootName: syncManager.duplicateScanRoot.map { ($0 as NSString).lastPathComponent },
                providerName: providerName),
            // An all-clear can be the result of everything having been kept separate, so it says
            // so and offers the way back, as the list's foot does.
            caption: kept > 0 ? Self.keptSeparateSentence(kept) : nil,
            primary: kept > 0
                ? .init("Show Them Again", systemImage: "eye",
                        help: Self.keptSeparateHelp) { showKeptSeparateAgain() }
                : nil,
            secondary: .init("Scan Again", systemImage: "arrow.clockwise", handler: onFindDuplicates)
        )
    }

    /// The way back from Keep separate, at the foot of the list, so a mis-click can't hide a group
    /// for good across every rescan.
    @ViewBuilder
    private func keptSeparateRow(kept: Int) -> some View {
        if kept > 0 {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Self.keptSeparateSentence(kept))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Show Them Again") { showKeptSeparateAgain() }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(glassHue.accentColor)
                    .chromeHover()
                    .help(Self.keptSeparateHelp)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
        }
    }

    /// The groups kept separate that a scan of this folder could flag. The keys cover every folder
    /// and provider at once; only these are this lens's to count or forget.
    private var keptSeparateCount: Int {
        syncManager.keptSeparateKeys(under: keptSeparateFolder).count
    }

    /// The one folder *Show them again* counts, forgets and rescans: the deeper of the scan's root
    /// and the scope, the folder the list on screen covers. See
    /// ``OrganizeAim/keptSeparateFolder(scannedRoot:scope:)``.
    private var keptSeparateFolder: String? {
        OrganizeAim.keptSeparateFolder(scannedRoot: syncManager.duplicateScanRoot,
                                       scope: appliedScope(for: .duplicates))
    }

    /// Counts only this folder's groups (``keptSeparateCount``), so it says "in this folder".
    static func keptSeparateSentence(_ count: Int) -> String {
        count == 1 ? "You’ve kept 1 group in this folder separate — scans skip it."
            : "You’ve kept \(count.formatted()) groups in this folder separate — scans skip them."
    }

    static let keptSeparateHelp = "Forget the groups kept separate in this folder and scan again"

    /// Kept-separate groups leave no trace a scan can restore from, so the way back is to forget
    /// them and scan again, for this folder only. The rescan is aimed here, not through
    /// `onFindDuplicates`, which hashes the scope or the focused pane's folder: either can differ
    /// from the folder whose keys were just forgotten.
    private func showKeptSeparateAgain() {
        guard let folder = keptSeparateFolder else { return }
        syncManager.forgetKeptSeparateGroups(under: folder)
        Logger.shared.info("User asked to show kept-separate groups again in \(folder)")
        syncManager.startFindDuplicates(root: URL(fileURLWithPath: folder),
                                        options: DuplicateFinderOptions.fromDefaults())
    }

    // MARK: Filing content

    @ViewBuilder
    private func filingContent(filing: [FilingSuggestion], counts: RailCounts) -> some View {
        VStack(spacing: 0) {
            // No teach prompt here: inserted above the cards after a move, it would slide the next
            // card's "File here" out from under the pointer. The offer rides in the move's "Filed …"
            // result message as "Save as rule…" (`FilingRuleOfferPanel`), so these cards never move.
            Group {
                switch Self.filingContentState(
                    isScanning: syncManager.isSuggestingFiles, showsSetup: showsFilingSetupCard,
                    rowsShown: filing.count, suggestions: syncManager.filingSuggestions.count,
                    scopeIsSet: scope != nil, scopeWasScanned: scope.map { passCoverage(for: $0).filing } ?? true) {
                case .scanning: filingScanningState
                case .setup: filingIntroState
                case .notScannedHere: if let scope { filingNotScannedHereState(scope) }
                case .clean: filingCleanState
                case .hidden:
                    noMatchesState(scopedTotal: counts.toFile,
                                   globalTotal: syncManager.filingSuggestions.count,
                                   noun: "loose file")
                case .list: filingList(filing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The Automations lens. The shared card carries New rule / Preview all, so the host threads in
    /// the filtered rules and the shared `viewingResults` state the card's Preview button flips.
    @ViewBuilder
    private func automationsContent(rules: [AutomationRule], counts: RailCounts) -> some View {
        if !syncManager.automationRules.isEmpty, rules.isEmpty, !automationsState.viewingResults {
            noMatchesState(scopedTotal: counts.rules,
                           globalTotal: syncManager.automationRules.count, noun: "rule")
        } else {
            AutomationsLens(
                syncManager: syncManager,
                state: automationsState,
                rules: rules,
                providerName: providerName,
                // File Into's folder when the host gives one: the tree the Rules preview resolves
                // into, so the editor relativizes against the same root.
                destinationRoot: (fileInto?.path ?? providerAnchor).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } },
                onReveal: { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
                onPreview: onPreviewAutomations
            )
        }
    }

    // MARK: Learned rules (offered after a filing move)

    /// After the user files a loose file, propose an editable Automation rule for files like it:
    /// the deterministic, learn-by-example complement to the AI backend. The manager assembles it
    /// (see `proposeAutomationRule`), because it keys on the page this scan read and the tree's own
    /// filing memory.
    ///
    /// `providerRoot` is the tree the card was scanned against, which a rule's relative destination
    /// resolves from on the next scan. Not ``providerAnchor``: with File Into on iCloud Documents
    /// and the source on the Home folder, the anchor would save `Documents/Family/Shweta`, which
    /// the next scan would resolve to `Documents/Documents/Family/Shweta` and create.
    private func offerRule(fileName: String, filePath: String, destinationPath: String,
                           providerRoot: String?, modificationDate: Date?) {
        let rel = RuleOfferLogic.relativeToProviderRoot(destinationPath, providerRoot: providerRoot)
        // The file's own date lets a destination ending in a year generalise to `{year}` rather
        // than freezing the example's year.
        guard let proposal = syncManager.proposeAutomationRule(fileName: fileName,
                                                               filePath: filePath,
                                                               destinationRelativePath: rel,
                                                               modificationDate: modificationDate)
        else { return }
        pendingRememberPrompt = nil   // the new offer supersedes the legacy override prompt
        ruleVariantChoice = proposal.defaultVariant
        // Rides in the move's result message, set by the move this follows, and leaves with it.
        pendingRuleOffer = RuleOffer(fileName: fileName, proposal: proposal, ridesOn: syncManager.banner?.id)
    }

    private func filingList(_ filing: [FilingSuggestion]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                // Grouped by confidence (High / Medium / Low), so the list reads as sure, maybe and
                // needs-you. Sectioned from the filtered rows, so a tier the query empties loses
                // its header too.
                ForEach(FilingSuggestionGrouping.sections(filing)) { section in
                    filingSectionHeader(section)
                    ForEach(section.suggestions) { suggestion in
                        filingCard(suggestion)
                            .transition(cardRemoval)
                    }
                }
            }
            .padding(densityMetrics.cardListPadding)
            // Slide and fade a filed or dismissed card out and settle the list. Keyed on the ids so
            // only a leaving card animates; an emptied tier's header falls away in the same pass.
            .designAnimation(listSettle, value: RowIdentities(rows: filing))
        }
        .scrollContentBackground(.hidden)
    }

    private func filingSectionHeader(_ section: FilingSuggestionSection) -> some View {
        // The 3-bar meter makes the header read as a scale, and the tier's gloss doubles as the
        // once-per-screen legend for what raises confidence.
        HStack(spacing: 8) {
            ConfidenceMeter(tier: section.tier)
            Text(section.tier.title)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(section.suggestions.count.formatted())
                .scaledFont(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("· \(section.tier.gloss)")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2).padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.tier.title), \(section.suggestions.count) file\(section.suggestions.count == 1 ? "" : "s"). \(section.tier.gloss)")
    }

    private func filingCard(_ suggestion: FilingSuggestion) -> some View {
        FilingSuggestionCard(
            suggestion: suggestion,
            densityMetrics: densityMetrics,
            onFileHere: { dest in
                filedThisSession = true
                Task {
                    // Offer a rule only when the file actually moved: filing into the folder it
                    // already lives in (`.notNeeded`) is a no-op, and a rule from it is noise.
                    guard await syncManager.applyFilingSuggestion(suggestion, to: dest) == .moved else { return }
                    offerRule(fileName: suggestion.fileName, filePath: suggestion.filePath,
                              destinationPath: dest.path,
                              providerRoot: suggestion.providerRoot ?? providerAnchor,
                              modificationDate: suggestion.modificationDate)
                }
            },
            onChooseFolder: { chooseFolder(for: suggestion) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.filePath)]) },
            onNotHere: {
                dismissedThisSession = true
                syncManager.dismissFilingSuggestion(suggestion)
            },
            onPreview: onQuickLook.map { ql in { ql(URL(fileURLWithPath: suggestion.filePath)) } },
            onTryAnother: { Task { await syncManager.tryAnotherFolder(for: suggestion) } },
            tryAnotherNote: syncManager.filingTryAnotherNotes[suggestion.filePath],
            onAskClaudeWithPage: syncManager.filingTryAnotherNotes[suggestion.filePath]?.offersClaudeWithPage == true
                && syncManager.canAskClaudeWithPage(suggestion)
                ? { Task { await syncManager.tryAnotherFolder(for: suggestion, askingClaudeWithPage: true) } } : nil,
            isTryAnotherBusy: syncManager.filingTryAnotherInFlight.keys.contains(suggestion.id),
            // Offered only for files the scan read and got nothing from; see
            // `FileSyncManager.readScan(for:)` for why it is an offer, not a scan step.
            onReadScan: syncManager.filingUnreadableScans.contains(suggestion.filePath)
                ? { Task { await syncManager.readScan(for: suggestion) } }
                : nil,
            isReadScanBusy: syncManager.filingOCRInFlight.contains(suggestion.filePath),
            isNotDownloaded: syncManager.filingNotDownloaded.contains(suggestion.filePath)
        )
    }

    /// The pre-scan state. Not `EmptyStateView` like the other four: this card shows three sample
    /// rows in the shape real suggestions take, which makes the first real list legible. See
    /// ``FilingSetupCard``. No price: the scan runs at ``FilingClassifierTier/free``, and money is
    /// spent only by the refine button, which quotes a real estimate for a batch it has in hand.
    private var filingIntroState: some View {
        FilingSetupCard(
            // `documentsRead` is the memory's own answer: a tree whose documents have been read
            // has learned folders. Reading it here keeps the sentence and its fact together.
            intro: LensIntros.organize(
                scanTargetName: scanTargetName,
                documentsRead: !(syncManager.filingMemory?.folders.isEmpty ?? true)),
            accent: glassHue.accentColor,
            onStart: onFindFilingSuggestions
        )
    }

    /// Whether To File is showing its pre-scan setup card.
    private var showsFilingSetupCard: Bool {
        !syncManager.isSuggestingFiles && !syncManager.hasSuggestedFiling
    }

    /// Renames before its first run: the walk's job for this lens, one trigger (the same file pass
    /// To File offers, since one walk answers both), and the row shapes of all three categories a
    /// scan can produce, the red to-fix first.
    private var renameSetupState: some View {
        LensSetupCard(
            intro: LensIntros.renames(providerName: providerName),
            accent: glassHue.accentColor,
            triggerTitle: "Run the File Pass",
            triggerSymbol: "folder.badge.gearshape",
            triggerHelp: "One walk of the tree answers To File and this backlog. Free, and on-device.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: "Example of the rename formats: a provider-hostile name and "
                + "its safe form, a file renamed to its folder’s convention, and a one-digit "
                + "ordinal padded to two. These are samples, not files on your disk.",
            onStart: onFindFilingSuggestions
        ) {
            LensSetupSampleRow {
                Pill(.mini, tint: SemanticColor.error, text: "to fix")
                Text("Tax: 2024?.pdf").scaledFont(.caption.monospaced()).lineLimit(1)
                Image(systemName: "arrow.right").scaledFont(.system(size: 9)).foregroundStyle(.tertiary)
                Text("Tax - 2024.pdf").scaledFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            LensSetupSampleRow {
                Pill(.mini, tint: glassHue.accentColor, text: "to name")
                Text("9829custbill.pdf").scaledFont(.caption.monospaced()).lineLimit(1)
                Image(systemName: "arrow.right").scaledFont(.system(size: 9)).foregroundStyle(.tertiary)
                Text("07. Jul 2023.pdf").scaledFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            LensSetupSampleRow {
                Pill(.mini, tint: .secondary, text: "to pad")
                Text("1. Jan 2011.pdf").scaledFont(.caption.monospaced()).lineLimit(1)
                Image(systemName: "arrow.right").scaledFont(.system(size: 9)).foregroundStyle(.tertiary)
                Text("01. Jan 2011.pdf").scaledFont(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var filingScanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.filingScanLifecycle.status ?? "Analyzing…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelFindFilingSuggestions() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        // No backing, for the duplicate scan's reason above.
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var filingCleanState: some View {
        if filedThisSession {
            // Earned: the user filed everything loose this session, a positive terminal state, not
            // a neutral empty one. Its own glyph (a full tray), never the duplicate finder's seal.
            EmptyStateView(
                icon: FilingGlyph.allFiled,
                tint: SemanticColor.success,
                title: "All filed",
                message: "Every loose file in \(filingFolderName) is in its home now. Undo any move with ⌘Z, or scan again after adding more.",
                secondary: .init("Scan Again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        } else if dismissedThisSession {
            // Handled, but not by filing: the user cleared every suggestion with "Not here". Don't
            // claim the scan found nothing; it found these and the user set them aside.
            EmptyStateView(
                icon: FilingGlyph.nothingLoose,
                tint: .secondary,
                title: "Suggestions cleared",
                message: "You set aside every suggestion in \(filingFolderName). Scan again to look afresh, or add more files first.",
                secondary: .init("Scan Again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        } else {
            // Neutral: the scan found nothing loose to begin with.
            EmptyStateView(
                icon: FilingGlyph.nothingLoose,
                tint: .secondary,
                title: "Nothing loose to file",
                message: "No files in \(filingFolderName) need a home right now.",
                secondary: .init("Scan Again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        }
    }

    private var filingFolderName: String {
        guard let folder = syncManager.filingScanFolder else { return "this folder" }
        return (folder as NSString).lastPathComponent
    }

    /// What To File's content area shows: the chooser `filingContent` switches on, kept pure so
    /// the order of its questions can be asserted without mounting a scope.
    enum FilingContentState: Equatable { case scanning, setup, notScannedHere, clean, hidden, list }

    /// "Not scanned here" is asked before "clean" and "hidden": with a scope To File never
    /// read, the list is empty by construction, and both of those would describe a folder nobody
    /// looked at ("Nothing loose to file", or "Nothing in “Downloads”").
    static func filingContentState(isScanning: Bool, showsSetup: Bool, rowsShown: Int, suggestions: Int,
                                   scopeIsSet: Bool, scopeWasScanned: Bool) -> FilingContentState {
        if isScanning { return .scanning }
        if showsSetup { return .setup }
        if rowsShown == 0, scopeIsSet, !scopeWasScanned { return .notScannedHere }
        if suggestions == 0 { return .clean }
        if rowsShown == 0 { return .hidden }
        return .list
    }

    /// The scope is a folder To File hasn't read. Moving the scope doesn't scan, and the filing
    /// pass reads one folder's own files, so after a scan of `Finance` nothing is listed under
    /// `Downloads`, and ``scopeHidesAllState`` would wrongly say "Nothing in “Downloads”".
    /// ``passCoverage(for:)`` is the overview's test for this, so the two surfaces agree.
    private func filingNotScannedHereState(_ scope: OrganizeScope) -> some View {
        let into = fileInto.map { " in \($0.label)" } ?? ""
        // Named apart when the two share a name (iCloud ▸ Downloads scanned, Home ▸ Downloads
        // scoped), or the sentence would read "last read “Downloads”. Scan “Downloads”".
        let last = syncManager.filingScanFolder.map { folder -> String in
            let name = (folder as NSString).lastPathComponent
            return name == scope.name ? "To File last read another folder named “\(name)”. "
                                      : "To File last read “\(name)”. "
        } ?? ""
        return EmptyStateView(
            icon: "scope",
            title: "“\(scope.name)” hasn’t been scanned",
            message: "\(last)Scan “\(scope.name)” to find homes\(into) for its loose files.",
            primary: .init("Scan “\(scope.name)”", systemImage: "doc.text.magnifyingglass",
                           handler: onFindFilingSuggestions),
            secondary: .init("Organize Everything", systemImage: "xmark.circle",
                             help: "Clear the “\(scope.name)” scope and show the whole tree") {
                withAnimation(listSettle) { setScope(nil) }
            }
        )
    }

    /// "Download and Read 13": fetches the cloud-only files among the rows on screen, reads page 1
    /// of each and places them again. Absent when none of them is cloud-only.
    @ViewBuilder
    private func downloadAndReadButton(_ filing: [FilingSuggestion]) -> some View {
        let cloudOnly = filing.filter { syncManager.filingNotDownloaded.contains($0.filePath) }
        if !cloudOnly.isEmpty, syncManager.filingSnippetExtractor != nil {
            let busy = syncManager.isDownloadingFilingFiles
            Button {
                Task { await syncManager.downloadAndReadFiling(cloudOnly) }
            } label: {
                HStack(spacing: 4) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(busy ? "Downloading…" : "Download and Read \(cloudOnly.count)")
                }
            }
            .controlSize(.small)
            .disabled(busy || syncManager.isSuggestingFiles)
            .help("Downloads the \(cloudOnly.count) file\(cloudOnly.count == 1 ? "" : "s") only in the cloud, reads page 1 of each, and suggests homes from what they say. They stay downloaded.")
        }
    }

    /// Asks where this suggestion should go, then files it there. The picker browses the provider
    /// the rail is showing and opens near where you last filed; the system panel stays as
    /// `Other…`, for a destination outside the provider.
    private func chooseFolder(for suggestion: FilingSuggestion) {
        // Both fallbacks test for empty, not just nil: `providerRoot` is "" for an unconfigured
        // provider, so `??` alone would never reach the next option.
        //
        // The card's own root first: the tree the scan filed this file against. It is the source's
        // anchor except when File Into points elsewhere (loose files in Home ▸ Downloads filed
        // into iCloud Documents), where browsing Home would miss the suggestion's folders.
        let root = [suggestion.providerRoot, providerAnchor]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let panel = { Self.runSystemFolderPanel(for: suggestion.fileName,
                                                startingAt: syncManager.filingScanFolder) }
        // Nothing to browse without a provider root: `subfolders` refuses an empty root, so the
        // picker's first column would be permanently empty. Fall back to the system panel.
        guard !root.isEmpty else {
            if let chosen = panel() { file(suggestion, into: chosen) }
            return
        }
        onRequestDestination(PendingDestination(
            request: DestinationRequest(
                sourcePaths: [suggestion.filePath],
                firstItemName: suggestion.fileName,
                isMove: true,
                providerRoot: root,
                providerName: fileInto.flatMap { $0.path == root ? $0.label : nil }
                    ?? ((providerName?.isEmpty == false) ? providerName! : "this provider"),
                // Opens where the rail is looking, not at the root: the folder you were just in is
                // the best guess, one click from the root either way. Only when it is inside the
                // tree being browsed, or files read from Home ▸ Downloads and filed into Documents
                // would open the picker outside its own root.
                openAt: syncManager.filingScanFolder.flatMap {
                    PathBoundary.relativize($0, under: root) != nil ? $0 : nil
                } ?? root
            ),
            onCommit: { destination in file(suggestion, into: destination) },
            onOther: panel
        ))
    }

    /// Files `suggestion` into `destination` and, when this overrode the suggested home and the
    /// filename has something distinctive to key on, offers to remember it. Shared by the picker
    /// and the system panel, so one path reaches the transfer whichever answered.
    private func file(_ suggestion: FilingSuggestion, into destination: String) {
        let dest = FilingDestination(path: destination, confidence: .high,
                                     reasons: ["You chose this folder"], newSegments: [])
        filedThisSession = true
        let teachable = FilingOverride.isOverride(suggestion, chosenPath: destination)
            && FilingEngine.canRemember(fileName: suggestion.fileName)
        Task {
            // Only prompt to remember an override when the file actually moved: a rule from filing
            // into the folder it already sits in (`.notNeeded`) is pointless.
            if await syncManager.applyFilingSuggestion(suggestion, to: dest) == .moved, teachable {
                pendingRuleOffer = nil   // a stale offer would otherwise hide the fresh teach prompt
                pendingRememberPrompt = PendingRememberPrompt(fileName: suggestion.fileName,
                                                              destinationPath: destination,
                                                              ridesOn: syncManager.banner?.id)
            }
        }
    }

    /// The escape hatch the picker's `Other…` opens: the system folder panel, for a destination
    /// outside the provider. Returns nil when cancelled.
    private static func runSystemFolderPanel(for fileName: String, startingAt folder: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "File Here"
        panel.message = "Choose a folder for “\(fileName)”"
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Files `batch`, the exact array `fileAllButton` counted. Never re-derived from
    /// `syncManager.filingSuggestions`: under a query that is a different, larger set, and the
    /// confirmation names this one.
    private func applyRecommendedFiling(_ batch: [FilingSuggestion]) {
        guard !batch.isEmpty else { return }
        let newFolders = batch.filter { $0.best?.isNew == true }.count
        let folderNote = newFolders > 0 ? " Creates \(newFolders) new folder\(newFolders == 1 ? "" : "s")." : ""
        // `confirmChange`, not `confirmDestructive`: filing moves files and ⌘Z moves them back;
        // nothing goes to the Trash. The destructive alert's caution icon and red default are
        // reserved for a real Trash, as in the duplicate dialogs below. The confirm stays because
        // this can create folders, which "Rename N files" and "Fix all N" never do.
        let ok = NativeAlerts.confirmChange(
            messageText: "File \(batch.count) file\(batch.count == 1 ? "" : "s") into their suggested homes?",
            informativeText: "Moves each file into its suggested folder.\(folderNote) Unsure files stay put. Every move can be undone with ⌘Z.",
            confirmTitle: "File"
        )
        guard ok else { return }
        filedThisSession = true
        Task { await syncManager.applyRecommendedFiling(batch) }
    }

    // MARK: Actions

    // MARK: The "Find duplicates of this" landing

    /// The reveal task's key; see the `.task(id:)` it drives for why each field is in it.
    private struct RevealKey: Equatable {
        let requestID: UUID?
        let isScanning: Bool
        let groupCount: Int
        let scanRoot: String?
    }

    private var revealKey: RevealKey {
        RevealKey(requestID: revealRequest?.id,
                  isScanning: syncManager.isFindingDuplicates,
                  groupCount: syncManager.duplicateGroups.count,
                  scanRoot: syncManager.duplicateScanRoot)
    }

    /// Applies whatever `DuplicateReveal` decides about the current request. Every decision lives
    /// there, so the handoff's behaviour, including "no duplicates of X" never degrading into a
    /// silently empty list, is pinned by `DuplicateRevealTests` without mounting anything. This
    /// only writes state; `applyRevealPlan` is the seam a view test drives.
    ///
    /// `appliedRevealID` is set only once an outcome answers the request. `.waiting` leaves it
    /// alone, so the same request resolves again when the scan publishes. Once recorded,
    /// re-resolving is suppressed, or a group resolving (which moves the key) would re-clear a
    /// search typed since landing. Every outcome, `.waiting` included, goes through the same apply.
    func applyRevealRequest() {
        guard let request = revealRequest, request.id != appliedRevealID,
              let outcome = DuplicateReveal.outcome(for: request,
                                                    groups: syncManager.duplicateGroups,
                                                    isScanning: syncManager.isFindingDuplicates,
                                                    scannedRoot: syncManager.duplicateScanRoot)
        else { return }
        if outcome != .waiting {
            appliedRevealID = request.id
            // Retire the request at the host too: the applied id above is @State and dies with this
            // view, and a request that outlives its answer would replay on the next remount. See
            // `onRevealHandled`.
            onRevealHandled?(request.id)
            // A handoff names one file, and the scope must not answer about a different subject.
            // The outcome is resolved against the whole group list while the rows on screen come
            // through `filteredRows`; see
            // ``OrganizeScopeFilter/revealClearsScope(revealedPath:scope:)`` for why that gap
            // produces a silent "no other copies" and why clearing is the honest resolution.
            if OrganizeScopeFilter.revealClearsScope(revealedPath: request.path, scope: scope) {
                setScope(nil)
            }
        }
        applyRevealPlan(DuplicateReveal.plan(for: outcome, path: request.path))
    }

    /// Writes one plan into this lens's state. Split from the resolve, which is already pure, so a
    /// test can hand it a plan and read back what the lens does with it.
    func applyRevealPlan(_ plan: DuplicateReveal.Plan) {
        if plan.clearsFilterAndQuery { filter = .all }
        if let query = plan.searchQuery {
            searchQueries[.duplicates] = query
            // The field is revealed only when there is something in it: a landing that clears the
            // query also puts the field away, rather than leaving an empty box the user didn't open.
            if query.isEmpty {
                searchExpandedLenses.remove(.duplicates)
            } else {
                searchExpandedLenses.insert(.duplicates)
            }
        }
        // An empty-query landing shows now or never: dropped rather than stored when the list has
        // rows, so it can't sit latent and surface over a later all-clear. See `landingToStore`.
        revealLanding = DuplicateReveal.landingToStore(plan.landing,
                                                       listIsEmpty: syncManager.duplicateGroups.isEmpty)
        if let id = plan.expandsGroupID { expanded.insert(id) }
        revealedGroupID = plan.revealedGroupID
    }

    /// Test seam: what the lens shows as a result of a handoff. One value, so a test asserts the
    /// landing (which group is open, which is marked, what the field says).
    struct RevealState: Equatable {
        var expandedGroupIDs: Set<UUID>
        var revealedGroupID: UUID?
        var landing: DuplicateReveal.Landing?
        var query: String
        var filter: DuplicateMatchFilter
    }

    var revealState: RevealState {
        RevealState(expandedGroupIDs: expanded, revealedGroupID: revealedGroupID,
                    landing: revealLanding, query: searchQueries[.duplicates] ?? "",
                    filter: filter)
    }

    private func toggle(_ id: UUID) {
        // Touching any card by hand ends the landing: the mark says "this is the one you were sent
        // to", and once the user is working the list themselves it no longer applies.
        revealedGroupID = nil
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func apply(_ group: DuplicateGroup) {
        let count = group.recommendedRemovalPaths.count
        guard count > 0 else { return }
        let itemWord = DuplicateRemovalPrompt.itemWord(for: group.matchType.kind, count: count)
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Move \(count) \(itemWord) of “\(group.name)” to the Trash?",
            informativeText: DuplicateRemovalPrompt.informativeText(
                kind: group.matchType.kind,
                keeperName: group.keeper.name,
                keeperLocation: displayPath(group.keeper.path),
                reclaimText: FileSyncManager.formatBytes(group.reclaimableBytes)),
            confirmTitle: "Move to Trash"
        )
        guard ok else { return }
        // Only identical (batch-eligible) groups feed `duplicateSummary.reclaimableBytes`, the
        // figure the ReclaimPill counts down, so only those credit the "freed this session"
        // count-up and the two numbers stay in lockstep. Versions and overlap groups still go to
        // the Trash and stay undoable; they just aren't headlined in this pill.
        let reclaimable = group.isRecommendedForBatch ? group.reclaimableBytes : 0
        Task {
            if await syncManager.resolveDuplicateGroup(group) { creditReclaim(reclaimable) }
        }
    }

    /// Trashes the redundant copies of `groups`, the exact array `applyAllButton` counted. Never
    /// re-derived from `syncManager.duplicateGroups`: under a query that is a different, larger
    /// set, and this dialog's counts must describe what will actually happen.
    private func applyRecommended(_ groups: [DuplicateGroup]) {
        guard !groups.isEmpty else { return }
        let bytes = groups.reduce(0) { $0 + $1.reclaimableBytes }
        let copies = groups.reduce(0) { $0 + $1.recommendedRemovalPaths.count }
        let ok = NativeAlerts.confirmDestructive(
            // From `DuplicateRemovalPrompt`, like the per-group dialog: the wording of the last
            // screen before a delete belongs in a pure, testable type.
            messageText: DuplicateRemovalPrompt.batchMessageText(groupCount: groups.count,
                                                                 providerName: providerName),
            informativeText: DuplicateRemovalPrompt.batchInformativeText(
                copyCount: copies, reclaimText: FileSyncManager.formatBytes(bytes)),
            // The per-group dialog's verb: the honest name for what happens.
            confirmTitle: "Move to Trash"
        )
        guard ok else { return }
        // Credit the batch by the reclaimable it actually erased (the drop in the still-reclaimable
        // figure), so a partial failure counts only what landed: `applyRecommendedDuplicates`
        // returns Void, so measure the delta rather than trust the promised total.
        //
        // The meter is shared: a per-card `apply` finishing during this batch lowers it too, and
        // has already credited itself, so the raw drop would count those bytes twice.
        // `netBatchCredit` nets out what the tally banked meanwhile (see ``ReclaimTally``).
        let before = syncManager.duplicateSummary.reclaimableBytes
        let bankedAtStart = reclaim.totalBytes
        Task {
            await syncManager.applyRecommendedDuplicates(groups)
            let drop = before - syncManager.duplicateSummary.reclaimableBytes
            creditReclaim(reclaim.netBatchCredit(reclaimableDrop: drop, bankedAtStart: bankedAtStart))
        }
    }

    private func merge(_ group: DuplicateGroup) {
        // Belt over the manager's own re-entry guard: no confirm dialog for a group whose merge is
        // already in flight (the button disables, but state can flip between click and handler).
        guard !syncManager.mergingGroupIDs.contains(group.id) else { return }
        let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
        let many = group.redundantCopies.count != 1
        // "About": this is the scan's distinct-content estimate, while the merge plans copies per
        // relative path, re-hashing at merge time, so the two can differ either way. The safety
        // statement, nothing trashed until everything has landed, is the load-bearing part.
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Merge “\(group.name)” into one folder?",
            informativeText: "Copies anything “\(group.keeper.name)” doesn’t already have (about \(unique) item\(unique == 1 ? "" : "s")) into it, then moves the folded cop\(many ? "ies" : "y") to the Trash. Nothing is lost; undo with ⌘Z.",
            confirmTitle: "Merge"
        )
        guard ok else { return }
        Task { await syncManager.mergeDuplicateGroup(group) }
    }

    private func reveal(_ group: DuplicateGroup) {
        let urls = group.copies.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Reclaim pill (H5)

/// The Duplicates summary's reclaim figure: the still-reclaimable number rolls with `numericText`
/// as groups resolve, an optional "… freed this session" caption counts up, and a green glow
/// flashes once per resolve and fades over ~1s.
private struct ReclaimPill: View {
    /// Bytes still reclaimable across the remaining groups (counts *down* as you resolve).
    let reclaimableBytes: Int
    /// "… freed this session": nil until something has been reclaimed, so it is hidden at zero.
    let freedCaption: String?
    /// Bumped once per successful resolve to retrigger the glow.
    let flashToken: Int
    let reduceMotion: Bool

    /// Glow strength, 1 at the instant of a resolve, eased to 0 over ~1s.
    @State private var glow: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .scaledFont(PillVariant.standard.iconFont)
                .symbolRenderingMode(.hierarchical)
            Text("\(FileSyncManager.formatBytes(reclaimableBytes)) reclaimable")
                .scaledFont(PillVariant.standard.numberFont)
                .monospacedDigit()
                // The numeric roll stays under Reduce motion (an acceptable content transition).
                .contentTransition(.numericText())
            if let freedCaption {
                Text("· \(freedCaption)")
                    .scaledFont(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(SemanticColor.success.opacity(0.85))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(SemanticColor.success)
        // No capsule: the reclaimable figure is not a subset, so it isn't a filter, and dressing
        // it like the filter pills would teach that clicking a pill sometimes does nothing. The
        // once-per-resolve glow rides on the text.
        .shadow(color: SemanticColor.success.opacity(0.65 * glow), radius: 6 * glow)
        .fixedSize()
        // Roll the numbers whenever they change (both the count-down and the count-up caption).
        .animation(.easeInOut(duration: 0.35), value: reclaimableBytes)
        .animation(.easeInOut(duration: 0.35), value: freedCaption)
        .onChange(of: flashToken) { _, _ in
            // The glow is pure decoration, so it is dropped under Reduce motion; the numeric roll
            // above still conveys the change.
            guard !reduceMotion else { return }
            glow = 1
            withAnimation(.easeOut(duration: 1.0)) { glow = 0 }
        }
    }
}


/// Where Organize's refined results link to: the Ask Claude chat card that holds the pass. Shown only
/// while a chat holds one (the chat restarts after an hour; the results and Undo stay).
public struct LensRefineChatLink {
    public var isAvailable: () -> Bool
    public var show: () -> Void
    public init(isAvailable: @escaping () -> Bool, show: @escaping () -> Void) {
        self.isAvailable = isAvailable
        self.show = show
    }
}
