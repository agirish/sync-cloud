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

    /// Both states render — and it is the same card, so a layout that only worked in one would
    /// fail here rather than on a three-week-old survey.
    @Test func theNoteRendersFreshAndStale() {
        for age in [1, RestructureLens.staleSurveyDays + 3] {
            let lens = RestructureLens(
                findings: [], hasProfile: true, folderCount: 3013,
                surveyedAt: Calendar.current.date(byAdding: .day, value: -age, to: Date()),
                accent: .blue, onReveal: { _ in }, hasReviewed: false,
                onUpdateSurvey: {})
            let hosting = NSHostingView(rootView: lens.frame(width: 660, height: 520))
            hosting.frame = NSRect(x: 0, y: 0, width: 660, height: 520)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0)
        }
    }
}
