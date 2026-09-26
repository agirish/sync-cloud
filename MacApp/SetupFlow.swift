import Foundation

/// The setup form's decision logic and copy, kept UI-free so `SyncCloudTests` can pin the show
/// gate, the step order and every claim the screens make without driving a view.
///
/// **This replaces the six-page welcome tour (`SetupArt` still carries its illustrations).** The
/// tour asked the user for nothing: everything the filing engine needs — who they are, which
/// sources matter, who else is in the household, which tree to learn — was left to be found later
/// across nine settings tabs, and the folder survey that drives Organize had no trigger in the app
/// at all. The form asks for the four things a walk cannot work out.
///
/// **Nobody who works on this ever sees it, which is why so much of it is pinned here.** It renders
/// once per install on a machine that has never run SyncCloud; the tour it replaces spent an entire
/// release calling Duplicates a *workspace* because nothing failed when the fold happened. The
/// copy below is data, and the tests derive their claims from it.
enum SetupFlow {

    // MARK: - Persisted state

    /// Set when the user reaches the end of the form. QA reset:
    /// `defaults delete com.abhishekgirish.SyncCloud hasCompletedSetup`.
    static let hasCompletedDefaultsKey = "hasCompletedSetup"

    /// The retired welcome tour's seen flag — read, never written by the form.
    ///
    /// **The key outlives the screen on purpose.** Every machine that ran a build before this one
    /// has it set, and `defaults delete com.abhishekgirish.SyncCloud hasSeenFirstRunWelcome` is in
    /// the QA notes; renaming it would make every one of those users look like a fresh install and
    /// open a form over their working app. ``shouldAutoShow`` reads it as "already greeted".
    static let legacyWelcomeSeenDefaultsKey = "hasSeenFirstRunWelcome"

    /// The source whose tree SyncCloud learns from — the one the Learn screen reads.
    ///
    /// **Held here rather than in `SettingsManager` for as long as nothing but setup reads it.**
    /// The survey is what gives it meaning, and the survey is a later stage; a key promoted into
    /// the Settings module before then would be a published property that answers a question no
    /// caller asks. Stage B moves it to where `FolderSurveyBuilder`'s caller can see it.
    static let primarySourceDefaultsKey = "setupPrimarySourceId"

    // MARK: - The screens

    /// A screen of the guided sheet, in the order it is walked.
    ///
    /// **Ten cases rather than a welcome plus a rail of five.** The form this replaces put every
    /// step on a rail, which made each one a place to *go*; the sheet asks one thing at a time and
    /// then shows what it found, which is a sequence. Only five of the ten ask a question, and
    /// those five are the ones that carry a number — the rest confirm, show or offer.
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
        /// **Fixed per screen, never recomputed from what is on screen.** When Learn is skipped
        /// Countries drops out entirely, and a strip that renumbered would move People from 4 to
        /// something else between two visits to the same sheet — so the numbers stay put and the
        /// missing one is simply absent, which needs no explaining.
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
        /// **Three screens do not, and each for its own reason.** Welcome and Summary are the
        /// sheet's own bookends and use the full width; Structure is its own explanation — the
        /// tree, the readings and the counts are the argument, and a column of prose beside them
        /// would be arguing with the thing being checked.
        ///
        /// `theWhyPanelIsDrawnExactlyWhereTheRuleSaysItIs` renders each screen and checks the
        /// column for ink, so this cannot drift from what the sheet actually draws.
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
    /// and a crumb for either would offer exactly that.
    static let crumbs: [Screen] = Screen.allCases.filter { $0 != .welcome && $0 != .summary }

    /// How many screens actually ask the user something.
    ///
    /// The welcome card counts them out loud, so it is derived rather than written twice.
    static var questionCount: Int { Screen.allCases.filter { $0.number != nil }.count }

    /// What the walk did, as the flow needs to know it.
    ///
    /// UI-free so ``next(after:walk:hasProfile:)`` can be tested; the sheet's own richer state
    /// (which carries the tree and the failure text) reduces to this.
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
    /// Two screens depend on a walk, and they depend on it differently:
    ///
    /// - **Countries** is dropped only when the user *skipped*. A walk that ran and found no
    ///   candidates still has its free-text field to offer, and a walk that failed shows its
    ///   failure there rather than vanishing — a screen that disappears after an error tells the
    ///   user nothing about what went wrong.
    /// - **Structure** needs a tree to read. Without one it is dropped, unless this machine
    ///   already has a profile, in which case it shows that one read-only.
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
    /// **Back reaches Welcome from Locations on a first run**, which is the opposite of the form
    /// this replaces. There, Back into Welcome would have offered *Not now* as a way out of a form
    /// whose answers were already written; here nothing is written until Structure's Save, so
    /// stepping back to the introduction costs nothing and refusing it would be the odd choice. On
    /// a re-run Welcome is not in the flow at all, so Locations has no Back.
    /// - Parameter welcomeIsInThisRun: whether the welcome card is part of the run in progress.
    ///   **It is a property of the run, not of the Mac**, which is the correction here: the rule
    ///   used to be `hasCompletedSetup || hasProfile`, so on any Mac that had set up once, Back
    ///   from Locations returned nil — including on a run that had *opened* on the welcome card and
    ///   walked forward from it, where the user could see the card they had just left and had no
    ///   way back to it.
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
    /// **A re-run does not get the welcome screen.** It introduces the app and counts out questions
    /// for somebody who has never seen any of this; somebody returning from Help ▸ Set Up
    /// SyncCloud… is not being introduced to anything. The test is the same one the auto-show gate
    /// asks, so both read the same two facts rather than inventing a third.
    static func initialScreen(hasCompletedSetup: Bool, hasFilingProfile: Bool) -> Screen {
        hasCompletedSetup || hasFilingProfile ? .locations : .welcome
    }

    /// Whether this screen opens with the caret already in its first field.
    ///
    /// **You alone.** It is the only screen whose first control is a text field, and a form that
    /// opens with nothing focused asks you to click before you can type. Everywhere else a claimed
    /// caret would be a caret with nowhere to go.
    ///
    /// A rule rather than a `case` inside the view: `SetupSheet` cannot be constructed in a test,
    /// so the version of this that lived in `onAppear` only ever fired on the path that opens on a
    /// question screen, and never on a first launch that reaches one by a screen change.
    static func wantsFirstFieldFocus(_ screen: Screen) -> Bool {
        screen == .you
    }

    // MARK: - The show gate

    /// Whether the form opens itself on launch.
    ///
    /// Three inputs, and the last two are what keep an existing install from being interrupted by a
    /// screen it has no use for:
    ///
    /// - `hasCompletedSetup` — the form's own flag. Once through, never again unprompted.
    /// - `hasSeenLegacyWelcome` — the retired tour's flag (`hasSeenFirstRunWelcome`), still on disk
    ///   for every machine that ever ran a build before this one. It reads as “this user has been
    ///   greeted”, so they get the form from Help rather than in their face.
    /// - `hasFilingProfile` — a machine that already has a surveyed tree has answered the form's
    ///   most expensive question by other means. Setup has things to offer it, but not unprompted.
    ///
    /// **The gate is deliberately generous about refusing.** A form that opens over somebody's
    /// working app is a far worse failure than one they have to find in the Help menu, and the Help
    /// entry is unconditional.
    static func shouldAutoShow(hasCompletedSetup: Bool,
                               hasSeenLegacyWelcome: Bool,
                               hasFilingProfile: Bool) -> Bool {
        !hasCompletedSetup && !hasSeenLegacyWelcome && !hasFilingProfile
    }

    // MARK: - Welcome copy

    /// What the app is, in one sentence, on the card that opens the sheet.
    ///
    /// **It names the four workspaces the panels below it draw**, and it says the two things a
    /// person deciding whether to continue actually needs: the folders stay where they are, and
    /// every change can be undone.
    static let welcomeBlurb =
        "Browse, compare, organize and edit the cloud folders already on this Mac: iCloud Drive, "
        + "Google Drive, OneDrive, Dropbox. Your folders stay where they are, and every change is "
        + "one ⌘Z."

    /// The heading over the numbered list of what the sheet will ask.
    ///
    /// **It counts the questions, so it is derived from them** — an earlier draft said "four short
    /// questions" and kept saying it after a step folded away.
    ///
    /// **It does not say how long any of this takes, by decision.** A version of this sentence
    /// promised "about two minutes" over a flow with a tree walk and an optional hours-long read
    /// in it. The reading offer's own "About 3 h for N documents" is a different claim — it is
    /// about work the user is choosing, measured from a real count — and it stays.
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

    /// What follows the five questions — said on the welcome card, because the shape of this sheet
    /// is the thing that changed: it learns first and then shows what it found.
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
    /// **Order is a claim, not a layout choice.** Browse leads because Browse is where a fresh
    /// install opens; `theWelcomeStripOpensWhereTheAppDoes` pins that against
    /// `WorkspaceSelection.default` so the two cannot part the way the retired tour's did.
    ///
    /// Edit is here because it ships. The three-panel version of this strip was written before the
    /// editor landed and went on describing an app with three workspaces in it — the same way the
    /// tour it replaced went on calling Duplicates a workspace for a release.
    ///
    /// Blurbs describe shipping behaviour and must keep doing so —
    /// `noPanelCallsARetiredWorkspaceAWorkspace` is derived from
    /// ``Workspace/retiredWorkspaceRawValues``, because prose written before a workspace folds into
    /// an Organize lens keeps calling it a workspace and nothing else here would notice.
    static let panels: [Panel] = [
        Panel(art: .browse, title: "Browse", blurb: "One tree, full width."),
        Panel(art: .compare, title: "Compare", blurb: "Two folders side by side."),
        Panel(art: .filing, title: "Organize", blurb: "Loose files, duplicates, renames."),
        Panel(art: .edit, title: "Edit", blurb: "Text and Markdown, in place."),
    ]

    /// A row of the numbered list on the welcome screen.
    struct OutlineRow: Equatable, Sendable {
        let screen: Screen
        let detail: String
    }

    /// What the sheet is going to ask, said before it asks — so *Get started* is a decision rather
    /// than a leap. Derived from ``Screen`` so a numbered screen added without a line here fails
    /// `theWelcomeOutlineNamesEveryQuestionTheSheetAsks` rather than going unannounced.
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
    /// **Pure, because the interesting half is a refusal.** When `people.json` cannot be read — or
    /// had to have a duplicated id collapsed — the list the form showed is a seed from folder
    /// names, and `PeopleStore.save()` will not write over the file. A summary that counted it
    /// anyway would make a claim about the user's family out of directory listings, on the screen
    /// whose heading is "You're all set".
    static func peopleSummary(otherCount: Int, rosterIsReadOnly: Bool) -> String {
        let others = "\(otherCount) other\(otherCount == 1 ? "" : "s")"
        if rosterIsReadOnly {
            return "\(others) listed, but people.json could not be read — fix it in Settings ▸ People"
        }
        return otherCount == 0 ? "Nobody else on the list yet" : "\(others) on the list"
    }

    /// What Structure and Summary say about a walk that ran but is not in use.
    ///
    /// The store refuses to re-point away from a profile SyncCloud did not write, so on a machine
    /// with a hand-built one the walk succeeds, lands on disk, and changes nothing the user will
    /// notice. Saying so is the difference between "done" and "done, and it changed nothing".
    static let walkNotInUse =
        "This Mac already has a folder profile SyncCloud did not write, so that one is still in "
        + "use. What was just learned is saved beside it and unused."

    /// What Summary says about the answers that have nowhere to land yet.
    ///
    /// **On a machine with no folder profile there is no `people.json` to write into**, so the You
    /// and People answers sit in `setup-draft.json` until a walk mints one. Summary says what is
    /// already in effect, and for those two rows on that machine it is not — the answers are kept,
    /// and they start working when SyncCloud has learned a tree.
    /// Saying so is the difference between a promise and a lie about the most common case there is.
    static let heldUntilSurveyed = "kept, and applied once SyncCloud learns a folder tree"

    /// The one-line privacy claim, said on the welcome screen and echoed in the footer of every
    /// step.
    ///
    /// **Checked rather than asserted**, and it is checked in three places: the walk and the
    /// document read are `FileManager`, PDFKit and Vision; on-device suggestions go through
    /// `SystemLanguageModel.default`, Apple's on-device model rather than a server endpoint; the
    /// roster is `people.json` beside the profile. The single exception is Organize's opt-in Refine
    /// pass, which is off unless the user turns it on and is named on the survey step rather than
    /// left for them to find — see ``surveyPrivacyNote`` and ``surveyThirdPartyNote``.
    static let privacyClaim =
        "All of this happens on this Mac. SyncCloud reads your files locally and keeps what it "
        + "learns in your own Library folder. Nothing is uploaded, and there is no account to create."

    /// The four-word reminder carried in the footer of every screen once the claim above has been
    /// made properly.
    static let privacyFooter = "Stays on this Mac"

    /// The screen the privacy disclosure is made on.
    ///
    /// **A named constant with one call site, because this has already been wrong once.** The two
    /// notes below are the app's whole promise about reading the user's documents, plus its one
    /// exception. They belong in front of the control that does the reading — the *Learn* button —
    /// and while the folder step was folded into Done they moved there with it. The step came back
    /// in `e52076eb` and the notes did not, so for two commits the disclosure was made on the screen
    /// *after* the walk had already run, which is not a disclosure.
    ///
    /// `theDisclosureIsDrawnOnTheStepThatAsksForIt` pins the constant AND the call site: a rule
    /// extracted for testability is one revert from being unused.
    static let disclosureScreen: Screen = .learn

    /// The local half of the Learn screen's disclosure — stated where the user authorises reading
    /// their documents, which is the only screen that asks for that.
    ///
    /// **Drawn verbatim, never paraphrased.** A revision of the redesign shortened it and lost the
    /// subject of its own sentence along with four of the five tokens
    /// `theSurveyDisclosureNamesItsOneException` requires; the shortened version also removed the
    /// form's only "Settings ▸" and took a second test with it.
    static let surveyPrivacyNote =
        "Your documents are read on this Mac and never leave it. SyncCloud keeps what it learns in "
        + "your own Library folder — not the files, not the text, not the folder names."

    /// The exception, named on the same screen **even though setup cannot enable it**.
    ///
    /// A promise stated without its exception reads as complete, and the user meets the Refine
    /// button a week later. Four lines here are what make the rest of the claim believable.
    static let surveyThirdPartyNote =
        "One thing can reach a third party, and setup does not turn it on: Organize's optional "
        + "Refine pass asks Claude — Anthropic's service, on an API key you supply. It never runs "
        + "on its own, and it is off unless you turn it on in Settings ▸ Intelligence."

    // MARK: - The You screen's pre-fill

    /// What the You screen offers before the user types anything.
    ///
    /// **Two sources, and neither is trusted on its own.** The Mac account name is a real name in
    /// the overwhelming case and something like `admin` in the rest; a folder in the learned tree
    /// whose name matches its first word is corroboration, and it is what lets the screen say
    /// *"your Mac account says X, and Documents has a folder named X"* rather than asserting.
    ///
    /// Split at the **first** space, so a three-part name keeps everything after the first word as
    /// the surname — the forms are built from the two halves, and "Maria del Carmen Ruiz" splits
    /// better that way than by taking the last word.
    ///
    /// Pure, and here rather than in the view, because `SetupSheet` cannot be built in a test and
    /// this is the first `NSFullUserName()` call in the repo.
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
    /// **Order matters, so surname-first is its own form** rather than a re-ordering of the same
    /// one: an Indian bank statement prints `Girish Abhishek` and a US one prints
    /// `Abhishek Girish`, and the matcher is positional.
    ///
    /// Initials are offered and **not** ticked: `A. Girish` matches a great many people, and a form
    /// the user ticks is one the router will act on. An accented name is offered in both spellings
    /// because forms and scanners routinely drop the accent, and the user is the only one who knows
    /// which their documents carry.
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

        // The same forms without their accents, when that is a different string. Not a
        // transliteration: `folding` drops diacritics and leaves the letters, which is exactly what
        // a form printed by a system that cannot carry them does.
        for (form, ticked) in forms {
            let folded = form.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            if folded != form { add(folded, ticked) }
        }
        return forms.map { (form: $0.0, ticked: $0.1) }
    }
}
