import AppKit
import Design
import Events
import Foundation
import Settings
import SwiftUI
import Sync

/// Everything the guided setup sheet knows, and every rule it follows.
///
/// **The screens are views; this is the sheet.** The form this replaces kept its state in
/// `@State` on one 1,978-line view, which meant no rule in it could be tested — the version of
/// "put the caret in the first field" that lived in `onAppear` fired on the re-run path and never
/// on a first launch, and nothing could ask. A model can be built in a test; a `SetupSheet` cannot.
///
/// It owns four things the screens read and none of them owns:
///
/// - **One walk.** ``walkState`` holds the tree from Learn until the sheet closes, and People,
///   Countries, Structure and the loose-file routing are all pure functions over it. Nothing walks
///   the disk again until Save.
/// - **A profile that is not on disk.** ``preview`` is built in memory whenever the answers change,
///   so Back from Structure costs a rebuild rather than a written directory.
/// - **The draft.** You and People land in `setup-draft.json` on a machine with no profile, and in
///   `people.json` the moment there is one.
/// - **Where the user is**, and which screens are in the flow at all given what the walk did.
@MainActor
final class SetupModel: ObservableObject {

    // MARK: - What it was built with

    let settings: SettingsManager
    /// The roster this view was built with. **Nil is the ordinary state on the machine setup is
    /// for** — no profile means no `profiles/<id>/` to write `people.json` into, which is why
    /// ``SetupDraft`` exists. Read ``roster`` instead of this, always.
    private let initialPeopleStore: PeopleStore?
    /// The engine. Nil in a layout test, which never walks.
    let syncManager: FileSyncManager?
    /// Re-reads the filing artifacts after a profile lands, so it takes effect without a relaunch.
    let onProfileWritten: () -> Void
    /// Starts the document survey on the folder just learned. Handed in because the survey's
    /// verbs live on `ContentView`, which owns the scope the card reads.
    let onStartSurvey: (URL) -> Void
    private let defaults: UserDefaults

    // MARK: - Where the user is

    @Published var screen: SetupFlow.Screen

    // MARK: - The answers

    @Published var draft = SetupDraft()
    /// The name field's two halves. The surname builds the forms and is never stored on its own.
    @Published var firstName = ""
    @Published var surname = ""
    /// Forms the user typed rather than picked — a nickname, a spelling the rules cannot derive.
    @Published private(set) var customForms: [String] = []
    /// Where the user disagreed with a suggestion's default, keyed by the form itself.
    @Published private(set) var formOverrides: [String: Bool] = [:]
    @Published var newPersonField = ""
    @Published var newFormField = ""
    @Published var newCountryField = ""
    /// The countries the user confirmed. **Nothing is ticked that the rule is not confident of** —
    /// see ``JurisdictionCandidates/isConfident(_:)``.
    @Published var confirmedCountries: Set<String> = []
    /// Whether Save also starts reading documents. On by default; the button says which it is.
    @Published var readDocuments = true

    // MARK: - The walk

    /// Where the walk has got to. One value rather than three booleans that can disagree.
    enum WalkState: Equatable {
        case idle
        case running
        case done(SetupWalk)
        case failed(String)
        /// The user pressed Skip. Distinct from `.failed`: nothing was attempted.
        case skipped

        static func == (a: WalkState, b: WalkState) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.running, .running), (.skipped, .skipped): return true
            case (.done, .done): return true
            case (.failed(let x), .failed(let y)): return x == y
            default: return false
            }
        }

        var walk: SetupWalk? { if case .done(let w) = self { return w }; return nil }
        var isRunning: Bool { self == .running }
        var isDone: Bool { walk != nil }
    }

    @Published var walkState: WalkState = .idle
    /// The folder the walk reads. Seeded from the primary location, changeable.
    @Published var walkRoot: URL?
    /// Set once the user picks a root themselves — an explicit choice outranks a default that
    /// arrives later.
    @Published private(set) var rootChosenByHand = false
    @Published var isRefreshingProviders = false
    /// True from the moment Save is pressed until the profile is on disk.
    ///
    /// **A second press wrote a second profile.** `writeWalkProfile` mints a fresh id every time
    /// and never overwrites, so two presses inside one second produced `walk-…` and `walk-…-2`,
    /// the first of them immediately superseded and left on disk for `retireSupersededProfiles`
    /// to find later.
    @Published private(set) var isSaving = false

    /// Whether Learn has a folder to read. The button is disabled without one — the alternative is
    /// a press that silently does nothing and a sheet that then cannot reach Structure.
    var canLearn: Bool { walkRoot != nil && syncManager != nil }

    // MARK: - What Structure shows, and what Save wrote

    /// The profile as it would be written, built in memory. Rebuilt whenever an answer changes.
    @Published private(set) var preview: FolderProfile?
    /// Where the loose files would go, by name alone.
    @Published private(set) var looseRoutes: [SetupLooseFileRouting.LooseFileRoute] = []
    /// The sibling map and the shape findings the Structure tree reads, derived once with the
    /// profile they describe.
    ///
    /// **They were computed properties on the view, and one of them ran a detector.**
    /// `FolderReading.shapeFindings` is `StructureDivergence.findings(in:)`, a whole pass over the
    /// profile — and the tree asked for it inside the body of every row it drew. On this Mac's
    /// 5,020-folder profile that is the detector re-run a hundred times per frame, for a lookup
    /// whose answer cannot change while the row is on screen.
    @Published private(set) var previewReadings = FolderProfileReadings()
    /// The report from Save, once there is one.
    @Published private(set) var writtenReport: FileSyncManager.FolderWalkReport?
    /// Set when Save wrote a profile this Mac will not use — see ``SetupFlow/walkNotInUse``.
    @Published private(set) var walkNotInUse = false

    // MARK: - Live settings

    var primarySourceId: String {
        get { defaults.string(forKey: SetupFlow.primarySourceDefaultsKey) ?? "" }
        set {
            // Before the write, not after: `objectWillChange` is a promise about what is *about*
            // to change, and SwiftUI is entitled to read the value the moment it is told.
            objectWillChange.send()
            defaults.set(newValue, forKey: SetupFlow.primarySourceDefaultsKey)
        }
    }

    init(settings: SettingsManager,
         peopleStore: PeopleStore?,
         syncManager: FileSyncManager?,
         hasFilingProfile: Bool,
         defaults: UserDefaults = .standard,
         // **Injectable, and the reason is a measurement.** Three screens grow with what the walk
         // found — People's chips, Countries' chips, Structure's whole tree — and a fixture that
         // cannot walk shows none of them. A fit test built that way measures the empty state and
         // passes at any card height, which is exactly how the retired form's Sources step came to
         // scroll on a real Mac with every one of its tests green.
         walk: SetupWalk? = nil,
         /// A screen to open on instead of the one the defaults imply. **For a harness that has to
         /// photograph or measure one screen**: `initialScreen` reads `hasCompletedSetup`, so a
         /// fixture built on the standard defaults opens wherever *this* Mac would open, and every
         /// picture it takes is of the same screen.
         startScreen: SetupFlow.Screen? = nil,
         onProfileWritten: @escaping () -> Void = {},
         onStartSurvey: @escaping (URL) -> Void = { _ in }) {
        self.settings = settings
        self.initialPeopleStore = peopleStore
        self.syncManager = syncManager
        self.defaults = defaults
        self.onProfileWritten = onProfileWritten
        self.onStartSurvey = onStartSurvey
        // **Resolved here rather than in `onAppear`**, which fires after the first layout: a re-run
        // would render the welcome card for a frame before replacing it.
        let opensOn = startScreen ?? SetupFlow.initialScreen(
            hasCompletedSetup: defaults.bool(forKey: SetupFlow.hasCompletedDefaultsKey),
            hasFilingProfile: hasFilingProfile)
        self.screen = opensOn
        self.welcomeIsInThisRun = opensOn == .welcome
        self.hasFilingProfileAtLaunch = hasFilingProfile
        if let walk { adopt(walk) }
    }

    /// Takes a tree the model did not walk for, and brings everything downstream of one with it.
    ///
    /// The same four steps `startWalk` performs on success, so a fixture reaches the state a real
    /// walk reaches rather than a partial imitation of it.
    func adopt(_ walk: SetupWalk) {
        walkRoot = walk.root
        walkState = .done(walk)
        confirmedCountries = Set(walk.places.filter(JurisdictionCandidates.isConfident).map(\.value))
        rebuildPreview()
    }

    private let hasFilingProfileAtLaunch: Bool

    /// Where the draft lives. One file, one place that names it.
    private var draftURL: URL? { SetupDraftStore.defaultURL() }

    // MARK: - Reading through the engine, never from a capture

    /// The roster to read and write, preferring the engine's own over the one this was built with.
    ///
    /// **The captured property goes stale the moment a walk succeeds, and nothing tells the view.**
    /// `FileSyncManager`'s filing artifacts are plain `var`s, so `FilingArtifacts.attach(to:)` sets
    /// a roster and triggers no SwiftUI invalidation at all. Reading through the manager fixes it
    /// without making six properties `@Published` and paying a re-render on every scan.
    var roster: PeopleStore? { syncManager?.filingPeopleStore ?? initialPeopleStore }

    /// Whether this machine has a surveyed tree **now**, not when the sheet was built.
    var hasProfile: Bool {
        syncManager?.filingFolderProfile != nil || hasFilingProfileAtLaunch
    }

    /// Whether the roster on this Mac is one the store will refuse to write. Both refusals live in
    /// `PeopleStore.save()`; this is the store's own name for the pair.
    var rosterIsReadOnly: Bool { roster?.rosterIsReadOnly ?? false }

    /// The household to hand the walk, whether or not there is a roster on disk yet.
    ///
    /// **This is why People comes before Structure.** Passing `roster?.registry` is nil on the
    /// machine setup exists for, so the profile would be built with no person axis and no
    /// `person-bucket` roles at all, from a sheet that had just finished asking who the household
    /// is. The roster wins where there is one: it carries full names and aliases the draft's bare
    /// first names do not.
    var walkRegistry: PersonRegistry? {
        roster?.registry ?? draft.registry
    }

    // MARK: - The flow

    /// What the flow needs to know about the walk.
    var walkOutcome: SetupFlow.WalkOutcome {
        switch walkState {
        case .idle, .running: return .pending
        case .done: return .learned
        case .skipped: return .skipped
        case .failed: return .failed
        }
    }

    var crumbs: [SetupFlow.Screen] {
        SetupFlow.crumbs(walk: walkOutcome, hasProfile: hasProfile)
    }

    var canGoBack: Bool {
        SetupFlow.previous(before: screen, walk: walkOutcome, hasProfile: hasProfile,
                           welcomeIsInThisRun: welcomeIsInThisRun) != nil
    }

    /// Whether the welcome card belongs to the run in progress.
    ///
    /// **The run opened on it, or it did not.** A first launch resolves to `.welcome` through
    /// `SetupFlow.initialScreen`; asking for setup by name — Help ▸ Set Up SyncCloud…, or
    /// Settings ▸ General ▸ Run setup again… — opens on it too, because somebody who asked for
    /// setup asked for setup, not for its second screen. Either way the card is in this run and
    /// Back reaches it. Only the automatic re-presentation on a Mac that is already set up skips
    /// it, which is the case it was written for.
    let welcomeIsInThisRun: Bool

    /// Steps forward, committing what this screen collected first.
    ///
    /// **Each screen commits as you leave it**, which is what makes quitting mid-setup survivable:
    /// preferences and the location list are live settings the moment they are touched, and the two
    /// answers that need a profile go to the draft. Nothing waits for a button the user may never
    /// press. The profile is the one exception, and it waits for Save on purpose.
    func advance() -> Bool {
        commitCurrentScreen()
        guard let next = SetupFlow.next(after: screen, walk: walkOutcome, hasProfile: hasProfile) else {
            return false
        }
        go(to: next)
        return true
    }

    func retreat() {
        commitCurrentScreen()
        guard let previous = SetupFlow.previous(
            before: screen, walk: walkOutcome, hasProfile: hasProfile,
            welcomeIsInThisRun: welcomeIsInThisRun) else { return }
        go(to: previous)
    }

    /// Skip, on the four screens that offer it. Commits nothing.
    func skip() -> Bool {
        if screen == .learn {
            walkState = .skipped
            Logger.shared.info("Setup: Learn skipped — nothing is read and nothing will be "
                               + "written; Countries and Structure drop out of the flow")
        }
        guard let next = SetupFlow.next(after: screen, walk: walkOutcome, hasProfile: hasProfile) else {
            return false
        }
        go(to: next)
        return true
    }

    private func go(to next: SetupFlow.Screen) {
        withAnimation(.easeInOut(duration: 0.15)) { screen = next }
        // Structure reads a profile that has to exist by the time it is drawn.
        if next == .structure { rebuildPreview() }
    }

    func commitCurrentScreen() {
        switch screen {
        case .locations:
            reconcilePrimary()
        case .you:
            commitNameIfTyped()
            saveDraft()
            applyDraftIfPossible()
        case .people:
            applyDraftIfPossible()
        default:
            // Countries commits nothing: what it collected is read when Structure is built, and
            // `go(to:)` does that on the way in — rebuilding here as well paid for the preview
            // twice going forward, and once going backwards to a screen that never shows it.
            break
        }
    }

    // MARK: - Locations

    var primaryProvider: CloudProvider? {
        settings.enabledProviders.first { $0.id == primarySourceId }
            ?? settings.enabledProviders.first
    }

    func reconcilePrimary() {
        let enabled = settings.enabledProviders
        if enabled.contains(where: { $0.id == primarySourceId }) { return }
        primarySourceId = enabled.first?.id ?? ""
    }

    func addFolderSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as a location"
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = settings.addFolderSource(path: url.path)
        if primarySourceId.isEmpty { primarySourceId = id }
    }

    func refreshProviders() {
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

    // MARK: - Learn

    /// Starts the walk root at the primary location, which is what the user just confirmed.
    ///
    /// A *folder*, and the location's LANDING folder is the honest default: on this Mac the iCloud
    /// source lands at `~/Documents`, which is exactly the tree the hand-built profile describes.
    /// Landing rather than root, deliberately — an account's root also holds `Teams Recordings` and
    /// a Copilot chat cache, which teach the profile nothing and cost a walk over gigabytes to say
    /// so.
    ///
    /// Through the manager, not `primary.landingPath`: the value type joins root and `openAt`
    /// unconditionally, and the manager's spelling degrades to the root when the landing folder is
    /// not there. Seeding at a URL that does not exist starts a walk over nothing.
    ///
    /// **Seeds, never walks.** The seed is driven by the primary location, which moves on every
    /// toggle, so a seed that walked would fire a full read of a three-thousand-folder tree per
    /// click on the Locations screen.
    func seedWalkRoot() {
        // **A finished reading is a decision about a folder, exactly as picking one by hand is.**
        // Without `!walkState.isDone` this runs on every change to the provider list — the sheet
        // watches it — and if `reconcilePrimary` has just moved the primary, the seeded path
        // differs and `invalidateProposals()` throws away a completed walk with nothing said. It
        // is reachable in a few clicks: learn a folder, Back to Locations, switch that location
        // off. Structure then reads "Nothing has been learned yet" and Save has nothing to write,
        // and no screen ever says why.
        //
        // Keeping the root is also the honest answer to what the user did: they turned a location
        // off, they did not ask for the folder they had just read to be forgotten. If the folder
        // really is no longer in use, ``SetupFlow/walkNotInUse`` says so on the summary — which is
        // a sentence, where this was silence.
        guard !rootChosenByHand, !walkState.isDone, let primary = primaryProvider else { return }
        let seeded = URL(fileURLWithPath: settings.landingPath(for: primary.id))
        guard seeded != walkRoot else { return }
        walkRoot = seeded
        invalidateProposals()
    }

    /// Drops what the previous tree produced, without asking for the next lot.
    func invalidateProposals() {
        walkState = .idle
        confirmedCountries = []
        preview = nil
        looseRoutes = []
    }

    /// Asks for a folder, and — from any screen but Learn — reads it straight away.
    ///
    /// **`thenLearn` is not a convenience.** Learn has a button that says what it will do, so it
    /// picks and waits. Every later screen offers a bare *Change…* beside the found items, and
    /// changing the folder there discards those items: without a re-read the screen would sit on
    /// "Reading names…" with nothing reading, forever, and the only way out would be to walk back
    /// to Learn and press it.
    func chooseWalkRoot(thenLearn: Bool = false) {
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
        invalidateProposals()
        if thenLearn { startWalk() }
    }

    var walkRootDisplay: String {
        guard let root = walkRoot else { return "No folder chosen yet" }
        let home = NSHomeDirectory()
        return root.path.hasPrefix(home) ? "~" + root.path.dropFirst(home.count) : root.path
    }

    /// The name of the folder itself — what the screens call it in a sentence.
    var walkRootName: String {
        walkRoot.map { $0.lastPathComponent } ?? "your folder"
    }

    /// Reads the tree, once, and advances at the same moment.
    ///
    /// **Continue never waits.** The screens after this one each work without the walk and fill in
    /// when it lands, so the user is never held in front of a spinner for a tree they have already
    /// told the app to read.
    func startWalk() {
        guard let root = walkRoot, let manager = syncManager else { return }
        walkState = .running
        let known = Set((roster?.people.flatMap(\.nameForms) ?? [])
                        + draft.everyone.map(\.displayName))
        Task { [weak self] in
            let result = await manager.walkForSetup(root: root, known: known)
            guard let self else { return }
            switch result {
            case .success(let walk):
                self.walkState = .done(walk)
                self.confirmedCountries = Set(walk.places.filter(JurisdictionCandidates.isConfident)
                    .map(\.value))
                self.seedNameSuggestion()
            case .failure(let failure):
                self.walkState = .failed(failure.description)
                Logger.shared.warning("Setup walk failed: \(failure.description)")
            }
        }
    }

    /// The failure's own words, for the line the three screens after Learn show in place of items.
    var walkFailureReason: String? {
        if case .failed(let why) = walkState { return why }
        return nil
    }

    // MARK: - You

    /// Fills in the name fields from the Mac account and the learned tree, without overwriting
    /// anything the user has typed or anything the roster already knows.
    func seedNameSuggestion() {
        guard firstName.isEmpty, surname.isEmpty else { return }
        if !draft.yourName.isEmpty {
            firstName = draft.yourName
            // A roster or draft answer is the user's own, so it stays offered whether or not the
            // suggestion rules would have proposed it.
            customForms = draft.yourFullNames
            return
        }
        let suggestion = SetupFlow.suggestedName(fullUserName: NSFullUserName(),
                                                 folderNames: topLevelFolderNames)
        firstName = suggestion.first
        surname = suggestion.surname ?? ""
    }

    /// The folder in the learned tree whose name is the user's first name — the corroboration that
    /// lets the You screen say *"your Mac account says X, and Documents has a folder named X"*
    /// rather than asserting.
    ///
    /// **Computed, and that is a fix.** It was stored, and set inside `seedNameSuggestion`, which
    /// guards on the fields being empty — so on every real path it ran once at open, before the
    /// walk existed, found nothing, and never ran again. The sentence it exists for could not
    /// appear on the machine setup is for. Asking the tree each time also makes it follow the name
    /// the user actually typed, which a value captured at open never could.
    var matchedFolder: String? {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return nil }
        return topLevelFolderNames.first { $0.caseInsensitiveCompare(first) == .orderedSame }
    }

    /// The top-level folder names of the learned tree, or none when there is no tree.
    var topLevelFolderNames: [String] {
        (walkState.walk?.tree ?? []).filter(\.isDirectory).map(\.name)
    }

    /// Every form on offer, ticked state included — the suggestions for the name as it stands now,
    /// then anything the user typed.
    ///
    /// **Derived from the fields every time, never accumulated.** Holding the ticked set as the
    /// answer meant editing the name left the old name's forms ticked *and* still on screen: they
    /// were no longer suggestions, so they fell through to the "typed by hand" list and the screen
    /// offered `Abhishek Girish` under a name now reading `Abhi`. What is remembered instead is the
    /// user's *decisions* — which suggestions they overrode, and which forms they typed — and both
    /// survive an edit without outliving the name they were about.
    var offeredNameForms: [(form: String, ticked: Bool)] {
        var out: [(form: String, ticked: Bool)] = []
        var seen: Set<String> = []
        for suggestion in SetupFlow.nameForms(first: firstName,
                                              surname: surname.isEmpty ? nil : surname) {
            out.append((suggestion.form, formOverrides[suggestion.form] ?? suggestion.ticked))
            seen.insert(suggestion.form)
        }
        for custom in customForms where !seen.contains(custom) {
            out.append((custom, formOverrides[custom] ?? true))
            seen.insert(custom)
        }
        return out
    }

    /// The forms the user will actually be filed under.
    var tickedForms: [String] { offeredNameForms.filter(\.ticked).map(\.form) }

    func toggleForm(_ form: String) {
        let current = offeredNameForms.first { $0.form == form }?.ticked ?? false
        formOverrides[form] = !current
    }

    func commitTypedForm() {
        let form = newFormField.trimmingCharacters(in: .whitespacesAndNewlines)
        newFormField = ""
        guard !form.isEmpty else { return }
        if !customForms.contains(form) { customForms.append(form) }
        formOverrides[form] = true
    }

    /// Writes the name answers into the draft. **The surname is not stored on its own** — it exists
    /// to build the forms, and a bare surname is not a name any document prints.
    func commitNameIfTyped() {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return }
        draft.yourName = first
        draft.yourFullNames = tickedForms
    }

    // MARK: - People

    var rosterNames: [String] {
        if let store = roster {
            let mine = draft.yourName.trimmingCharacters(in: .whitespacesAndNewlines)
            return store.people
                // **Two ways to be you, and the second is not redundant.** A roster seeded from a
                // survey's person axis carries no relationships at all, so nothing answers to "me"
                // — and matching on the draft name alone then listed the user among everyone else,
                // with a Remove button beside them.
                .filter { $0.relationship?.lowercased() != "me" }
                .map(\.displayName)
                .filter {
                    mine.isEmpty || $0.compare(mine, options: [.caseInsensitive, .diacriticInsensitive])
                        != .orderedSame
                }
        }
        return draft.others.map(\.displayName)
    }

    /// The proposals still worth showing — capped, because a chip row is a glance and the rule
    /// over-proposes on purpose.
    var visiblePeopleCandidates: [PersonCandidate] {
        let already = Set(rosterNames.map { $0.lowercased() }
                          + [draft.yourName.lowercased(), firstName.lowercased()]
                          + draft.others.map { $0.displayName.lowercased() })
        return (walkState.walk?.people ?? [])
            .filter { !already.contains($0.name.lowercased()) }
            .prefix(Self.peopleChipLimit)
            .map { $0 }
    }

    /// How many found names the People screen offers at once.
    static let peopleChipLimit = 12

    func addProposedPerson(_ candidate: PersonCandidate) {
        addPerson(named: candidate.name)
    }

    func commitTypedPerson() {
        let name = newPersonField.trimmingCharacters(in: .whitespacesAndNewlines)
        newPersonField = ""
        addPerson(named: name)
    }

    private func addPerson(named name: String) {
        guard !name.isEmpty, !rosterNames.contains(where: {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return }
        if let store = roster {
            store.add(displayName: name)
            objectWillChange.send()
        } else {
            draft.others.append(SetupDraft.DraftPerson(displayName: name))
            saveDraft()
        }
    }

    func removePerson(named name: String) {
        if let store = roster {
            if let person = store.people.first(where: { $0.displayName == name }) {
                store.remove(id: person.id)
                objectWillChange.send()
            }
        } else {
            draft.others.removeAll { $0.displayName == name }
            saveDraft()
        }
    }

    /// What the roster records this person as, when it records anything.
    func relationship(of name: String) -> String? {
        guard let store = roster else { return nil }
        let match = store.people.first {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
        guard let relationship = match?.relationship?.trimmingCharacters(in: .whitespaces),
              !relationship.isEmpty else { return nil }
        return relationship
    }

    // MARK: - Countries

    var countryCandidates: [JurisdictionCandidate] { walkState.walk?.places ?? [] }

    /// Countries the user typed in, which the tree never proposed.
    @Published private(set) var addedCountries: [String] = []

    func toggleCountry(_ value: String) {
        if confirmedCountries.contains(value) {
            confirmedCountries.remove(value)
        } else {
            confirmedCountries.insert(value)
        }
    }

    func commitTypedCountry() {
        let value = newCountryField.trimmingCharacters(in: .whitespacesAndNewlines)
        newCountryField = ""
        guard !value.isEmpty, !confirmedCountries.contains(value) else { return }
        if !countryCandidates.contains(where: { $0.value == value }) {
            addedCountries.append(value)
        }
        confirmedCountries.insert(value)
    }

    // MARK: - Structure

    /// Rebuilds the in-memory profile from the retained tree and the answers as they stand.
    ///
    /// Sub-second on a few thousand folders, and it writes nothing — which is what makes Back from
    /// Structure free. Writing a profile per preview would mint a directory per press, refuse over
    /// its own id inside one second, and churn the fingerprint cached verdicts hang off.
    func rebuildPreview() {
        guard let walk = walkState.walk else { return }
        let built = FileSyncManager.previewProfile(walk: walk, registry: walkRegistry,
                                                   jurisdictionValues: confirmedCountries)
        preview = built
        previewReadings = FolderProfileReadings(built)
        looseRoutes = SetupLooseFileRouting.route(walk: walk, profile: built,
                                                  registry: walkRegistry)
    }

    /// What Structure reads: the preview's derivations, or — on a re-run with no walk — the ones
    /// for the profile this Mac already has, computed on first use and kept.
    func readings(for profile: FolderProfile) -> FolderProfileReadings {
        if preview != nil { return previewReadings }
        if let cached = activeReadings, cached.profileId == profile.profileId { return cached }
        let built = FolderProfileReadings(profile)
        activeReadings = built
        return built
    }

    private var activeReadings: FolderProfileReadings?

    /// The profile Structure is reading — the preview, or on a re-run without a walk, the one this
    /// Mac already has.
    var structureProfile: FolderProfile? {
        preview ?? syncManager?.filingFolderProfile
    }

    /// Whether Structure is showing a profile it cannot write to — a re-run where Learn was
    /// skipped. Its Save writes nothing, and the loose-file view is hidden.
    var structureIsReadOnly: Bool { preview == nil && structureProfile != nil }

    /// Whether Structure's button has a profile to write.
    ///
    /// False in two states that look different and behave the same: a re-run showing the profile
    /// this Mac already has, and a folder that was changed and not re-read. Both used to offer a
    /// Save that returned at its first guard.
    var canWriteProfile: Bool { walkState.walk != nil && syncManager != nil }

    /// Writes the profile, attaches it, lands the draft, and starts the reading if it was asked
    /// for — in that order, which is the order today's walk already depends on.
    func save() async {
        guard !isSaving, let walk = walkState.walk, let manager = syncManager else { return }
        isSaving = true
        defer { isSaving = false }
        let result = await manager.writeWalkProfile(tree: walk.tree, root: walk.root,
                                                    jurisdictionValues: confirmedCountries,
                                                    registry: walkRegistry)
        switch result {
        case .success(let report):
            writtenReport = report
            walkNotInUse = !report.becameActive
            // Attach first, so `roster` resolves to the store the write just created; then land
            // the draft in it. Reading a captured store here is what made this a no-op for two
            // stages.
            onProfileWritten()
            applyDraftIfPossible()
            Logger.shared.info("Setup saved profile '\(report.profileId)' — \(report.summary)")
            if readDocuments { onStartSurvey(walk.root) }
        case .failure(let failure):
            walkState = .failed(failure.description)
            Logger.shared.warning("Setup could not write its profile: \(failure.description)")
        }
    }

    // MARK: - The draft

    func loadDraft() {
        guard let url = draftURL, let stored = SetupDraftStore.read(at: url) else {
            seedDraftFromRoster()
            return
        }
        draft = stored
        if draft.yourName.isEmpty { seedDraftFromRoster() }
    }

    /// Fills the sheet in from a roster that already exists, so a re-run opens on current state.
    ///
    /// **"You" is read by relationship, not by the literal `me`.** `PeopleOrder.tier(of:)` maps a
    /// six-word vocabulary onto the same tier, and a roster written by hand may say `self` or
    /// `owner`.
    private func seedDraftFromRoster() {
        guard let store = roster else { return }
        if let me = store.people.first(where: { PeopleOrder.tier(of: $0.relationship) == .yourself }) {
            draft.yourName = me.displayName
            draft.yourFullNames = me.fullNames
        }
    }

    /// Writes the draft — but only on a machine that has nowhere better to put the answers.
    ///
    /// **With a roster the draft is not a backup, it is a second copy that goes stale.** Those
    /// answers land in `people.json` the moment the screen is left, so writing them here too would
    /// leave a file `loadDraft` prefers over the roster on the next open.
    func saveDraft() {
        guard roster == nil, let url = draftURL else { return }
        SetupDraftStore.write(draft, to: url)
    }

    /// Writes the draft into the roster where there is one, and clears it once it has landed.
    func applyDraftIfPossible() {
        guard !draft.isEmpty else { return }
        guard let store = roster else {
            // Said once, where it can be read back: there is no profile on this machine, so there
            // is no `people.json` to write into and the answers wait in `setup-draft.json`.
            Logger.shared.info("Setup: no filing profile yet, so \(draft.everyone.count) roster "
                               + "answer(s) stay in the setup draft until a walk creates one")
            return
        }
        let result = SetupDraft.apply(draft, to: store)
        if result.added > 0 || result.updated > 0, let url = draftURL {
            // **Cleared only when it actually landed.** `apply` is idempotent, so a no-op result on
            // a re-run is not evidence the draft reached the roster — and clearing on that would
            // delete the only copy of answers a failed apply never wrote.
            SetupDraftStore.clear(at: url)
        }
    }

    // MARK: - Opening

    func onOpen() {
        loadDraft()
        reconcilePrimary()
        seedWalkRoot()
        seedNameSuggestion()
        Logger.shared.info("Setup opened on \(screen.displayName) — "
                           + "\(settings.availableProviders.count) location(s) discovered, "
                           + "roster \(roster == nil ? "not writable yet (no profile)" : "available")")
    }
}

/// A profile's sibling map and shape findings, derived once.
///
/// One value rather than two properties, so a caller cannot end up holding a map from one profile
/// and findings from another.
struct FolderProfileReadings {
    let profileId: String
    let children: [String: [String]]
    let shapes: [String: StructureFinding]

    init() {
        profileId = ""
        children = [:]
        shapes = [:]
    }

    init(_ profile: FolderProfile) {
        profileId = profile.profileId
        children = FolderReading.childrenByParent(profile)
        shapes = FolderReading.shapeFindings(in: profile)
    }
}
