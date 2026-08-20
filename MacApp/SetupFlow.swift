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

    /// The source whose tree SyncCloud learns from — the one Step 4 will survey.
    ///
    /// **Held here rather than in `SettingsManager` for as long as nothing but setup reads it.**
    /// The survey is what gives it meaning, and the survey is a later stage; a key promoted into
    /// the Settings module before then would be a published property that answers a question no
    /// caller asks. Stage B moves it to where `FolderSurveyBuilder`'s caller can see it.
    static let primarySourceDefaultsKey = "setupPrimarySourceId"

    // MARK: - The screens

    /// A step of the form, in rail order. Welcome is deliberately not a case — see ``Screen``.
    enum Step: String, CaseIterable, Sendable {
        /// Your name and the forms of it documents print, plus the four preferences with no wrong
        /// answer.
        case you
        /// Which discovered sources to use, and which one is primary.
        case sources
        /// The household the filing rules attribute documents to.
        case people
        /// How much of each source to learn. Inert until the survey stage lands.
        case survey
        /// The summary, and what is running.
        case done

        var displayName: String {
            switch self {
            case .you: return "You"
            case .sources: return "Sources"
            case .people: return "People"
            case .survey: return "Survey"
            case .done: return "Done"
            }
        }

        /// The rail row's SF Symbol. Outline weight throughout, the same rule the Settings rail
        /// follows: a rail of mixed filled and outline glyphs reads as though the filled ones meant
        /// something.
        var symbolName: String {
            switch self {
            case .you: return "person"
            case .sources: return "cloud"
            case .people: return "person.2"
            case .survey: return "folder.badge.gearshape"
            case .done: return "checkmark.circle"
            }
        }

        /// 1-based position, for “Step 2 of 5”.
        var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    }

    /// What the sheet is showing. Welcome precedes the rail rather than joining it, because it is
    /// not a step the user can come back to: on the re-run the form opens on the rail with every
    /// step showing current state (there is nothing to welcome anyone to), and a rail row that
    /// vanished on the second visit would be worse than one that was never there.
    enum Screen: Equatable, Sendable {
        case welcome
        case step(Step)
    }

    /// The screen after this one, or nil at the end.
    static func next(after screen: Screen) -> Screen? {
        switch screen {
        case .welcome:
            return .step(.you)
        case .step(let step):
            guard let index = Step.allCases.firstIndex(of: step),
                  index + 1 < Step.allCases.count else { return nil }
            return .step(Step.allCases[index + 1])
        }
    }

    /// The screen before this one, or nil at the start.
    ///
    /// **Welcome is not reachable by Back**, which is why `.step(.you)` answers nil rather than
    /// `.welcome`: stepping back into it from the first step would offer *Not now* as a way out of
    /// a form the user has already begun filling in, and the answers behind it are already written.
    static func previous(before screen: Screen) -> Screen? {
        switch screen {
        case .welcome:
            return nil
        case .step(let step):
            guard let index = Step.allCases.firstIndex(of: step), index > 0 else { return nil }
            return .step(Step.allCases[index - 1])
        }
    }

    /// Where the form opens.
    ///
    /// **A re-run does not get the welcome screen.** It introduces the app and promises “four short
    /// questions, then SyncCloud learns your folders” — a sentence addressed to somebody who has
    /// never seen any of this. Somebody returning from Help ▸ Set Up SyncCloud… is not being
    /// introduced to anything; for them the rail is a menu of things to change, which is why the
    /// steps are a rail and not a wizard in the first place.
    ///
    /// The test is the same one the auto-show gate asks — has this machine been through it, by the
    /// form or by other means — so both read the same two facts rather than inventing a third.
    static func initialScreen(hasCompletedSetup: Bool, hasFilingProfile: Bool) -> Screen {
        hasCompletedSetup || hasFilingProfile ? .step(.you) : .welcome
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

    /// One of the three panels on the welcome screen: what SyncCloud does, in a strip.
    struct Panel: Equatable, Sendable {
        let art: SetupArt.Art
        let title: String
        let blurb: String
    }

    /// The tour's six pages, folded to three panels.
    ///
    /// **Order is a claim, not a layout choice.** Browse leads because Browse is where a fresh
    /// install opens; `theWelcomeStripOpensWhereTheAppDoes` pins that against
    /// `WorkspaceSelection.default` so the two cannot part the way the tour's did.
    ///
    /// Blurbs describe shipping behaviour and must keep doing so —
    /// `noPanelCallsARetiredWorkspaceAWorkspace` is derived from
    /// ``Workspace/retiredWorkspaceRawValues``, because prose written before a workspace folds into
    /// an Organize lens keeps calling it a workspace and nothing else here would notice.
    static let panels: [Panel] = [
        Panel(art: .browse,
              title: "Browse",
              blurb: "One tree at full width, in columns or as an outline."),
        Panel(art: .compare,
              title: "Compare",
              blurb: "Two folders side by side. Copy either way, undo with ⌘Z."),
        Panel(art: .filing,
              title: "Organize",
              blurb: "Files loose documents, finds duplicates, proposes better names."),
    ]

    /// A row of the “setting up asks for” list on the welcome screen.
    struct OutlineRow: Equatable, Sendable {
        let step: Step
        let detail: String
    }

    /// What the form is going to ask, said before it asks — so *Set up SyncCloud* is a decision
    /// rather than a leap. Derived from ``Step`` so a step added without a line here fails
    /// `theWelcomeOutlineNamesEveryStepTheFormHas` rather than going unannounced.
    static let outline: [OutlineRow] = [
        OutlineRow(step: .you, detail: "Your name, and the forms of it documents print"),
        OutlineRow(step: .sources, detail: "The places SyncCloud found on this Mac"),
        OutlineRow(step: .people, detail: "Anyone else your documents are filed for"),
        OutlineRow(step: .survey, detail: "How much of each source to learn"),
    ]

    /// What the Done step says about the household.
    ///
    /// **Pure, because the interesting half is a refusal.** When `people.json` cannot be read — or
    /// had to have a duplicated id collapsed — the list the form showed is a seed from folder
    /// names, and `PeopleStore.save()` will not write over the file. A summary that counted it
    /// anyway would make a claim about the user's family out of directory listings, on the screen
    /// whose heading is "everything below is already in effect".
    static func peopleSummary(otherCount: Int, rosterIsReadOnly: Bool) -> String {
        let others = "\(otherCount) other\(otherCount == 1 ? "" : "s")"
        if rosterIsReadOnly {
            return "\(others) listed, but people.json could not be read — fix it in Settings ▸ People"
        }
        return otherCount == 0 ? "Nobody else on the list yet" : "\(others) in your household"
    }

    /// What the Done step says about the answers that have nowhere to land yet.
    ///
    /// **On a machine with no folder profile there is no `people.json` to write into**, so the You
    /// and People answers sit in `setup-draft.json` until a survey mints one. The Done step's
    /// heading is "everything below is already in effect", and for those two rows on that machine
    /// it is not — the answers are kept, and they start working when SyncCloud has learned a tree.
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

    /// The four-word reminder carried in the footer of every step once the claim above has been
    /// made properly.
    static let privacyFooter = "Stays on this Mac"

    /// The local half of the survey step's disclosure — stated where the user authorises reading
    /// their documents, which is the only screen that asks for that.
    static let surveyPrivacyNote =
        "Your documents are read on this Mac and never leave it. SyncCloud opens each file locally, "
        + "keeps a few hundred characters of text to learn from, and writes the result into your own "
        + "Library folder. Nothing is uploaded — not the files, not the text, not the folder names."

    /// The exception, named on the same screen **even though setup cannot enable it**.
    ///
    /// A promise stated without its exception reads as complete, and the user meets the Refine
    /// button a week later. Four lines here are what make the rest of the claim believable.
    static let surveyThirdPartyNote =
        "One thing can reach a third party, and setup does not turn it on. Organize has an optional "
        + "Refine button that asks Claude — Anthropic's service, billed to an API key you supply — "
        + "about a scan's results. It never runs on its own, you see a cost estimate first, and it "
        + "sends folder and file names plus a short excerpt only for files whose name says nothing. "
        + "Off unless you turn it on in Settings ▸ Intelligence."
}
