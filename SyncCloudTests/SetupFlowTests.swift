import Foundation
import Settings
import Testing
@testable import SyncCloud

/// The setup form's decision logic and the claims its copy makes.
///
/// **This screen is the one nobody who works on the app ever sees.** It renders once per install on
/// a machine that has never run SyncCloud, so it drifts silently while every other surface gets
/// looked at daily — the tour it replaces spent an entire release calling Duplicates a *workspace*
/// and nothing failed. Everything here that looks like it is testing prose is testing that.
@Suite struct SetupFlowTests {

    // MARK: - Persisted keys

    /// Renaming any of these changes what an existing install looks like to the app.
    ///
    /// The legacy one is the sharp edge: every machine that ran a build before the form carries
    /// `hasSeenFirstRunWelcome`, and `shouldAutoShow` reads it as “already greeted”. Rename it and
    /// every one of those users looks like a fresh install, so the form opens over their working
    /// app on the next launch.
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

    /// Every other combination refuses — and each for its own reason, which is why this enumerates
    /// all eight rather than spot-checking three.
    ///
    /// A single `||` written the wrong way round still passes a spot check; it fails here.
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

    /// Each input can refuse on its own.
    ///
    /// The positive control for the table above: with the other two clear, flipping any single flag
    /// must be enough to close the gate. A rule that only refused on *two* of the three would still
    /// satisfy a test that never varied them one at a time.
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
    /// Everything else opens on the first question.
    ///
    /// **The welcome screen is addressed to somebody who has never seen the app.** Showing it to
    /// somebody who came back through Help ▸ Set Up SyncCloud… to change one answer describes
    /// neither what they did nor what they are about to do.
    @Test func aReRunOpensOnTheFirstQuestion() {
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: false) == .locations)
        #expect(SetupFlow.initialScreen(hasCompletedSetup: false, hasFilingProfile: true) == .locations)
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: true) == .locations)
    }

    /// The two rules read the same facts.
    ///
    /// `shouldAutoShow` decides whether the sheet appears; `initialScreen` decides what it opens
    /// on. Both are asking "has this machine been through this?", so a machine the gate would greet
    /// is exactly the machine that gets the greeting.
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

    /// **Back reaches Welcome when the run includes it, and this is the reversal.** The form this
    /// replaces refused, because by its first step the user's answers were already written and a
    /// Back into Welcome would have offered *Not now* as a way out of a form in progress. Here
    /// nothing is written until Structure's Save, so stepping back to the introduction costs
    /// nothing.
    ///
    /// **And whether it is reachable is a property of the RUN, not of the Mac** — the correction
    /// this test carries. The rule was `hasCompletedSetup || hasProfile`, which is a fact about the
    /// machine, so on any Mac that had set up once Back returned nil from Locations — including on
    /// a run that had *opened* on the welcome card and walked forward from it, where the user could
    /// see the card they had just left and had no way back to it. Asking for setup by name opens on
    /// that card whatever the Mac has done before.
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

    /// **Skipping Learn drops the two screens that need a walk, and drops them rather than
    /// renumbering.** Locations through People keep 1 to 4, so there is no gap to explain and no
    /// screen that changes number between two visits to the same sheet.
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

    /// **A failed walk is not a skipped one.** The user asked for a walk and did not get one, so
    /// Countries stays — it is where the failure is explained — and only Structure, which needs a
    /// tree to read, drops out.
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

    /// **Four screens can be skipped, and the others cannot for a reason.** Locations and Countries
    /// are already right if left alone, so a Skip there would be a second spelling of Continue;
    /// Structure is the screen that writes.
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

    /// The caret goes to You's first field — **including on the path a first launch takes.**
    ///
    /// The rule lived as a `case` inside `onAppear`, which fires once, before the first layout. A
    /// re-run opens straight on a question and got the caret; a FIRST run opens on the welcome card
    /// and reaches You by a screen change, long after `onAppear` — so the machine this whole sheet
    /// exists for was the one machine whose first field never took focus.
    @Test func onlyTheYouScreenClaimsTheCaret() {
        #expect(SetupFlow.wantsFirstFieldFocus(.you))
        #expect(!SetupFlow.wantsFirstFieldFocus(.welcome))
        for screen in SetupFlow.Screen.allCases where screen != .you {
            #expect(!SetupFlow.wantsFirstFieldFocus(screen),
                    "\(screen.displayName) claims the caret, and its first control is not a text field")
        }
    }

    /// The first-run route reaches the focused screen by a screen CHANGE, which is the fact the
    /// broken version could not see.
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

    /// **Order matters, so surname-first is its own form** — the matcher is positional, and an
    /// Indian bank statement prints one order while a US one prints the other. Initials are offered
    /// and not ticked: `A. Girish` matches a great many people.
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
    /// Derived from `Screen.number` rather than counting to five, so a numbered screen added
    /// without a line here fails instead of going unannounced. The screens that show rather than
    /// ask are the deliberate exception: promising them up front would be promising a screen rather
    /// than a question.
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

    /// **Setup never says how long it takes.** An earlier draft promised "about two minutes" over
    /// a flow with a tree walk and an optional hours-long read in it. The reading offer's own
    /// figure is a different claim — it is about work the user is choosing, measured from a real
    /// count — and it is not made here.
    @Test func noWelcomeCopyEstimatesHowLongSetupTakes() {
        let copy = [SetupFlow.welcomeBlurb, SetupFlow.welcomeQuestionsHeading,
                    SetupFlow.welcomeAfterQuestions, SetupFlow.privacyClaim,
                    SetupFlow.runAgainNote].joined(separator: " ").lowercased()
        for duration in ["minute", "seconds", "a few hours", " h ", "quick"] {
            #expect(!copy.contains(duration),
                    "the welcome copy estimates a duration again: \(duration)")
        }
    }

    /// Four panels, one per shipping workspace.
    ///
    /// **Edit is the one that was missing**, and its absence is exactly the defect this test now
    /// catches: the three-panel strip was written before the editor shipped and went on describing
    /// an app with three workspaces in it.
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

    /// The strip opens on the workspace the app opens on.
    ///
    /// Inherited from the tour, where it was a real defect: the pages taught Compare, Transfer,
    /// Duplicates and Organize and then dismissed the user into Browse, which they had never been
    /// shown. Pinned against `WorkspaceSelection.default` rather than against the string "Browse",
    /// so moving the default workspace fails here instead of silently making the strip wrong again.
    @Test func theWelcomeStripOpensWhereTheAppDoes() throws {
        #expect(WorkspaceSelection.default.workspace == .browse,
                "if the default workspace moves, the leading panel should move with it")
        let leading = try #require(SetupFlow.panels.first)
        #expect(leading.art == .browse)
        #expect(leading.title == "Browse")
    }

    /// No panel may describe a retired workspace as a workspace.
    ///
    /// Derived from `Workspace.retiredWorkspaceRawValues` rather than spelling out today's
    /// offenders, because the failure is structural: every time a workspace folds into an Organize
    /// lens, prose written before the fold keeps calling it a workspace. That is exactly what
    /// happened to “The Duplicates workspace finds duplicate files”, which shipped for the whole of
    /// the v3 line on a screen nobody was ever going to look at.
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

    /// The positive control for the scan above.
    ///
    /// That test asserts an ABSENCE across a derived list, so it passes just as happily if the
    /// table is empty, the copy is empty, or the matcher never matches anything. This proves all
    /// three are live.
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

    /// The Done step reports a household, not a guess.
    ///
    /// **The refusal is the point.** `PeopleStore.save()` will not write over a `people.json` it
    /// could not read, nor over one whose duplicated id it had to collapse — so in both states the
    /// list the form showed is a seed from folder names and nothing the user did to it was saved.
    /// The heading above this line says "everything below is already in effect", which makes a
    /// plain count the one thing it must not print.
    @Test func theSummaryWillNotCountAHouseholdItCouldNotRead() {
        let honest = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: false)
        #expect(honest == "6 others on the list")

        let refused = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: true)
        #expect(refused.contains("could not be read"))
        #expect(refused.contains("Settings ▸ People"), "it has to say where to fix it")
        #expect(refused != honest)
    }

    @Test func theSummaryCountsInSingularAndPlural() {
        #expect(SetupFlow.peopleSummary(otherCount: 0, rosterIsReadOnly: false)
                == "Nobody else on the list yet")
        #expect(SetupFlow.peopleSummary(otherCount: 1, rosterIsReadOnly: false)
                == "1 other on the list")
    }

    // MARK: - Retired vocabulary

    /// The form's copy may not use product words that were retired.
    ///
    /// **The Help book has had this guard for a while, and it caught the first draft of this very
    /// screen.** “Filing” became Organize's To File lens and “tidy” left the product's voice with
    /// it; both survived in Help long after every other surface was reworded, because nothing
    /// looked — and setup is the surface *least* likely to be looked at, since it renders once per
    /// install on a machine nobody developing the app is using.
    ///
    /// Scanned over the source rather than over a list of constants because most of this screen's
    /// copy is written inline in the step bodies, where a constant-only check would see none of it.
    /// Only string literals count, so a comment explaining the retired word is not a violation, and
    /// `Logger` lines are exempt: the log names the artifacts by what the code calls them
    /// (`filing profile`, `filing-memory.json`), and renaming those in a log would make it harder
    /// to read rather than easier.
    @Test func noSetupCopyUsesRetiredVocabulary() throws {
        // A known sentence from each file, so "the extractor works" is a claim about *this* copy
        // rather than a count that a broken extractor could still satisfy on a big enough file.
        // **Every screen file, each with its own canary.** The sheet used to be one file; a scan
        // that still named only that one would pass over nine screens of unchecked copy, which is
        // exactly the shape of the defect this rule exists to catch.
        let canaries = ["MacApp/SetupSheet.swift": "Set up SyncCloud",
                        "MacApp/SetupFlow.swift": "Stays on this Mac",
                        "MacApp/Setup/SetupChrome.swift": "More options",
                        "MacApp/Setup/WelcomeScreen.swift": "Welcome to SyncCloud",
                        "MacApp/Setup/LocationsScreen.swift": "Switch off any you don't use.",
                        "MacApp/Setup/LearnScreen.swift": "Which folder should SyncCloud learn from?",
                        "MacApp/Setup/YouScreen.swift": "Is this you?",
                        "MacApp/Setup/PeopleScreen.swift": "Who else is in your folders?",
                        "MacApp/Setup/CountriesScreen.swift": "Which of these are countries?",
                        "MacApp/Setup/StructureScreen.swift": "Here is how you file",
                        "MacApp/Setup/SetupTreeView.swift": "would go here",
                        "MacApp/Setup/WorkspacesScreen.swift": "What you can do now",
                        "MacApp/Setup/AppearanceScreen.swift": "Make it yours",
                        "MacApp/Setup/SummaryScreen.swift": "You're all set"]
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

    /// The positive control: the extractor really returns copy, and the matcher really catches the
    /// banned word in it.
    ///
    /// Without this, an extractor that returned nothing — or a `contains` that never matched —
    /// would let the scan above pass on a screen full of retired vocabulary.
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

    /// Every "Settings ▸ X" the form prints names a tab that really exists.
    ///
    /// **The same drift the Help book was carrying, on a surface with even less traffic.** The
    /// Providers tab was relabelled *Sources* when it started listing plain folders beside the
    /// cloud accounts, the case kept its name so stored state and deep links survived — correctly —
    /// and two Help articles went on naming a tab that is not on screen. The form points at four
    /// tabs, and it is read once per install.
    ///
    /// Derived from `SettingsTab.displayName`, so the next relabel fails here rather than shipping.
    @Test func everySettingsPathInTheFormNamesARealTab() throws {
        let realNames = Set(SettingsView.SettingsTab.allCases.map(\.displayName))
        var found = 0

        // **Every file the sheet is made of.** Naming two of them was right when the sheet was
        // one file; after the split it would have scanned the host — which sends the user nowhere
        // — and passed over ten screens of live "Settings ▸ …" pointers.
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

    /// The tab names in every "Settings ▸ X" in a string.
    ///
    /// Scanning stops at the first character that is neither a letter nor a space, and then only the
    /// leading *capitalised* words are kept — so "Settings ▸ People — a first name is enough" yields
    /// `People` rather than the rest of the sentence.
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

    /// String literals on lines that are neither comments nor `Logger` calls.
    ///
    /// Deliberately line-based and simple. It cannot see a literal split across lines by `+`
    /// concatenation as one string — each half is checked on its own, which is enough for a
    /// word-level ban — and it drops single-word literals, which are overwhelmingly symbol names,
    /// SF Symbol ids and defaults keys rather than copy.
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

    /// The exception is named on the same screen that makes the promise.
    ///
    /// **The claim and its exception are two strings and could drift apart in one edit.** A promise
    /// stated without its exception reads as complete, and the user meets the Refine button a week
    /// later — so the survey step's note has to keep naming Claude, keep saying it is off, and keep
    /// saying where it lives.
    @Test func theSurveyDisclosureNamesItsOneException() {
        #expect(SetupFlow.surveyPrivacyNote.contains("never leave it"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Claude"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Anthropic"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("never runs on its own"))
        #expect(SetupFlow.surveyThirdPartyNote.localizedCaseInsensitiveContains("Settings ▸ Intelligence"),
                "the exception has to say where it can be turned on")
    }

    /// The plain claim promises nothing the app does not do.
    ///
    /// It is stated on the welcome screen, where there is no room for the exception, so it must not
    /// be phrased as an absolute the Refine pass contradicts — “nothing is uploaded” is about the
    /// files SyncCloud reads, and the sentence that follows the user into the survey step is where
    /// the third party is named.
    /// **The disclosure is made on the screen that asks for it, and is drawn from that rule.**
    ///
    /// This was wrong for two commits and nothing failed. `89373824` folded the folder step into
    /// Done and took the two notes with it; `e52076eb` brought the step back — with the button that
    /// reads the user's documents on it — and left the notes on Done. A promise about reading
    /// somebody's files, made on the screen *after* the reading, is not a promise, and every test
    /// over this copy asserts the STRINGS, which were correct the whole time.
    ///
    /// So all four halves are pinned: the constant, the gate that reads it, the order against the
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
        // **And above the button.** The button lives in the card's footer, which is drawn after the
        // content, so what this holds is the notes being the LAST thing in the content column —
        // nothing of the screen's own may come between them and the footer.
        let gate = try #require(source.range(of: "if SetupFlow.disclosureScreen == .learn {"))
        let closing = try #require(source.range(of: "SetupFlow.surveyThirdPartyNote"))
        #expect(gate.lowerBound < closing.lowerBound)
        let after = String(source[closing.upperBound...])
        #expect(!after.contains("Button("),
                "a control is drawn after the disclosure — the notice has to be the last thing before the footer")
        // And exactly once each: a second copy is how the two screens came to disagree before.
        for note in ["SetupFlow.surveyPrivacyNote", "SetupFlow.surveyThirdPartyNote"] {
            #expect(source.components(separatedBy: note).count - 1 == 1,
                    "\(note) is drawn \(source.components(separatedBy: note).count - 1) times — one of them is on the wrong screen")
        }
        // The button the notice is about, on the screen it is about.
        let host = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let hostSource = try #require(try? String(contentsOf: host, encoding: .utf8))
        #expect(hostSource.contains("model.walkState.isDone ? \"Learn again\" : \"Learn\""),
                "Learn's primary button no longer reads the walk state")
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

    /// The Help topic counts the same screens the sheet has.
    ///
    /// **Prose does not fail to compile.** The article says how many screens setup is and how many
    /// of them ask a question; both are facts about `SetupFlow`, and both went stale in the topic
    /// this one replaces — it described four steps of a form that had five, for two releases.
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

    /// `hasWhyPanel` says what the sheet draws.
    ///
    /// **Two places decide this and only one of them is visible to a measurement.** The rule sets
    /// how wide every fit test lays a screen out; the sheet's own `switch` decides whether a panel
    /// is really there. When those parted, screens were measured against a width the card never
    /// gives them — which is how the Structure screen came to overflow the card with its fit test
    /// green.
    @Test func theWhyPanelRuleMatchesWhatTheSheetDraws() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        // Anchored without the access level: `screenCard` went from `private` to internal so the
        // screen gallery could photograph it, and this scan failed on the rename rather than on
        // anything it exists to check.
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

    @Test func theWelcomeClaimIsAboutWhatSyncCloudItselfDoes() {
        #expect(SetupFlow.privacyClaim.contains("on this Mac"))
        #expect(!SetupFlow.privacyClaim.localizedCaseInsensitiveContains("never"),
                "an absolute belongs on the survey step, next to its exception")
        #expect(SetupFlow.privacyFooter == "Stays on this Mac")
    }
}
