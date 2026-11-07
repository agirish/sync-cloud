import Foundation
import Settings
import Testing
@testable import SyncCloud

/// The setup form's decision logic and the claims its copy makes.
///
/// Nobody who works on the app ever sees this sheet: it renders once per install, on a machine that
/// has never run SyncCloud, so its copy drifts silently. The tests that look like they test prose
/// are guarding that.
@Suite struct SetupFlowTests {

    // MARK: - Persisted keys

    /// Renaming any of these changes what an existing install looks like to the app. The legacy
    /// `hasSeenFirstRunWelcome` is the sharp edge: `shouldAutoShow` reads it as "already greeted",
    /// so renaming it would open the form over every older install's working app.
    @Test func defaultsKeysAreStable() {
        #expect(SetupFlow.hasCompletedDefaultsKey == "hasCompletedSetup")
        #expect(SetupFlow.legacyWelcomeSeenDefaultsKey == "hasSeenFirstRunWelcome")
        #expect(SetupFlow.primarySourceDefaultsKey == "setupPrimarySourceId")
    }

    // MARK: - The show gate

    /// The only combination that opens the form by itself: nothing completed, nobody greeted, no
    /// profile.
    @Test func theFormOpensItselfOnlyOnAnUntouchedMachine() {
        #expect(SetupFlow.shouldAutoShow(hasCompletedSetup: false,
                                         hasSeenLegacyWelcome: false,
                                         hasFilingProfile: false))
    }

    /// Every other combination refuses. All eight are enumerated, because a `||` written the wrong
    /// way round still passes a spot check.
    @Test func everyOtherCombinationRefuses() {
        for completed in [true, false] {
            for greeted in [true, false] {
                for profile in [true, false] {
                    let expected = !completed && !greeted && !profile
                    #expect(SetupFlow.shouldAutoShow(hasCompletedSetup: completed,
                                                     hasSeenLegacyWelcome: greeted,
                                                     hasFilingProfile: profile) == expected,
                            "completed=\(completed) greeted=\(greeted) profile=\(profile)")
                }
            }
        }
    }

    /// Each input can refuse on its own: with the other two clear, any single flag closes the gate.
    /// The control for the table above, which a rule refusing only on two of three could pass.
    @Test func eachFlagClosesTheGateByItself() {
        #expect(!SetupFlow.shouldAutoShow(hasCompletedSetup: true,
                                          hasSeenLegacyWelcome: false, hasFilingProfile: false))
        #expect(!SetupFlow.shouldAutoShow(hasCompletedSetup: false,
                                          hasSeenLegacyWelcome: true, hasFilingProfile: false))
        #expect(!SetupFlow.shouldAutoShow(hasCompletedSetup: false,
                                          hasSeenLegacyWelcome: false, hasFilingProfile: true))
    }

    // MARK: - Where it opens

    /// A machine that has never been set up gets the introduction.
    @Test func aFirstRunOpensOnTheWelcomeScreen() {
        #expect(SetupFlow.initialScreen(hasCompletedSetup: false, hasFilingProfile: false) == .welcome)
    }
    /// Everything else opens on the first question: the welcome screen is for somebody who has
    /// never seen the app, not somebody back through Help ▸ Set Up SyncCloud… to change an answer.
    @Test func aReRunOpensOnTheFirstQuestion() {
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: false) == .locations)
        #expect(SetupFlow.initialScreen(hasCompletedSetup: false, hasFilingProfile: true) == .locations)
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: true) == .locations)
    }

    /// `shouldAutoShow` (whether the sheet appears) and `initialScreen` (what it opens on) read the
    /// same facts, so a machine the gate would greet is exactly the one that gets the greeting.
    @Test func theOpeningScreenAgreesWithTheShowGate() {
        for completed in [true, false] {
            for profile in [true, false] {
                let greeted = SetupFlow.shouldAutoShow(hasCompletedSetup: completed,
                                                       hasSeenLegacyWelcome: false,
                                                       hasFilingProfile: profile)
                let opensOnWelcome = SetupFlow.initialScreen(hasCompletedSetup: completed,
                                                             hasFilingProfile: profile) == .welcome
                #expect(greeted == opensOnWelcome,
                        "completed=\(completed) profile=\(profile): the gate and the opening screen disagree")
            }
        }
    }

    // MARK: - Movement

    @Test func theWelcomeScreenLeadsIntoTheFirstQuestion() {
        #expect(SetupFlow.next(after: .welcome) == .locations)
    }

    /// Back reaches Welcome when the run includes it. Nothing is written until Structure's Save, so
    /// stepping back to the introduction costs nothing.
    ///
    /// Whether it is reachable is a property of the run, not the Mac: a run that opened on the
    /// welcome card must be able to go back to it, even on a Mac that has been set up or has a
    /// profile. Asking for setup by name opens on that card whatever the Mac has done before.
    @Test func backReachesWelcomeWhenTheRunIncludesIt() {
        #expect(SetupFlow.previous(before: .welcome, welcomeIsInThisRun: true) == nil,
                "there is nothing before the first screen")
        #expect(SetupFlow.previous(before: .locations, welcomeIsInThisRun: true) == .welcome)

        // The automatic re-presentation on a Mac that is already set up: it opens on Locations, so
        // there is no card behind it.
        #expect(SetupFlow.previous(before: .locations, welcomeIsInThisRun: false) == nil)
        #expect(SetupFlow.previous(before: .locations, hasProfile: true,
                                   welcomeIsInThisRun: false) == nil)

        // A profile on disk does not by itself put the card out of reach — only the run does.
        #expect(SetupFlow.previous(before: .locations, hasProfile: true,
                                   welcomeIsInThisRun: true) == .welcome,
                "an explicit re-run on a Mac with a profile still opened on Welcome")
    }

    /// Forward from Welcome reaches every screen, in order, and stops.
    @Test func nextWalksEveryScreenAndStops() {
        var visited: [SetupFlow.Screen] = []
        var screen: SetupFlow.Screen? = .welcome
        while let current = screen {
            visited.append(current)
            screen = SetupFlow.next(after: current)
            #expect(visited.count <= SetupFlow.Screen.allCases.count + 1,
                    "next(after:) does not terminate")
        }
        #expect(visited == SetupFlow.Screen.allCases)
        #expect(SetupFlow.next(after: .summary) == nil)
    }

    /// Back retraces exactly the path forward took.
    @Test func previousIsTheInverseOfNext() throws {
        for screen in SetupFlow.Screen.allCases.dropFirst() {
            let back = try #require(SetupFlow.previous(before: screen, welcomeIsInThisRun: true))
            #expect(SetupFlow.next(after: back) == screen)
        }
    }

    // MARK: - What the walk drops

    /// Skipping Learn drops the two screens that need a walk, without renumbering: Locations through
    /// People keep 1 to 4, so no screen changes number between two visits to the same sheet.
    @Test func skippingLearnDropsCountriesAndStructure() {
        let crumbs = SetupFlow.crumbs(walk: .skipped, hasProfile: false)
        #expect(!crumbs.contains(.countries))
        #expect(!crumbs.contains(.structure))
        #expect(crumbs.prefix(4) == [.locations, .learn, .you, .people])
        #expect(crumbs.compactMap(\.number) == [1, 2, 3, 4], "the numbers moved")
        #expect(SetupFlow.next(after: .people, walk: .skipped, hasProfile: false) == .workspaces)
    }

    /// A machine that already has a profile keeps Structure when Learn is skipped: there is
    /// something to show, read-only.
    @Test func aSkippedLearnKeepsStructureWhenAProfileExists() {
        #expect(SetupFlow.includes(.structure, walk: .skipped, hasProfile: true))
        #expect(!SetupFlow.includes(.structure, walk: .skipped, hasProfile: false))
        #expect(SetupFlow.next(after: .people, walk: .skipped, hasProfile: true) == .structure)
    }

    /// A failed walk is not a skipped one: Countries stays, since it explains the failure, and only
    /// Structure, which needs a tree, drops out.
    @Test func aFailedWalkKeepsCountriesAndDropsStructure() {
        #expect(SetupFlow.includes(.countries, walk: .failed, hasProfile: false))
        #expect(!SetupFlow.includes(.structure, walk: .failed, hasProfile: false))
        #expect(SetupFlow.next(after: .countries, walk: .failed, hasProfile: false) == .workspaces)
    }

    /// A walk that ran and found nothing still asks about countries: the free-text field is the
    /// whole question in that case.
    @Test func aWalkThatFoundNothingStillAsksAboutCountries() {
        #expect(SetupFlow.includes(.countries, walk: .learned, hasProfile: false))
    }

    /// Nothing is dropped while the walk is still running — Continue never waits.
    @Test func aRunningWalkDropsNothing() {
        #expect(SetupFlow.crumbs(walk: .pending, hasProfile: false) == SetupFlow.crumbs)
    }

    // MARK: - Numbering and labels

    /// Five screens ask a question and carry a number; the rest confirm, show or offer.
    @Test func onlyTheQuestionScreensAreNumbered() {
        let numbered = SetupFlow.Screen.allCases.filter { $0.number != nil }
        #expect(numbered == [.locations, .learn, .you, .people, .countries])
        #expect(numbered.compactMap(\.number) == [1, 2, 3, 4, 5])
        #expect(SetupFlow.questionCount == numbered.count)
    }

    /// The crumb strip is everything between the introduction and the summary — neither of which
    /// is a place to navigate back to.
    @Test func theCrumbsAreEveryScreenBetweenWelcomeAndSummary() {
        #expect(!SetupFlow.crumbs.contains(.welcome))
        #expect(!SetupFlow.crumbs.contains(.summary))
        #expect(SetupFlow.crumbs.count == SetupFlow.Screen.allCases.count - 2)
    }

    /// Four screens can be skipped. Locations and Countries are right if left alone, so a Skip
    /// there would be a second Continue; Structure is the screen that writes.
    @Test func theSkippableScreensAreTheOnesWithSomethingToRefuse() {
        let skippable = SetupFlow.Screen.allCases.filter(\.isSkippable)
        #expect(skippable == [.learn, .you, .people, .appearance])
        #expect(!SetupFlow.Screen.structure.isSkippable)
        #expect(!SetupFlow.Screen.locations.isSkippable)
    }

    @Test func everyScreenHasItsOwnName() {
        for screen in SetupFlow.Screen.allCases {
            #expect(!screen.displayName.isEmpty)
        }
        #expect(Set(SetupFlow.Screen.allCases.map(\.displayName)).count
                == SetupFlow.Screen.allCases.count)
    }

    // MARK: - Focus

    /// The caret goes to You's first field, including on a first launch, which opens on the welcome
    /// card and reaches You by a screen change long after `onAppear` has fired. A rule that only ran
    /// in `onAppear` would miss exactly the machine this sheet exists for.
    @Test func onlyTheYouScreenClaimsTheCaret() {
        #expect(SetupFlow.wantsFirstFieldFocus(.you))
        #expect(!SetupFlow.wantsFirstFieldFocus(.welcome))
        for screen in SetupFlow.Screen.allCases where screen != .you {
            #expect(!SetupFlow.wantsFirstFieldFocus(screen),
                    "\(screen.displayName) claims the caret, and its first control is not a text field")
        }
    }

    /// The first-run route reaches the focused screen by a screen change, which an `onAppear`-only
    /// rule can't see.
    @Test func aFirstRunReachesTheFocusedScreenByAScreenChange() throws {
        let opening = SetupFlow.initialScreen(hasCompletedSetup: false, hasFilingProfile: false)
        #expect(!SetupFlow.wantsFirstFieldFocus(opening),
                "a first run now opens on the focused screen, so an `onAppear` claim would suffice")
        var screen = opening
        var hops = 0
        while !SetupFlow.wantsFirstFieldFocus(screen), let next = SetupFlow.next(after: screen) {
            screen = next
            hops += 1
        }
        #expect(SetupFlow.wantsFirstFieldFocus(screen))
        #expect(hops > 0, "the caret screen is reached without a screen change")
    }

    // MARK: - The name rules

    /// The pre-fill splits at the FIRST space, so everything after the first word is the surname.
    @Test func theNameSplitsAtTheFirstSpace() {
        let split = SetupFlow.suggestedName(fullUserName: "Maria del Carmen Ruiz", folderNames: [])
        #expect(split.first == "Maria")
        #expect(split.surname == "del Carmen Ruiz")
    }

    /// A one-word account name has no surname, and the forms are that one word.
    @Test func aOneWordAccountNameHasNoSurname() {
        let split = SetupFlow.suggestedName(fullUserName: "Abhishek", folderNames: [])
        #expect(split.first == "Abhishek")
        #expect(split.surname == nil)
        #expect(SetupFlow.nameForms(first: "Abhishek", surname: nil).map(\.form) == ["Abhishek"])
    }

    /// The folder match is corroboration and is case-insensitive; without one the screen says so
    /// rather than inventing it.
    @Test func theFolderMatchIsEvidenceNotAnAssertion() {
        let matched = SetupFlow.suggestedName(fullUserName: "Abhishek Girish",
                                              folderNames: ["Finance", "abhishek", "Family"])
        #expect(matched.matchedFolder == "abhishek")
        let unmatched = SetupFlow.suggestedName(fullUserName: "Abhishek Girish",
                                                folderNames: ["Finance", "Family"])
        #expect(unmatched.matchedFolder == nil)
    }

    /// Surname-first is its own form, because the matcher is positional and statements print either
    /// order. Initials are offered but not ticked: `A. Girish` matches a great many people.
    @Test func bothNameOrdersAreTickedAndInitialsAreNot() {
        let forms = SetupFlow.nameForms(first: "Abhishek", surname: "Girish")
        let ticked = forms.filter(\.ticked).map(\.form)
        #expect(ticked == ["Abhishek Girish", "Girish Abhishek"])
        #expect(forms.map(\.form).contains("A. Girish"))
        #expect(forms.first { $0.form == "A. Girish" }?.ticked == false)
        #expect(forms.first { $0.form == "Girish A." }?.ticked == false)
    }

    /// An accented name is offered in both spellings, because forms and scanners routinely drop
    /// the accent and only the user knows which their documents carry.
    @Test func anAccentedNameIsOfferedInBothSpellings() {
        let forms = SetupFlow.nameForms(first: "José", surname: "Álvarez").map(\.form)
        #expect(forms.contains("José Álvarez"))
        #expect(forms.contains("Jose Alvarez"))
        #expect(Set(forms).count == forms.count, "a form is offered twice")
    }

    /// An empty name has no forms at all — a bare surname is not a name any document prints.
    @Test func anEmptyFirstNameHasNoForms() {
        #expect(SetupFlow.nameForms(first: "", surname: "Girish").isEmpty)
        #expect(SetupFlow.nameForms(first: "   ", surname: nil).isEmpty)
    }

    // MARK: - The welcome copy

    /// The welcome screen says what the sheet is going to ask before it asks it — for every screen
    /// that asks something.
    ///
    /// Derived from `Screen.number`, so a numbered screen added without a line fails instead of
    /// going unannounced. Screens that show rather than ask are left out on purpose.
    @Test func theWelcomeOutlineNamesEveryQuestionTheSheetAsks() {
        let announced = Set(SetupFlow.outline.map(\.screen))
        let asking = Set(SetupFlow.Screen.allCases.filter { $0.number != nil })
        #expect(announced == asking, "the outline and the questions have parted")
        #expect(!announced.contains(.summary), "Summary reports; it does not ask")
        for row in SetupFlow.outline {
            #expect(!row.detail.isEmpty)
        }
    }

    /// The heading over that list counts it, in words.
    @Test func theWelcomeHeadingCountsTheQuestionsItLists() {
        #expect(SetupFlow.welcomeQuestionsHeading.hasPrefix("Five "))
        #expect(SetupFlow.questionCount == 5)
        #expect(SetupFlow.spelled(SetupFlow.questionCount) == "Five")
    }

    /// Setup never says how long it takes: the flow holds a tree walk and an optional hours-long
    /// read. The reading offer's own figure, measured from a real count, is a different claim and
    /// isn't made here.
    @Test func noWelcomeCopyEstimatesHowLongSetupTakes() {
        let copy = [SetupFlow.welcomeBlurb, SetupFlow.welcomeQuestionsHeading,
                    SetupFlow.welcomeAfterQuestions, SetupFlow.privacyClaim,
                    SetupFlow.runAgainNote].joined(separator: " ").lowercased()
        for duration in ["minute", "seconds", "a few hours", " h ", "quick"] {
            #expect(!copy.contains(duration),
                    "the welcome copy estimates a duration again: \(duration)")
        }
    }

    /// Nor does Help's page about it. "A few hours" isn't banned here: the page says the optional
    /// document reading runs "over a few hours", the reading offer's own claim.
    @Test func helpsSetupPageEstimatesNoDurationEither() throws {
        let topic = try #require(HelpBook.sections.flatMap(\.topics).first { $0.id == "setup" })
        let copy = ([topic.article.intro] + topic.article.blocks.map(\.searchableText))
            .joined(separator: " ").lowercased()
        for duration in ["minute", "seconds", " h ", "quick"] {
            #expect(!copy.contains(duration),
                    "Help's Setup page estimates a duration again: \(duration)")
        }
    }

    /// Four panels, one per shipping workspace, Edit included.
    @Test func everyPanelHasCopyAndItsOwnIllustration() {
        #expect(SetupFlow.panels.count == 4)
        for panel in SetupFlow.panels {
            #expect(!panel.title.isEmpty)
            #expect(!panel.blurb.isEmpty)
        }
        let arts = SetupFlow.panels.map(\.art)
        #expect(Set(arts).count == arts.count, "two panels share an illustration")
        #expect(SetupFlow.panels.map(\.title).contains("Edit"))
    }

    /// Setup says Edit opens PDFs, on both its Edit lines: the welcome strip's panel and the
    /// Workspaces screen's card. Dropping "PDFs" from either must fail its check.
    @Test func setupsEditLinesNamePDFs() throws {
        let panel = try #require(SetupFlow.panels.first { $0.art == .edit })
        #expect(panel.blurb.contains("PDFs"), "the welcome strip's Edit panel leaves out PDFs: \(panel.blurb)")
        let card = try #require(WorkspacesScreen.plainWorkspaces.first { $0.workspace == .editor })
        #expect(card.blurb.contains("PDFs"), "the Workspaces screen's Edit card leaves out PDFs: \(card.blurb)")
    }

    /// The strip opens on the workspace the app opens on, so the user lands somewhere they were
    /// shown. Pinned against `WorkspaceSelection.default`, so moving the default fails here.
    @Test func theWelcomeStripOpensWhereTheAppDoes() throws {
        #expect(WorkspaceSelection.default.workspace == .browse,
                "if the default workspace moves, the leading panel should move with it")
        let leading = try #require(SetupFlow.panels.first)
        #expect(leading.art == .browse)
        #expect(leading.title == "Browse")
    }

    /// No panel may describe a retired workspace as a workspace. Derived from
    /// `Workspace.retiredWorkspaceRawValues`, because each time a workspace folds into an Organize
    /// lens, prose written before the fold keeps calling it a workspace.
    @Test func noPanelCallsARetiredWorkspaceAWorkspace() {
        for retired in Workspace.retiredWorkspaceRawValues.keys {
            for panel in SetupFlow.panels {
                #expect(!panel.blurb.localizedCaseInsensitiveContains("\(retired) workspace"),
                        "“\(panel.title)” calls \(retired) a workspace — it is an Organize lens")
                #expect(!panel.title.localizedCaseInsensitiveContains("\(retired) workspace"),
                        "“\(panel.title)” calls \(retired) a workspace — it is an Organize lens")
            }
        }
        for row in SetupFlow.outline {
            for retired in Workspace.retiredWorkspaceRawValues.keys {
                #expect(!row.detail.localizedCaseInsensitiveContains("\(retired) workspace"))
            }
        }
    }

    /// The positive control for the scan above, which asserts an absence and would pass on an empty
    /// table, empty copy or a matcher that never matches. This proves all three are live.
    @Test func theRetiredWorkspaceScanCanActuallyFail() {
        #expect(!Workspace.retiredWorkspaceRawValues.isEmpty)
        #expect(!SetupFlow.panels.isEmpty)
        let offender = "The Duplicates workspace finds duplicate files."
        let caught = Workspace.retiredWorkspaceRawValues.keys.contains {
            offender.localizedCaseInsensitiveContains("\($0) workspace")
        }
        #expect(caught, "the matcher no longer catches the phrasing this test exists to ban")
    }

    // MARK: - What the summary may claim

    /// The Done step reports a household, not a guess. `PeopleStore.save()` won't write over a
    /// `people.json` it couldn't read or whose duplicated id it collapsed, so in both states nothing
    /// the user did to the list was saved. Under a heading saying "everything below is already in
    /// effect", a plain count would be false.
    @Test func theSummaryWillNotCountAHouseholdItCouldNotRead() {
        let honest = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: false)
        #expect(honest == "6 others on the list")

        let refused = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: true)
        #expect(refused.contains("could not be read"))
        #expect(refused.contains("Settings ▸ Organize, under People"), "it has to say where to fix it")
        #expect(refused != honest)

        // A roster read perfectly well, with one id twice, is not called unreadable.
        let repeated = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: true,
                                               rosterRepeatsAnId: true)
        #expect(!repeated.contains("could not be read"), "a readable roster was called unreadable")
        #expect(repeated.contains("lists someone twice") && repeated.contains("Settings ▸ Organize, under People"))
    }

    @Test func theSummaryCountsInSingularAndPlural() {
        #expect(SetupFlow.peopleSummary(otherCount: 0, rosterIsReadOnly: false)
                == "Nobody else on the list yet")
        #expect(SetupFlow.peopleSummary(otherCount: 1, rosterIsReadOnly: false)
                == "1 other on the list")
    }

    // MARK: - Retired vocabulary

    /// The form's copy may not use retired product words: "filing" (now Organize's To File lens) and
    /// "tidy". The Help book has the same guard.
    ///
    /// Scanned over the source, since most of the copy is inline in the screen bodies. Only string
    /// literals count, and `Logger` lines are exempt: the log names artifacts as the code does
    /// (`filing profile`, `filing-memory.json`).
    @Test func noSetupCopyUsesRetiredVocabulary() throws {
        // Every screen file, each with a known sentence as its canary, so "the extractor works" is
        // a claim about this copy rather than a count a broken extractor could still satisfy.
        let canaries = ["MacApp/SetupSheet.swift": "Set up SyncCloud",
                        "MacApp/SetupFlow.swift": "Stays on this Mac",
                        "MacApp/Setup/SetupChrome.swift": "More options",
                        "MacApp/Setup/WelcomeScreen.swift": "Welcome to SyncCloud",
                        "MacApp/Setup/LocationsScreen.swift": "Switch off any you don’t use.",
                        "MacApp/Setup/LearnScreen.swift": "Which folder should SyncCloud learn from?",
                        "MacApp/Setup/YouScreen.swift": "Is this you?",
                        "MacApp/Setup/PeopleScreen.swift": "Who else is in your folders?",
                        "MacApp/Setup/CountriesScreen.swift": "Which of these are countries?",
                        "MacApp/Setup/StructureScreen.swift": "Here is how you file",
                        "MacApp/Setup/SetupTreeView.swift": "would go here",
                        "MacApp/Setup/WorkspacesScreen.swift": "What you can do now",
                        "MacApp/Setup/AppearanceScreen.swift": "Make it yours",
                        "MacApp/Setup/SummaryScreen.swift": "You’re all set"]
        for (file, canary) in canaries {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(file)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                      "cannot read \(file) — this scan would be vacuous")
            try #require(source.count > 500, "\(file) is implausibly short")

            let literals = Self.userFacingLiterals(in: source)
            #expect(literals.contains(canary),
                    "\(file): the extractor did not find “\(canary)”, so this scan is not reading the copy")

            for word in ["tidy", "filing"] {
                let offenders = literals.filter { $0.localizedCaseInsensitiveContains(word) }
                #expect(offenders.isEmpty,
                        "\(file) still says “\(word)” to the user: \(offenders.prefix(3))")
            }
        }
    }

    /// The positive control: the extractor returns copy, and the matcher catches the banned word in
    /// it. Without this, an extractor returning nothing would pass the scan above on any screen.
    @Test func theVocabularyScanCanActuallyFail() {
        let sample = [
            "        let a = \"Organize sorts loose files\"",
            "        // filing is fine in a comment",
            "        let b = \"your filing conventions\"",
            "        Logger.shared.info(\"no filing profile yet\")",
        ].joined(separator: "\n")

        let literals = Self.userFacingLiterals(in: sample)
        #expect(literals.contains { $0.localizedCaseInsensitiveContains("filing") },
                "the extractor did not find the offending literal")
        #expect(!literals.contains { $0.contains("is fine in a comment") },
                "the extractor is reading comments as copy")
        #expect(!literals.contains { $0.contains("no filing profile yet") },
                "Logger lines should be exempt from the product-vocabulary rule")
    }

    /// Every "Settings ▸ X" the form prints names a tab that really exists. A tab's label can change
    /// while its case keeps its name, so this is derived from `SettingsTab.displayName` and the next
    /// relabel fails here rather than shipping.
    @Test func everySettingsPathInTheFormNamesARealTab() throws {
        let realNames = Set(SettingsView.SettingsTab.allCases.map(\.displayName))
        var found = 0

        // Every file the sheet is made of: the host alone sends the user nowhere, and the screens
        // hold the live "Settings ▸ …" pointers.
        var files = ["MacApp/SetupSheet.swift", "MacApp/SetupFlow.swift"]
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent("MacApp/Setup")
        let screens = try #require(try? FileManager.default.contentsOfDirectory(atPath: directory.path))
            .filter { $0.hasSuffix(".swift") }
        try #require(screens.count >= 10,
                     "the setup directory holds \(screens.count) files — this scan is looking at the wrong place")
        files += screens.map { "MacApp/Setup/\($0)" }

        for file in files {
            let url = repo.appendingPathComponent(file)
            let source = try #require(try? String(contentsOf: url, encoding: .utf8))
            for literal in Self.userFacingLiterals(in: source) {
                for named in Self.settingsDestinations(in: literal) {
                    found += 1
                    #expect(realNames.contains(named),
                            "\(file) sends the user to Settings ▸ \(named), which is not a tab. Real tabs: \(realNames.sorted())")
                }
            }
        }

        #expect(found > 0, "no “Settings ▸ …” references were found in the form — this scan is vacuous")
    }

    /// The tab names in every "Settings ▸ X" in a string. Stops at the first character that is
    /// neither a letter nor a space and keeps only the leading capitalised words, so "Settings ▸
    /// People — a first name is enough" yields `People`.
    private static func settingsDestinations(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let marker = rest.range(of: "Settings ▸ ") {
            let tail = rest[marker.upperBound...]
            let run = tail.prefix { $0.isLetter || $0 == " " }
            var name: [String] = []
            for word in run.split(separator: " ").map(String.init) {
                guard let first = word.first, first.isUppercase else { break }
                name.append(word)
            }
            if !name.isEmpty { out.append(name.joined(separator: " ")) }
            rest = tail
        }
        return out
    }

    /// String literals on lines that are neither comments nor `Logger` calls. Line-based on
    /// purpose: each half of a `+`-joined literal is checked alone, which suffices for a word ban.
    /// Single-word literals are dropped, being mostly symbol names, SF Symbol ids and defaults keys.
    private static func userFacingLiterals(in source: String) -> [String] {
        var out: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.contains("Logger.shared") else { continue }
            var inside = false
            var current = ""
            var escaped = false
            for character in line {
                if escaped {
                    if inside { current.append(character) }
                    escaped = false
                    continue
                }
                if character == "\\" { escaped = true; continue }
                if character == "\"" {
                    if inside { out.append(current); current = "" }
                    inside.toggle()
                    continue
                }
                if inside { current.append(character) }
            }
        }
        return out.filter { $0.contains(" ") }
    }

    // MARK: - The privacy claim

    /// The exception is named on the same screen that makes the promise. They are two strings that
    /// could drift apart in one edit, and a promise without its exception reads as complete, so the
    /// note must keep naming Claude, saying it is off, and saying where it lives.
    @Test func theSurveyDisclosureNamesItsOneException() {
        #expect(SetupFlow.surveyPrivacyNote.contains("never leave it"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Claude"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Anthropic"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("never runs on its own"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Settings ▸ Organize"),
                "the exception has to say where it can be turned on")
    }

    /// The disclosure is made on the screen that asks for it, and is drawn from that rule. A promise
    /// about reading somebody's files, made on a screen after the reading, is no promise, and tests
    /// of the strings alone can't see where they are drawn.
    ///
    /// So four things are pinned: the constant, the gate that reads it, the order against the
    /// button, and each note being drawn exactly once.
    @Test func theDisclosureIsDrawnOnTheScreenThatAsksForIt() throws {
        #expect(SetupFlow.disclosureScreen == .learn,
                "the disclosure is made on \(SetupFlow.disclosureScreen.displayName), which is not the screen that reads the user's files")
        #expect(SetupFlow.disclosureScreen != .summary,
                "Summary comes after the walk — a notice there discloses nothing")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Setup/LearnScreen.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read LearnScreen.swift — the checks below would be vacuous")
        try #require(source.count > 500, "LearnScreen.swift is implausibly short")

        // Drawn through the rule, not at a location somebody has to remember.
        #expect(source.contains("if SetupFlow.disclosureScreen == .learn {"),
                "the notes are no longer gated on `disclosureScreen` — moving the constant would move nothing")
        // And above the button: it lives in the footer, drawn after the content, so the notes must
        // be the last thing in the content column.
        let gate = try #require(source.range(of: "if SetupFlow.disclosureScreen == .learn {"))
        let closing = try #require(source.range(of: "SetupFlow.surveyThirdPartyNote"))
        #expect(gate.lowerBound < closing.lowerBound)
        let after = String(source[closing.upperBound...])
        #expect(!after.contains("Button("),
                "a control is drawn after the disclosure — the notice has to be the last thing before the footer")
        // And exactly once each, so no second copy can sit on another screen.
        for note in ["SetupFlow.surveyPrivacyNote", "SetupFlow.surveyThirdPartyNote"] {
            #expect(source.components(separatedBy: note).count - 1 == 1,
                    "\(note) is drawn \(source.components(separatedBy: note).count - 1) times — one of them is on the wrong screen")
        }
        // The button the notice is about, on the screen it is about.
        let host = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let hostSource = try #require(try? String(contentsOf: host, encoding: .utf8))
        #expect(hostSource.contains("primary: model.learnPrimaryTitle"),
                "Learn's primary button no longer reads the walk state")
    }

    /// The setup buttons call the model's rules, which `SetupModelTests` pins one by one.
    /// `SetupSheet` can't be built in a test, so without this the rule tests would stay green over a
    /// button that went back to doing its own thing.
    @Test func theSetupButtonsCallTheRulesTheModelTests() throws {
        let setup = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        func source(_ path: String) throws -> String {
            let text = try #require(try? String(contentsOf: setup.appendingPathComponent(path), encoding: .utf8),
                                    "cannot read \(path) — the checks below would be vacuous")
            try #require(text.count > 1_000, "\(path) is implausibly short")
            return text
        }
        let sheet = try source("SetupSheet.swift")
        // Learn: Continue over a reading keeps it; Learn Again is the secondary.
        #expect(sheet.contains("primaryAction: { model.pressLearnPrimary() }"),
                "Learn's primary no longer goes through `pressLearnPrimary` — Continue may re-read")
        #expect(sheet.contains("secondary: model.learnAgainTitle.map"),
                "Learn Again is no longer offered as the secondary button")
        #expect(sheet.contains("model.pressLearnAgain()"))
        // Structure: a failed write stays put.
        #expect(sheet.contains("Task { await model.pressStructurePrimary(shownSkipSaving: shownSkipSaving) }"),
                "Structure's primary no longer goes through `pressStructurePrimary`")
        // What the button said is captured as it is drawn, from the title it drew.
        #expect(sheet.contains("let primary = model.structurePrimaryTitle\n            frame(primary: primary,"),
                "Structure's button draws one title and the press reads another")
        #expect(sheet.contains("{ [shownSkipSaving = primary == SetupModel.skipSavingTitle] in"),
                "a Skip Saving press is decided when the Task runs, not when the button was drawn")
        #expect(!sheet.contains("primaryAction: model.canWriteProfile"),
                "Structure's primary decides for itself again, past the model's rule")
        #expect(!sheet.contains("await model.save()"),
                "Structure calls `save()` directly again, and will move on whatever it answers")
        // A failed Save offers a way on that writes nothing.
        #expect(sheet.contains("secondary: model.structureSecondaryTitle.map"),
                "Structure no longer offers Continue Without Saving after a failed Save")
        #expect(sheet.contains("model.continueWithoutSaving()"))
        // And the failure is drawn where the press stays, with the two ways on.
        let structure = try source("Setup/StructureScreen.swift")
        // A reading still running is said in the tree's box, not "Nothing has been learned yet".
        #expect(structure.contains("} else if model.structureShowsWalkStatus {"),
                "Structure no longer says it is reading, or that the reading failed")
        // And draws nothing that explains or counts a tree it does not have.
        #expect(structure.contains("let counts = Self.counts(model)"),
                "Structure's stats row counts past `counts(_:)` — zeros or old counts while it reads")
        #expect(structure.contains(".disabled(!model.structureReadingSwitchIsEnabled)"),
                "the reading switch is live past `structureReadingSwitchIsEnabled`")
        #expect(structure.components(separatedBy: "} else if !model.structureShowsWalkStatus {").count - 1 == 2,
                "Structure draws its lens or its grey-words legend over a reading it does not have")
        #expect(structure.contains("private var profile: FolderProfile? { model.structureShownProfile }"),
                "Structure draws a tree past `structureShownProfile` — an old one while a reading runs")
        #expect(structure.contains("if let failure = model.saveFailure"),
                "Structure no longer draws a failed Save")
        #expect(structure.contains("Text(failure + \" \" + Self.saveFailedNextStep)"),
                "the failure line no longer says what to do next")
        // Closing (Esc, ✕, a click outside, Not Now) keeps the open screen's answers.
        #expect(sheet.contains("model.commitBeforeClosing()\n        onDismiss()"),
                "closing no longer commits the open screen before it closes")
        #expect(sheet.contains(".onTapGesture { close() }"), "a click outside skips the commit")
        #expect(sheet.contains("onDismiss: { close() },"), "Esc and ✕ skip the commit")
        #expect(!sheet.contains("onDismiss: onDismiss"), "the chrome is handed the bare dismiss again")
        // And every teardown without a close: a panel ranking above setup, the window closing
        // (both hosted in `SetupSheetTeardownTests`), and quitting, which that suite must not post.
        #expect(sheet.contains(".onDisappear { model.commitBeforeClosing() }"),
                "taking the sheet down no longer commits the open screen")
        #expect(sheet.contains("NSApplication.willTerminateNotification)) { _ in\n            model.commitBeforeClosing()"),
                "quitting with setup open no longer commits the open screen")
        // Summary: Learn goes back to the Learn screen, not out to a Settings tab.
        #expect(try source("Setup/SummaryScreen.swift").contains("action: { model.returnToLearn() }"),
                "Summary's Learn no longer goes back to the Learn screen")
        // People: a chip's ✕ asks about a roster person; only the question's Remove removes.
        let people = try source("Setup/PeopleScreen.swift")
        #expect(people.contains("? nil : { model.requestRemovePerson(named: $0) })"),
                "People's ✕ no longer goes through `requestRemovePerson` — a roster person may go unasked")
        // …and none is drawn on a roster this sheet cannot write.
        #expect(people.contains("onRemove: model.rosterIsReadOnly\n                              ? nil :"),
                "People draws a ✕ on a read-only roster — the chip goes and the person comes back")
        #expect(people.contains("rosterRepeatsAnId: model.rosterRepeatsAnId"),
                "People's read-only note no longer says which refusal it is")
        #expect(people.components(separatedBy: "model.removePerson(").count - 1 == 1,
                "People calls `removePerson` somewhere besides the question's Remove button")
        #expect(people.contains("if let name = model.personAwaitingRemoval { model.removePerson(named: name) }"),
                "the question's Remove no longer removes the person it asked about")
    }

    /// Countries says "ticked" only when it ticked something. Short names found but none certain
    /// enough to tick arrive unticked, and the line invites the picking.
    @Test func countriesClaimsTicksOnlyWhenItTickedSome() throws {
        #expect(CountriesScreen.foundBlurb(candidates: 3, confident: 2).contains("ticked"))
        let unsure = CountriesScreen.foundBlurb(candidates: 3, confident: 0)
        #expect(!unsure.contains("ticked"), "nothing was ticked, yet the line says so: \(unsure)")
        #expect(unsure.contains("Tick the ones"))
        #expect(CountriesScreen.foundBlurb(candidates: 0, confident: 0).hasPrefix("No short folder names"))
    }

    /// People tells "found names, all added" from "found none", so taking the last chip doesn't say
    /// no names were found.
    @Test func peopleTellsAllAddedFromNoneFound() throws {
        #expect(PeopleScreen.foundBlurb(found: 4, offered: 2).contains("found some names to offer"))
        let allAdded = PeopleScreen.foundBlurb(found: 4, offered: 0)
        #expect(!allAdded.contains("No folder names"), "every name was added, yet the line says none was found")
        #expect(allAdded.hasPrefix("Everyone SyncCloud found is added"))
        #expect(PeopleScreen.foundBlurb(found: 0, offered: 0).hasPrefix("No folder names looked like people"))

        // Both screens route their finished reading through these rules.
        let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Setup")
        let people = try String(contentsOf: setup.appendingPathComponent("PeopleScreen.swift"), encoding: .utf8)
        #expect(people.contains("return Self.foundBlurb(found: model.walkState.walk?.people.count ?? 0,"))
        let countries = try String(contentsOf: setup.appendingPathComponent("CountriesScreen.swift"), encoding: .utf8)
        #expect(countries.contains("confident: model.countryCandidates.filter(JurisdictionCandidates.isConfident).count)"))
    }

    /// Summary no longer talks about the folder walk as work that has not shipped.
    @Test func summaryDoesNotDescribeTheWalkAsUnshipped() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Setup/SummaryScreen.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        for stale in ["Learning your folders comes next", "when it lands",
                      "not in this build yet"] {
            #expect(!source.contains(stale),
                    "the sheet still says “\(stale)” about a screen it now has")
        }
        // The positive control: the sweep can see this file's copy at all.
        #expect(source.contains("You have not learned a folder tree yet"),
                "the replacement copy is not there — every check above is vacuous")
    }

    /// The Help topic counts the same screens the sheet has. Prose doesn't fail to compile, and the
    /// article's counts of screens and questions are facts about `SetupFlow`.
    @Test func theHelpTopicCountsTheScreensTheSheetHas() throws {
        let topic = try #require(HelpBook.topic(id: "setup"), "the setup Help topic is gone")
        let prose = ([topic.article.intro] + topic.article.blocks.map(\.searchableText))
            .joined(separator: " ")
        #expect(prose.contains("\(SetupFlow.spelled(SetupFlow.questionCount).lowercased()) short questions")
                || prose.contains("\(SetupFlow.questionCount) short questions"),
                "the topic does not say how many questions setup asks, or says a different number")
        #expect(prose.localizedCaseInsensitiveContains("ten screens"),
                "the topic no longer says how many screens there are")
        #expect(SetupFlow.Screen.allCases.count == 10,
                "the sheet has \(SetupFlow.Screen.allCases.count) screens and the Help topic says ten")
        // Each numbered screen is named in the topic, so a question added without a line there
        // fails here rather than going undocumented.
        for screen in SetupFlow.Screen.allCases where screen.number != nil {
            #expect(prose.localizedCaseInsensitiveContains(screen.displayName),
                    "the Help topic never names the \(screen.displayName) screen")
        }
    }

    /// `hasWhyPanel` says what the sheet draws. The rule sets the width every fit test lays a screen
    /// out at, while the sheet's own `switch` decides whether a panel is there; if they part, screens
    /// are measured at a width the card never gives them.
    @Test func theWhyPanelRuleMatchesWhatTheSheetDraws() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        // Anchored without the access level, so changing `screenCard`'s visibility doesn't break
        // the scan.
        let body = try #require(source.range(of: "var screenCard: some View {"),
                                "the sheet's screen switch has moved — this scan would be vacuous")
        let switchBody = String(source[body.upperBound...])

        for screen in SetupFlow.Screen.allCases {
            let label = "        case .\(screen.rawValue):"
            let caseStart = try #require(switchBody.range(of: label),
                                         "the sheet has no case for \(screen.displayName)")
            let rest = String(switchBody[caseStart.upperBound...])
            // Up to the next case, or the end of the switch.
            let arm = rest.range(of: "\n        case .").map { String(rest[..<$0.lowerBound]) } ?? rest
            let drawsPanel = arm.contains("why: {")
            #expect(drawsPanel == screen.hasWhyPanel,
                    "\(screen.displayName) says hasWhyPanel == \(screen.hasWhyPanel) and the sheet draws \(drawsPanel ? "one" : "none")")
        }
    }

    /// The plain claim promises nothing the app does not do. It sits on the welcome screen, with no
    /// room for the exception, so it must not be an absolute the Refine pass contradicts: it is
    /// about the files SyncCloud reads, and the survey step names the third party.
    @Test func theWelcomeClaimIsAboutWhatSyncCloudItselfDoes() {
        #expect(SetupFlow.privacyClaim.contains("on this Mac"))
        #expect(!SetupFlow.privacyClaim.localizedCaseInsensitiveContains("never"),
                "an absolute belongs on the survey step, next to its exception")
        #expect(SetupFlow.privacyFooter == "Stays on this Mac")
    }
}
