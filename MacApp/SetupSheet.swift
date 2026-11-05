import AppKit
import Design
import Events
import Settings
import SwiftUI
import Sync

/// How big the setup card is, and how much of it the current step gets.
///
/// A separate table from `SettingsSheetMetrics`, which is internal to the `Settings` module. Its
/// rule is copied on purpose: clamp to the host window, so the card never hangs off the edge of a
/// small display. Fit tests must measure the clamped size, or a card too tall for a 1280×800
/// screen (about 740pt of window) passes them all and still scrolls.
enum SetupSheetMetrics {
    /// The card's width. Fixed, because a measure that changed between steps would reflow every
    /// line of prose as you moved.
    static let cardWidth: CGFloat = 720

    /// One inset for the whole card, chrome and content alike, so the crumb strip, heading, Back
    /// button and closing line all start on one vertical line, and the text-size control, ✕ and
    /// primary button all end on it. Different insets would read as three rows sharing a card
    /// rather than one screen.
    ///
    /// This is the inset at the default text size; the views apply `inset(scale:)`.
    static let horizontalInset: CGFloat = 22

    /// The factor the card's own geometry moves by, as against the factor its type moves by.
    ///
    /// `max(1, scale)`: bigger type needs a bigger card, but smaller type doesn't need a smaller
    /// one. The small preset exists to fit more on screen, and a card shrinking with its type fits
    /// no more. It also squeezes, since fixed padding doesn't shrink: the crumb strip would
    /// truncate its step names.
    static func chromeScale(_ scale: CGFloat) -> CGFloat { max(1, scale) }

    /// The factor the card's height *actually* grew by, once the window has had its say.
    ///
    /// `chromeScale` is what the card asks for; `resolvedHeight` is what the display can give. On
    /// a small window the card stops growing before the text does, so anything sized off the ask
    /// claims room the card never got. Structure's tree box, the one element sized in points, uses
    /// this so it can't push the Read documents switch below the fold.
    static func cardScale(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        min(chromeScale(scale),
            resolvedHeight(availableSize: availableSize, scale: scale) / cardHeight)
    }

    /// The card's inset at a given text size.
    ///
    /// Scaled, and `contentWidth` subtracts the same scaled inset, so fit measurements use the
    /// width the card really lays out. A mismatch is too small to fail a test and can hide an
    /// overflow.
    static func inset(scale: CGFloat) -> CGFloat { horizontalInset * chromeScale(scale) }

    /// The Why panel's width at a given text size, taken out of the content column on the screens
    /// that carry one.
    ///
    /// The column explains the question being asked; a sheet that asks one thing at a time needs
    /// no list of the other steps.
    ///
    /// It takes the scale because the card and the panel's prose both grow with it; a fixed column
    /// at large text would break provider names mid-word. `LocationsWhy.MarkStrip` handles the
    /// rest.
    static func whyWidth(scale: CGFloat) -> CGFloat { SetupWhyMetrics.width(scale: scale) }

    /// The bottom chrome the screen's own content does not get.
    ///
    /// Checked against the real footer by `theFooterFitsTheHeightTheOpeningIsComputedFrom`: if it
    /// were wrong, every height this file computes would be off by the difference.
    static let footerHeight: CGFloat = 56

    /// The top chrome: the crumb strip, the text-size control and the ✕. `contentHeight` must
    /// subtract it as well as the footer, or fit tests measure against more room than the card
    /// gives, and an overflowing screen is centred by SwiftUI with the crumb strip clipped off.
    static let topBarHeight: CGFloat = 36

    /// The air between the chrome and the screen's own content, top and bottom together.
    static let contentVerticalPadding: CGFloat = 36

    /// The two hairlines that separate the three rows.
    static let dividerHeight: CGFloat = 2

    /// Breathing room kept between the card and the window edge.
    static let hostMargin: CGFloat = 48

    /// One height for every screen. A card that resized per step would draw the eye to the
    /// container; it should be a steady frame you fill in.
    ///
    /// Measured from the screens' content, with a little room for copy edits, and held up by
    /// `SetupSheetFitTests`. The ceiling is the window, not this constant: re-measure the screens
    /// before raising it. Locations is left out, because it draws a row per source and a user may
    /// add any number; it scrolls past the count `sourcesOutgrowsTheOpeningEventually` names.
    ///
    /// Screens are top-aligned with the air below, because a question and its controls read as a
    /// block. The Why panel keeps its closing line at the foot of its column.
    static let cardHeight: CGFloat = 610

    /// Below this a Why panel plus a usable content column stops being possible, so the card stops
    /// shrinking and its screen scrolls. Overflowing a tiny window beats a card too small to use.
    static let minCardHeight: CGFloat = 360

    /// The width the card actually gets, clamped to the window it is centred in.
    static func resolvedWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        let wanted = cardWidth * chromeScale(scale)
        let room = max(availableSize.width - hostMargin, 460)
        return min(wanted, room)
    }

    /// The height the card actually gets, clamped to the window it is centred in.
    ///
    /// Clamped because a 1280×800-class display has about 740pt of window, and a card sized
    /// without that in mind hangs off the edge while every test still passes.
    static func resolvedHeight(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        let room = max(availableSize.height - hostMargin, minCardHeight)
        return min(cardHeight * chromeScale(scale), room)
    }

    /// The height a step's own content gets before it has to scroll.
    static func contentHeight(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        resolvedHeight(availableSize: availableSize, scale: scale)
            - (topBarHeight + footerHeight + contentVerticalPadding + dividerHeight)
            * chromeScale(scale)
    }

    /// The width a screen's own content is laid out at.
    ///
    /// The Why panel's column comes off only on screens that carry one; measuring Welcome,
    /// Structure or Summary in the narrow column would use a width the card never gives them.
    static func contentWidth(availableSize: CGSize, scale: CGFloat,
                             screen: SetupFlow.Screen) -> CGFloat {
        resolvedWidth(availableSize: availableSize, scale: scale)
            - (screen.hasWhyPanel ? whyWidth(scale: scale) : 0)
            - inset(scale: scale) * 2
    }

    /// The width a screen's own content is laid out at, on a screen that carries a Why panel.
    ///
    /// The inset is subtracted: `card − panel` is the column the content sits in, not the width it
    /// is given, and measuring at it would be optimistic about wrapping and height.
    static func contentWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        resolvedWidth(availableSize: availableSize, scale: scale) - whyWidth(scale: scale)
            - inset(scale: scale) * 2
    }
}

/// The guided setup sheet: ten screens in one card.
///
/// Hosted like Settings and Help, as an in-window overlay, the same surface on a first launch and
/// on a re-run from Help. A separate window would need its own restore state, its own ⌘W meaning
/// and a story for a closed main window, for a sheet only ever used in front of the app.
///
/// This file is the host and nothing else. Every rule is on ``SetupModel``, which a test can build;
/// every screen is its own file under `MacApp/Setup/`.
struct SetupSheet: View {
    @StateObject private var model: SetupModel
    @ObservedObject var settings: SettingsManager

    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let availableSize: CGSize
    let onOpenSettings: (SettingsView.SettingsTab) -> Void
    /// The user reached the end. The caller persists the completed flag.
    let onFinish: () -> Void
    /// Esc, ✕, a click outside, or *Not Now*, once the open screen's answers are committed
    /// (``close()``). The caller does **not** mark setup finished.
    let onDismiss: () -> Void
    /// What a Start-with button on Summary asks the app to open.
    var onStartWith: (SetupStart) -> Void = { _ in }

    @Environment(\.appFontScale) private var fontScale
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var firstFieldFocused: Bool
    @AppStorage(FontSize.defaultsKey) private var fontSizePercent = FontSize.medium.percent

    /// The text size, as the corner stepper and the Appearance tiles both write it.
    private var fontSize: Binding<FontSize> {
        Binding(get: { FontSize(percent: fontSizePercent) }, set: { fontSizePercent = $0.percent })
    }

    init(settings: SettingsManager,
         peopleStore: PeopleStore?,
         glassHue: LiquidGlassHue,
         glassLevel: GlassLevel,
         surfaceTint: Double,
         availableSize: CGSize,
         hasFilingProfile: Bool,
         syncManager: FileSyncManager? = nil,
         defaults: UserDefaults = .standard,
         /// A tree to start from instead of walking for one — see `SetupModel.init`.
         walk: SetupWalk? = nil,
         /// Whether the user asked for setup by name (Help ▸ Set Up SyncCloud…, or
         /// Settings ▸ General ▸ Run Setup Again…) rather than the app offering it on launch. An
         /// explicit ask opens on the welcome card; the automatic offer follows
         /// `SetupFlow.initialScreen`, which skips it on a Mac already set up.
         wasAskedFor: Bool = false,
         /// A screen to open on, overriding both of the above — see `SetupModel.init`.
         startScreen: SetupFlow.Screen? = nil,
         /// Where the draft lives. Handed in only by a test that mounts the sheet: taking the sheet
         /// down commits the open screen, and a test must never write the real draft.
         draftURL: URL? = SetupDraftStore.defaultURL(),
         /// A model to host instead of building one, for a test that types into it and then takes
         /// the sheet away.
         model: SetupModel? = nil,
         onProfileWritten: @escaping () -> Void = {},
         onStartSurvey: @escaping (URL) -> Void = { _ in },
         onOpenSettings: @escaping (SettingsView.SettingsTab) -> Void,
         onFinish: @escaping () -> Void,
         onDismiss: @escaping () -> Void,
         onStartWith: @escaping (SetupStart) -> Void = { _ in }) {
        self.settings = settings
        self.glassHue = glassHue
        self.glassLevel = glassLevel
        self.surfaceTint = surfaceTint
        self.availableSize = availableSize
        self.onOpenSettings = onOpenSettings
        self.onFinish = onFinish
        self.onDismiss = onDismiss
        self.onStartWith = onStartWith
        _model = StateObject(wrappedValue: model ?? SetupModel(
            settings: settings, peopleStore: peopleStore, syncManager: syncManager,
            hasFilingProfile: hasFilingProfile, defaults: defaults, walk: walk,
            startScreen: startScreen ?? (wasAskedFor ? .welcome : nil), draftURL: draftURL,
            onProfileWritten: onProfileWritten, onStartSurvey: onStartSurvey))
    }

    /// The hues offered on the Appearance screen: a spread across the palette, not all of it.
    /// `.none` is left out: it follows the system accent and paints the same blue as `.blue`, so
    /// the two swatches side by side couldn't be told apart.
    static let offeredHues: [LiquidGlassHue] = [.blue, .teal, .green, .amber, .coral, .purple, .graphite]

    /// The box a welcome panel's illustration draws in, before it is scaled into the strip.
    static let panelArtBox = CGSize(width: 150, height: 110)
    /// How far down. 0.44 puts a 110pt illustration in 48pt.
    static let panelArtScale: CGFloat = 0.44

    var body: some View {
        ZStack {
            OverlayScrim(level: glassLevel)
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                // Absorb clicks on the card so they don't fall through to the dismiss backdrop.
                .contentShape(Rectangle())
                .environment(\.setupCardScale, SetupSheetMetrics.cardScale(
                    availableSize: availableSize, scale: fontScale))
        }
        .transition(.opacity)
        .onAppear {
            model.onOpen()
            focusFirstFieldIfNeeded()
        }
        // Every teardown keeps the open screen's answers, not only the card's own ways out.
        // ContentView's overlays are one if/else, and Settings (⌘,), Help (⌘?) and a destination
        // pick rank above setup, so opening one (or closing the window) destroys this view and its
        // model with no `close()`. Quitting tears nothing down, so it is heard separately.
        // Committing again after `close()` or `finish()` is harmless: a commit writes what the
        // fields hold, and applying the draft is idempotent.
        .onDisappear { model.commitBeforeClosing() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.commitBeforeClosing()
        }
        .onChange(of: settings.availableProviders.map(\.id)) { _, _ in
            model.reconcilePrimary()
            model.seedWalkRoot()
        }
        .onChange(of: model.screen) { _, _ in focusFirstFieldIfNeeded() }
    }

    /// Puts the caret in the first field of the screen that has one.
    ///
    /// The rule is ``SetupFlow/wantsFirstFieldFocus(_:)``, not a `case` inlined here, because this
    /// view can't be built in a test.
    private func focusFirstFieldIfNeeded() {
        firstFieldFocused = SetupFlow.wantsFirstFieldFocus(model.screen)
    }

    private var cardWidth: CGFloat {
        SetupSheetMetrics.resolvedWidth(availableSize: availableSize, scale: fontScale)
    }

    private var cardHeight: CGFloat {
        SetupSheetMetrics.resolvedHeight(availableSize: availableSize, scale: fontScale)
    }

    @ViewBuilder
    private var card: some View {
        screenCard
            .frame(width: cardWidth, height: cardHeight)
            // Setup's switches and checkboxes take the window's hue, not the Mac's accent.
            .nativeControlAccent(glassHue)
            .contentSurface(hue: glassHue, tint: surfaceTint)
            .groundedGlassCard(level: glassLevel)
            .overlayPanelShadow()
    }

    // MARK: - One card, ten screens

    /// The whole card for the current screen, chrome included.
    ///
    /// Internal so a render harness can photograph it: the only way to see chrome and content in
    /// one picture, which is where alignment problems show.
    @ViewBuilder
    var screenCard: some View {
        switch model.screen {
        case .welcome:
            frame(title: "Set up SyncCloud", primary: "Get Started",
                  skip: ("Not Now", { close() })) {
                WelcomeScreen(paneNames: paneNames, hue: glassHue)
            }

        case .locations:
            frame(primary: "Continue", why: { LocationsWhy(hue: glassHue, marks: paneMarks) }) {
                LocationsScreen(model: model, settings: settings, hue: glassHue)
            }

        case .learn:
            // Once the reading is done, the primary keeps it: Continue moves on with the tree and
            // ticks as they stand, and reading again is the secondary button.
            frame(primary: model.learnPrimaryTitle,
                  primaryAction: { model.pressLearnPrimary() },
                  // Nothing to read means nothing to press: a Learn that silently did nothing
                  // would leave Structure unreachable with no reason given. Continue over a
                  // finished reading reads nothing, so this never holds it back.
                  primaryDisabled: !model.hasReadingOfChosenFolder && !model.canLearn,
                  secondary: model.learnAgainTitle.map { title in
                      (title, { model.pressLearnAgain() }, !model.canLearn)
                  },
                  skip: ("Skip", { _ = model.skip() }),
                  why: { LearnWhy(hue: glassHue, folderName: model.walkRootName) }) {
                LearnScreen(model: model, settings: settings, hue: glassHue)
            }

        case .you:
            frame(primary: "Continue", skip: ("Skip", { _ = model.skip() }),
                  why: { YouWhy(hue: glassHue, firstName: model.firstName) }) {
                YouScreen(model: model, hue: glassHue, firstFieldFocused: $firstFieldFocused)
            }

        case .people:
            frame(primary: "Continue", skip: ("Skip", { _ = model.skip() }),
                  why: { PeopleWhy(hue: glassHue) }) {
                PeopleScreen(model: model, hue: glassHue)
            }

        case .countries:
            frame(primary: "Continue",
                  why: { CountriesWhy(hue: glassHue, folderName: model.walkRootName) }) {
                CountriesScreen(model: model, hue: glassHue)
            }

        case .structure:
            // The button says what it will do. With a tree in hand it writes, and names which of
            // its two writes. With nothing to write (a re-run that skipped Learn, a folder changed
            // but not read, or a reading Save already wrote) it says Continue; writing again would
            // make a second profile. While the reading runs it says Skip Saving and moves on
            // without waiting. The words are `structurePrimaryTitle`, so a test can read them.
            let primary = model.structurePrimaryTitle
            frame(primary: primary,
                  // Moves on only once the profile is written: a failed write stays here and
                  // says what failed (`saveAndContinue`, through `pressStructurePrimary`). The
                  // button's label is captured as drawn, so a reading that lands before the Task
                  // runs can't turn a Skip Saving press into a Save.
                  primaryAction: { [shownSkipSaving = primary == SetupModel.skipSavingTitle] in
                      Task { await model.pressStructurePrimary(shownSkipSaving: shownSkipSaving) }
                  },
                  primaryDisabled: model.isSaving,
                  // Only once a Save has failed: the primary stays Save so it can be retried, and
                  // this is the way on that writes nothing.
                  secondary: model.structureSecondaryTitle.map { title in
                      (title, { model.continueWithoutSaving() }, model.isSaving)
                  }) {
                StructureScreen(model: model, hue: glassHue)
            }

        case .workspaces:
            frame(primary: "Continue", why: { WorkspacesWhy(hue: glassHue) }) {
                WorkspacesScreen(model: model, hue: glassHue)
            }

        case .appearance:
            frame(primary: "Continue", skip: ("Skip", { _ = model.skip() }),
                  why: { AppearanceWhy(hue: glassHue) }) {
                AppearanceScreen(model: model, settings: settings, hue: glassHue,
                                 fontSize: fontSize)
            }

        case .summary:
            frame(title: "Set up SyncCloud", primary: "Start Browsing",
                  primaryAction: { finish() }) {
                SummaryScreen(model: model, settings: settings, hue: glassHue,
                              onChange: { tab in finish(); onOpenSettings(tab) },
                              onStartWith: { start in onStartWith(start); finish() })
            }
        }
    }

    /// One screen's own content, without the chrome around it.
    ///
    /// Internal so a fit test can measure it. The card is one fixed height, so the content column
    /// is what must fit, and `SetupSheet` itself can't be laid out in a test without a window, a
    /// manager and a walk.
    @ViewBuilder
    func screenBody(_ screen: SetupFlow.Screen,
                    outlineRows: [SetupFlow.OutlineRow] = SetupFlow.outline) -> some View {
        switch screen {
        case .welcome: WelcomeScreen(paneNames: paneNames, hue: glassHue, rows: outlineRows)
        case .locations: LocationsScreen(model: model, settings: settings, hue: glassHue)
        case .learn: LearnScreen(model: model, settings: settings, hue: glassHue)
        case .you: YouScreen(model: model, hue: glassHue, firstFieldFocused: $firstFieldFocused)
        case .people: PeopleScreen(model: model, hue: glassHue)
        case .countries: CountriesScreen(model: model, hue: glassHue)
        case .structure: StructureScreen(model: model, hue: glassHue)
        case .workspaces: WorkspacesScreen(model: model, hue: glassHue)
        case .appearance:
            AppearanceScreen(model: model, settings: settings, hue: glassHue, fontSize: fontSize)
        case .summary:
            SummaryScreen(model: model, settings: settings, hue: glassHue,
                          onChange: { _ in }, onStartWith: { _ in })
        }
    }

    /// The model, for a test that needs to put a walk or a roster in front of a screen.
    var setupModel: SetupModel { model }

    /// The card chrome, filled in for one screen.
    ///
    /// Defaulted so a screen states only what is unusual about it: most screens continue, most
    /// offer Back, and the four that can be skipped say so.
    @ViewBuilder
    private func frame<Content: View, Why: View>(
        title: String? = nil,
        primary: String,
        primaryAction: (() -> Void)? = nil,
        primaryDisabled: Bool = false,
        secondary: (String, () -> Void, Bool)? = nil,
        skip: (String, () -> Void)? = nil,
        @ViewBuilder why: @escaping () -> Why,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SetupScreenCard(
            crumbs: title == nil ? model.crumbs : [],
            current: model.screen,
            title: title,
            fontSize: fontSize,
            tint: glassHue.accentColor,
            onBack: model.canGoBack ? { model.retreat() } : nil,
            skipTitle: skip?.0,
            onSkip: skip.map { pair in { pair.1() } },
            secondaryTitle: secondary?.0,
            onSecondary: secondary.map { triple in { triple.1() } },
            isSecondaryDisabled: secondary?.2 ?? false,
            primaryTitle: primary,
            onPrimary: primaryAction ?? { if !model.advance() { finish() } },
            isPrimaryDisabled: primaryDisabled,
            onDismiss: { close() },
            content: content,
            why: why)
    }

    @ViewBuilder
    private func frame<Content: View>(
        title: String? = nil,
        primary: String,
        primaryAction: (() -> Void)? = nil,
        primaryDisabled: Bool = false,
        secondary: (String, () -> Void, Bool)? = nil,
        skip: (String, () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        frame(title: title, primary: primary, primaryAction: primaryAction,
              primaryDisabled: primaryDisabled, secondary: secondary, skip: skip,
              why: { EmptyView() }, content: content)
    }

    /// Every way out that is not finishing: keeps the open screen's answers, then closes.
    private func close() {
        model.commitBeforeClosing()
        onDismiss()
    }

    private func finish() {
        model.commitCurrentScreen()
        model.applyDraftIfPossible()
        Logger.shared.info("Setup finished — \(settings.enabledProviders.count) location(s) enabled, "
                           + "\(model.rosterNames.count) other person/people on the roster")
        onFinish()
    }

    private var paneNames: (String, String) {
        let enabled = settings.enabledProviders
        return (enabled.first?.displayName ?? "iCloud",
                enabled.dropFirst().first?.displayName ?? "Dropbox")
    }

    /// The kinds of location the Why panel draws; see `LocationsWhy.marks(for:)`.
    private var paneMarks: [LocationsWhy.Mark] {
        let marks = LocationsWhy.marks(for: settings.enabledProviders)
        return marks.isEmpty ? LocationsWhy.fallback : marks
    }
}

/// What a Start-with button on the Summary screen asks the app to open.
enum SetupStart: Equatable, Sendable {
    /// Organize, on the To File lens.
    case toFile
    /// Compare, on the first two enabled locations.
    case compare
}
