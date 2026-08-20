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

    /// Everything else opens on the rail.
    ///
    /// **The welcome screen is addressed to somebody who has never seen the app** — it promises
    /// “four short questions, then SyncCloud learns your folders”. Showing that to somebody who
    /// came back through Help ▸ Set Up SyncCloud… to change one answer describes neither what they
    /// did nor what they are about to do.
    @Test func aReRunOpensOnTheRail() {
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: false) == .step(.you))
        #expect(SetupFlow.initialScreen(hasCompletedSetup: false, hasFilingProfile: true) == .step(.you))
        #expect(SetupFlow.initialScreen(hasCompletedSetup: true, hasFilingProfile: true) == .step(.you))
    }

    /// The two rules read the same facts.
    ///
    /// `shouldAutoShow` decides whether the form appears; `initialScreen` decides what it opens on.
    /// Both are asking “has this machine been through this?”, so a machine the gate would greet is
    /// exactly the machine that gets the greeting — and any machine it refuses, if it is opened by
    /// hand, does not.
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
        #expect(honest == "6 others in your household")

        let refused = SetupFlow.peopleSummary(otherCount: 6, rosterIsReadOnly: true)
        #expect(refused.contains("could not be read"))
        #expect(refused.contains("Settings ▸ People"), "it has to say where to fix it")
        #expect(refused != honest)
    }

    @Test func theSummaryCountsInSingularAndPlural() {
        #expect(SetupFlow.peopleSummary(otherCount: 0, rosterIsReadOnly: false)
                == "Nobody else on the list yet")
        #expect(SetupFlow.peopleSummary(otherCount: 1, rosterIsReadOnly: false)
                == "1 other in your household")
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
        let canaries = ["MacApp/SetupSheet.swift": "Who are you?",
                        "MacApp/SetupFlow.swift": "Stays on this Mac"]
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

        for file in ["MacApp/SetupSheet.swift", "MacApp/SetupFlow.swift"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(file)
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
    @Test func theWelcomeClaimIsAboutWhatSyncCloudItselfDoes() {
        #expect(SetupFlow.privacyClaim.contains("on this Mac"))
        #expect(!SetupFlow.privacyClaim.localizedCaseInsensitiveContains("never"),
                "an absolute belongs on the survey step, next to its exception")
        #expect(SetupFlow.privacyFooter == "Stays on this Mac")
    }
}
