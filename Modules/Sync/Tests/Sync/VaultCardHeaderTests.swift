import Foundation
import Testing
@testable import Sync

/// A card's header row of labels over a row of values (``VaultReading/cardValues(on:)``): each
/// label names the value in its own column (the second review). Every number is made up.
@Suite struct VaultCardHeaderTests {
    static func values(_ lines: [String]) -> [VaultCardValue] { VaultReading.cardValues(on: [lines]) }

    @Test func eachLabelOfAHeaderRowNamesTheValueInItsColumn() {
        let groupFirst = Self.values(["Delta Dental", "Group No    Member ID", "0012345    W123456789"])
        #expect(groupFirst == [VaultCardValue(label: "Member ID", value: "W123456789")],
                "the group's number named the member's, or the member's ID was lost")
        let memberFirst = Self.values(["Delta Dental", "Member ID    Group No", "W123456789    0012345"])
        #expect(memberFirst == [VaultCardValue(label: "Member ID", value: "W123456789")],
                "the group's label kept the member's ID out")
        // One label over one value reads as before.
        #expect(Self.values(["Subscriber ID", "W123456789"]) == [VaultCardValue(label: "Subscriber ID", value: "W123456789")])
    }
}
