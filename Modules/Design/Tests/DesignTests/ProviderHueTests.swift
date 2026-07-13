import Testing
import SwiftUI
@testable import Design

/// UX H2: provider-identity elements are tinted by classifying the provider *display name*.
/// These pins guard the substring-order traps ("iCloud Drive" and "OneDrive" both contain
/// "drive"; "Dropbox" contains "box") and keep the brand hues visibly distinct, so a reordered
/// check or a collapsed color fails here instead of painting both panes the same blue again.
@Suite struct ProviderHueTests {

    // MARK: - Classification

    @Test func testICloudWinsOverDriveSubstring() {
        // "iCloud Drive" contains "drive" — iCloud must be checked first.
        #expect(ProviderHue.classify("iCloud Drive") == .iCloud)
        #expect(ProviderHue.classify("iCloud") == .iCloud)
    }

    @Test func testDropboxWinsOverBoxSubstring() {
        // "Dropbox" contains "box" — Dropbox must be checked before Box.
        #expect(ProviderHue.classify("Dropbox") == .dropbox)
        #expect(ProviderHue.classify("My Dropbox") == .dropbox)
    }

    @Test func testOneDriveWinsOverDriveSubstring() {
        // "OneDrive" contains "drive" — OneDrive must be checked before Drive.
        #expect(ProviderHue.classify("OneDrive") == .oneDrive)
        #expect(ProviderHue.classify("OneDrive — Work") == .oneDrive)
    }

    @Test func testGoogleDriveAndBareDriveClassifyAsDrive() {
        #expect(ProviderHue.classify("Google Drive") == .googleDrive)
        #expect(ProviderHue.classify("Drive") == .googleDrive)
    }

    @Test func testBoxClassifies() {
        #expect(ProviderHue.classify("Box") == .box)
    }

    @Test func testClassificationIsCaseInsensitive() {
        #expect(ProviderHue.classify("DROPBOX") == .dropbox)
        #expect(ProviderHue.classify("icloud drive") == .iCloud)
        #expect(ProviderHue.classify("GOOGLE DRIVE") == .googleDrive)
    }

    @Test func testUnrecognizedNamesFallBackToNeutral() {
        // Custom/local providers keep the user's app accent instead of a made-up brand hue.
        #expect(ProviderHue.classify("NAS") == .neutral)
        #expect(ProviderHue.classify("Backup") == .neutral)
        #expect(ProviderHue.classify("") == .neutral)
    }

    // MARK: - Hues

    @Test func testBrandTintsArePairwiseDistinct() {
        // The whole point of H2: every branded hue must differ from every other, and the two
        // blues (iCloud vs Dropbox) especially must not collapse back into one.
        let branded: [ProviderHue] = [.iCloud, .dropbox, .googleDrive, .oneDrive, .box]
        for (i, a) in branded.enumerated() {
            for b in branded[(i + 1)...] {
                #expect(a.tint != b.tint, "\(a) and \(b) share a tint")
            }
        }
    }

    @Test func testNeutralFollowsTheAppAccent() {
        #expect(ProviderHue.neutral.tint == Color.accentColor)
    }

    @Test func testSoftVariantIsTheTintAtChipOpacity() {
        // Mirrors the 0.12 soft-chip fill StatusBadge established.
        for hue in ProviderHue.allCases {
            #expect(hue.soft == hue.tint.opacity(0.12))
        }
    }
}
