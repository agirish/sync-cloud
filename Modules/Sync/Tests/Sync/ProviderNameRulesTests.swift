import Testing
import Foundation
@testable import Sync

/// Pins `ProviderNameRules`: the near-name normalization the diff engine matches invisible
/// renames with, and the per-provider destination-name validity/sanitization the pre-write
/// check offers alternatives from.
@Suite struct ProviderNameRulesTests {

    // MARK: - Near-name normalization

    @Test func testNormalizedComponentStripsInvisibleAffixes() {
        #expect(ProviderNameRules.normalizedComponent("Swimming ") == "Swimming")
        #expect(ProviderNameRules.normalizedComponent("  Swimming") == "Swimming")
        #expect(ProviderNameRules.normalizedComponent("Notes..") == "Notes")
        #expect(ProviderNameRules.normalizedComponent("name . ") == "name")
        #expect(ProviderNameRules.normalizedComponent("plain") == "plain")
        // Interior whitespace and dots are real, visible name content.
        #expect(ProviderNameRules.normalizedComponent("a b.c") == "a b.c")
    }

    @Test func testNormalizedComponentUnifiesUnicodeForms() {
        let nfc = "Café"                                          // precomposed é
        let nfd = "Cafe\u{0301}"                                  // e + combining acute
        #expect(Array(nfc.utf8) != Array(nfd.utf8))               // distinct bytes on disk
        #expect(nfc == nfd)                                       // but Swift equality is canonical
        let normalized = ProviderNameRules.normalizedComponent(nfd)
        #expect(Array(normalized.utf8) == Array(nfc.utf8))        // keys settle on the NFC bytes
    }

    @Test func testNormalizedComponentKeepsAllInvisibleNamesDistinct() {
        // Names that would trim to nothing keep their original form: collapsing " " and "."
        // onto one empty key would pair unrelated pathological names.
        #expect(ProviderNameRules.normalizedComponent(" ") == " ")
        #expect(ProviderNameRules.normalizedComponent(".") == ".")
        #expect(ProviderNameRules.normalizedComponent(" ") != ProviderNameRules.normalizedComponent("."))
    }

    @Test func testNearNameKeyNormalizesEveryComponentAndFoldsCaseOnRequest() {
        #expect(ProviderNameRules.nearNameKey(forRelativePath: "Fitness /Swimming .", foldCase: false) == "Fitness/Swimming")
        #expect(ProviderNameRules.nearNameKey(forRelativePath: "Fitness/SWIMMING ", foldCase: true) == "fitness/swimming")
        #expect(ProviderNameRules.nearNameKey(forRelativePath: "Fitness/SWIMMING ", foldCase: false) == "Fitness/SWIMMING")
    }

    @Test func testNameDifferenceDetailNamesTheCulprit() {
        #expect(ProviderNameRules.nameDifferenceDetail("Swimming ", "Swimming") == "a trailing space")
        #expect(ProviderNameRules.nameDifferenceDetail(" Swimming", "Swimming") == "a leading space")
        #expect(ProviderNameRules.nameDifferenceDetail("Notes.", "Notes") == "a trailing period")
        #expect(ProviderNameRules.nameDifferenceDetail("Cafe\u{0301}", "Café") == "same name in a different Unicode form")
        #expect(ProviderNameRules.nameDifferenceDetail(" Swimming.", "Swimming ") == "invisible name characters")
    }

    @Test func testNameConflictDescriptionQuotesBothSpellings() {
        let description = ProviderNameRules.nameConflictDescription(
            leftName: "Swimming ", leftProvider: "iCloud",
            rightName: "Swimming", rightProvider: "Dropbox"
        )
        #expect(description.contains("\"Swimming \" (iCloud)"))
        #expect(description.contains("\"Swimming\" (Dropbox)"))
        #expect(description.contains("trailing space"))
    }

    // MARK: - Dropbox validity

    @Test func testDropboxRejectsTrailingSpaceAndPeriod() {
        let space = ProviderNameRules.violation(name: "Swimming ", provider: .dropBox)
        #expect(space != nil)
        #expect(space?.reason.contains("space") == true)
        #expect(space?.sanitizedName == "Swimming")

        let period = ProviderNameRules.violation(name: "Notes.", provider: .dropBox)
        #expect(period != nil)
        #expect(period?.reason.contains("period") == true)
        #expect(period?.sanitizedName == "Notes")
    }

    @Test func testDropboxAcceptsOrdinaryAndEdgeValidNames() {
        #expect(ProviderNameRules.violation(name: "Swimming", provider: .dropBox) == nil)
        #expect(ProviderNameRules.violation(name: "report (final) v2.txt", provider: .dropBox) == nil)
        // Dropbox has no character or reserved-name rules beyond the affix ones.
        #expect(ProviderNameRules.violation(name: "CON", provider: .dropBox) == nil)
        #expect(ProviderNameRules.violation(name: "a|b", provider: .dropBox) == nil)
    }

    // MARK: - OneDrive validity

    @Test func testOneDriveRejectsForbiddenCharacters() {
        for character in ["\"", "*", ":", "<", ">", "?", "\\", "|"] {
            let violation = ProviderNameRules.violation(name: "a\(character)b", provider: .oneDrive)
            #expect(violation != nil, "expected \(character) to be rejected")
            #expect(violation?.sanitizedName == "a-b")
        }
    }

    @Test func testOneDriveRejectsAffixSpacesAndTrailingPeriod() {
        #expect(ProviderNameRules.violation(name: " Swimming", provider: .oneDrive) != nil)
        #expect(ProviderNameRules.violation(name: "Swimming ", provider: .oneDrive) != nil)
        #expect(ProviderNameRules.violation(name: "Notes.", provider: .oneDrive) != nil)
    }

    @Test func testOneDriveRejectsReservedDeviceNames() {
        for name in ["CON", "con", "PRN", "AUX", "NUL", "COM1", "LPT9", "con.txt"] {
            #expect(ProviderNameRules.violation(name: name, provider: .oneDrive) != nil, "expected \(name) to be rejected")
        }
        // Reserved-lookalikes with more characters are fine.
        #expect(ProviderNameRules.violation(name: "CONSOLE", provider: .oneDrive) == nil)
        #expect(ProviderNameRules.violation(name: "COM10", provider: .oneDrive) == nil)
    }

    // MARK: - Permissive providers

    @Test func testICloudAndGoogleDriveAcceptEverything() {
        for provider in [CloudProvider.ProviderType.iCloud, .googleDrive] {
            #expect(ProviderNameRules.violation(name: "Swimming ", provider: provider) == nil)
            #expect(ProviderNameRules.violation(name: "Notes.", provider: provider) == nil)
            #expect(ProviderNameRules.violation(name: "CON", provider: provider) == nil)
        }
    }

    // MARK: - Sanitization

    @Test func testSanitizedSettlesCombinedAffixes() {
        #expect(ProviderNameRules.sanitized(name: "Swimming ", for: .dropBox) == "Swimming")
        #expect(ProviderNameRules.sanitized(name: "name . ", for: .dropBox) == "name")
        #expect(ProviderNameRules.sanitized(name: "   ", for: .dropBox) == "untitled")
        #expect(ProviderNameRules.sanitized(name: "CON", for: .oneDrive) == "CON-1")
        #expect(ProviderNameRules.sanitized(name: "a:b.txt", for: .oneDrive) == "a-b.txt")
    }

    @Test func testSanitizedRelativePathTouchesOnlyInvalidComponents() {
        #expect(
            ProviderNameRules.sanitizedRelativePath("Fitness/Swimming /log.txt", for: .dropBox)
                == "Fitness/Swimming/log.txt"
        )
        #expect(
            ProviderNameRules.sanitizedRelativePath("Fitness/Swimming/log.txt", for: .dropBox)
                == "Fitness/Swimming/log.txt"
        )
    }

    @Test func testViolationInRelativePathReportsFirstOffendingComponent() {
        let violation = ProviderNameRules.violation(inRelativePath: "Fitness/Swimming /log.txt", for: .dropBox)
        #expect(violation?.componentName == "Swimming ")
        #expect(ProviderNameRules.violation(inRelativePath: "Fitness/Swimming/log.txt", for: .dropBox) == nil)
    }
}
