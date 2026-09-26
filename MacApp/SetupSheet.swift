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

    /// **One inset for the whole card**, so the crumb strip, the heading, the Back button and the
    /// closing line all begin on the same vertical line, and the text-size control, the ✕ and the
    /// primary button all end on it.
    ///
    /// This is the inset at the default text size; `inset(scale:)` is what the views apply.
    ///
    /// It was two: 22 for the content and 14 for the chrome above and below it. Nothing failed —
    /// the chrome simply hugged the card's edges more tightly than the content did, which reads as
    /// three separate rows that happen to share a card rather than one screen.
    static let horizontalInset: CGFloat = 22

    /// The factor the card's own geometry moves by, as against the factor its type moves by.
    ///
    /// **`max(1, scale)`, and the asymmetry is the whole of it.** Bigger type needs a bigger card
    /// to put it in. *Smaller* type does not need a smaller one — the small preset exists "to fit
    /// more on screen", in the words of its own caption in Settings, and a card that gives up the
    /// same 10% as its type fits exactly as much as it did before, only harder to read. It also
    /// squeezed, because not everything in the card was giving up 10%: at 90% the crumb strip lost
    /// 72pt of card to a row of padding that lost nothing, and truncated four of its eight steps to
    /// "1 Locat…", "5 Count…", "Workspac…", "Appeara…".
    static func chromeScale(_ scale: CGFloat) -> CGFloat { max(1, scale) }

    /// The factor the card's height *actually* grew by, once the window has had its say.
    ///
    /// `chromeScale` is what the card asks for; `resolvedHeight` is what the display can give. On a
    /// 1200×740 window the card stops growing at 692pt — a factor of 1.13 — while the text goes on
    /// to 1.35, so anything inside sized off the ask claims room the card never got. Structure is
    /// where that shows, because its tree box is the only element on the sheet sized in points
    /// rather than by its content: at 135% an unclamped box took 45pt the card did not have, and
    /// pushed the Read documents switch below the fold.
    static func cardScale(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        min(chromeScale(scale),
            resolvedHeight(availableSize: availableSize, scale: scale) / cardHeight)
    }

    /// The card's inset at a given text size.
    ///
    /// **Scaled, because the width arithmetic below always assumed it was** — `contentWidth`
    /// subtracts `horizontalInset * 2 * scale` while the views applied a flat 22, so at 135% every
    /// fit measurement was taken 15pt narrower than the card actually lays out, and at 90% 4pt
    /// wider. Small enough never to fail a test, and wrong in the direction that hides overflows.
    static func inset(scale: CGFloat) -> CGFloat { horizontalInset * chromeScale(scale) }

    /// The Why panel's width at a given text size, taken out of the content column on the screens
    /// that carry one.
    ///
    /// **This replaced a 176pt step rail.** The rail was a list of places to go, which is what a
    /// form with independent steps needs; a sheet that asks one thing at a time and then shows what
    /// it found is a sequence, and the column is better spent explaining the question than
    /// enumerating the others.
    ///
    /// **It takes the scale because everything else in the card does, and for a while this did
    /// not.** `resolvedWidth` grows the card by the full text scale and `scaledFont` grows the
    /// panel's prose by it too, but the column the prose sits in was the constant 250 at every
    /// size — so raising the text size put 35% more type in the same box and the panel got worse
    /// the more help the reader asked for. At 135% it drew four provider names as "iCloud",
    /// "OneDri/ve", "Google/Drive", "Dropb/ox": two of them broken across a line *inside the word*.
    /// The strip's own fix is in `LocationsWhy.MarkStrip`; this is the reason it was needed.
    static func whyWidth(scale: CGFloat) -> CGFloat { SetupWhyMetrics.width(scale: scale) }

    /// The bottom chrome the screen's own content does not get.
    ///
    /// Checked against the real footer by `theFooterFitsTheHeightTheOpeningIsComputedFrom`: an
    /// unverified constant here would make every height this file computes wrong by the difference.
    static let footerHeight: CGFloat = 56

    /// The top chrome — the crumb strip, the text-size control and the ✕.
    ///
    /// **This was missing from the budget, and the card showed it.** The form this replaces had no
    /// top bar; the sheet does, and `contentHeight` went on subtracting only the footer. Rendered
    /// at the card's own size, the Structure screen overflowed by about the height of that bar and
    /// SwiftUI centred the overflow, clipping the crumb strip off the top — while every fit test
    /// passed, because they all measured against a budget 38pt larger than the card gives.
    static let topBarHeight: CGFloat = 36

    /// The air between the chrome and the screen's own content, top and bottom together.
    static let contentVerticalPadding: CGFloat = 36

    /// The two hairlines that separate the three rows.
    static let dividerHeight: CGFloat = 2

    /// Breathing room kept between the card and the window edge.
    static let hostMargin: CGFloat = 48

    /// **One height for every screen.**
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
    /// Where the slack sits changed with the sheet: the form pinned each step's closing line to
    /// the bottom of the pane, and the guided screens are top-aligned with the air below them,
    /// because a question and its controls read as a block and a line pushed to the far edge of a
    /// 610pt card reads as unrelated to it. The Why panel keeps its own closing line at the foot of
    /// its column, where it is the answer to the question above it.
    static let cardHeight: CGFloat = 610

    /// Below this a rail plus a usable content column stops being possible; the card stops shrinking
    /// and its step scrolls instead. Overflowing a tiny window beats a card too small to use.
    static let minCardHeight: CGFloat = 360

    /// The width the card actually gets, clamped to the window it is centred in.
    static func resolvedWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        let wanted = cardWidth * chromeScale(scale)
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
    /// The Why panel's column comes off it only on the screens that carry one — measuring Welcome,
    /// Structure or Summary in the narrow column would hold them to a width the card never gives
    /// them.
    static func contentWidth(availableSize: CGSize, scale: CGFloat,
                             screen: SetupFlow.Screen) -> CGFloat {
        resolvedWidth(availableSize: availableSize, scale: scale)
            - (screen.hasWhyPanel ? whyWidth(scale: scale) : 0)
            - inset(scale: scale) * 2
    }

    /// The width a screen's own content is laid out at, on a screen that carries a Why panel.
    ///
    /// **The inset is subtracted, and that is a correction.** It was `card − panel`, which is the
    /// column the content sits *in* rather than the width it is given — so every fit measurement
    /// laid the content out 44pt wider than the card ever does, and was optimistic about its height
    /// by whatever that extra width saved in wrapping.
    static func contentWidth(availableSize: CGSize, scale: CGFloat) -> CGFloat {
        resolvedWidth(availableSize: availableSize, scale: scale) - whyWidth(scale: scale)
            - inset(scale: scale) * 2
    }
}

/// The guided setup sheet: ten screens in one card, replacing the five-step form.
///
/// **Hosted the same way Settings and Help are** — an in-window overlay rather than a window of its
/// own. It is the same surface on a first launch and on a re-run from Help, which is the property
/// that made a card the right choice: a separate window would have needed its own restore state,
/// its own ⌘W meaning, and a story for what happens when the main window is closed, all to deliver
/// a sheet that is only ever used in front of the app.
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
    /// Esc, ✕, a click outside, or *Not now*. The caller does **not** persist anything.
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
         /// Whether the user asked for setup by name — Help ▸ Set Up SyncCloud…, or
         /// Settings ▸ General ▸ Run setup again… — rather than the app offering it on launch.
         /// **An explicit ask opens on the welcome card**, because that is what "run setup" means;
         /// the automatic offer follows `SetupFlow.initialScreen`, which skips it on a Mac that is
         /// already set up.
         wasAskedFor: Bool = false,
         /// A screen to open on, overriding both of the above — see `SetupModel.init`.
         startScreen: SetupFlow.Screen? = nil,
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
        _model = StateObject(wrappedValue: SetupModel(
            settings: settings, peopleStore: peopleStore, syncManager: syncManager,
            hasFilingProfile: hasFilingProfile, defaults: defaults, walk: walk,
            startScreen: startScreen ?? (wasAskedFor ? .welcome : nil),
            onProfileWritten: onProfileWritten, onStartSurvey: onStartSurvey))
    }

    /// The hues offered on the Appearance screen — a spread across the palette, not the whole of it.
    ///
    /// `.none` is deliberately absent: it means "follow the system accent" and paints the same blue
    /// as `.blue`, so side by side the row began with two swatches that could not be told apart.
    static let offeredHues: [LiquidGlassHue] = [.blue, .teal, .green, .amber, .coral, .purple, .graphite]

    /// The box a welcome panel's illustration draws in, before it is scaled into the strip.
    static let panelArtBox = CGSize(width: 150, height: 110)
    /// How far down. 0.44 puts a 110pt illustration in 48pt.
    static let panelArtScale: CGFloat = 0.44

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(glassLevel.overlayScrimOpacity))
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

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
        .onChange(of: settings.availableProviders.map(\.id)) { _, _ in
            model.reconcilePrimary()
            model.seedWalkRoot()
        }
        .onChange(of: model.screen) { _, _ in focusFirstFieldIfNeeded() }
    }

    /// Puts the caret in the first field of the screen that has one.
    ///
    /// The rule is ``SetupFlow/wantsFirstFieldFocus(_:)`` rather than a `case` inlined here: this
    /// view cannot be built in a test, so a rule spelled inside it is a rule nothing can flip.
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
            .contentSurface(hue: glassHue, tint: surfaceTint)
            .groundedGlassCard(level: glassLevel)
            .overlayPanelShadow()
    }

    // MARK: - One card, ten screens

    /// The whole card for the current screen, chrome included.
    ///
    /// Internal so a render harness can photograph it; there is no other way to see the chrome and
    /// the content in the same picture, which is where the alignment defects live.
    @ViewBuilder
    var screenCard: some View {
        switch model.screen {
        case .welcome:
            frame(title: "Set up SyncCloud", primary: "Get started",
                  skip: ("Not now", { onDismiss() })) {
                WelcomeScreen(paneNames: paneNames)
            }

        case .locations:
            frame(primary: "Continue", why: { LocationsWhy(hue: glassHue, marks: paneMarks) }) {
                LocationsScreen(model: model, settings: settings, hue: glassHue)
            }

        case .learn:
            frame(primary: model.walkState.isDone ? "Learn again" : "Learn",
                  primaryAction: { model.startWalk(); _ = model.advance() },
                  // Nothing to read means nothing to press: a Learn that silently did nothing
                  // left the sheet unable to reach Structure with no line saying why.
                  primaryDisabled: !model.canLearn,
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
            // **The button says what it will do, and there are three answers.** With a tree in
            // hand it writes, and names which of the two things it will do. On a re-run where
            // Learn was skipped there is a profile on screen and nothing to write; and after a
            // folder is changed but not read there is neither — a Save in either case is a button
            // whose whole effect is to move to the next screen, so it says Continue instead.
            frame(primary: model.canWriteProfile
                    ? (model.readDocuments ? "Save and start reading" : "Save")
                    : "Continue",
                  primaryAction: model.canWriteProfile ? {
                      Task {
                          await model.save()
                          _ = model.advance()
                      }
                  } : nil,
                  primaryDisabled: model.isSaving) {
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
            frame(title: "Set up SyncCloud", primary: "Start browsing",
                  primaryAction: { finish() }) {
                SummaryScreen(model: model, settings: settings, hue: glassHue,
                              onChange: { tab in finish(); onOpenSettings(tab) },
                              onStartWith: { start in onStartWith(start); finish() })
            }
        }
    }

    /// One screen's own content, without the chrome around it.
    ///
    /// **Internal so a fit test can measure it.** The card is one fixed height for every screen, so
    /// what has to fit is the content column — and `SetupSheet` itself cannot be laid out in a test
    /// without a window, a manager and a walk.
    @ViewBuilder
    func screenBody(_ screen: SetupFlow.Screen,
                    outlineRows: [SetupFlow.OutlineRow] = SetupFlow.outline) -> some View {
        switch screen {
        case .welcome: WelcomeScreen(paneNames: paneNames, rows: outlineRows)
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
            primaryTitle: primary,
            onPrimary: primaryAction ?? { if !model.advance() { finish() } },
            isPrimaryDisabled: primaryDisabled,
            onDismiss: onDismiss,
            content: content,
            why: why)
    }

    @ViewBuilder
    private func frame<Content: View>(
        title: String? = nil,
        primary: String,
        primaryAction: (() -> Void)? = nil,
        primaryDisabled: Bool = false,
        skip: (String, () -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        frame(title: title, primary: primary, primaryAction: primaryAction,
              primaryDisabled: primaryDisabled, skip: skip,
              why: { EmptyView() }, content: content)
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

    /// The kinds of location the Why panel draws — see `LocationsWhy.marks(for:)`.
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
