import AppKit
import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// `PeopleOverviewRow`: what the roster governs, and the people it doesn't reach.
/// `PeopleOverview.make` is pinned in `Sync` and the store in `PeopleSectionTests`; this pins the
/// row. It is display-only and its sentences are built by `private` members, so pixels are the
/// instrument, and the claims are ones pixels can carry.
///
/// The tests cover the row's branches, not its wording: a complete tree says so rather than leave a
/// blank, an unsurveyed one draws nothing rather than claim "0 folders", and a person the roster
/// can't reach appears in the caution colour with an offer beside them. Ink, not geometry, because
/// a height comparison passes against a branch that reserves space and draws nothing.
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

    /// Somebody the tree files for whom the roster doesn't know: the gap the section exists for.
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

    /// The row's natural height at the sheet's content width, which tells one line from two where
    /// no input can switch a single line off.
    private func height(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view.frame(width: Self.width)))
        return host.fittingSize.height
    }

    /// Pixels differing in brightness from the window background, optionally within a horizontal
    /// band given as fractions of the width. `SemanticColor.caution` is a yellow, close to a light
    /// background's brightness, so the unclaimed line inks less than the grey sentence it replaces
    /// and a whole-row tally drops when a gap appears. Hue (`cautionInk`) or position (the band)
    /// has to do that work instead.
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

    /// Pixels carrying the caution hue, which on this row only the unclaimed line wears. By hue,
    /// not ink, because the claim is about which of two sentences is drawn and both ink about the
    /// same; grey text has no hue, so hue separates them.
    private func cautionInk(_ view: some View) -> Int {
        guard let rep = render(view) else { return 0 }
        let caution = NSColor(SemanticColor.caution).usingColorSpace(.sRGB)
        guard let target = caution else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Saturated and near the target hue. The saturation floor keeps out grey text and
                // the background, which sit near zero however bright they are.
                guard c.saturationComponent > 0.25 else { continue }
                var delta = abs(c.hueComponent - target.hueComponent)
                delta = min(delta, 1 - delta)          // hue is a circle
                if delta < 0.06 { n += 1 }
            }
        }
        return n
    }

    // MARK: An unsurveyed tree draws nothing

    /// With nothing surveyed the row draws nothing: not "0 folders…", and not the reassurance.
    /// Both sentences are gated on `claimedFolders > 0`, the state of a fresh install until a
    /// survey runs; dropping either guard states a fact about a tree nobody has looked at. The
    /// populated case is measured first, so a harness that renders nothing can't pass.
    @Test func anUnsurveyedTreeDrawsNoRowAtAll() {
        let surveyed = ink(Self.row(PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                                   unclaimed: [], peopleWithNoFolders: [])))
        #expect(surveyed > 200,
                "the populated row inked only \(surveyed) pixels — the harness is drawing nothing, and the check below is vacuous")

        let unsurveyed = ink(Self.row(.empty))
        #expect(unsurveyed == 0,
                "an empty overview still painted \(unsurveyed) pixels — the row is asserting something about a tree nobody has surveyed")
    }

    /// A complete roster says so plainly instead of leaving a blank. "Everyone your tree files for
    /// is on this list" is the section's usual state, and worth reading once rather than being
    /// empty space.
    @Test func aCompleteRosterDrawsItsReassurance() {
        let complete = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                      unclaimed: [], peopleWithNoFolders: [])
        let coverageOnly = ink(Self.row(complete))
        // The same overview with a gap, which swaps the reassurance for the amber line: only it
        // should carry caution ink.
        let withGap = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                     unclaimed: [Self.ravi], peopleWithNoFolders: [])
        #expect(coverageOnly > 200, "the complete roster drew almost nothing (\(coverageOnly) pixels)")
        #expect(cautionInk(Self.row(complete)) == 0,
                "the complete roster is drawing something in the caution colour — nothing here is a warning")
        #expect(cautionInk(Self.row(withGap)) > 20,
                "a person the roster cannot reach is not drawn in the caution colour")

        // None of the three above sees the reassurance: the coverage sentence alone clears the
        // ink floor, and a `.secondary` line carries no caution hue. So it is checked by height.
        // No input switches it off alone (its condition is `unclaimed.isEmpty`), but a complete row
        // holds only the coverage sentence and the reassurance, so two lines tall means it is
        // drawn. One line is measured from the only other single-line state: no survey, one inert
        // person on the roster.
        let oneLine = height(Self.row(PeopleOverview(claimedFolders: 0, claimedDocuments: 0,
                                                     unclaimed: [], peopleWithNoFolders: ["daughter"])))
        let bothLines = height(Self.row(complete))
        #expect(oneLine > 0, "the single-line control measured nothing — the comparison below is vacuous")
        #expect(bothLines > oneLine * 1.6,
                "the complete roster is \(bothLines)pt tall against \(oneLine)pt for one line — it is drawing the coverage sentence and nothing else, so a complete roster reads as a blank")
    }

    // MARK: The gap is the actionable half

    /// An unreachable person brings an Add offer, not just a sentence. The button is the row's only
    /// action and `cautionInk` can't see it, so it is found by position: a `Spacer(minLength: 8)`
    /// pushes it to the trailing edge, where no leading-aligned prose reaches. Comparing that band
    /// with and without a gap cancels the coverage line's share.
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

    /// Two gaps draw two lines. A row that drew only the first unclaimed person would pass every
    /// check above.
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

    /// A person on the roster with no folders is reported by name, since their record changes
    /// nothing. The line looks each id up in the store, so `noFolderLine` returns `""` when none
    /// resolves. Both directions: a resolvable id paints, an unknown one draws nothing.
    @Test func anInertPersonIsNamed() {
        let base = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                  unclaimed: [], peopleWithNoFolders: [])
        let inert = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                   unclaimed: [], peopleWithNoFolders: ["daughter"])
        #expect(ink(Self.row(inert)) > ink(Self.row(base)) + 100,
                "a person with no folders recorded adds nothing to the row — their record's inertness is never said")
        // An id nobody on the roster answers to drops the line, rather than drawing it blank or as
        // the raw id.
        let stranger = PeopleOverview(claimedFolders: 12, claimedDocuments: 140,
                                      unclaimed: [], peopleWithNoFolders: ["nobody-by-that-id"])
        #expect(ink(Self.row(stranger)) == ink(Self.row(base)),
                "an unresolvable id still draws a line — most likely a blank one, or the raw id")
    }
}

/// The coverage line groups its counts, like every other count the app prints (as
/// `RestructureLens.cleanMessage` does). Asserted on the sentence, not a render: a pixel count
/// can't tell "1204" from "1,204".
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
        // The formatter is locale-aware, so this pins the difference rather than a comma.
        #expect(!text.contains("1204") || 1204.formatted() == "1204", "raw interpolation survived")
    }

    /// The singular forms still read: "1 folder", not "1.0 folders".
    @Test func theSingularsStillRead() {
        #expect(line(folders: 1, documents: 1).contains("1 folder in your tree"))
        #expect(line(folders: 1, documents: 1).contains("1 filed document"))
        #expect(!line(folders: 1, documents: 1).contains("documents"))
    }
}
