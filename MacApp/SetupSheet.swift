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
    /// The card at the default text size.
    ///
    /// Narrower and shorter than the settings sheet (760×704) because it holds one step rather than
    /// nine tabs, and every step is a short form. The height is chosen against the tallest of them
    /// — Sources, which draws a row per source this Mac has — and `SetupSheetFitTests` measures
    /// that against the CLAMPED opening rather than this number.
    ///
    /// **620 → 648, from a measurement rather than a preference.** At 620 the opening is 564pt and
    /// Sources lays out at 565pt on a Mac with seven sources, which is what the machine this was
    /// designed against actually has — one point over, and the guard caught it on its first run.
    /// 648 gives a 592pt opening and 27pt of headroom at that count.
    ///
    /// **It is deliberately not raised until Sources cannot overflow, because it cannot be.** That
    /// step draws a row per source and a user may add any number of folders, so no height promises
    /// to hold it — the same property that keeps the settings sheet's Providers tab out of its fit
    /// guard. What replaces the promise is a measurement of where it breaks:
    /// `sourcesOutgrowsTheOpeningEventually` names the count, so raising this is a decision someone
    /// takes against a number rather than a surprise a user finds.
    static let baseSize = CGSize(width: 720, height: 648)

    /// Below this a rail plus a usable content column stops being possible; the card stops
    /// shrinking and its step scrolls instead.
    static let floorSize = CGSize(width: 520, height: 400)

    /// Breathing room kept between the card and the window edge.
    static let hostMargin: CGFloat = 48

    /// The rail's width — the same 176pt the Settings rail uses, because they are the same kind of
    /// list in the same kind of card and two widths would read as a mistake.
    static let railWidth: CGFloat = 176

    /// The title/footer chrome the step's own content does not get.
    static let footerHeight: CGFloat = 56

    /// The card's size: the base size scaled by the text setting, then clamped to what the host
    /// actually has room for, never below `floorSize`.
    static func resolvedSize(availableSize: CGSize, scale: CGFloat) -> CGSize {
        let wanted = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let room = CGSize(width: max(availableSize.width - hostMargin, floorSize.width),
                          height: max(availableSize.height - hostMargin, floorSize.height))
        return CGSize(width: min(wanted.width, max(room.width, floorSize.width)),
                      height: min(wanted.height, max(room.height, floorSize.height)))
    }

    /// The height a step's own content gets inside a card of `size` — what a fit test measures a
    /// step against.
    static func contentOpening(cardSize: CGSize) -> CGSize {
        CGSize(width: cardSize.width - railWidth, height: cardSize.height - footerHeight)
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
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let availableSize: CGSize
    /// Whether this machine already has a surveyed tree. Drives the survey step's copy, which must
    /// not offer to learn a tree that is already learned.
    let hasFilingProfile: Bool
    let onOpenSettings: (SettingsView.SettingsTab) -> Void
    /// The user reached the end. The caller persists the completed flag.
    let onFinish: () -> Void
    /// Esc, ✕, a click outside, or *Not now*. The caller does **not** persist anything.
    let onDismiss: () -> Void

    @Environment(\.appFontScale) private var fontScale
    @State private var screen: SetupFlow.Screen
    @State private var draft = SetupDraft()
    @State private var fullNameField = ""
    @State private var newPersonField = ""
    @State private var isRefreshingProviders = false
    @AppStorage(SetupFlow.primarySourceDefaultsKey) private var primarySourceId = ""
    @AppStorage(LiquidGlass.appearanceModeKey) private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(LiquidGlass.hueKey) private var selectedHueRaw = LiquidGlassHue.blue.rawValue
    @AppStorage(GeneralSettings.notifyOnBackgroundCompletionKey) private var notifyInBackground = false

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
         defaults: UserDefaults = .standard,
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
            Logger.shared.info("Setup opened on \(screenName) — "
                               + "\(settings.availableProviders.count) source(s) discovered, "
                               + "roster \(peopleStore == nil ? "not writable yet (no profile)" : "available")")
        }
        // Discovery republishes the list on every refresh and every folder added, and the primary
        // may have been in what changed.
        .onChange(of: settings.availableProviders.map(\.id)) { _, _ in reconcilePrimary() }
    }

    /// The box a panel's illustration draws in, before it is scaled down into the strip.
    ///
    /// The illustrations were drawn for the tour's 120pt header and have fixed internal geometry —
    /// `BrowseArt`'s columns are 46×92 points — so shrinking them means scaling, and scaling means
    /// knowing the box they were drawn for.
    static let panelArtBox = CGSize(width: 150, height: 110)
    /// How far down. 0.44 puts a 110pt illustration in 48pt, which is the tallest a three-up strip
    /// can carry above two lines of copy and still leave the outline list room on the card.
    static let panelArtScale: CGFloat = 0.44

    private var cardSize: CGSize {
        SetupSheetMetrics.resolvedSize(availableSize: availableSize, scale: fontScale)
    }

    @ViewBuilder
    private var card: some View {
        Group {
            switch screen {
            case .welcome: welcomeScreen
            case .step(let step): stepScreen(step)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
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
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        SetupIllustration(art: .welcome, leftName: paneNames.0, rightName: paneNames.1)
                            .frame(height: 108)
                            .accessibilityHidden(true)
                        Text("Welcome to SyncCloud")
                            .scaledFont(.title2.weight(.semibold))
                        Text("Four short questions, then SyncCloud learns your folders in the "
                             + "background. About two minutes.")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 380)
                    }

                    HStack(alignment: .top, spacing: 9) {
                        ForEach(SetupFlow.panels, id: \.title) { panel in
                            VStack(spacing: 6) {
                                // **Scaled, not framed.** A `frame(height:)` does not resize its
                                // content — the illustrations draw at their natural ~120pt and a
                                // smaller frame simply lets them overflow, which is what the first
                                // render of this strip did: Compare's panes spilled across both its
                                // neighbours and Organize's folders sat on top of its own title.
                                // The outer frame is the space it takes; the inner one is the box it
                                // draws in.
                                SetupIllustration(art: panel.art,
                                                  leftName: paneNames.0, rightName: paneNames.1)
                                    .frame(width: Self.panelArtBox.width,
                                           height: Self.panelArtBox.height)
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
                            .padding(.vertical, 10)
                            .padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.secondary.opacity(0.07)))
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Setting up asks for")
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(SetupFlow.outline, id: \.step) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Image(systemName: row.step.symbolName)
                                    .foregroundStyle(.tint)
                                    .frame(width: 18)
                                Text(row.step.displayName).scaledFont(.callout.weight(.medium))
                                Text(row.detail)
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    privacyNote(SetupFlow.privacyClaim, systemImage: "lock")
                }
                .padding(24)
            }

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
            .padding(.horizontal, 18)
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
                ScrollView { stepContent(step) }
                Divider()
                footer(step)
            }
        }
    }

    /// A step's own content, without the scroll view that holds it.
    ///
    /// **Split out so a fit test can measure the thing that actually overflows.** A `ScrollView`
    /// accepts any height it is offered, so `fittingSize` taken on the card answers the card's own
    /// height however tall the step inside it is — a guard written that way would pass with a step
    /// twice the size of the opening. `SetupSheetFitTests` measures this instead, and it is
    /// `internal` for exactly that reason.
    @ViewBuilder
    func stepContent(_ step: SetupFlow.Step) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case .you: youStep
            case .sources: sourcesStep
            case .people: peopleStep
            case .survey: surveyStep
            case .done: doneStep
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }

    private func rail(current: SetupFlow.Step) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Setup")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            ForEach(SetupFlow.Step.allCases, id: \.self) { step in
                railRow(step, current: current)
            }
            Spacer(minLength: 8)
            Text("Everything here is in Settings afterwards. Nothing is locked in.")
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(width: SetupSheetMetrics.railWidth, alignment: .leading)
    }

    private func railRow(_ step: SetupFlow.Step, current: SetupFlow.Step) -> some View {
        let isCurrent = step == current
        let isDone = step.number < current.number
        return HStack(spacing: 9) {
            Image(systemName: isDone ? "checkmark.circle.fill" : step.symbolName)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white)
                                 : isDone ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(Color.secondary))
                .frame(width: 18)
            Text(step.displayName)
                .scaledFont(.callout.weight(isCurrent ? .medium : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
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
    /// trusted.** That constant is subtracted from the card to get the opening every step is
    /// measured against, so if the real footer is taller than the number, every fit assertion in
    /// this form is optimistic by the difference — and nothing else would ever say so.
    func footer(_ step: SetupFlow.Step) -> some View {
        HStack(spacing: 10) {
            if SetupFlow.previous(before: .step(step)) != nil {
                Button("Back") { retreat() }
            }
            Label(SetupFlow.privacyFooter, systemImage: "lock")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Step 1, You

    private var youStep: some View {
        Group {
            stepHeader("Who are you?",
                       "SyncCloud reads names out of your documents to work out whose they are. It "
                       + "needs to know yours, and every form a document might print it in.")

            section("Your name") {
                HStack(spacing: 8) {
                    // **Not saved per keystroke.** This used to write the whole draft — a JSON
                    // encode and an atomic file replace, on the main actor — for every character
                    // typed into it. The draft is written when the step is left, when Return
                    // commits a field, and when a person is added or removed, which is every point
                    // at which an answer is actually finished.
                    TextField("First name", text: $draft.yourName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit { saveDraft() }
                    Text("is what your folders call you")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            section("Full names on documents") {
                chipRow(draft.yourFullNames) { name in
                    draft.yourFullNames.removeAll { $0 == name }
                    saveDraft()
                }
                HStack(spacing: 8) {
                    TextField("Add a form…", text: $fullNameField)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit(commitFullName)
                    Button("Add", action: commitFullName)
                        .controlSize(.small)
                        .disabled(fullNameField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A full name is matched before any single word, so a shared surname stops "
                     + "making two people out of one document.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("Preferences") {
                HStack {
                    Text("Appearance").scaledFont(.callout)
                    Spacer()
                    Picker("Appearance", selection: $appearanceModeRaw) {
                        ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                HStack {
                    Text("Accent").scaledFont(.callout)
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(LiquidGlassHue.allCases, id: \.rawValue) { hue in
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
                Toggle("Notify me when a long pass finishes", isOn: $notifyInBackground)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .scaledFont(.callout)
                Text("Surveys, duplicate scans and bulk copies. Startup, and everything else, is in "
                     + "Settings ▸ General.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            stepHeader("SyncCloud found \(settings.availableProviders.count) "
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

            Text("Primary only decides what gets learned. Every enabled source is browsable and "
                 + "comparable either way, and you can change which one is primary later.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceRow(_ provider: CloudProvider) -> some View {
        let isEnabled = settings.isEnabled(provider.id)
        return HStack(spacing: 10) {
            ProviderLogo(provider.imageName, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName).scaledFont(.callout.weight(.medium))
                Text(provider.path)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusBadge(isValid: settings.isPathValid(for: provider.id))
            Button {
                primarySourceId = provider.id
            } label: {
                Image(systemName: primarySourceId == provider.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(primarySourceId == provider.id
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(isEnabled ? "Learn this source's folders"
                  : "Turn \(provider.displayName) on to make it primary.")
            .accessibilityLabel("Make \(provider.displayName) primary")
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { settings.setEnabled($0, for: provider.id); reconcilePrimary() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isEnabled && !settings.canDisable(provider.id))
                .help(isEnabled && !settings.canDisable(provider.id)
                      ? "At least one source must remain enabled."
                      : "Show \(provider.displayName) in the pane sidebar.")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .opacity(isEnabled ? 1 : 0.55)
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
            stepHeader("Who else is in your folders?",
                       hasFilingProfile
                       ? "These are the people Organize files for. Add anyone it should know about."
                       : "Add anyone your documents are filed for. Once SyncCloud has learned your "
                       + "folders it will offer the names it found there too.")

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
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        if name != rosterNames.last { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06)))
            }

            HStack(spacing: 8) {
                TextField("Add a person…", text: $newPersonField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(commitPerson)
                Button("Add", action: commitPerson)
                    .controlSize(.small)
                    .disabled(newPersonField.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Full names and nicknames are worth adding in Settings ▸ People — a first name is "
                 + "enough to get started. A name left off costs nothing but attribution: documents "
                 + "naming that person are filed by their content instead.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The household as it stands — the roster where one exists, the draft otherwise.
    ///
    /// **Your own record is excluded**, because Step 1 is where it is edited and a list that
    /// repeated you here would offer a Remove that unpicks an answer given two screens ago.
    private var rosterNames: [String] {
        if let store = peopleStore {
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

    /// What the roster records this person as, when it records anything.
    private func relationship(of name: String) -> String? {
        guard let store = peopleStore else { return nil }
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
        if let store = peopleStore {
            store.add(displayName: name)
        } else {
            draft.others.append(SetupDraft.DraftPerson(displayName: name))
            saveDraft()
        }
        newPersonField = ""
    }

    private func removePerson(named name: String) {
        if let store = peopleStore {
            if let person = store.people.first(where: { $0.displayName == name }) {
                store.remove(id: person.id)
            }
        } else {
            draft.others.removeAll { $0.displayName == name }
            saveDraft()
        }
    }

    // MARK: - Step 4, Survey

    private var surveyStep: some View {
        Group {
            stepHeader("How much should SyncCloud learn?",
                       "Folder names are free. Reading what is inside your documents is what makes "
                       + "Organize propose destinations and better names — and it takes a while.")

            if hasFilingProfile {
                privacyNote("This Mac has already learned a tree, so there is nothing to survey here "
                            + "yet. Organize is using it now.", systemImage: "checkmark.circle")
            } else {
                privacyNote("Learning your folders is not in this build yet. When it lands it will "
                            + "run in the background, pause whenever you are busy, and pick up where "
                            + "it left off — including after you quit. Until then Organize files by "
                            + "folder name, which needs no survey.",
                            systemImage: "clock")
            }

            if let primary = primaryProvider {
                section("What it would learn from") {
                    HStack(spacing: 10) {
                        ProviderLogo(primary.imageName, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(primary.displayName).scaledFont(.callout.weight(.medium))
                            Text(primary.path)
                                .scaledFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("SyncCloud learns from a folder, not a whole account — you will pick which "
                         + "one when the survey lands.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            privacyNote(SetupFlow.surveyPrivacyNote, systemImage: "lock")
            privacyNote(SetupFlow.surveyThirdPartyNote, systemImage: "diamond")
        }
    }

    private var primaryProvider: CloudProvider? {
        settings.availableProviders.first { $0.id == primarySourceId }
    }

    // MARK: - Step 5, Done

    private var doneStep: some View {
        Group {
            stepHeader("SyncCloud is set up",
                       "Everything below is already in effect. Change any of it in Settings.")

            VStack(spacing: 0) {
                summaryRow("person", youSummary, tab: .people)
                Divider()
                summaryRow("cloud", sourcesSummary, tab: .providers)
                Divider()
                summaryRow("person.2", peopleSummary, tab: .people)
                Divider()
                summaryRow("lock", "Everything stays on this Mac — cloud refinement is off",
                           tab: .intelligence)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06)))

            Text("Run setup again from Help ▸ Set Up SyncCloud…")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// **Reads the roster where there is one, and the draft only where there is not.**
    ///
    /// The step above it says “everything below is already in effect”, so it has to report what is
    /// in effect. On a machine with a profile that is `people.json` — which may carry name forms
    /// this run of the form never touched, typed into Settings ▸ People months ago — and reporting
    /// the draft there would undercount them, or say “no name given” about a household the app is
    /// actively filing for.
    private var youSummary: String {
        let me = peopleStore?.people.first { $0.relationship?.lowercased() == "me" }
        let name = (me?.displayName ?? draft.yourName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "No name given — Organize will file by content alone" }
        let forms = me?.fullNames.count ?? draft.yourFullNames.count
        return forms == 0 ? "You — \(name)"
            : "You — \(name), with \(forms) full name form\(forms == 1 ? "" : "s")"
    }

    private var sourcesSummary: String {
        let count = settings.enabledProviders.count
        guard let primary = primaryProvider else {
            return "\(count) source\(count == 1 ? "" : "s") enabled"
        }
        return "\(count) source\(count == 1 ? "" : "s") enabled, \(primary.displayName) primary"
    }

    private var peopleSummary: String {
        let count = rosterNames.count
        return count == 0 ? "Nobody else on the list yet"
            : "\(count) other\(count == 1 ? "" : "s") in your household"
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

    private func stepHeader(_ title: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).scaledFont(.title3.weight(.semibold))
            Text(blurb)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .scaledFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ items: [String], onRemove: @escaping (String) -> Void) -> some View {
        FlowChips(items: items, onRemove: onRemove)
    }

    private func privacyNote(_ text: String, systemImage: String) -> some View {
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
        guard let store = peopleStore else { return }
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
        guard peopleStore == nil, let url = draftURL else { return }
        SetupDraftStore.write(draft, to: url)
    }

    /// Writes the draft into the roster where there is one, and clears it once it has landed.
    ///
    /// **Only clears after a successful apply.** The draft is the only copy of these answers on a
    /// machine with no profile; deleting it on the way past the People step would throw away
    /// everything the survey stage is supposed to pick up.
    private func applyDraftIfPossible() {
        guard !draft.isEmpty else { return }
        guard let store = peopleStore else {
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
            Text("None yet")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
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
