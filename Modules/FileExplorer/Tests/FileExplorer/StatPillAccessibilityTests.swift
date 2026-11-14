import Testing
@testable import FileExplorer

/// What VoiceOver reads for a `StatPill`. The pill collapses to a single accessibility element, so
/// this one string is all that is spoken for the differences header's most important control, with
/// no second element to correct a wrong one.
@Suite struct StatPillAccessibilityTests {

    @Test(arguments: [
        (7, "Differences", String?.none, "7 Differences"),
        // The detail follows a comma.
        (576, "Differences", "scanned 29m ago", "576 Differences, scanned 29m ago"),
        // The pill reads the phrase it is handed and adds no grammar: prefixing "scanned" itself
        // would turn the in-flight phrase into "576 Differences, scanned scanning…".
        (576, "Differences", "scanning for changes", "576 Differences, scanning for changes"),
        // Nothing glued onto an empty phrase: a trailing ", " reads as a pause before nothing.
        (3, "conflicts", "", "3 conflicts"),
        // Counts are spoken as shown, through `formatted()`: the separator depends on the locale.
        (1284, "identical", nil, "\(1284.formatted()) identical"),
    ])
    func whatThePillSpeaks(count: Int, label: String, detail: String?, expected: String) {
        #expect(StatPill.accessibilityLabel(count: count, label: label, spokenDetail: detail) == expected)
    }
}
