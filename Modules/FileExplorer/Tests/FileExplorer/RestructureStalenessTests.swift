import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §4.1's last piece: the survey note's caution tint, with the remedy beside it (proposal O13).
@MainActor
@Suite struct RestructureStalenessTests {

    private static func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    /// Both sides of the threshold, with an injected instant — a boundary tested from one side
    /// is a constant, and one tested against `Date()` is a test that changes its mind overnight.
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

    /// The VALUE, not just the boundary — it was measured, and a test that derived its fixture
    /// from the constant would pass for 14 or 30 alike.
    @Test func theThresholdIsTheMeasuredOne() {
        #expect(RestructureLens.staleSurveyDays == 21)
        let now = Self.day("2026-08-28 12:00")
        // The state this machine was actually in when the number was picked: artifacts written
        // 9 Aug, nineteen days old, and the only re-survey in a month of log.
        #expect(!RestructureLens.surveyIsStale(Self.day("2026-08-09 23:34"), now: now),
                "a fortnight would have tinted the ordinary state of this tree")
        #expect(RestructureLens.surveyIsStale(Self.day("2026-08-01 09:00"), now: now))
    }

    /// **Unknown is not stale.** A corpus from before §4.1's stamp existed has no date, and the
    /// note already declines to invent one — inventing a warning about it is the same overreach.
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

    /// **The tint lands on the glyph and never on the sentence** — amber on 11pt body text is
    /// the documented contrast trap this rule exists for. Pinned at the call site, because the
    /// rule alone cannot say where its answer is used.
    @Test func onlyTheGlyphTakesTheCaution() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let note = try #require(text.range(of: "private var surveyNote: some View {"))
        let body = String(text[note.lowerBound...].prefix(1800))
        let image = try #require(body.range(of: "Image(systemName: stale"))
        let orange = try #require(body.range(of: "AnyShapeStyle(.orange)"))
        let sentence = try #require(body.range(of: "Text(Self.surveyNoteText("))
        #expect(orange.lowerBound > image.lowerBound && orange.lowerBound < sentence.lowerBound,
                "the tint belongs to the glyph, above the sentence")
        #expect(!body[sentence.lowerBound...].prefix(300).contains(".orange"),
                "the sentence keeps its ordinary colour")
    }

    /// A caution with nothing to do about it is one people learn to scroll past.
    @Test func theRemedySitsBesideTheWarning() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("if stale, let onUpdateSurvey {"),
                "the Rescan link appears with the caution and not otherwise")
    }

    /// **The card acts on `surveyIsStale`.** Comparing a fresh render against a stale one looks
    /// like the test to write and is not one: the two also carry different date sentences ("1 day
    /// ago" / "24 days ago"), so they differ whatever the staleness branch does — hard-coding
    /// `stale = false` at the call site left that comparison passing.
    ///
    /// What only staleness controls is whether the Rescan link is offered at all. So the
    /// comparison holds the date fixed and toggles the handler: on a stale survey that must
    /// change the card, and on a fresh one it must change nothing, because a fresh survey offers
    /// no link for a handler to attach to.
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

        // §4.1's rule puts the caution on the GLYPH and nowhere else, so amber is present in
        // exactly one state — and unlike a whole-render comparison it cannot be satisfied by the
        // date sentence changing.
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
