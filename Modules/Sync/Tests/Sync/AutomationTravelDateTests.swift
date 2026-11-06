import Foundation
import Testing
@testable import Sync

/// `{travel-month}`'s date on pages that print times beside their dates: a time is never read as a
/// year.
@Suite struct AutomationTravelDateTests {

    /// Page 1 of an e-ticket with its departure times, as the reader returns it.
    static let ticketWithTimes = """
        JAPAN AIRLINES  e-Ticket Itinerary / Receipt
        Passenger: GIRISH/ABHISHEK MR   Date of birth: 12MAR1985
        Date of Issue: 15JUL26   Ticket Number: 131 2345678901
        JL 754  23SEP 2145  Tokyo Narita (NRT) - Bengaluru (BLR)
        JL 753  14OCT 0930  Bengaluru (BLR) - Tokyo Narita (NRT)
        """

    @Test func aTicketsDepartureTimesAreNotYears() {
        #expect(AutomationTravelDate.first(in: Self.ticketWithTimes) == .init(year: 2026, month: 9, day: 23))
    }

    /// 20:15 is a time and 2015 a year, by the digits alone: the page's issue year decides.
    @Test func aTimeThatCouldBeAYearTakesThePagesYear() {
        #expect(AutomationTravelDate.first(in: "Issued 01 Aug 2026\nAI 173  23SEP 2015  SFO-BLR")
                == .init(year: 2026, month: 9, day: 23))
        #expect(AutomationTravelDate.first(in: "Issued 2026-08-01\nDeparts Sep 23 2145 from SFO")
                == .init(year: 2026, month: 9, day: 23))
    }

    @Test func aTimeWithAColonIsNotATwoDigitYear() {
        #expect(AutomationTravelDate.first(in: "Issued 2026-08-01\nDeparture 23 SEP 21:45 NRT")
                == .init(year: 2026, month: 9, day: 23))
        // No year anywhere on the page: nothing to go by, rather than 2021.
        #expect(AutomationTravelDate.first(in: "Departure 23 SEP 21:45 NRT") == nil)
    }

    /// A year written after a space is still a year: alone, or beside the page's own year.
    @Test func aSpacedYearIsStillAYear() {
        #expect(AutomationTravelDate.first(in: "Departure: 23 September 2026") == .init(year: 2026, month: 9, day: 23))
        #expect(AutomationTravelDate.first(in: "Issued 15JUL26\nOut 23 Sep 2026\nBack 14 Oct 2026")
                == .init(year: 2026, month: 9, day: 23))
        #expect(AutomationTravelDate.first(in: "Issued 20 Dec 2026\nOut 05 Jan 2027") == .init(year: 2027, month: 1, day: 5))
    }
}
