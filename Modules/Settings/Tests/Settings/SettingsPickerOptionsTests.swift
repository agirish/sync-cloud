import Testing
@testable import Settings

/// Pins the rule that keeps the five numeric Settings pickers honest.
///
/// The bug: each picker bound straight to its stored value with a hand-spelled `.tag(…)` per row.
/// A persisted value that isn't one of those tags — written by an older build's option set, a
/// `defaults write`, or a hand-edited plist — renders the control with NO selection while
/// continuing to govern every scan, and the user's first click on that blank-looking picker
/// silently replaces a setting they never knowingly chose.
///
/// These tests are about the *widening*: the offered rows are left exactly as they were (an
/// unrecognized value must not reshuffle a list the user knows), and an unrecognized value gains
/// its own row instead of being coerced onto a neighbouring one.
@Suite struct SettingsPickerOptionsTests {

    // MARK: - The offered rows are unchanged

    /// Every picker still offers exactly the values and labels it shipped with when the stored
    /// value is one of them. This is the guard against "fixing" the blank-picker bug by quietly
    /// rewriting the menus.
    @Test func recognizedValuesLeaveTheOfferedRowsExactlyAsTheyWere() {
        #expect(SettingsPickerOptions.dateTolerance(including: 1).map(\.value) == [0, 1, 2, 5, 60])
        #expect(SettingsPickerOptions.dateTolerance(including: 1).map(\.label)
            == ["Exact match", "1 second", "2 seconds", "5 seconds", "1 minute"])

        #expect(SettingsPickerOptions.minFileSize(including: 4096).map(\.value) == [0, 4096, 102_400, 1_048_576])
        #expect(SettingsPickerOptions.minFileSize(including: 4096).map(\.label)
            == ["No minimum", "4 KB", "100 KB", "1 MB"])

        #expect(SettingsPickerOptions.overlapThreshold(including: 0.7).map(\.value) == [0.5, 0.6, 0.7, 0.8, 0.9])
        #expect(SettingsPickerOptions.overlapThreshold(including: 0.7).map(\.label)
            == ["50%", "60%", "70%", "80%", "90%"])

        #expect(SettingsPickerOptions.monthlyBudget(including: 0).map(\.value) == [0, 1, 5, 10, 25, 50])
        #expect(SettingsPickerOptions.monthlyBudget(including: 0).map(\.label)
            == ["Off (no limit)", "$1", "$5", "$10", "$25", "$50"])

        #expect(SettingsPickerOptions.totalBudget(including: 5).map(\.value) == [0, 5, 10, 25, 50, 100])
        #expect(SettingsPickerOptions.totalBudget(including: 5).map(\.label)
            == ["Off (no limit)", "$5", "$10", "$25", "$50", "$100"])
    }

    // MARK: - An unrecognized stored value gets a row

    /// The finding, one picker at a time: whatever is persisted, some row carries it — which is
    /// exactly the condition SwiftUI needs to render a selection at all.
    @Test func everyPickerCarriesAnUnrecognizedStoredValue() {
        #expect(SettingsPickerOptions.dateTolerance(including: 3).contains { $0.value == 3 })
        #expect(SettingsPickerOptions.minFileSize(including: 51_200).contains { $0.value == 51_200 })
        #expect(SettingsPickerOptions.overlapThreshold(including: 0.65).contains { $0.value == 0.65 })
        #expect(SettingsPickerOptions.monthlyBudget(including: 3).contains { $0.value == 3 })
        #expect(SettingsPickerOptions.totalBudget(including: 7.5).contains { $0.value == 7.5 })
    }

    /// The extra row is *added*, never substituted: the count grows by one and every original
    /// option survives. Coercing the stored value onto a neighbour would be the same data loss the
    /// blank picker caused, just one click earlier.
    @Test func theStoredValueIsAddedRatherThanReplacingAnOfferedOption() {
        let widened = SettingsPickerOptions.dateTolerance(including: 3)
        #expect(widened.count == 6)
        #expect(widened.map(\.value) == [0, 1, 2, 3, 5, 60])
    }

    /// Inserted in value order, so the menu still reads as an ascending scale rather than dumping
    /// the odd value at the end.
    @Test func theExtraRowIsSortedIntoPlace() {
        #expect(SettingsPickerOptions.overlapThreshold(including: 0.65).map(\.value)
            == [0.5, 0.6, 0.65, 0.7, 0.8, 0.9])
        // Below every option…
        #expect(SettingsPickerOptions.overlapThreshold(including: 0.1).map(\.value).first == 0.1)
        // …and above every option.
        #expect(SettingsPickerOptions.totalBudget(including: 500).map(\.value).last == 500)
    }

    /// The extra row is labeled by the same formatter as its neighbours, so the menu speaks one
    /// vocabulary. A row reading "3.0" next to "2 seconds" would announce the value as a glitch
    /// rather than as a setting.
    @Test func theExtraRowUsesTheSameVocabularyAsItsNeighbours() {
        #expect(SettingsPickerOptions.dateTolerance(including: 3).first { $0.value == 3 }?.label == "3 seconds")
        #expect(SettingsPickerOptions.dateTolerance(including: 120).first { $0.value == 120 }?.label == "2 minutes")
        #expect(SettingsPickerOptions.minFileSize(including: 51_200).first { $0.value == 51_200 }?.label == "50 KB")
        #expect(SettingsPickerOptions.minFileSize(including: 500).first { $0.value == 500 }?.label == "500 bytes")
        #expect(SettingsPickerOptions.overlapThreshold(including: 0.65).first { $0.value == 0.65 }?.label == "65%")
        #expect(SettingsPickerOptions.monthlyBudget(including: 3).first { $0.value == 3 }?.label == "$3")
        #expect(SettingsPickerOptions.totalBudget(including: 500).first { $0.value == 500 }?.label == "$500")
    }

    /// `Picker` keys its rows by tag, so two rows sharing a value would collide — the widening
    /// must never fire for a value the list already offers, including the zero/"off" sentinels.
    @Test func aRecognizedValueNeverProducesADuplicateRow() {
        for stored in [0.0, 1, 2, 5, 60] {
            let rows = SettingsPickerOptions.dateTolerance(including: stored)
            #expect(rows.count == 5)
            #expect(Set(rows.map(\.value)).count == rows.count)
        }
        #expect(SettingsPickerOptions.monthlyBudget(including: 0).count == 6)
        #expect(SettingsPickerOptions.minFileSize(including: 0).count == 4)
    }

    // MARK: - Labels

    /// A value can arrive from `defaults write`, which will happily store a huge or non-finite
    /// number. The label must not trap trying to shorten it.
    @Test func hostileStoredValuesStillProduceARow() {
        for stored in [1e300, -5, Double.nan, .infinity] {
            let rows = SettingsPickerOptions.monthlyBudget(including: stored)
            // NaN compares false against everything, so it lands at the end rather than in order —
            // still present, which is all that matters for the picker to show something.
            #expect(rows.contains { $0.value == stored || ($0.value.isNaN && stored.isNaN) })
            #expect(rows.allSatisfy { !$0.label.isEmpty })
        }
    }

    /// The ".0" tail is trimmed, but a genuinely fractional value keeps its fraction.
    @Test func trimmedDropsOnlyAPointlessDecimalTail() {
        #expect(SettingsPickerOptions.trimmed(3) == "3")
        #expect(SettingsPickerOptions.trimmed(2.5) == "2.5")
        #expect(SettingsPickerOptions.trimmed(0) == "0")
    }

    /// 0.6 is not exactly representable, so the percent label rounds before trimming — otherwise
    /// the perfectly ordinary 60% row would read "60.00000000000001%".
    @Test func percentLabelSurvivesBinaryFloatingPoint() {
        #expect(SettingsPickerOptions.percentLabel(0.6) == "60%")
        #expect(SettingsPickerOptions.percentLabel(0.07) == "7%")
        #expect(SettingsPickerOptions.percentLabel(0.655) == "65.5%")
    }
}
