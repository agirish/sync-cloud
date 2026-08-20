import AppKit
import Design
import Events
import Settings
import SwiftUI
import Sync

/// How big the setup card is, and how much of it the current step gets.
///
/// **A separate table from `SettingsSheetMetrics` rather than a reuse of it**, for the reason that
/// one is not visible from here at all: it lives in the `Settings` module and is internal. The
/// *rule* is copied deliberately, though, and it is the important half — clamp to the host window
/// so the card can never hang off the edge of a small display. That is the exact trap the settings
/// sheet fell into: every fit test there measured the UNCLAMPED opening, so a card raised to 758pt
/// passed them all and still scrolled on a 1280×800 screen, where the window has ~740pt to give.
enum SetupSheetMetrics {
    /// The card's width. Fixed, because a form whose measure changed between steps would reflow
    /// every line of prose in it as you moved.
    static let cardWidth: CGFloat = 720

    /// The rail's width — the same 176pt the Settings rail uses, because they are the same kind of
    /// list in the same kind of card and two widths would read as a mistake.
    static let railWidth: CGFloat = 176

    /// The bottom chrome the step's own content does not get.
    ///
    /// Checked against the real footer by `theFooterFitsTheHeightTheOpeningIsComputedFrom`: an
    /// unverified constant here would make every height this file computes wrong by the difference.
    static let footerHeight: CGFloat = 56

    /// Breathing room kept between the card and the window edge.
    static let hostMargin: CGFloat = 48

    /// **One height for every step.**
    ///
    /// It was briefly sized to each step, which removed the dead space and introduced something
    /// worse: the card grew and shrank as you moved — 563pt on Sources, 360pt on People — and a
    /// container that resizes under a form draws the eye to the container. A setup card should be a
    /// steady frame you fill in, not a thing that moves while you read it.
    ///
    /// **Measured against the steps that can be measured.** You lays out at 530pt, Done at 484pt
    /// and People at 412pt on a 1200×740 window; 610 gives the tallest of those 24pt for a copy
    /// edit. (You was 484 too until it gained the text-size preset row, which costs 46pt — the
    /// number moved because the content did, which is the whole method here.)
    ///
    /// **The ceiling is the window, not this constant.** A 1200×740 host leaves 692pt after
    /// `hostMargin`, so there is real room above 610; what stops it growing further is the step
    /// below, not the display. Re-measure before raising it again — and re-measure the steps, not
    /// this number.
    /// Sources is deliberately not in that set — it draws a row per source and a user may add any
    /// number of folders, so no height promises to hold it (at seven sources it wants 635pt, more
    /// than a 1280×800 display can give *any* card). It scrolls past a count
    /// `sourcesOutgrowsTheOpeningEventually` names, which is the same bargain the settings sheet
    /// strikes with its Providers tab — the difference being that this one has the measurement
    /// under it rather than a label.
    ///
    /// What keeps this from being the old 648pt problem is the other half of the change: every
    /// step's closing line is pinned to the bottom of the pane, so the slack sits between the
    /// controls and their caption rather than trailing off the end of the content.
    static let cardHeight: CGFloat = 610

    /// Below this a rail plus a usable content column stops being possible; the card stops shrinking
    /// and its step scrolls instead. Overflowing a tiny window beats a card too small to use.
    static let minCardHeight: CGFloat = 360

    /// The width the card actually gets, clamped to the window it is centred in.
    static func resolvedWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        let wanted = cardWidth * scale
        let room = max(availableSize.width - hostMargin, 460)
        return min(wanted, room)
    }

    /// The height the card actually gets, clamped to the window it is centred in.
    ///
    /// Clamped for the reason the settings sheet learned the hard way: a card sized in points on a
    /// 1280×800-class display has ~740pt of window to live in, and a number chosen without that in
    /// mind hangs off the edge while every test still passes.
    static func resolvedHeight(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        let room = max(availableSize.height - hostMargin, minCardHeight)
        return min(cardHeight * scale, room)
    }

    /// The height a step's own content gets before it has to scroll.
    static func contentHeight(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        resolvedHeight(availableSize: availableSize, scale: scale) - footerHeight
    }

    /// The width a step's content is laid out at.
    static func contentWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        resolvedWidth(availableSize: availableSize, scale: scale) - railWidth
    }
}

/// The setup form: a dimmed-backdrop card with a step rail, replacing the six-page welcome tour.
///
/// **Hosted the same way Settings and Help are** — an in-window overlay rather than a window of its
/// own. It is the same surface on a first launch and on a manual re-run from Help, which is the
/// property that made a card the right choice: a separate window would have needed its own restore
/// state, its own ⌘W meaning, and a story for what happens when the main window is closed, all to
/// deliver a form that is only ever used in front of the app.
struct SetupSheet: View {
    @ObservedObject var settings: SettingsManager
    /// The roster, when this machine has a profile to hold one. **Nil is the ordinary state on the
    /// machine this form is for** — no profile means no `profiles/<id>/` to write `people.json`
    /// into — and it is why ``SetupDraft`` exists.
    var peopleStore: PeopleStore?

    /// The roster to read and write, preferring the engine's own over the one this view was built
    /// with.
    ///
    /// **The captured property goes stale the moment a walk succeeds, and nothing tells the view.**
    /// `FileSyncManager`'s filing artifacts — `filingPeopleStore`, `filingFolderProfile` and the
    /// rest — are plain `var`s rather than `@Published`, so `FilingArtifacts.attach(to:)` sets a
    /// roster and triggers no SwiftUI invalidation at all. `peopleStore` was read once at
    /// construction, so after the Folders step wrote a profile it was still nil: the draft had a
    /// roster to land in and could not see it, and the hand-off stage A's draft and stage B's walk
    /// were built for did nothing.
    ///
    /// Reading through the manager fixes it without making six properties `@Published` and paying
    /// for a re-render on every scan: the walk's own `@State` change re-renders this view, and by
    /// then the manager holds the new store.
    private var roster: PeopleStore? { syncManager?.filingPeopleStore ?? peopleStore }

    /// Whether this machine has a surveyed tree **now**, not when the view was built.
    ///
    /// The same staleness as `roster`, and it reads on the Done step: after a walk the passed-in
    /// flag still said no, so Done went on offering "learning your folders comes next" about a tree
    /// the user had just finished learning.
    private var hasProfile: Bool {
        syncManager?.filingFolderProfile != nil || hasFilingProfile
    }
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let availableSize: CGSize
    /// Whether this machine already has a surveyed tree. Drives the survey step's copy, which must
    /// not offer to learn a tree that is already learned.
    let hasFilingProfile: Bool
    /// The engine, for the walk. Nil in a layout test, which never runs one.
    var syncManager: FileSyncManager?
    /// Re-reads the filing artifacts after a profile lands, so it takes effect without a relaunch.
    let onProfileWritten: () -> Void
    let onOpenSettings: (SettingsView.SettingsTab) -> Void
    /// The user reached the end. The caller persists the completed flag.
    let onFinish: () -> Void
    /// Esc, ✕, a click outside, or *Not now*. The caller does **not** persist anything.
    let onDismiss: () -> Void

    @Environment(\.appFontScale) private var fontScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var screen: SetupFlow.Screen
    @State private var draft = SetupDraft()
    @State private var fullNameField = ""
    @State private var newPersonField = ""
    @State private var isRefreshingProviders = false
    /// The first field on the first step. A form that opens with nothing focused asks you to click
    /// before you can type.
    @FocusState private var nameFieldFocused: Bool
    /// The folder the walk will learn. Seeded from the primary source, changeable.
    @State private var walkRoot: URL?
    /// Household names the walk proposed, with their evidence. Empty until a root is known.
    @State private var peopleCandidates: [PersonCandidate] = []
    /// Whether the place walk has been asked for, so a step revisited does not walk again.
    @State private var askedForPlaces = false
    /// Whether the proposal walk has been asked for, so it happens once per opening.
    @State private var askedForPeople = false
    /// What the walk proposed as places, with their evidence. Empty until a root is chosen.
    @State private var placeCandidates: [JurisdictionCandidate] = []
    /// The ones the user ticked. **Nothing starts ticked** — see `placeChip`.
    @State private var confirmedPlaces: Set<String> = []
    @State private var walkPhase: WalkPhase = .idle
    /// Whether the user picked the root themselves. Once they have, the primary source no longer
    /// moves it — an explicit choice must outrank a default that arrives later.
    @State private var rootChosenByHand = false
    @State private var walkStatus = ""

    /// Where the walk has got to. Its own type so the step can render one thing at a time rather
    /// than juggling three booleans that can disagree.
    enum WalkPhase: Equatable {
        case idle
        case running
        case done(FileSyncManager.FolderWalkReport)
        case failed(String)

        var isDone: Bool { if case .done = self { return true }; return false }
    }
    @AppStorage(SetupFlow.primarySourceDefaultsKey) private var primarySourceId = ""
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw = LiquidGlassHue.blue.rawValue
    @AppStorage(GeneralSettings.notifyOnBackgroundCompletionKey) private var notifyInBackground = false
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent = FontSize.medium.percent
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw = ListDensity.comfortable.rawValue

    /// The text size and row spacing as one pair, for the preset row on the You step. It writes
    /// both settings and stores nothing of its own — see `SizePreset`.
    private var setupFontSize: Binding<FontSize> {
        Binding(get: { FontSize(percent: fontSizePercent) }, set: { fontSizePercent = $0.percent })
    }

    private var setupDensity: Binding<ListDensity> {
        Binding(get: { ListDensity(rawValue: listDensityRaw) ?? .comfortable },
                set: { listDensityRaw = $0.rawValue })
    }

    /// **The opening screen is resolved here rather than in `onAppear`.** `onAppear` fires after
    /// the first layout, so a re-run would render the welcome card — “four short questions, then
    /// SyncCloud learns your folders” — for a frame before replacing it with the rail. Reading the
    /// completed flag straight from `UserDefaults` is the same store the `@AppStorage` below reads;
    /// a property wrapper simply cannot be consulted before `self` exists.
    init(settings: SettingsManager,
         peopleStore: PeopleStore?,
         glassHue: LiquidGlassHue,
         glassLevel: GlassLevel,
         surfaceTint: Double,
         availableSize: CGSize,
         hasFilingProfile: Bool,
         syncManager: FileSyncManager? = nil,
         defaults: UserDefaults = .standard,
         // **Injectable so a fit test can measure the step with chips in it.** The Folders step
         // grows with the number of places the walk proposed, and a fixture built with no engine
         // proposes none — which is measuring the empty state, the way the Organize tab's fit guard
         // passed for a release while real users scrolled.
         placeCandidates: [JurisdictionCandidate] = [],
         peopleCandidates: [PersonCandidate] = [],
         onProfileWritten: @escaping () -> Void = {},
         onOpenSettings: @escaping (SettingsView.SettingsTab) -> Void,
         onFinish: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.settings = settings
        self.peopleStore = peopleStore
        self.glassHue = glassHue
        self.glassLevel = glassLevel
        self.surfaceTint = surfaceTint
        self.availableSize = availableSize
        self.hasFilingProfile = hasFilingProfile
        self.syncManager = syncManager
        _placeCandidates = State(initialValue: placeCandidates)
        _peopleCandidates = State(initialValue: peopleCandidates)
        self.onProfileWritten = onProfileWritten
        self.onOpenSettings = onOpenSettings
        self.onFinish = onFinish
        self.onDismiss = onDismiss
        _screen = State(initialValue: SetupFlow.initialScreen(
            hasCompletedSetup: defaults.bool(forKey: SetupFlow.hasCompletedDefaultsKey),
            hasFilingProfile: hasFilingProfile))
    }

    private var draftURL: URL? { SetupDraftStore.defaultURL() }

    /// What the log calls the current screen.
    private var screenName: String {
        switch screen {
        case .welcome: return "the welcome screen"
        case .step(let step): return "step \(step.number), \(step.displayName)"
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            card
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
        }
        .transition(.opacity)
        .onAppear {
            loadDraft()
            // **Something has to be primary before the Sources step is looked at.** With no
            // selection the step renders every radio empty, which reads as "SyncCloud has not
            // decided" when what it means is "nobody has decided yet" — and the survey step behind
            // it then has no source to describe. The first enabled source is the honest default:
            // it is what discovery put at the top, and changing it is one click.
            reconcilePrimary()
            if case .step(.you) = screen { nameFieldFocused = true }
            seedWalkRoot()
            proposeForCurrentStep()
            Logger.shared.info("Setup opened on \(screenName) — "
                               + "\(settings.availableProviders.count) source(s) discovered, "
                               + "roster \(roster == nil ? "not writable yet (no profile)" : "available")")
        }
        // Discovery republishes the list on every refresh and every folder added, and the primary
        // may have been in what changed.
        .onChange(of: settings.availableProviders.map(\.id)) { _, _ in reconcilePrimary() }
        // **The root follows the primary source, because Sources is answered after this view
        // appeared.** `seedWalkRoot` ran once in `onAppear` and only when the root was nil, so
        // changing which source is primary on step 2 left the Folders step still aimed at the one
        // discovery happened to put first — the step would learn a tree the user had just moved
        // away from, and nothing on screen would disagree.
        .onChange(of: primarySourceId) { _, _ in
            seedWalkRoot()
            // Only if the user is standing on a step that needs it — otherwise the walk waits until
            // they get there.
            proposeForCurrentStep()
        }
        // Each step asks for what it needs when it is reached, once per root.
        .onChange(of: screen) { _, _ in proposeForCurrentStep() }
    }

    /// The hues offered here — a spread across the palette, not the whole of it.
    ///
    /// `.none` is deliberately absent: it means "follow the system accent" and paints the same blue
    /// as `.blue`, so side by side the row began with two swatches that could not be told apart.
    /// Somebody who wants it wants Settings ▸ Appearance, where every hue is named.
    static let offeredHues: [LiquidGlassHue] = [.blue, .teal, .green, .amber, .coral, .purple, .graphite]

    /// The box a panel's illustration draws in, before it is scaled down into the strip.
    ///
    /// The illustrations were drawn for the tour's 120pt header and have fixed internal geometry —
    /// `BrowseArt`'s columns are 46×92 points — so shrinking them means scaling, and scaling means
    /// knowing the box they were drawn for.
    static let panelArtBox = CGSize(width: 150, height: 110)
    /// How far down. 0.44 puts a 110pt illustration in 48pt, which is the tallest a three-up strip
    /// can carry above two lines of copy and still leave the outline list room on the card.
    static let panelArtScale: CGFloat = 0.44

    private var cardWidth: CGFloat {
        SetupSheetMetrics.resolvedWidth(availableSize: availableSize, scale: fontScale)
    }

    private var cardHeightResolved: CGFloat {
        SetupSheetMetrics.resolvedHeight(availableSize: availableSize, scale: fontScale)
    }

    @ViewBuilder
    private var card: some View {
        Group {
            switch screen {
            case .welcome: welcomeScreen
            case .step(let step): stepScreen(step)
            }
        }
        .frame(width: cardWidth, height: cardHeightResolved)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        .groundedGlassCard(level: glassLevel)
        .shadow(color: .black.opacity(0.3), radius: 30, y: 8)
        .overlay(alignment: .topTrailing) {
            CloseButton { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc")
                .padding(4)
                .help(ShortcutHint.tooltip("Not now", "esc"))
                .accessibilityLabel("Not now")
        }
    }

    // MARK: - Welcome

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    SetupIllustration(art: .welcome, leftName: paneNames.0, rightName: paneNames.1)
                        .frame(height: 104)
                        .accessibilityHidden(true)
                    Text("Welcome to SyncCloud")
                        .scaledFont(.largeTitle.weight(.semibold))
                    Text(SetupFlow.welcomeBlurb)
                        .scaledFont(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                HStack(alignment: .top, spacing: 10) {
                    ForEach(SetupFlow.panels, id: \.title) { panel in
                        VStack(spacing: 7) {
                            // **Scaled, not framed.** A `frame(height:)` does not resize its
                            // content — the illustrations draw at their natural ~120pt and a smaller
                            // frame simply lets them overflow, which is what the first render of
                            // this strip did: Compare's panes spilled across both its neighbours and
                            // Organize's folders sat on top of its own title.
                            SetupIllustration(art: panel.art,
                                              leftName: paneNames.0, rightName: paneNames.1)
                                .frame(width: Self.panelArtBox.width, height: Self.panelArtBox.height)
                                .scaleEffect(Self.panelArtScale)
                                .frame(width: Self.panelArtBox.width * Self.panelArtScale,
                                       height: Self.panelArtBox.height * Self.panelArtScale)
                                .accessibilityHidden(true)
                            Text(panel.title).scaledFont(.callout.weight(.semibold))
                            Text(panel.blurb)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.07)))
                    }
                }

                quietNote(SetupFlow.privacyClaim, systemImage: "lock")
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 24)


            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 10) {
                Text("Run this again any time from Help ▸ Set Up SyncCloud…")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Not now") { onDismiss() }
                Button("Set up SyncCloud") { advance() }
                    .buttonStyle(.borderedProminent)
                    .chromeHover()
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("⏎")
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - A step

    @ViewBuilder
    private func stepScreen(_ step: SetupFlow.Step) -> some View {
        HStack(spacing: 0) {
            rail(current: step)
            Divider()
            VStack(spacing: 0) {
                // **Scrolls only when the card has stopped growing.** The card is sized to its
                // content, so on every ordinary step there is nothing to scroll and a greedy
                // `ScrollView` would simply claim the whole card again — which is the shape this
                // replaced, where four of five steps floated in the space the tallest one needed.
                ScrollView {
                    stepContent(step)
                        // At least the height of the pane, so the closing line sits on the bottom
                        // edge rather than under the controls — and more than that when a step
                        // genuinely outgrows the card, which is when this scrolls.
                        .frame(minHeight: SetupSheetMetrics.contentHeight(availableSize: availableSize,
                                                                          scale: fontScale),
                               alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                Divider()
                footer(step)
            }
        }
    }

    /// A step's own content, without the scroll view that holds it.
    ///
    /// **Split out so a fit test can measure the thing that actually overflows**, and so the card
    /// can size itself to it. A `ScrollView` accepts any height it is offered, so a measurement
    /// taken on the card answers the card's own height however tall the step inside it is.
    @ViewBuilder
    func stepContent(_ step: SetupFlow.Step) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .you: youStep
            case .sources: sourcesStep
            case .people: peopleStep
            case .survey: surveyStep
            case .done: doneStep
            }

            // **The slack goes here, above the closing line, not after it.**
            //
            // Every step is drawn in a card sized for the tallest of them, so all but one has空
            // room to place. Left at the end of the content it reads as a card that ran out of
            // things to say; put between the controls and the sentence that explains them, it reads
            // as the margin a form ought to have — and the closing line lands in the same place on
            // every step, which is its own kind of order.
            Spacer(minLength: 14)

            Text(stepFootnote(step))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity,
                       alignment: step == .done ? .center : .leading)
        }
        // **No `maxHeight: .infinity` here.** A view that fills whatever it is offered cannot be
        // measured: `fittingSize` on it answers the offer rather than the content, which is the
        // same trap as measuring a `ScrollView`. It reported Sources at 635pt against a real 521.
        // The pane gives it a floor instead — see `stepScreen` — so the spacer expands there and
        // the natural height is still what a test sees.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    /// The line that closes each step, pinned to the bottom of the pane.
    private func stepFootnote(_ step: SetupFlow.Step) -> String {
        switch step {
        case .you:
            return "Startup, text size and the rest are in Settings ▸ General."
        case .sources:
            return "Primary only decides what gets learned. Every enabled source is browsable and "
                + "comparable either way, and you can change which one is primary later."
        case .people:
            return "A first name is enough here. Full names and nicknames are worth adding in "
                + "Settings ▸ People, where they do the most work."
        case .survey:
            return "Learning is quick — it reads names only. Reading inside your documents is a "
                + "longer pass that comes later."
        case .done:
            return "Run setup again from Help ▸ Set Up SyncCloud…"
        }
    }

    /// The primary source, where one is set.
    private var primaryProvider: CloudProvider? {
        settings.availableProviders.first { $0.id == primarySourceId }
    }

    private func rail(current: SetupFlow.Step) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Setup")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.bottom, 6)
            ForEach(SetupFlow.Step.allCases, id: \.self) { step in
                railRow(step, current: current)
            }
            Spacer(minLength: 12)
            Text("Everything here is in Settings afterwards.")
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 9)
        .frame(width: SetupSheetMetrics.railWidth, alignment: .leading)
    }

    /// One rail row.
    ///
    /// **Quieter than it was, and the reason is that there were three blues on screen at once.** The
    /// selected row was a filled accent pill, every completed row was a filled accent check, and the
    /// primary button is accent too — so the rail, which is the least important thing on the card,
    /// read louder than the question being asked. Selection is now a soft fill with an accent label,
    /// the way a macOS sidebar marks a row, and a finished step is a plain secondary checkmark.
    private func railRow(_ step: SetupFlow.Step, current: SetupFlow.Step) -> some View {
        let isCurrent = step == current
        let isDone = step.number < current.number
        return HStack(spacing: 9) {
            Image(systemName: isDone ? "checkmark" : step.symbolName)
                .scaledFont(.callout)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint)
                                 : isDone ? AnyShapeStyle(Color.secondary)
                                 : AnyShapeStyle(Color.secondary.opacity(0.7)))
                .frame(width: 17)
            Text(step.displayName)
                .scaledFont(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        // The rail reports where you are; it is not a way to skip ahead past answers a later step
        // depends on. Steps already visited are reachable with Back.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.displayName), step \(step.number) of \(SetupFlow.Step.allCases.count)"
                            + (isDone ? ", done" : isCurrent ? ", current" : ""))
    }

    /// The card's bottom chrome.
    ///
    /// **`internal`, so `SetupSheetMetrics.footerHeight` can be checked against it rather than
    /// trusted.** That constant is subtracted from the card to get the height the content may take,
    /// so if the real footer is taller than the number, every height this form computes is wrong by
    /// the difference — and nothing else would ever say so.
    func footer(_ step: SetupFlow.Step) -> some View {
        HStack(spacing: 10) {
            if SetupFlow.previous(before: .step(step)) != nil {
                Button("Back") { retreat() }
            }
            Spacer(minLength: 8)
            // The lock sat immediately beside Back, where a bordered neighbour made it read as a
            // second button. It belongs with the step counter: both are things the card is telling
            // you, not things you can press.
            Label(SetupFlow.privacyFooter, systemImage: "lock")
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            if step == .done {
                Button("Start browsing") { finish() }
                    .buttonStyle(.borderedProminent)
                    .chromeHover()
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("⏎")
            } else {
                Text("Step \(step.number) of \(SetupFlow.Step.allCases.count)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .chromeHover()
                    .keyboardShortcut(.defaultAction)
                    .shortcutKeycap("⏎")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Step 1, You

    private var youStep: some View {
        Group {
            stepHeader(.you, "Who are you?",
                       "SyncCloud reads names out of your documents to work out whose they are. It "
                       + "needs to know yours, and every form a document might print it in.")

            section("Your name") {
                VStack(alignment: .leading, spacing: 5) {
                    // **Not saved per keystroke.** This used to write the whole draft — a JSON
                    // encode and an atomic file replace, on the main actor — for every character
                    // typed into it. The draft is written when the step is left, when Return
                    // commits a field, and when a person is added or removed, which is every point
                    // at which an answer is actually finished.
                    TextField("First name", text: $draft.yourName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused($nameFieldFocused)
                        .onSubmit { saveDraft() }
                    Text("This is what your folders call you — usually a first name.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            section("Full names on documents") {
                chipRow(draft.yourFullNames) { name in
                    draft.yourFullNames.removeAll { $0 == name }
                    saveDraft()
                }
                // **One field, no Add button.** The button was disabled until you typed and then
                // did what ⏎ already did — a second control for one action, sitting there greyed
                // out most of the time. The placeholder carries the instruction instead.
                TextField("Add a form, then press ⏎", text: $fullNameField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(commitFullName)
                Text("A full name is matched before any single word, so a shared surname stops "
                     + "making two people out of one document.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Preferences") {
                // **First in the block, and the only one here that is not a matter of taste.**
                // Somebody who needs larger text needs it for the four steps that follow, not
                // after them — and because the sheet is inside `appFontSizeFromSettings()`, the
                // card they are reading resizes under the click, which is the whole argument for
                // asking here rather than leaving it in Settings ▸ Appearance.
                //
                // The tiles show a miniature rather than naming a row spacing: this runs before
                // the user has seen a file list, so "Comfortable" and "Compact" name nothing yet.
                // The fine 5%-step slider stays in Settings; setup asks one question.
                //
                // **Label left, control right — the same column the rows below it keep**, and one
                // row rather than a stack. That is a budget, not a preference: the You step shares
                // a card with People and Done, and a first draft with its own label line and
                // caption put the step 88pt past what a 1280×800 display can show without
                // scrolling. The caption lives in Settings, where there is room; here the tiles
                // are the explanation.
                HStack {
                    Text("Text size").scaledFont(.callout)
                    Spacer(minLength: 12)
                    // **No fixed width.** It was framed at 232pt, which the row's own minimum
                    // outgrows at 125% (235pt) and 135% (247pt) — and a preset row narrower than
                    // its content does not shrink, it truncates: the tiles shipped reading
                    // "Comfor…". Letting it take the trailing space means the only thing that has
                    // to fit is the card, which `theSetupTextSizeRowFitsTheCardAtEveryTextSize`
                    // measures.
                    SizePresetRow(fontSize: setupFontSize, density: setupDensity, style: .specimen)
                }
                HStack {
                    Text("Appearance").scaledFont(.callout)
                    Spacer(minLength: 12)
                    Picker("Appearance", selection: $appearanceModeRaw) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // The selection paints the SYSTEM accent otherwise, while every other control
                    // in this card follows the hue the user picked one row down. `SegmentedAccentTests`
                    // source-scans every `.segmented` picker in the app for this — and it caught
                    // this one, from a package suite the app-target test run never executes.
                    .accentedSegments(glassHue)
                    .fixedSize()
                }
                HStack {
                    Text("Accent").scaledFont(.callout)
                    Spacer()
                    HStack(spacing: 7) {
                        // **Not every hue.** Twelve dots is a wall, and the first two of them —
                        // `.none` and `.blue` — paint the same blue, so the row opened with what
                        // looked like the same colour twice. The full set lives in
                        // Settings ▸ Appearance, where it has room and a label each.
                        ForEach(Self.offeredHues, id: \.rawValue) { hue in
                            Button { selectedHueRaw = hue.rawValue } label: {
                                Circle()
                                    .fill(hue.accentColor)
                                    .frame(width: 17, height: 17)
                                    .overlay {
                                        if hue.rawValue == selectedHueRaw {
                                            Circle().strokeBorder(hue.accentColor, lineWidth: 1.5)
                                                .padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(hue.displayName)
                            .accessibilityLabel(hue.displayName)
                        }
                    }
                }
                // **Label left, control right — the same column the two rows above it set up.**
                // A `Toggle` with its own title puts the switch immediately after the text, which
                // broke that column and made the block read as two unrelated groups.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify me when a long pass finishes").scaledFont(.callout)
                        Text("Surveys, duplicate scans and bulk copies")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $notifyInBackground)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    private func commitFullName() {
        let name = fullNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let known = draft.yourFullNames.contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if !known { draft.yourFullNames.append(name) }
        fullNameField = ""
        saveDraft()
    }

    // MARK: - Step 2, Sources

    private var sourcesStep: some View {
        Group {
            stepHeader(.sources, "SyncCloud found \(settings.availableProviders.count) "
                       + "place\(settings.availableProviders.count == 1 ? "" : "s") on this Mac",
                       "Turn off the ones you do not use. One of them is primary: the tree "
                       + "SyncCloud learns your folder conventions from.")

            if settings.availableProviders.isEmpty {
                emptyNote("No cloud accounts were found in ~/Library/CloudStorage, and iCloud Drive "
                          + "is not set up. Add any folder on this Mac to get started — Compare and "
                          + "Organize work the same over it.")
            } else {
                VStack(spacing: 0) {
                    ForEach(settings.availableProviders) { provider in
                        sourceRow(provider)
                        if provider.id != settings.availableProviders.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06)))
            }

            HStack(spacing: 8) {
                Button("Add Folder…", action: addFolder).controlSize(.small)
                Button(isRefreshingProviders ? "Refreshing…" : "Refresh", action: refreshProviders)
                    .controlSize(.small)
                    .disabled(isRefreshingProviders)
                Spacer()
                Text("\(settings.enabledProviders.count) enabled")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        }
    }

    private func sourceRow(_ provider: CloudProvider) -> some View {
        let isEnabled = settings.isEnabled(provider.id)
        let isValid = settings.isPathValid(for: provider.id)
        let isPrimary = primarySourceId == provider.id
        return HStack(spacing: 11) {
            ProviderLogo(provider.imageName, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(sourceName(provider))
                        .scaledFont(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // **The badge appears only when something is wrong.** Seven green "Valid path"
                    // pills said nothing seven times and made the one red one hard to find; a list
                    // where every row is decorated has no way left to point at a row.
                    if !isValid {
                        Text("Can't be found")
                            .scaledFont(.caption2.weight(.medium))
                            .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.caution))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(SemanticColor.caution.opacity(0.16)))
                    }
                }
                Text(sourceDetail(provider))
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(provider.path)
            }
            Spacer(minLength: 10)

            // **The primary control says what it is.** It was a bare radio circle beside a switch,
            // with nothing in the row naming it — the header sentence explained the idea and the
            // control itself explained nothing. A labelled button is both the affordance and its
            // own caption, and the chosen one reads as a state rather than as another thing to press.
            Button {
                primarySourceId = provider.id
            } label: {
                Label(isPrimary ? "Primary" : "Make primary",
                      systemImage: isPrimary ? "star.fill" : "star")
                    .scaledFont(.caption)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(isPrimary ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        if isPrimary {
                            Capsule().fill(Color.accentColor.opacity(0.14))
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || isPrimary)
            // The label already reads "Primary"; without this the chosen row announces a button
            // somebody can press, which is exactly what it is not.
            .opacity(isEnabled ? 1 : 0)
            .help(isPrimary ? "SyncCloud learns your folder conventions from this source."
                  : "Learn folder conventions from \(provider.displayName) instead.")

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { settings.setEnabled($0, for: provider.id); reconcilePrimary() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(isEnabled && !settings.canDisable(provider.id))
                .help(isEnabled && !settings.canDisable(provider.id)
                      ? "At least one source must remain enabled."
                      : "Show \(provider.displayName) in the pane sidebar.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(isEnabled ? 1 : 0.5)
    }

    /// The provider's name without the account in it.
    ///
    /// **The account is what makes these truncate.** `Google Drive (abhishek.girish@gmail.com)` is
    /// 41 characters and clipped mid-address in a row that also holds a badge, a primary control and
    /// a switch — and the clipped half is the only part that tells two Drive accounts apart. The
    /// name goes on the first line and the account leads the second, where it has the width.
    private func sourceName(_ provider: CloudProvider) -> String {
        guard let open = provider.displayName.firstIndex(of: "("),
              provider.displayName.hasSuffix(")") else { return provider.displayName }
        return String(provider.displayName[..<open]).trimmingCharacters(in: .whitespaces)
    }

    /// What identifies this source at a glance.
    ///
    /// **The same rule Settings ▸ Sources follows, and for its reason**: a cloud account is
    /// identified by the account, and its path is a consequence of that — while a folder source's
    /// id is a UUID that says nothing to anyone, so the folder *is* the path.
    ///
    /// Showing both was worse than either. `OneDrive` over
    /// `HewlettPackardEnterp…dEnterprise/Documents` says one thing twice and truncates in the
    /// middle of both halves; the full path is on the row's tooltip, where it costs nothing.
    private func sourceDetail(_ provider: CloudProvider) -> String {
        if provider.isLocalFolder { return shortPath(provider.path) }
        guard let open = provider.displayName.firstIndex(of: "("),
              provider.displayName.hasSuffix(")") else { return shortPath(provider.path) }
        return String(provider.displayName[provider.displayName.index(after: open)...].dropLast())
    }

    /// A source path with the home directory folded to `~`, which is most of what the long ones say.
    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Keeps the primary pointer on a source that is actually enabled.
    ///
    /// **Turning off the primary source has to move the pointer, not just dim it.** A primary id
    /// naming a disabled source is a survey aimed at a tree the user has taken out of the app, and
    /// nothing downstream would say so — the survey step would simply show a row that is not there.
    private func reconcilePrimary() {
        let enabled = settings.enabledProviders
        if enabled.contains(where: { $0.id == primarySourceId }) { return }
        primarySourceId = enabled.first?.id ?? ""
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a source"
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = settings.addFolderSource(path: url.path)
        if primarySourceId.isEmpty { primarySourceId = id }
    }

    private func refreshProviders() {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        Task {
            await settings.discoverProviders()
            await MainActor.run {
                isRefreshingProviders = false
                reconcilePrimary()
            }
        }
    }

    // MARK: - Step 3, People

    private var peopleStep: some View {
        Group {
            stepHeader(.people, "Who else is in your folders?",
                       hasProfile
                       ? "These are the people Organize files for. Add anyone it should know about."
                       : "Add anyone your documents are filed for. Once SyncCloud has learned your "
                       + "folders it will offer the names it found there too.")

            // **Said before the list, because while either of these holds the edits below it will
            // not be written.** `PeopleStore.save()` refuses over a `people.json` it could not read
            // (this session's roster is a seed, and writing it would replace the real household with
            // a guess) and over one whose records it had to collapse (a copy-pasted id, where a
            // whole-file write would delete a record the user typed). Settings ▸ People carries the
            // same warning for the same reason; without it, adding somebody here is a change that
            // appears to work and does nothing.
            if let store = roster, store.rosterIsUnreadable {
                quietNote("This Mac's people.json exists but could not be read, so the list below "
                            + "is what SyncCloud guessed from your folder names. Nothing you change "
                            + "here will be saved until the file is fixed — Settings ▸ People says "
                            + "where it is.", systemImage: "exclamationmark.triangle")
            } else if let store = roster, !store.repeatedRosterIds.isEmpty {
                quietNote("Two people in this Mac's people.json share an id, so one record was "
                            + "dropped when the file was read. Nothing you change here will be saved "
                            + "until they have separate ids — Settings ▸ People names which.",
                            systemImage: "exclamationmark.triangle")
            }

            if rosterNames.isEmpty {
                emptyNote("Nobody yet. You are on the list already — this is for everyone else whose "
                          + "documents live in your folders.")
            } else {
                VStack(spacing: 0) {
                    ForEach(rosterNames, id: \.self) { name in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            Text(name).scaledFont(.callout)
                            // The roster already knows who these people are to the user, and a
                            // column of bare first names is the one thing this list can be that a
                            // household is not. Absent for a draft person, who has no relationship
                            // until they reach a roster.
                            if let relationship = relationship(of: name) {
                                Text(relationship)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Remove") { removePerson(named: name) }
                                .controlSize(.small)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(rosterIsReadOnly)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        if name != rosterNames.last { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06)))
            }

            if !visiblePeopleCandidates.isEmpty {
                section("Found in your folders") {
                    Text("These folders sit under a household folder, so they might be people. Add "
                         + "the ones that are.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WrapLayout(spacing: 7) {
                        ForEach(visiblePeopleCandidates.prefix(12)) { candidate in
                            personChip(candidate)
                        }
                    }
                }
            }

            TextField("Add a person, then press ⏎", text: $newPersonField)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(commitPerson)
                .disabled(rosterIsReadOnly)

        }
    }

    /// The household as it stands — the roster where one exists, the draft otherwise.
    ///
    /// **Your own record is excluded**, because Step 1 is where it is edited and a list that
    /// repeated you here would offer a Remove that unpicks an answer given two screens ago.
    private var rosterNames: [String] {
        if let store = roster {
            let mine = draft.yourName.trimmingCharacters(in: .whitespacesAndNewlines)
            return store.people
                // **Two ways to be you, and the second is not redundant.** A roster seeded from the
                // survey's person axis carries no relationships at all, so on a machine whose
                // `people.json` has never been hand-edited nothing answers to "me" — and matching
                // on the draft name alone then listed the user among "everyone else", with a Remove
                // button beside them. Removing yourself from your own household is not a thing this
                // step should be able to do.
                .filter { $0.relationship?.lowercased() != "me" }
                .map(\.displayName)
                .filter {
                    mine.isEmpty || $0.compare(mine, options: [.caseInsensitive, .diacriticInsensitive])
                        != .orderedSame
                }
        }
        return draft.others.map(\.displayName)
    }

    /// Whether the roster on this Mac is one the store will refuse to write.
    ///
    /// Both refusals live in `PeopleStore.save()`; `rosterIsReadOnly` is the store's own name for
    /// the pair. Read here so the form does not offer edits that would silently do nothing.
    private var rosterIsReadOnly: Bool { roster?.rosterIsReadOnly ?? false }

    /// The proposals still worth showing.
    ///
    /// **Filtered here rather than only when they are fetched.** `proposePeople` passes the roster
    /// as `known`, which covers who was there when the walk ran — and not somebody added afterwards
    /// by typing their name into the field below, or removed and re-added, or added on a previous
    /// visit to this step. A chip offering to add a person who is already in the list above it reads
    /// as the app having lost track, and this is the one place that can see both lists at once.
    private var visiblePeopleCandidates: [PersonCandidate] {
        let already = Set(rosterNames.map { $0.lowercased() }
                          + [draft.yourName.lowercased()]
                          + draft.others.map { $0.displayName.lowercased() })
        return peopleCandidates.filter { !already.contains($0.name.lowercased()) }
    }

    /// One proposed household name, with the folder that vouches for it.
    ///
    /// **Adding is one click and nothing is added by default.** The rule over-proposes on purpose —
    /// `Events` and `Hiring` are in the 28 it finds on the reference tree — so the evidence is on the
    /// chip and the decision is the user's. Tapping adds; the chip then leaves the list, because the
    /// person is on the roster below it and offering them twice reads as the app losing track.
    private func personChip(_ candidate: PersonCandidate) -> some View {
        Button {
            addProposedPerson(candidate)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle").scaledFont(.caption2)
                Text(candidate.name).scaledFont(.caption.weight(.medium))
                if let parent = candidate.parents.first, !parent.isEmpty {
                    Text("· \(parent)")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(rosterIsReadOnly)
        .help(peopleEvidence(candidate))
        .accessibilityLabel("Add \(candidate.name), \(peopleEvidence(candidate))")
    }

    private func peopleEvidence(_ candidate: PersonCandidate) -> String {
        let parents = candidate.parents.filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
        let count = "\(candidate.folderCount) folder\(candidate.folderCount == 1 ? "" : "s")"
        return parents.isEmpty ? count : "\(count) under \(parents)"
    }

    private func addProposedPerson(_ candidate: PersonCandidate) {
        if let store = roster {
            store.add(displayName: candidate.name)
        } else {
            draft.others.append(SetupDraft.DraftPerson(displayName: candidate.name))
            saveDraft()
        }
        peopleCandidates.removeAll { $0.name == candidate.name }
    }

    /// The household to hand the walk, whether or not there is a roster on disk yet.
    ///
    /// **This is the reason People comes before Folders, and the walk was ignoring it.** It passed
    /// `roster?.registry`, which is nil on the machine this form exists for — so the profile was
    /// built with no person axis and no `person-bucket` roles at all, from a form that had just
    /// finished asking who the household is. The answers were sitting in the draft.
    ///
    /// The roster wins where there is one: it carries full names and aliases the draft's bare first
    /// names do not.
    private var walkRegistry: PersonRegistry? {
        // The roster wins where there is one: it carries the full names and aliases the draft's
        // bare first names do not. Otherwise the draft is the household — see `SetupDraft.registry`.
        roster?.registry ?? draft.registry
    }

    /// Asks the walk who might be in the household, once per opening.
    ///
    /// Walks for itself rather than sharing the Folders step's tree: the People step comes first, so
    /// there is nothing to share yet, and a walk is seconds.
    private func proposePeople() {
        guard !askedForPeople, let root = walkRoot, let manager = syncManager else { return }
        askedForPeople = true
        let known = Set((roster?.people.flatMap(\.nameForms) ?? []) + draft.everyone.map(\.displayName))
        Task {
            peopleCandidates = await manager.proposePeople(root: root, known: known)
        }
    }

    /// What the roster records this person as, when it records anything.
    private func relationship(of name: String) -> String? {
        guard let store = roster else { return nil }
        let match = store.people.first {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
        guard let relationship = match?.relationship?.trimmingCharacters(in: .whitespaces),
              !relationship.isEmpty else { return nil }
        return relationship
    }

    private func commitPerson() {
        let name = newPersonField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rosterNames.contains(where: {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { newPersonField = ""; return }
        if let store = roster {
            store.add(displayName: name)
        } else {
            draft.others.append(SetupDraft.DraftPerson(displayName: name))
            saveDraft()
        }
        newPersonField = ""
    }

    private func removePerson(named name: String) {
        if let store = roster {
            if let person = store.people.first(where: { $0.displayName == name }) {
                store.remove(id: person.id)
            }
        } else {
            draft.others.removeAll { $0.displayName == name }
            saveDraft()
        }
    }

    // MARK: - Step 4, Folders

    private var surveyStep: some View {
        Group {
            stepHeader(.survey, "Which folder should SyncCloud learn?",
                       "It reads folder and file names — no document is opened — and uses what it "
                       + "finds to propose where things belong.")

            section("The folder") {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    Text(walkRootDisplay)
                        .scaledFont(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(walkRoot?.path ?? "")
                    Spacer(minLength: 8)
                    Button("Change…", action: chooseWalkRoot)
                        .controlSize(.small)
                        .disabled(walkPhase == .running)
                }
                // **A folder, not a whole account.** The store records a tree, and on this machine
                // the hand-built profile's is `~/Documents` — surveying the iCloud source's own root
                // would pull in Desktop, Downloads and Word beside it.
                Text("SyncCloud learns from one folder, not a whole account. Your documents folder "
                     + "is usually the right answer.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !placeCandidates.isEmpty {
                section("Places in your folder names") {
                    Text("These folder names might be places. Tick the ones that are — the rest are "
                         + "read as ordinary names.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WrapLayout(spacing: 7) {
                        ForEach(placeCandidates) { candidate in
                            placeChip(candidate)
                        }
                    }
                }
            }

            switch walkPhase {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(walkStatus)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done(let report):
                quietNote(report.becameActive ? report.summary : SetupFlow.walkNotInUse,
                          systemImage: report.becameActive ? "checkmark.circle" : "exclamationmark.triangle")
            case .failed(let why):
                quietNote("SyncCloud could not learn that folder — \(why).",
                          systemImage: "exclamationmark.triangle")
            }

            HStack(spacing: 8) {
                Button(walkPhase.isDone ? "Learn again" : "Learn this folder") { startWalk() }
                    .buttonStyle(.borderedProminent)
                    .chromeHover()
                    .disabled(walkRoot == nil || walkPhase == .running)
                if walkPhase == .idle, hasProfile {
                    Text("This Mac already has a folder profile.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One proposed place, with the evidence that makes it refusable at a glance.
    ///
    /// **Nothing is pre-ticked**, and that is measured rather than cautious: used as-is the rule
    /// agrees with the hand-built profile on 83.2% of folders, and every point of the gap is an
    /// invention — `HPE` is an employer, `IT` a department, `PRD` a product stage. Handed only the
    /// confirmed values the same code is right about 100%. The whole error is in the guessing.
    private func placeChip(_ candidate: JurisdictionCandidate) -> some View {
        let isOn = confirmedPlaces.contains(candidate.value)
        return Button {
            if isOn { confirmedPlaces.remove(candidate.value) }
            else { confirmedPlaces.insert(candidate.value) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.caption2)
                Text(candidate.value).scaledFont(.caption.weight(.medium))
                Text("· \(candidate.folderCount)")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.16)
                                       : Color.secondary.opacity(0.10)))
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(placeEvidence(candidate))
        .accessibilityLabel("\(candidate.value), \(placeEvidence(candidate))")
    }

    /// Why this name was proposed — the parents it splits, and how many folders it would change.
    private func placeEvidence(_ candidate: JurisdictionCandidate) -> String {
        let parents = candidate.parents.filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
        let where_ = parents.isEmpty ? "at the top level" : "under \(parents)"
        return "\(candidate.folderCount) folder\(candidate.folderCount == 1 ? "" : "s") \(where_)"
    }

    private var walkRootDisplay: String {
        guard let root = walkRoot else { return "No folder chosen" }
        let home = NSHomeDirectory()
        return root.path.hasPrefix(home) ? "~" + root.path.dropFirst(home.count) : root.path
    }

    private func chooseWalkRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = walkRoot
        panel.message = "Choose the folder SyncCloud should learn from"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        walkRoot = url
        rootChosenByHand = true
        // The proposals belong to the tree they came from, so a new root discards them rather than
        // carrying a stale list — and any tick the user made on it.
        invalidateProposals()
        proposeForCurrentStep()
    }

    /// Starts the walk root at the primary source, which is what the user just chose on Sources.
    ///
    /// A *folder*, and the source's own path is the honest default: on this Mac the iCloud source's
    /// path is already `~/Documents`, which is exactly the tree the hand-built profile describes.
    private func seedWalkRoot() {
        guard !rootChosenByHand, let primary = primaryProvider else { return }
        let seeded = URL(fileURLWithPath: primary.path)
        guard seeded != walkRoot else { return }
        walkRoot = seeded
        invalidateProposals()
    }

    /// Drops what the previous tree produced, without asking for the next lot.
    ///
    /// **Invalidate here, walk when the step is shown.** Seeding used to kick off both proposal
    /// walks itself, and the seed is driven by the primary source — which `reconcilePrimary` moves
    /// on every source toggle. So clicking through the Sources step fired two full walks of a
    /// three-thousand-folder tree per click, in the background, while the user was still clicking.
    /// Nothing failed; the disk simply churned and the step went sluggish for work no one had asked
    /// for yet.
    private func invalidateProposals() {
        placeCandidates = []
        confirmedPlaces = []
        peopleCandidates = []
        askedForPeople = false
        askedForPlaces = false
        walkPhase = .idle
    }

    /// Asks for whatever the screen now on show actually needs, and nothing else.
    private func proposeForCurrentStep() {
        guard case .step(let step) = screen else { return }
        switch step {
        case .people: proposePeople()
        case .survey: proposePlaces()
        case .you, .sources, .done: break
        }
    }

    /// Asks the walk what might be a place, without committing to anything.
    private func proposePlaces() {
        guard !askedForPlaces, let root = walkRoot, let manager = syncManager else { return }
        askedForPlaces = true
        Task {
            let proposals = await manager.proposePlaces(root: root)
            placeCandidates = proposals
        }
    }

    private func startWalk() {
        guard let root = walkRoot, let manager = syncManager else { return }
        walkPhase = .running
        walkStatus = "Reading \(walkRootDisplay)…"
        Task {
            let result = await manager.deriveFolderProfile(root: root,
                                                           jurisdictionValues: confirmedPlaces,
                                                           registry: walkRegistry)
            switch result {
            case .success(let report):
                // The profile is on disk; this is what makes it take effect without a relaunch —
                // and what gives the draft a roster to land in at last.
                // Order matters: attach first so `roster` resolves to the store the walk just
                // created, then land the draft in it. Reading the captured `peopleStore` here is
                // what made this a no-op for two stages.
                onProfileWritten()
                applyDraftIfPossible()
                Logger.shared.info("Setup: walk finished — profile '\(report.profileId)', "
                                   + "roster \(roster == nil ? "still unavailable" : "now holds \(roster?.people.count ?? 0) person(s)")")
                walkPhase = .done(report)
            case .failure(let failure):
                walkPhase = .failed(String(describing: failure))
            }
        }
    }

    // MARK: - Step 5, Done

    private var doneStep: some View {
        Group {
            // **A completion moment, because finishing a form should feel like finishing it.**
            // Every other step opens with a question; this one opens with an answer, so it takes
            // the accent mark the rest of the card deliberately does without.
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(.system(size: 40))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("You're all set")
                    .scaledFont(.title.weight(.semibold))
                Text("Everything below is in effect now. Change any of it in Settings.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                summaryRow("person", youSummary, tab: .people)
                Divider()
                summaryRow("cloud", sourcesSummary, tab: .providers)
                Divider()
                summaryRow("person.2", peopleSummary, tab: .people)
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            // **The survey's disclosure, folded in with the step it belonged to.** Learning your
            // folders is not in this build yet, so a whole step spent reading about it was a step
            // with no decision in it. What must not fold away is the promise and its one exception:
            // this is still the only place either is said in full.
            quietNote(SetupFlow.surveyPrivacyNote, systemImage: "lock")
            quietNote(SetupFlow.surveyThirdPartyNote, systemImage: "sparkles")

            if !hasProfile {
                quietNote("Learning your folders comes next. Until then Organize files by folder "
                          + "name, which needs no survey — and \(primaryName) is the tree it will "
                          + "learn from when it lands.", systemImage: "clock")
            }

        }
    }

    /// The primary source's name, for the line about what a survey would learn from.
    private var primaryName: String {
        settings.availableProviders.first { $0.id == primarySourceId }?.displayName
            ?? "your primary source"
    }

    /// **Reads the roster where there is one, and the draft only where there is not.**
    ///
    /// The step above it says “everything below is already in effect”, so it has to report what is
    /// in effect. On a machine with a profile that is `people.json` — which may carry name forms
    /// this run of the form never touched, typed into Settings ▸ People months ago — and reporting
    /// the draft there would undercount them, or say “no name given” about a household the app is
    /// actively filing for.
    private var youSummary: String {
        let me = roster?.people.first { $0.relationship?.lowercased() == "me" }
        let name = (me?.displayName ?? draft.yourName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "No name given — Organize will file by content alone" }
        let forms = me?.fullNames.count ?? draft.yourFullNames.count
        let base = forms == 0 ? "You — \(name)"
            : "You — \(name), with \(forms) full name form\(forms == 1 ? "" : "s")"
        return roster == nil ? "\(base) — \(SetupFlow.heldUntilSurveyed)" : base
    }

    private var sourcesSummary: String {
        let count = settings.enabledProviders.count
        guard let primary = primaryProvider else {
            return "\(count) source\(count == 1 ? "" : "s") enabled"
        }
        return "\(count) source\(count == 1 ? "" : "s") enabled, \(primary.displayName) primary"
    }

    private var peopleSummary: String {
        let summary = SetupFlow.peopleSummary(otherCount: rosterNames.count,
                                              rosterIsReadOnly: rosterIsReadOnly)
        guard roster == nil, !rosterNames.isEmpty else { return summary }
        return "\(summary) — \(SetupFlow.heldUntilSurveyed)"
    }

    private func summaryRow(_ symbol: String, _ text: String,
                            tab: SettingsView.SettingsTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(text).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // **Finishing first, and it is not a nicety.** These live on the last step: the user
            // has been through the whole form and is leaving it to adjust one answer in the surface
            // that owns it. Reporting only a dismissal would leave `hasCompletedSetup` false, so
            // the next launch of a machine that has not been surveyed would greet them with the
            // form all over again — for having read their own summary.
            Button("Change") {
                onFinish()
                onOpenSettings(tab)
            }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    // MARK: - Shared pieces

    /// A step's heading.
    ///
    /// **The mark is what makes this read as a setup pane rather than a settings tab.** Every step
    /// already declares an SF Symbol for its rail row; drawn once at size beside the question, it
    /// gives the top of the card something to hold and tells you at a glance which of the four you
    /// are on without reading the rail.
    private func stepHeader(_ step: SetupFlow.Step, _ title: String, _ blurb: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbolName)
                .scaledFont(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).scaledFont(.title2.weight(.semibold))
                Text(blurb)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // **Sentence case, not the Settings all-caps.** Three uppercase labels in a row made a
            // four-question form read as a settings pane; the step already has a title and a mark
            // saying what it is, so these only need to name the group.
            Text(title)
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ items: [String], onRemove: @escaping (String) -> Void) -> some View {
        FlowChips(items: items, onRemove: onRemove)
    }

    private func quietNote(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.07)))
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))
    }

    private var paneNames: (String, String) {
        let enabled = settings.enabledProviders
        return (enabled.first?.displayName ?? "iCloud", enabled.dropFirst().first?.displayName ?? "Dropbox")
    }

    // MARK: - Movement, and what each move commits

    /// Steps forward, committing what this step collected first.
    ///
    /// **Each step commits as you leave it**, which is what makes quitting mid-setup survivable:
    /// preferences and the source list are live settings the moment they are touched, and the two
    /// answers that need a profile are written to the draft. Nothing waits for a Finish button that
    /// the user may never press.
    private func advance() {
        commitCurrentStep()
        guard let next = SetupFlow.next(after: screen) else { finish(); return }
        withAnimation(.easeInOut(duration: 0.15)) { screen = next }
    }

    private func retreat() {
        commitCurrentStep()
        guard let previous = SetupFlow.previous(before: screen) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { screen = previous }
    }

    private func commitCurrentStep() {
        guard case .step(let step) = screen else { return }
        switch step {
        case .you:
            commitFullNameIfTyped()
            saveDraft()
            applyDraftIfPossible()
        case .people:
            applyDraftIfPossible()
        case .sources:
            reconcilePrimary()
        case .survey, .done:
            break
        }
    }

    /// A name typed but not committed with ⏎ is still an answer the user gave.
    private func commitFullNameIfTyped() {
        guard !fullNameField.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commitFullName()
    }

    private func finish() {
        commitCurrentStep()
        applyDraftIfPossible()
        Logger.shared.info("Setup finished — \(settings.enabledProviders.count) source(s) enabled, "
                           + "primary \(primaryProvider?.displayName ?? "none"), "
                           + "\(rosterNames.count) other person/people on the roster")
        onFinish()
    }

    // MARK: - The draft

    private func loadDraft() {
        guard let url = draftURL, let stored = SetupDraftStore.read(at: url) else {
            seedDraftFromRoster()
            return
        }
        draft = stored
        if draft.yourName.isEmpty { seedDraftFromRoster() }
    }

    /// Fills the form in from a roster that already exists, so a re-run opens on current state.
    private func seedDraftFromRoster() {
        guard let store = roster else { return }
        if let me = store.people.first(where: { $0.relationship?.lowercased() == "me" }) {
            draft.yourName = me.displayName
            draft.yourFullNames = me.fullNames
        }
    }

    /// Writes the draft — but only on a machine that has nowhere better to put the answers.
    ///
    /// **With a roster the draft is not a backup, it is a second copy that goes stale.** Those
    /// answers land in `people.json` the moment the step is left, so writing them here too would
    /// leave a file that `loadDraft` prefers over the roster on the next open — and it would be the
    /// older of the two the moment anything was edited in Settings ▸ People.
    private func saveDraft() {
        guard roster == nil, let url = draftURL else { return }
        SetupDraftStore.write(draft, to: url)
    }

    /// Writes the draft into the roster where there is one, and clears it once it has landed.
    ///
    /// **Only clears after a successful apply.** The draft is the only copy of these answers on a
    /// machine with no profile; deleting it on the way past the People step would throw away
    /// everything the survey stage is supposed to pick up.
    private func applyDraftIfPossible() {
        guard !draft.isEmpty else { return }
        guard let store = roster else {
            // **The state stage B has to know about, said once where it can be read back.** There
            // is no profile on this machine, so there is no `people.json` to write into and the
            // answers are sitting in `setup-draft.json` waiting for the first survey to mint one.
            // Nothing else on screen or on disk says so, and "the household I typed in did not
            // stick" is exactly the report this line answers.
            Logger.shared.info("Setup: no filing profile yet, so \(draft.everyone.count) roster "
                               + "answer(s) stay in the setup draft until a survey creates one")
            return
        }
        let result = SetupDraft.apply(draft, to: store)
        if result.added > 0 || result.updated > 0, let url = draftURL {
            // **Cleared only when it actually landed.** `apply` is idempotent, so a no-op result on
            // a re-run is not evidence the draft reached the roster — and clearing on that would
            // delete the only copy of answers a *failed* apply never wrote.
            SetupDraftStore.clear(at: url)
        }
    }
}

/// A wrapping row of removable chips.
///
/// Its own view because `Layout` conformance is the only way to wrap a variable number of chips
/// without either clipping them or reserving the full width for every row.
private struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            // Nothing. The field below is the whole affordance, and "None yet" floating above it
            // read as a warning about an empty list rather than as an ordinary starting point.
            EmptyView()
        } else {
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Text(item).scaledFont(.caption)
                        Button {
                            onRemove(item)
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item)")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
            }
        }
    }
}

/// Lays subviews out left to right, wrapping onto a new line when the proposed width runs out.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
