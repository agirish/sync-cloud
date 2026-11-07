import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The survey note's caution tint for a stale survey, with the remedy beside it.
@MainActor
@Suite struct RestructureStalenessTests {

    private static func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    /// Both sides of the threshold, with an injected instant: a boundary tested from one side is a
    /// constant, and one tested against `Date()` changes its mind overnight.
    @Test func theThresholdIsCrossedFromBothSides() {
        let now = Self.day("2026-08-28 12:00")
        let days = RestructureLens.staleSurveyDays
        let onIt = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let justUnder = Calendar.current.date(byAdding: .day, value: -(days - 1), to: now)!

        #expect(RestructureLens.surveyIsStale(onIt, now: now),
                "exactly at the threshold counts as stale")
        #expect(!RestructureLens.surveyIsStale(justUnder, now: now))
        #expect(!RestructureLens.surveyIsStale(now, now: now))
    }

    /// The value, not just the boundary: it was measured, and a fixture derived from the constant
    /// would pass for 14 or 30 alike.
    @Test func theThresholdIsTheMeasuredOne() {
        #expect(RestructureLens.staleSurveyDays == 21)
        let now = Self.day("2026-08-28 12:00")
        // A survey nineteen days old is an ordinary state for a real tree, so it must not tint.
        #expect(!RestructureLens.surveyIsStale(Self.day("2026-08-09 23:34"), now: now),
                "a fortnight would have tinted the ordinary state of this tree")
        #expect(RestructureLens.surveyIsStale(Self.day("2026-08-01 09:00"), now: now))
    }

    /// Unknown is not stale. An undated corpus gets no invented date in the note, and no invented
    /// warning either.
    @Test func anUndatedSurveyRaisesNoCaution() {
        #expect(!RestructureLens.surveyIsStale(nil, now: Self.day("2026-08-28 12:00")))
        #expect(!RestructureLens.surveyNoteText(folderCount: 10, surveyedAt: nil,
                                                now: Self.day("2026-08-28 12:00"))
                    .contains("Surveyed"),
                "no date, no claim about one")
    }

    /// A stamp from the future is a wrong clock, not a stale survey.
    @Test func aFutureStampIsNotStale() {
        let now = Self.day("2026-08-28 12:00")
        #expect(!RestructureLens.surveyIsStale(Self.day("2026-09-30 12:00"), now: now))
    }

    /// The tint lands on the glyph, never the sentence: amber on 11pt body text is the contrast
    /// trap this rule exists for. Pinned at the call site, because the rule can't say where its
    /// answer is used.
    @Test func onlyTheGlyphTakesTheCaution() throws {
        let text = try SourceText.fileExplorer("RestructureLens.swift")
        let body = try SourceText.block(opening: "private var surveyNote: some View {", in: text)
        let image = try #require(body.range(of: "Image(systemName: stale"))
        let orange = try #require(body.range(of: "AnyShapeStyle(.orange)"))
        let sentence = try #require(body.range(of: "Text(Self.surveyNoteText("))
        #expect(orange.lowerBound > image.lowerBound && orange.lowerBound < sentence.lowerBound,
                "the tint belongs to the glyph, above the sentence")
        #expect(!SourceText.normalized(String(body[sentence.lowerBound...].prefix(300))).contains(".orange"),
                "the sentence keeps its ordinary colour")
    }

    /// A caution with nothing to do about it is one people learn to scroll past.
    @Test func theRemedySitsBesideTheWarning() throws {
        let text = try SourceText.fileExplorer("RestructureLens.swift")
        #expect(text.contains("if stale, let onUpdateSurvey {"),
                "the Rescan link appears with the caution and not otherwise")
    }

    /// The card acts on `surveyIsStale`. A fresh and a stale render also carry different date
    /// sentences, so they differ whatever the branch does. What only staleness controls is the
    /// amber glyph and whether the Rescan link is offered, so this counts the amber and, holding
    /// the date fixed, toggles the handler. Hard-coding `stale = false` must fail it.
    @Test func theCardOffersItsRemedyOnlyWhenTheSurveyIsStale() throws {
        func lens(daysOld age: Int, remedy: Bool) -> RestructureLens {
            RestructureLens(
                findings: [], hasProfile: true, folderCount: 3013,
                surveyedAt: Calendar.current.date(byAdding: .day, value: -age, to: Date()),
                accent: .blue, onReveal: { _ in }, hasReviewed: false,
                onUpdateSurvey: remedy ? {} : nil)
        }
        let old = RestructureLens.staleSurveyDays + 3
        let stale = try #require(RestructureRender.raster(lens(daysOld: old, remedy: true),
                                                          width: 660, height: 520))
        let fresh = try #require(RestructureRender.raster(lens(daysOld: 1, remedy: true),
                                                          width: 660, height: 520))
        #expect(RestructureRender.inkedPixels(fresh) > 1000, "the note drew at all")

        // The caution is on the glyph and nowhere else, so amber appears in exactly one state,
        // and a changed date sentence can't produce it.
        #expect(RestructureRender.cautionPixels(fresh) == 0, "a fresh survey raises no caution")
        #expect(RestructureRender.cautionPixels(stale) > 5,
                "a three-week-old survey tints its glyph")

        // The remedy beside the warning: on a stale card the handler adds the Rescan link, and on
        // a fresh one there is nothing for it to attach to.
        let staleNoRemedy = try #require(RestructureRender.raster(lens(daysOld: old, remedy: false),
                                                                  width: 660, height: 520))
        #expect(RestructureRender.differingPixels(stale, staleNoRemedy) > 100,
                "a stale survey offers the Rescan link")
    }
}
