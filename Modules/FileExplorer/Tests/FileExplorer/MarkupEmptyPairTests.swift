import Testing
import Foundation
@testable import FileExplorer

/// **An empty pair selected whole is wrapped, and comes off.** Bold pressed with nothing selected
/// leaves `****` with the caret inside; selecting those four and pressing Bold again must take the
/// pair away, not wrap it in a second one. The pair is exactly twice the delimiter, the one length
/// at which `wrapState` reads "starts and ends with it" with nothing between.
@Suite struct MarkupEmptyPairTests {

    @Test(arguments: [(MarkupVerb.bold, "****"), (.strikethrough, "~~~~")])
    func anEmptyPairSelectedWholeComesOff(_ verb: MarkupVerb, _ pair: String) throws {
        let all = NSRange(location: 0, length: (pair as NSString).length)
        #expect(MarkdownEdits.isApplied(verb, in: pair, selection: all), "\(verb) is not lit over “\(pair)”")
        let edit = try #require(MarkdownEdits.apply(verb, to: pair, selection: all))
        #expect(edit.text == "", "\(verb) over “\(pair)” gave “\(edit.text)”")
        #expect(edit.selection == NSRange(location: 0, length: 0))
    }
}
