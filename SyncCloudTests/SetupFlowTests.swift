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

    // MARK: - Movement

    @Test func theWelcomeScreenLeadsIntoTheFirstStep() {
        #expect(SetupFlow.next(after: .welcome) == .step(.you))
    }

    /// Back never returns to the welcome screen.
    ///
    /// It offers *Not now* as its way out, and by the first step the user's answers are already
    /// written — a Back that landed there would present a way out of a form that has begun.
    @Test func backNeverReachesTheWelcomeScreen() {
        #expect(SetupFlow.previous(before: .welcome) == nil)
        #expect(SetupFlow.previous(before: .step(.you)) == nil)
        for step in SetupFlow.Step.allCases {
            #expect(SetupFlow.previous(before: .step(step)) != .welcome)
        }
    }

    /// Forward from the welcome screen reaches every step, in rail order, and stops.
    @Test func nextWalksTheWholeRailAndStops() {
        var visited: [SetupFlow.Step] = []
        var screen: SetupFlow.Screen? = .welcome
        while let current = screen {
            if case .step(let step) = current { visited.append(step) }
            screen = SetupFlow.next(after: current)
            #expect(visited.count <= SetupFlow.Step.allCases.count + 1, "next(after:) does not terminate")
        }
        #expect(visited == SetupFlow.Step.allCases)
        #expect(SetupFlow.next(after: .step(.done)) == nil)
    }

    /// Back retraces exactly the path forward took.
    @Test func previousIsTheInverseOfNext() {
        for step in SetupFlow.Step.allCases.dropFirst() {
            let back = SetupFlow.previous(before: .step(step))
            #expect(SetupFlow.next(after: try! #require(back)) == .step(step))
        }
    }

    @Test func stepNumbersAreOneBasedAndInRailOrder() {
        #expect(SetupFlow.Step.allCases.map(\.number) == Array(1...SetupFlow.Step.allCases.count))
        #expect(SetupFlow.Step.you.number == 1)
        #expect(SetupFlow.Step.done.number == SetupFlow.Step.allCases.count)
    }

    /// Every step renders a rail row, so every step needs both halves of one.
    @Test func everyStepHasALabelAndAGlyph() {
        for step in SetupFlow.Step.allCases {
            #expect(!step.displayName.isEmpty)
            #expect(!step.symbolName.isEmpty)
        }
        #expect(Set(SetupFlow.Step.allCases.map(\.displayName)).count == SetupFlow.Step.allCases.count)
        #expect(Set(SetupFlow.Step.allCases.map(\.symbolName)).count == SetupFlow.Step.allCases.count)
    }

    // MARK: - The welcome copy

    /// The welcome screen says what the form is going to ask before it asks it — for every step
    /// that asks something.
    ///
    /// Derived from `Step.allCases` rather than counting to four, so a step added without a line
    /// here fails instead of going unannounced. `done` is the deliberate exception: it reports,
    /// it does not ask, and promising it up front would be promising a screen rather than a
    /// question.
    @Test func theWelcomeOutlineNamesEveryStepThatAsksSomething() {
        let announced = Set(SetupFlow.outline.map(\.step))
        let asking = Set(SetupFlow.Step.allCases).subtracting([.done])
        #expect(announced == asking, "the outline and the steps have parted")
        #expect(!announced.contains(.done), "Done reports; it does not ask")
        for row in SetupFlow.outline {
            #expect(!row.detail.isEmpty)
        }
    }

    @Test func everyPanelHasCopyAndItsOwnIllustration() {
        #expect(SetupFlow.panels.count == 3)
        for panel in SetupFlow.panels {
            #expect(!panel.title.isEmpty)
            #expect(!panel.blurb.isEmpty)
        }
        let arts = SetupFlow.panels.map(\.art)
        #expect(Set(arts).count == arts.count, "two panels share an illustration")
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
    @Test func theWelcomeClaimIsAboutWhatSyncCloudItselfDoes() {
        #expect(SetupFlow.privacyClaim.contains("on this Mac"))
        #expect(!SetupFlow.privacyClaim.localizedCaseInsensitiveContains("never"),
                "an absolute belongs on the survey step, next to its exception")
        #expect(SetupFlow.privacyFooter == "Stays on this Mac")
    }
}
