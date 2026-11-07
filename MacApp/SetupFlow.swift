import Foundation

/// The setup form's decision logic and copy, kept UI-free so `SyncCloudTests` can pin the show
/// gate, the step order and every claim the screens make without driving a view.
///
/// The form asks for what a walk can't work out: who the user is, which sources matter, who else
/// is in the household, which tree to learn. It also starts the folder survey that drives Organize.
///
/// Nobody who works on the app sees it: it renders once per install, on a Mac that has never run
/// SyncCloud. That is why so much is pinned here: the copy below is data, and the tests derive
/// their claims from it.
enum SetupFlow {

    // MARK: - Persisted state

    /// Set when the user reaches the end of the form. QA reset:
    /// `defaults delete com.abhishekgirish.SyncCloud hasCompletedSetup`.
    static let hasCompletedDefaultsKey = "hasCompletedSetup"

    /// The retired welcome tour's seen flag: read, never written by the form.
    ///
    /// The key outlives the tour on purpose. Older installs have it set, and renaming it would make
    /// them look like fresh installs and open the form over a working app. ``shouldAutoShow`` reads
    /// it as "already greeted". QA reset:
    /// `defaults delete com.abhishekgirish.SyncCloud hasSeenFirstRunWelcome`.
    static let legacyWelcomeSeenDefaultsKey = "hasSeenFirstRunWelcome"

    /// The source whose tree SyncCloud learns from: the one the Learn screen reads.
    ///
    /// Held here, not in `SettingsManager`, while nothing but setup reads it: promoted into
    /// Settings, it would be a published property no caller asks for.
    static let primarySourceDefaultsKey = "setupPrimarySourceId"

    // MARK: - The screens

    /// A screen of the guided sheet, in the order it is walked.
    ///
    /// A sequence, not a rail of places to go: the sheet asks one thing at a time, then shows what
    /// it found. Only the five screens that ask a question carry a number; the rest confirm, show
    /// or offer.
    enum Screen: String, CaseIterable, Equatable, Sendable {
        /// What the app is, what the sheet will ask, and the privacy claim.
        case welcome
        /// Which discovered locations to use. A confirmation, not a question with a wrong answer.
        case locations
        /// The folder to read, and the one disclosure that matters — see ``disclosureScreen``.
        case learn
        /// Your name, and the forms of it a document might print.
        case you
        /// Anyone else the folders name.
        case people
        /// Which short folder names are countries.
        case countries
        /// What the walk found, read back as a tree, before anything is written.
        case structure
        /// What to do next, in the app's own four workspaces.
        case workspaces
        /// Text size, light or dark, accent — and the General preferences under More options.
        case appearance
        /// Every answer, the live reading row, and the way out.
        case summary

        var displayName: String {
            switch self {
            case .welcome: return "Welcome"
            case .locations: return "Locations"
            case .learn: return "Learn"
            case .you: return "You"
            case .people: return "People"
            case .countries: return "Countries"
            case .structure: return "Structure"
            case .workspaces: return "Workspaces"
            case .appearance: return "Appearance"
            case .summary: return "Summary"
            }
        }

        /// The number the crumb strip prints, or nil for a screen that asks nothing.
        ///
        /// Fixed per screen, never recomputed. When Learn is skipped Countries drops out, and a
        /// strip that renumbered would move People between two visits to the same sheet; instead
        /// the missing number is simply absent.
        var number: Int? {
            switch self {
            case .locations: return 1
            case .learn: return 2
            case .you: return 3
            case .people: return 4
            case .countries: return 5
            default: return nil
            }
        }

        /// Whether this screen carries a Why panel, and so lays its content out in the narrower
        /// column beside one.
        ///
        /// Welcome and Summary are the sheet's bookends and use the full width. Structure is its
        /// own explanation: prose beside the tree would argue with the thing being checked.
        ///
        /// `theWhyPanelRuleMatchesWhatTheSheetDraws` checks this against the sheet's own switch,
        /// so the two can't drift apart.
        var hasWhyPanel: Bool {
            switch self {
            case .welcome, .structure, .summary: return false
            default: return true
            }
        }

        /// Whether this screen offers a Skip.
        ///
        /// Locations and Countries have no Skip because their answer is already correct if left
        /// alone — every location on, the likely countries ticked — so a Skip would be a second
        /// spelling of Continue. Structure has none because it is the screen that writes.
        var isSkippable: Bool {
            switch self {
            case .learn, .you, .people, .appearance: return true
            default: return false
            }
        }
    }

    /// The screens the crumb strip draws: everything between Welcome and Summary.
    ///
    /// Welcome introduces the sheet and Summary closes it; neither is a place to navigate back to,
    /// which is what a crumb would offer.
    static let crumbs: [Screen] = Screen.allCases.filter { $0 != .welcome && $0 != .summary }

    /// How many screens ask the user something. The welcome card says the count, so it is derived,
    /// not written twice.
    static var questionCount: Int { Screen.allCases.filter { $0.number != nil }.count }

    /// What the walk did, as the flow needs to know it. UI-free so
    /// ``next(after:walk:hasProfile:)`` can be tested; the sheet's richer state (the tree, the
    /// failure text) reduces to this.
    enum WalkOutcome: Equatable, Sendable {
        /// Not started, or still reading. Neither drops a screen: Continue never waits.
        case pending
        /// A tree was read.
        case learned
        /// The user pressed Skip. Nothing was read and nothing will be written.
        case skipped
        /// A walk was asked for and did not happen.
        case failed
    }

    /// Whether a screen is part of the flow at all, given what the walk did.
    ///
    /// Two screens depend on a walk, differently:
    ///
    /// - Countries is dropped only when the user skipped. With no candidates it still offers its
    ///   free-text field, and after a failed walk it shows the failure: a screen that vanishes
    ///   after an error says nothing about what went wrong.
    /// - Structure needs a tree. Without one it is dropped, unless this Mac already has a profile,
    ///   which it then shows read-only.
    static func includes(_ screen: Screen, walk: WalkOutcome, hasProfile: Bool) -> Bool {
        switch screen {
        case .countries: return walk != .skipped
        case .structure: return walk == .pending || walk == .learned || hasProfile
        default: return true
        }
    }

    /// The crumbs to draw, for a sheet in this state.
    static func crumbs(walk: WalkOutcome, hasProfile: Bool) -> [Screen] {
        crumbs.filter { includes($0, walk: walk, hasProfile: hasProfile) }
    }

    /// The screen after this one, or nil at the end.
    static func next(after screen: Screen, walk: WalkOutcome = .pending,
                     hasProfile: Bool = false) -> Screen? {
        step(from: screen, by: 1, walk: walk, hasProfile: hasProfile)
    }

    /// The screen before this one, or nil at the start.
    ///
    /// Back reaches Welcome from Locations when the run opened on it: nothing is written until
    /// Structure's Save, so stepping back to the introduction costs nothing. A run without Welcome
    /// gives Locations no Back.
    /// - Parameter welcomeIsInThisRun: whether the welcome card is part of the run in progress. A
    ///   property of the run, not of the Mac: a Mac that set up once can still open a run on the
    ///   welcome card, and the user must be able to get back to it.
    static func previous(before screen: Screen, walk: WalkOutcome = .pending,
                         hasProfile: Bool = false, welcomeIsInThisRun: Bool = false) -> Screen? {
        let earlier = step(from: screen, by: -1, walk: walk, hasProfile: hasProfile)
        if earlier == .welcome && !welcomeIsInThisRun { return nil }
        return earlier
    }

    private static func step(from screen: Screen, by offset: Int,
                             walk: WalkOutcome, hasProfile: Bool) -> Screen? {
        guard var index = Screen.allCases.firstIndex(of: screen) else { return nil }
        while true {
            index += offset
            guard index >= 0, index < Screen.allCases.count else { return nil }
            let candidate = Screen.allCases[index]
            if includes(candidate, walk: walk, hasProfile: hasProfile) { return candidate }
        }
    }

    /// Where the sheet opens.
    ///
    /// A re-run skips the welcome screen: it introduces the app to someone who has never seen it,
    /// not to someone returning from Help ▸ Set Up SyncCloud…. It reads the same facts the
    /// auto-show gate does, rather than inventing another.
    static func initialScreen(hasCompletedSetup: Bool, hasFilingProfile: Bool) -> Screen {
        hasCompletedSetup || hasFilingProfile ? .locations : .welcome
    }

    /// Whether this screen opens with the caret already in its first field.
    ///
    /// You alone: it is the only screen whose first control is a text field, and without focus
    /// the user must click before typing. Elsewhere the caret would have nowhere to go.
    ///
    /// A rule, not a `case` in the view, because `SetupSheet` can't be built in a test. It must
    /// apply on a screen change too, not only in `onAppear`, or a first launch that reaches You by
    /// Continue never gets the caret.
    static func wantsFirstFieldFocus(_ screen: Screen) -> Bool {
        screen == .you
    }

    // MARK: - The show gate

    /// Whether the form opens itself on launch.
    ///
    /// Three inputs; the last two keep an existing install from being interrupted:
    ///
    /// - `hasCompletedSetup`: the form's own flag. Once through, never again unprompted.
    /// - `hasSeenLegacyWelcome`: the retired tour's flag (`hasSeenFirstRunWelcome`), still set on
    ///   older installs. It means the user has been greeted, so the form waits in Help.
    /// - `hasFilingProfile`: a Mac with a surveyed tree has answered the most expensive question
    ///   already. Setup has things to offer it, but not unprompted.
    ///
    /// Generous about refusing on purpose: a form opening over a working app is far worse than one
    /// found in the Help menu, whose entry is unconditional.
    static func shouldAutoShow(hasCompletedSetup: Bool,
                               hasSeenLegacyWelcome: Bool,
                               hasFilingProfile: Bool) -> Bool {
        !hasCompletedSetup && !hasSeenLegacyWelcome && !hasFilingProfile
    }

    // MARK: - Welcome copy

    /// What the app is, in one sentence, on the card that opens the sheet.
    ///
    /// It names the four workspaces the panels below draw, and says the two things someone
    /// deciding whether to continue needs: the folders stay where they are, and every change can be
    /// undone.
    static let welcomeBlurb =
        "Browse, compare, organize and edit the cloud folders already on this Mac: iCloud Drive, "
        + "Google Drive, OneDrive, Dropbox. Your folders stay where they are, and every change is "
        + "one ⌘Z."

    /// The heading over the numbered list of what the sheet will ask.
    ///
    /// It counts the questions, so it is derived from them and can't go stale.
    ///
    /// It says nothing about how long setup takes, by decision: the flow holds a tree walk and an
    /// optional read that can run for hours. The reading offer's estimate (`DocumentSurveyCost`)
    /// is a different claim, about work the user chooses, measured from a real count.
    static var welcomeQuestionsHeading: String {
        "\(spelled(questionCount)) questions, then a look at what it found"
    }

    /// Small numbers as words, for prose. Above nine, the digits read better anyway.
    static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine"]
        guard n >= 0, n < words.count else { return "\(n)" }
        return words[n].prefix(1).uppercased() + words[n].dropFirst()
    }

    /// What follows the five questions, said on the welcome card so the user knows the sheet's
    /// shape: it learns first, then shows what it found.
    static let welcomeAfterQuestions =
        "After learning your folder, SyncCloud shows what it found and asks you to confirm. "
        + "Appearance is optional and comes last. Each screen says why."

    /// One of the panels on the welcome screen: what SyncCloud does, in a strip.
    struct Panel: Equatable, Sendable {
        let art: SetupArt.Art
        let title: String
        let blurb: String
    }

    /// The four workspaces, one panel each.
    ///
    /// Order is a claim, not layout: Browse leads because a fresh install opens there.
    /// `theWelcomeStripOpensWhereTheAppDoes` pins that against `ContentView.selectedWorkspace`'s
    /// default.
    ///
    /// Blurbs must describe what ships. `noPanelCallsARetiredWorkspaceAWorkspace` lists the
    /// workspaces folded into Organize lenses, so none goes on being called a workspace here.
    static let panels: [Panel] = [
        Panel(art: .browse, title: "Browse", blurb: "One tree, full width."),
        Panel(art: .compare, title: "Compare", blurb: "Two folders side by side."),
        Panel(art: .filing, title: "Organize", blurb: "Loose files, duplicates, renames."),
        Panel(art: .edit, title: "Edit", blurb: "Text, Markdown, PDFs."),
    ]

    /// A row of the numbered list on the welcome screen.
    struct OutlineRow: Equatable, Sendable {
        let screen: Screen
        let detail: String
    }

    /// What the sheet will ask, said before it asks, so *Get Started* is a decision, not a leap. A
    /// numbered ``Screen`` added without a line here fails
    /// `theWelcomeOutlineNamesEveryQuestionTheSheetAsks`.
    static let outline: [OutlineRow] = [
        OutlineRow(screen: .locations, detail: "Which locations to use"),
        OutlineRow(screen: .learn, detail: "A folder to learn from"),
        OutlineRow(screen: .you, detail: "Your name"),
        OutlineRow(screen: .people, detail: "Other people"),
        OutlineRow(screen: .countries, detail: "Countries in folder names"),
    ]

    /// How to get back in, said on the first screen and the last.
    static let runAgainNote = "Run again any time: Help ▸ Set Up SyncCloud…"

    /// What the Summary screen says about the household.
    ///
    /// Pure, because the interesting half is a refusal. When `people.json` can't be read, or lists
    /// an id twice, the form's list is a seed from folder names and `PeopleStore.save()` won't
    /// write over the file. Counting it anyway would claim the user's family from directory
    /// listings, under "You're all set".
    ///
    /// Each refusal is named as Settings names it: a roster that lists an id twice was read fine,
    /// and "could not be read" would send the user looking for a broken file.
    static func peopleSummary(otherCount: Int, rosterIsReadOnly: Bool,
                              rosterRepeatsAnId: Bool = false) -> String {
        let others = "\(otherCount) other\(otherCount == 1 ? "" : "s")"
        if rosterIsReadOnly, rosterRepeatsAnId {
            return "\(others) listed, but people.json lists someone twice, so changes can’t be "
                + "saved — fix it in Settings ▸ Organize, under People"
        }
        if rosterIsReadOnly {
            return "\(others) listed, but people.json could not be read — fix it in Settings ▸ Organize, under People"
        }
        return otherCount == 0 ? "Nobody else on the list yet" : "\(others) on the list"
    }

    /// What Structure and Summary say about a walk that ran but is not in use.
    ///
    /// The store won't re-point away from a profile SyncCloud didn't write, so on a Mac with a
    /// hand-built one the walk succeeds, is saved, and changes nothing. The user should be told.
    static let walkNotInUse =
        "This Mac already has a folder profile SyncCloud did not write, so that one is still in "
        + "use. What was just learned is saved beside it and unused."

    /// What Summary says about the answers that have nowhere to land yet.
    ///
    /// On a Mac with no folder profile there is no `people.json` to write into, so the You and
    /// People answers wait in `setup-draft.json` until a walk mints one. Summary says what is in
    /// effect, and in this, the commonest case, those two rows are not yet.
    static let heldUntilSurveyed = "kept, and applied once SyncCloud learns a folder tree"

    /// The one-line privacy claim, said on the welcome screen and echoed in the footer of every
    /// step.
    ///
    /// Checked in three places: the walk and the document read are `FileManager`, PDFKit and
    /// Vision; suggestions go through `SystemLanguageModel.default`, Apple's on-device model; the
    /// roster is `people.json` beside the profile. The one exception is Organize's opt-in Refine
    /// pass, named on the survey step (``surveyPrivacyNote``, ``surveyThirdPartyNote``).
    static let privacyClaim =
        "All of this happens on this Mac. SyncCloud reads your files locally and keeps what it "
        + "learns in your own Library folder. Nothing is uploaded, and there is no account to create."

    /// The short reminder in every screen's footer, once the claim above has been made in full.
    static let privacyFooter = "Stays on this Mac"

    /// The screen the privacy disclosure is made on.
    ///
    /// A named constant with one call site, so a test can pin it. The two notes below are the
    /// app's whole promise about reading the user's documents, plus its one exception, and they
    /// belong in front of the *Learn* button that does the reading. On a later screen they would
    /// come after the walk, which is no disclosure.
    ///
    /// `theDisclosureIsDrawnOnTheScreenThatAsksForIt` pins both the constant and the call site.
    static let disclosureScreen: Screen = .learn

    /// The local half of the Learn screen's disclosure, stated where the user authorises reading
    /// their documents, the only screen that asks for that.
    ///
    /// Drawn verbatim, never paraphrased: `theSurveyDisclosureNamesItsOneException` requires its
    /// tokens.
    static let surveyPrivacyNote =
        "Your documents are read on this Mac and never leave it. SyncCloud keeps what it learns in "
        + "your own Library folder — not the files, not the text, not the folder names."

    /// The exception, named on the same screen **even though setup cannot enable it**.
    ///
    /// A promise stated without its exception reads as complete, until the user meets the Refine
    /// button later. Naming it makes the rest of the claim believable.
    static let surveyThirdPartyNote =
        "One thing can reach a third party, and setup does not turn it on: Organize’s optional "
        + "Refine pass asks Claude — Anthropic’s service, on an API key you supply. It never runs "
        + "on its own, and it is off unless you turn it on in Settings ▸ Organize."

    // MARK: - The You screen's pre-fill

    /// What the You screen offers before the user types anything.
    ///
    /// Two sources, neither trusted alone. The Mac account name is usually a real name but
    /// sometimes `admin`; a learned folder matching its first word corroborates it, so the screen
    /// can say *"your Mac account says X, and Documents has a folder named X"* rather than assert.
    ///
    /// Split at the first space, so everything after the first word is the surname: "Maria del
    /// Carmen Ruiz" builds better forms that way than by taking the last word.
    ///
    /// Pure, and here rather than in the view, because `SetupSheet` can't be built in a test.
    static func suggestedName(fullUserName: String,
                              folderNames: [String]) -> (first: String, surname: String?,
                                                         matchedFolder: String?) {
        let trimmed = fullUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else {
            return (trimmed, nil, folderNames.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        }
        let first = String(trimmed[trimmed.startIndex..<space])
        let rest = String(trimmed[trimmed.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        let matched = folderNames.first { $0.caseInsensitiveCompare(first) == .orderedSame }
        return (first, rest.isEmpty ? nil : rest, matched)
    }

    /// The forms of a name a document might print, and which of them start ticked.
    ///
    /// Order matters, so surname-first is its own form: an Indian bank statement prints
    /// `Girish Abhishek`, a US one `Abhishek Girish`, and the matcher is positional.
    ///
    /// Initials are offered but not ticked: `A. Girish` matches many people, and the router acts
    /// on every ticked form. An accented name is offered in both spellings, because forms and
    /// scanners often drop accents and only the user knows which their documents carry.
    static func nameForms(first: String, surname: String?) -> [(form: String, ticked: Bool)] {
        let first = first.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty else { return [] }
        var forms: [(String, Bool)] = []
        func add(_ form: String, _ ticked: Bool) {
            guard !form.isEmpty, !forms.contains(where: { $0.0 == form }) else { return }
            forms.append((form, ticked))
        }

        if let surname, !surname.isEmpty {
            add("\(first) \(surname)", true)
            add("\(surname) \(first)", true)
            if let initial = first.first {
                add("\(initial). \(surname)", false)
                add("\(surname) \(initial).", false)
            }
        } else {
            add(first, true)
        }

        // The same forms without accents, when that differs. Not a transliteration: `folding` drops
        // diacritics and keeps the letters, as a system that can't print them does.
        for (form, ticked) in forms {
            let folded = form.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            if folded != form { add(folded, ticked) }
        }
        return forms.map { (form: $0.0, ticked: $0.1) }
    }
}
