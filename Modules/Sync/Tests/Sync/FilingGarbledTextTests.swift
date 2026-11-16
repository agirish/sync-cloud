import Foundation
import Testing
@testable import Sync

/// ``FilingSurvey/isGarbled(_:)``: which extracted pages are a broken text layer, worth reading
/// again with OCR. Each case is a shape measured on his tree, 15 Nov 2026.
@Suite struct FilingGarbledTextTests {

    /// The start of a live PG&E statement's PDFKit text (`2024/01. Jan 2024.pdf`): a font whose
    /// `ToUnicode` map is broken extracts as punctuation and digits, with no word in it.
    static let pgeSoup = """
        ") )
        B B A B
        !
        )%& '( & + %' ,+23%& 0 (. (+ )+' ( 4
        .5)+ '(60 7 + $+32+1 3'$+ .0 ( (.(+)+ '( #
        ,+23%& 0 ' 8.31 ./.' $+ 4
        & ,,+' ( /+$(,3$ +/32+,5 9., :+0 4
        ! /+$(,3$ +' +,. (3% ' 9.,: +0 & ,,+' ( . 0 9 .,:+ 0 ;
        """

    /// The same statement as OCR reads it.
    static let pgeRead = """
        ENERGY STATEMENT
        www.pge.com/MyEnergy
        Questions about your bill?
        Account No: 1234567890-5
        Statement Date: 03/18/2024
        Due Date: 04/08/2024
        Your Account Summary
        Amount Due on Previous Statement $351.24
        Payments Received Since Last Statement -351.24
        Current PG&E Electric Delivery Charges $121.13
        """

    @Test func aBrokenTextLayerIsGarbled() {
        #expect(FilingSurvey.isGarbled(Self.pgeSoup))
    }

    @Test func aReadableStatementIsNot() {
        #expect(!FilingSurvey.isGarbled(Self.pgeRead))
    }

    /// A clean heading, printed twice, over thousands of characters of soup (a traffic-school
    /// certificate on his tree): ``FilingSurvey/isDecodable(_:)`` passes it on the heading's
    /// words; the share of characters in words is what sees the soup.
    @Test func aCleanHeadingOverSoupIsStillGarbled() {
        let page = String(repeating: "Congratulations, You Passed Your Traffic School Course!", count: 2) + "\n"
            + String(repeating: "V)F@&D#\"1-&e)Or&G)H&>10\"&N1%%\"+&->\"&M*14&\"L1$&F,->&1&%2)#\"\n", count: 100)
        #expect(FilingSurvey.isDecodable(page))
        #expect(FilingSurvey.isGarbled(page))
    }

    /// A table of figures with a word a row (an amortization schedule: share 0.07 on his tree,
    /// about 0.09 here) is real text: OCR would read the same figures.
    @Test func aTableOfFiguresIsNot() {
        let rows = (1...60).map { "\($0) Pmt 03/01/2021 $3,304.59 $1,345.04" }
        let page = "AMORTIZATION SCHEDULE\nLoan No.: Date: Borrower Lender Interest Rate\n"
            + rows.joined(separator: "\n")
        #expect(!FilingSurvey.isGarbled(page))
    }

    /// Too little to judge: a page under 100 visible characters is never garbled, and an empty one
    /// is a scan, which Read Scan offers.
    @Test func aShortOrEmptyPageIsNot() {
        #expect(!FilingSurvey.isGarbled(""))
        #expect(!FilingSurvey.isGarbled(String(Self.pgeSoup.prefix(60))))
    }
}
