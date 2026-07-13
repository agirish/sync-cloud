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

    // MARK: - Dark-mode contrast audit (H6)

    /// WCAG contrast ratio between two relative luminances.
    private func contrast(_ a: Double, _ b: Double) -> Double {
        let (hi, lo) = (max(a, b), min(a, b))
        return (hi + 0.05) / (lo + 0.05)
    }

    // Representative app grounds the tinted provider text sits on: a near-white light surface
    // and the dark bottom-pane surface. WCAG AA for normal text is 4.5:1.
    private let lightGround = ProviderHue.RGB(1.0, 1.0, 1.0)
    private let darkGround = ProviderHue.RGB(0.110, 0.118, 0.133) // ~#1C1E22
    private let aa = 4.5

    @Test func testDarkBrandVariantsClearAAOnDarkGround() {
        // The reason H6 exists: the static light-mode blues (Dropbox/OneDrive/Drive) failed as
        // tinted text in dark mode; the lifted dark variants must clear AA on the dark surface.
        let dg = darkGround.relativeLuminance
        for hue in ProviderHue.allCases where hue.brand != nil {
            let ratio = contrast(hue.brand!.dark.relativeLuminance, dg)
            #expect(ratio >= aa, "\(hue) dark tint only \(ratio) on the dark surface")
        }
    }

    @Test func testLightBrandVariantsUnchanged() {
        // H6 is a dark-mode audit — the shipped H2 light hexes must NOT be re-tuned. Pin them so
        // a future dark-mode tweak that also touches the light column trips here.
        #expect(ProviderHue.iCloud.brand!.light == .init(0.231, 0.612, 1.0))
        #expect(ProviderHue.dropbox.brand!.light == .init(0.0, 0.380, 1.0))
        #expect(ProviderHue.googleDrive.brand!.light == .init(0.118, 0.639, 0.384))
        #expect(ProviderHue.oneDrive.brand!.light == .init(0.012, 0.392, 0.722))
        #expect(ProviderHue.box.brand!.light == .init(0.141, 0.525, 0.988))
    }

    @Test func testDarkVariantsAreLiftedFromLight() {
        // Each dark variant is a lighter (higher-luminance) lift of its light hue — the fix is
        // "brighten for dark ground", never a hue swap.
        for hue in ProviderHue.allCases where hue.brand != nil {
            let b = hue.brand!
            #expect(b.dark.relativeLuminance > b.light.relativeLuminance, "\(hue) dark is not lifted")
        }
    }

    @Test func testDarkBluesStayDistinct() {
        // iCloud vs Dropbox must not collapse into one blue in dark mode either.
        #expect(ProviderHue.iCloud.brand!.dark != ProviderHue.dropbox.brand!.dark)
    }
}
