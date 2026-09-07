import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// `PeopleOverviewRow` — what the roster governs, and the people it does not reach.
///
/// `PeopleOverview.make` is pinned in `Sync` and the store is pinned in `PeopleSectionTests`;
/// **nothing looked at the row that draws the answer.** It is display-only, its three sentences are
/// built by `private` members, and SwiftUI cannot be driven from here — so pixels are the whole
/// instrument, and the claims are chosen to be ones pixels can actually carry.
///
/// The section's premise is that **the gap is the actionable half and it is normally empty**. That
/// makes the row's real subject its *branches*, not its wording: on a complete tree it must say so
/// rather than leave a blank, on an unsurveyed one it must draw nothing at all rather than assert
/// "0 folders", and a person the roster cannot reach must arrive in the caution colour with an offer
/// beside them. Each is a different arm, and each is measurable.
///
/// Ink, not geometry, for the reason this file's neighbour records: **room is not paint**, and a
/// height comparison passes against a branch that reserves space and draws nothing.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PeopleOverviewRowTests {

    private static let roster = [
        Person(id: "daughter", displayName: "Daughter", relationship: "daughter"),
        Person(id: "son", displayName: "Son", relationship: "son"),
    ]

    private static func row(_ overview: PeopleOverview,
                            people: [Person] = roster) -> PeopleOverviewRow {
        PeopleOverviewRow(overview: overview, store: PeopleStore(people: people))
    }

    private static let width = SettingsSheetMetrics.contentWidth(textScale: 1)

    /// Somebody the tree files for whom the roster does not know — the gap the section exists for.
    private static let ravi = PeopleOverview.UnclaimedPerson(
        name: "Ravi", folders: 2, documents: 9, exampleFolder: "Family/Ravi")

    // MARK: Harness

    private func render(_ view: some View) -> NSBitmapImageRep? {
        let subject = view.frame(width: Self.width)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: AnyView(subject))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(origin: .zero,
                            size: CGSize(width: Self.width, height: max(1, host.fittingSize.height)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The row's natural height at the sheet's content width — what separates a row of one line
    /// from a row of two when no input can switch a single line off on its own.
    private func height(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: Self.width)))
        return host.fittingSize.height
    }

    /// Pixels differing from the window background, optionally restricted to a horizontal band
    /// given as a fraction of the width.
    ///
    /// **Brightness, which is why the band exists.** `SemanticColor.caution` is a yellow, and yellow
    /// on a light background is nearly the background's brightness — the unclaimed line inks far
    /// less than the grey sentence it replaces, and a whole-row tally therefore goes *down* when a
    /// gap appears. That is not a defect, it is the reason the design note gives for the glyph
    /// carrying the colour elsewhere; here it means a total-ink threshold measures the wrong thing,
    /// and hue (`cautionInk`) or position (this band) has to do the work instead.
    private func ink(_ view: some View, from: CGFloat = 0, to: CGFloat = 1) -> Int {
        guard let rep = render(view), let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        let lower = Int(CGFloat(rep.pixelsWide) * from)
        let upper = min(rep.pixelsWide, Int(CGFloat(rep.pixelsWide) * to))
        var painted = 0
        for y in 0..<rep.pixelsHigh {
            for x in lower..<max(lower, upper) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.brightnessComponent - background.brightnessComponent) > 0.08 { painted += 1 }
            }
        }
        return painted
    }

    /// Pixels carrying the **caution** hue, which on this row only the unclaimed line wears.
    ///
    /// Measured by hue distance rather than by ink, because the claim is about *which* of two
    /// sentences is drawn and both draw about the same amount of it. Grey text has no hue to speak
    /// of, so the two are separable in a way their pixel counts are not — and this is the axis the
    /// People surfaces have been wrong on before, when a first pass tinted every row amber.
    private func cautionInk(_ view: some View) -> Int {
        guard let rep = render(view) else { return 0 }
        let caution = NSColor(SemanticColor.caution).usingColorSpace(.sRGB)
        guard let target = caution else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Saturated, and near the target hue. The saturation floor is what keeps grey text
                // and the window background out — both sit near zero however bright they are.
                guard c.saturationComponent > 0.25 else { continue }
                var delta = abs(c.hueComponent - target.hueComponent)
                delta = min(delta, 1 - delta)          // hue is a circle
                if delta < 0.06 { n += 1 }
            }
        }
        return n
    }

    // MARK: An unsurveyed tree draws nothing

    /// **With nothing surveyed the row draws nothing at all** — not "0 folders in your tree belong
    /// to someone on this list", and not the reassurance either.
    ///
    /// Both sentences are gated on `claimedFolders > 0`, and that is the arm a fresh install sits in
    /// for as long as it takes to run a survey. Dropping either guard puts a confident sentence
    /// about a tree nobody has looked at yet under the roster — an assertion of fact the app has no
    /// basis for, which is precisely the failure mode this section's design note argues against.
    ///
    /// The populated case is measured first, so "draws nothing" cannot be satisfied by a harness
    /// that renders nothing.
    @Test func anUnsurveyedTreeDrawsNoRowAtAll() {
        let surveyed = ink(Self.row(PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                                   unclaimed: [], peopleWithNoFolders: [])))
        #expect(surveyed > 200,
                "the populated row inked only \(surveyed) pixels — the harness is drawing nothing, and the check below is vacuous")

        let unsurveyed = ink(Self.row(.empty))
        #expect(unsurveyed == 0,
                "an empty overview still painted \(unsurveyed) pixels — the row is asserting something about a tree nobody has surveyed")
    }

    /// **A complete roster says so plainly instead of leaving a blank.**
    ///
    /// "Everyone your tree files for is on this list" is the state the section is in almost always,
    /// and the design note is explicit that it is worth reading once rather than being an empty
    /// space. Measured against the same overview with the reassurance's own condition broken — a
    /// tree with coverage *and* a gap — so what separates the two renders is the arm and not the
    /// presence of a survey.
    @Test func aCompleteRosterDrawsItsReassurance() {
        let complete = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                      unclaimed: [], peopleWithNoFolders: [])
        let coverageOnly = ink(Self.row(complete))
        // The coverage sentence alone, isolated by giving the same overview a gap: that suppresses
        // the reassurance and adds the amber line, so the difference is not a clean subtraction —
        // what it establishes is that the complete case is not merely the coverage line.
        let withGap = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                     unclaimed: [Self.ravi], peopleWithNoFolders: [])
        #expect(coverageOnly > 200, "the complete roster drew almost nothing (\(coverageOnly) pixels)")
        #expect(cautionInk(Self.row(complete)) == 0,
                "the complete roster is drawing something in the caution colour — nothing here is a warning")
        #expect(cautionInk(Self.row(withGap)) > 20,
                "a person the roster cannot reach is not drawn in the caution colour")

        // **None of the three above is about the reassurance.** `coverageOnly > 200` is cleared by
        // the coverage sentence on its own; both caution readings are unchanged by a line drawn in
        // `.secondary`. Delete the entire "Everyone your tree files for is on this list." block and
        // all three still pass — which leaves the state this section sits in on essentially every
        // real launch with no coverage at all.
        //
        // Isolated by HEIGHT, because no input isolates it: the reassurance's own condition is
        // `unclaimed.isEmpty`, so the only way to switch it off is to add a gap, which puts an amber
        // line and a button in its place. Two things can be in this row when the roster is complete
        // — the coverage sentence and the reassurance — and the coverage sentence's own content is
        // pinned by `PeopleCoverageLineTests`. So a complete row measuring TWO lines tall is the
        // reassurance being drawn. One line is measured from the row's only other single-line
        // state: a tree with no survey behind it and one inert person on the roster.
        let oneLine = height(Self.row(PeopleOverview(claimedFolders: 0, claimedDocuments: 0,
                                                     unclaimed: [], peopleWithNoFolders: ["daughter"])))
        let bothLines = height(Self.row(complete))
        #expect(oneLine > 0, "the single-line control measured nothing — the comparison below is vacuous")
        #expect(bothLines > oneLine * 1.6,
                "the complete roster is \(bothLines)pt tall against \(oneLine)pt for one line — it is drawing the coverage sentence and nothing else, so a complete roster reads as a blank")
    }

    // MARK: The gap is the actionable half

    /// **An unreachable person brings an offer, not just a sentence about them.**
    ///
    /// The Add button is the only thing on this row that *does* anything, and it is the half a
    /// reader is being asked to act on. It is also the half that is invisible to every other
    /// measurement here: `cautionInk` sees the amber sentence and not the control beside it.
    ///
    /// Isolated by **position** rather than by total ink. A `Spacer(minLength: 8)` pushes the button
    /// to the trailing edge, and nothing else on this row reaches there — every other line is
    /// leading-aligned prose. Comparing the same band between a row with a gap and a row without
    /// cancels whatever the coverage line contributes to it, so what is left is the control.
    @Test func anUnreachablePersonBringsAnOfferAndNotJustASentence() {
        let gap = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                 unclaimed: [Self.ravi], peopleWithNoFolders: [])
        let none = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                  unclaimed: [], peopleWithNoFolders: [])
        #expect(ink(Self.row(none)) > 200,
                "the control render is empty — the comparison below means nothing")
        let trailingWithGap = ink(Self.row(gap), from: 0.8)
        let trailingWithout = ink(Self.row(none), from: 0.8)
        #expect(trailingWithGap > trailingWithout + 150,
                "the trailing edge gained only \(trailingWithGap - trailingWithout) pixels when a gap appeared — the Add offer is not being drawn, leaving a warning nobody can act on")
    }

    /// **Two gaps draw two offers.** The `ForEach` is the only thing standing between "the section
    /// lists who is missing" and "the section mentions that somebody is", and a row that drew the
    /// first unclaimed person and stopped would satisfy every check above.
    @Test func everyUnreachablePersonGetsTheirOwnLine() {
        let one = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                 unclaimed: [Self.ravi], peopleWithNoFolders: [])
        let two = PeopleOverview(
            claimedFolders: 12, claimedDocuments: 140,
            unclaimed: [Self.ravi,
                        PeopleOverview.UnclaimedPerson(name: "Kavya", folders: 1, documents: 3,
                                                       exampleFolder: "School/Kavya")],
            peopleWithNoFolders: [])
        let first = cautionInk(Self.row(one))
        let both = cautionInk(Self.row(two))
        #expect(first > 20, "even one gap drew no caution ink — the harness is not seeing the line")
        #expect(both > first * 3 / 2,
                "two unreachable people drew \(both) caution pixels against one person's \(first) — the second is being dropped")
    }

    // MARK: The inert half

    /// **A person on the roster with no folders is reported by name.**
    ///
    /// Not a fault, and not actionable — but it does mean their record changes nothing, and the
    /// design note is explicit that *which* person is inert is the useful part. The sentence is
    /// assembled by looking each id up in the store, so it is the one line here that can come out
    /// empty from a mismatch between the overview and the roster: `noFolderLine` returns `""` when
    /// no id resolves, and an empty string draws an empty `Text` rather than nothing at all.
    ///
    /// So both directions: a resolvable id paints, and an id the store has never heard of does not.
    @Test func anInertPersonIsNamed() {
        let base = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                  unclaimed: [], peopleWithNoFolders: [])
        let inert = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                   unclaimed: [], peopleWithNoFolders: ["daughter"])
        #expect(ink(Self.row(inert)) > ink(Self.row(base)) + 100,
                "a person with no folders recorded adds nothing to the row — their record's inertness is never said")
        // An id nobody on the roster answers to resolves to no name, and the line is dropped rather
        // than drawn blank or drawn as the raw id.
        let stranger = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                      unclaimed: [], peopleWithNoFolders: ["nobody-by-that-id"])
        #expect(ink(Self.row(stranger)) == ink(Self.row(base)),
                "an unresolvable id still draws a line — most likely a blank one, or the raw id")
    }
}

/// **Numbers here are grouped, like every other count the app prints.**
///
/// The coverage line interpolated its counts raw — "holding 1204 filed documents" — two panels away
/// from `RestructureLens.cleanMessage`'s "Checked 3,013 folders". Same app, same kind of number, two
/// formats, and on a real tree this one is four digits.
///
/// Asserted on the SENTENCE rather than on a render: this is about the string, and a pixel count
/// cannot tell "1204" from "1,204" — it can barely tell it from "1205".
@MainActor
@Suite struct PeopleCoverageLineTests {

    /// The line as the row builds it, reached the way the row's other tests reach it.
    private func line(folders: Int, documents: Int) -> String {
        PeopleOverviewRow(overview: PeopleOverview(claimedFolders: folders,
                                                   claimedDocuments: documents,
                                                   unclaimed: [], peopleWithNoFolders: []),
                          store: PeopleStore(people: [])).coverageLineForTesting
    }

    @Test func fourDigitCountsAreGrouped() {
        let text = line(folders: 3013, documents: 1204)
        #expect(text.contains(1204.formatted()), "the document count is ungrouped: \(text)")
        #expect(text.contains(3013.formatted()), "the folder count is ungrouped: \(text)")
        // The formatter is locale-aware, so this pins the DIFFERENCE rather than a comma.
        #expect(!text.contains("1204") || 1204.formatted() == "1204", "raw interpolation survived")
    }

    /// The singular arms are untouched — "1 folder" is not "1.0 folders".
    @Test func theSingularsStillRead() {
        #expect(line(folders: 1, documents: 1).contains("1 folder in your tree"))
        #expect(line(folders: 1, documents: 1).contains("1 filed document"))
        #expect(!line(folders: 1, documents: 1).contains("documents"))
    }
}
