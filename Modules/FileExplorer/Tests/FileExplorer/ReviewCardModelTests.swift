import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Coverage for the review card's pure derivation: labels, the time/size delta chip, the
/// destination-newer and folder-replace warnings, verify eligibility, and the new-item copy.
/// `@MainActor` because the size/date formatting shares the module's main-actor formatters.
@MainActor
@Suite struct ReviewCardModelTests {

    private let paneNames = PaneProviderNames(leftName: "Local", rightName: "iCloud")

    private func diff(
        type: FileDifference.DifferenceType = .differentDates,
        action: FileDifference.SyncAction = .copyToRight,
        leftSize: Int? = nil,
        rightSize: Int? = nil,
        enclosedItemCount: Int? = nil
    ) -> FileDifference {
        FileDifference(
            relativePath: "Docs/report.txt",
            leftItemPath: "/l/Docs/report.txt",
            rightItemPath: "/r/Docs/report.txt",
            type: type,
            action: action,
            description: "test",
            leftFileSize: leftSize,
            rightFileSize: rightSize,
            enclosedItemCount: enclosedItemCount
        )
    }

    private func facts(source: Date? = nil, destination: Date? = nil) -> ReviewCardModel.Facts {
        var facts = ReviewCardModel.Facts()
        facts.sourceModified = source
        facts.destinationModified = destination
        return facts
    }

    // MARK: Replace vs new

    @Test func replaceCardNamesBothSidesAndDirection() {
        let model = ReviewCardModel.make(
            difference: diff(leftSize: 2000, rightSize: 1000),
            facts: facts(), paneNames: paneNames, isMove: false)
        #expect(model.isReplace)
        #expect(model.directionText == "Local → iCloud")
        #expect(model.directionDetail == "replaces existing")
        #expect(model.sourceLabel == "Copying from Local")
        #expect(model.destinationLabel == "Replaces on iCloud")
        #expect(model.newItemText == nil)
        #expect(model.fileName == "report.txt")
        #expect(model.parentPath == "Docs")
    }

    @Test func copyToLeftSwapsTheSides() {
        let model = ReviewCardModel.make(
            difference: diff(action: .copyToLeft),
            facts: facts(), paneNames: paneNames, isMove: false)
        #expect(model.directionText == "iCloud → Local")
        #expect(model.sourceLabel == "Copying from iCloud")
        #expect(model.destinationLabel == "Replaces on Local")
    }

    @Test func missingItemGetsTheCalmCardNoComparison() {
        let model = ReviewCardModel.make(
            difference: diff(type: .missingOnRight, leftSize: 500, enclosedItemCount: 34),
            facts: facts(), paneNames: paneNames, isMove: false)
        #expect(!model.isReplace)
        #expect(model.directionDetail == "new")
        #expect(model.newItemText == "New on iCloud — nothing replaced. Includes 34 items.")
        #expect(model.destinationLabel == nil)
        #expect(model.deltaText == nil)
        #expect(model.warningText == nil)
        #expect(!model.canVerify)
    }

    @Test func moveSessionRelabelsTheVerbs() {
        let model = ReviewCardModel.make(
            difference: diff(), facts: facts(), paneNames: paneNames, isMove: true)
        #expect(model.primaryVerb == "Move")
        #expect(model.sourceLabel == "Moving from Local")
    }

    // MARK: Deltas

    @Test func deltaReportsNewerSourceAndSizeGrowth() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let model = ReviewCardModel.make(
            difference: diff(leftSize: 2_400_000, rightSize: 1_300_000),
            facts: facts(source: base.addingTimeInterval(3 * 86400), destination: base),
            paneNames: paneNames, isMove: false)
        let delta = model.deltaText ?? ""
        #expect(delta.hasPrefix("3 days newer · +"))
        #expect(!model.sourceIsOlder)
    }

    @Test func timeDeltaPicksTheCoarsestUnitAndDirection() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        #expect(ReviewCardModel.timeDeltaDescription(
            sourceModified: base.addingTimeInterval(45), destinationModified: base) == "45 seconds newer")
        #expect(ReviewCardModel.timeDeltaDescription(
            sourceModified: base, destinationModified: base.addingTimeInterval(300)) == "5 minutes older")
        #expect(ReviewCardModel.timeDeltaDescription(
            sourceModified: base.addingTimeInterval(3600), destinationModified: base) == "1 hour newer")
        #expect(ReviewCardModel.timeDeltaDescription(
            sourceModified: base.addingTimeInterval(1), destinationModified: base) == "same date")
        #expect(ReviewCardModel.timeDeltaDescription(
            sourceModified: nil, destinationModified: base) == nil)
    }

    @Test func sizeDeltaIsSignedOrSame() {
        #expect(ReviewCardModel.sizeDeltaDescription(sourceSize: 1000, destinationSize: 1000) == "same size")
        #expect(ReviewCardModel.sizeDeltaDescription(sourceSize: nil, destinationSize: 1000) == nil)
        let grew = ReviewCardModel.sizeDeltaDescription(sourceSize: 2000, destinationSize: 1000) ?? ""
        #expect(grew.hasPrefix("+"))
        let shrank = ReviewCardModel.sizeDeltaDescription(sourceSize: 1000, destinationSize: 2000) ?? ""
        #expect(shrank.hasPrefix("−"))
    }

    // MARK: Warnings

    @Test func destinationNewerRaisesTheAmberWarning() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let model = ReviewCardModel.make(
            difference: diff(),
            facts: facts(source: base, destination: base.addingTimeInterval(3600)),
            paneNames: paneNames, isMove: false)
        #expect(model.sourceIsOlder)
        #expect(model.warningText == "The iCloud copy is newer than the one you're about to copy over it.")
    }

    @Test func nearTiedDatesRaiseNoWarning() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let model = ReviewCardModel.make(
            difference: diff(),
            // Within the 2s tolerance (FAT / cloud-stamp rounding) — not "newer".
            facts: facts(source: base, destination: base.addingTimeInterval(1.5)),
            paneNames: paneNames, isMove: false)
        #expect(!model.sourceIsOlder)
        #expect(model.warningText == nil)
    }

    @Test func folderReplaceWarningWinsAndCountsContents() {
        var replaceFacts = facts(
            source: Date(timeIntervalSince1970: 0),
            destination: Date(timeIntervalSince1970: 86400))  // dest newer too — folder wins
        replaceFacts.destinationIsDirectory = true
        replaceFacts.destinationChildCount = 34
        let model = ReviewCardModel.make(
            difference: diff(), facts: replaceFacts, paneNames: paneNames, isMove: false)
        #expect(model.warningText == "Replacing this folder replaces its entire contents — 34 items on iCloud will be removed.")
    }

    @Test func cappedFolderCountReadsAsAtLeast() {
        var replaceFacts = ReviewCardModel.Facts()
        replaceFacts.destinationIsDirectory = true
        replaceFacts.destinationChildCount = 1000
        replaceFacts.destinationChildCountCapped = true
        let text = ReviewCardModel.warningText(
            difference: diff(), facts: replaceFacts, destinationName: "iCloud", isMove: false)
        #expect(text?.contains("1000+ items") == true)
    }

    // MARK: Verify eligibility

    @Test func verifyOffersOnlyForSameSizeFileReplacements() {
        // Same size, date-only difference: verifiable.
        #expect(ReviewCardModel.make(
            difference: diff(leftSize: 1000, rightSize: 1000),
            facts: facts(), paneNames: paneNames, isMove: false).canVerify)
        // Different sizes: definitionally different content.
        #expect(!ReviewCardModel.make(
            difference: diff(leftSize: 1000, rightSize: 2000),
            facts: facts(), paneNames: paneNames, isMove: false).canVerify)
        // A folder can't be hashed.
        var folderFacts = ReviewCardModel.Facts()
        folderFacts.destinationIsDirectory = true
        #expect(!ReviewCardModel.make(
            difference: diff(leftSize: 1000, rightSize: 1000),
            facts: folderFacts, paneNames: paneNames, isMove: false).canVerify)
    }
}

/// The card's spoken key hint.
///
/// Exists because the first version of that hint shipped as **"Return copys"** — `primaryVerb`
/// lowercased with an `"s"` stuck on it, announced on every Copy review, in the one channel the
/// hint was added to serve. It was invisible to every test in the suite: the accessibility tree is
/// not observable under `swift test`, so nothing could have caught it downstream of the string.
/// Testing the string itself is the only place the grammar is checkable at all.
@Suite struct ReviewCardKeyHintSpeechTests {

    /// Both verbs, both grammatical. Parameterised rather than asserting one, because the bug was
    /// exactly that one of the two read correctly ("moves") and the other did not.
    @Test(arguments: [("Copy", "copy"), ("Move", "move")])
    func theHintReadsGrammaticallyForBothVerbs(verb: String, spoken: String) {
        let hint = ReviewCardModel.keyHintSpeech(primaryVerb: verb)
        #expect(hint.contains("Return to \(spoken),"), "got: \(hint)")
        // The specific failure, named: no conjugated form may reappear.
        #expect(!hint.contains("\(spoken)s"), "the verb was conjugated again: \(hint)")
    }

    /// All four keys are named. A hint that silently lost one would still read grammatically.
    @Test func everyReviewKeyIsNamed() {
        let hint = ReviewCardModel.keyHintSpeech(primaryVerb: "Copy")
        for key in ["Return", "Delete", "Space", "Escape"] {
            #expect(hint.contains(key), "\(key) is missing from: \(hint)")
        }
    }
}
