import Testing
import SwiftUI
@testable import Design

/// Provider-identity elements are tinted by classifying the provider's display name. These guard
/// the substring-order traps ("iCloud Drive" and "OneDrive" both contain "drive"; "Dropbox"
/// contains "box") and keep the brand hues distinct, so a reordered check or a collapsed colour
/// fails here instead of painting both panes the same blue.
@Suite struct ProviderHueTests {

    // MARK: - Classification

    /// The substring-order traps, case, and the neutral fallback for custom and local providers,
    /// which keep the user's app accent instead of a made-up brand hue.
    @Test(arguments: [
        ("iCloud Drive", ProviderHue.iCloud), ("iCloud", .iCloud),       // iCloud before "drive"
        ("Dropbox", .dropbox), ("My Dropbox", .dropbox),                 // Dropbox before "box"
        ("OneDrive", .oneDrive), ("OneDrive — Work", .oneDrive),         // OneDrive before "drive"
        ("Google Drive", .googleDrive), ("Drive", .googleDrive),
        ("Box", .box),
        ("DROPBOX", .dropbox), ("icloud drive", .iCloud), ("GOOGLE DRIVE", .googleDrive),
        ("NAS", .neutral), ("Backup", .neutral), ("", .neutral),
    ])
    func testClassification(_ name: String, _ hue: ProviderHue) {
        #expect(ProviderHue.classify(name) == hue)
    }

    // MARK: - Hues

    @Test func testBrandTintsArePairwiseDistinct() {
        // Every branded hue must differ from every other; the two blues (iCloud and Dropbox)
        // especially must not collapse into one.
        let branded: [ProviderHue] = [.iCloud, .dropbox, .googleDrive, .oneDrive, .box]
        for (i, a) in branded.enumerated() {
            for b in branded[(i + 1)...] {
                #expect(a.tint != b.tint, "\(a) and \(b) share a tint")
            }
        }
    }

    /// The hue the user picked, not SwiftUI's `Color.accentColor`, which is the system accent
    /// (`AccentFillScanTests` scans for that).
    @Test func testNeutralFollowsTheAppAccent() {
        #expect(ProviderHue.neutral.tint == LiquidGlassHue.stored().accentColor)
        if LiquidGlassHue.stored() != .none {
            #expect(ProviderHue.neutral.tint != Color.accentColor)
        }
    }

    @Test func testSoftVariantIsTheTintAtChipOpacity() {
        // Mirrors StatusBadge's 0.12 soft-chip fill.
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
        // The light-mode blues (Dropbox, OneDrive, Drive) fail as tinted text in dark mode, so the
        // lifted dark variants must clear AA on the dark surface.
        let dg = darkGround.relativeLuminance
        for hue in ProviderHue.allCases where hue.brand != nil {
            let ratio = contrast(hue.brand!.dark.relativeLuminance, dg)
            #expect(ratio >= aa, "\(hue) dark tint only \(ratio) on the dark surface")
        }
    }

    @Test func testLightBrandVariantsUnchanged() {
        // The light hexes are the brand colours and stay as they are; pinned so a dark-mode tweak
        // that also touches the light column trips here.
        #expect(ProviderHue.iCloud.brand!.light == .init(0.231, 0.612, 1.0))
        #expect(ProviderHue.dropbox.brand!.light == .init(0.0, 0.380, 1.0))
        #expect(ProviderHue.googleDrive.brand!.light == .init(0.118, 0.639, 0.384))
        #expect(ProviderHue.oneDrive.brand!.light == .init(0.012, 0.392, 0.722))
        #expect(ProviderHue.box.brand!.light == .init(0.141, 0.525, 0.988))
    }

    @Test func testDarkVariantsAreLiftedFromLight() {
        // Each dark variant is a lighter (higher-luminance) lift of its light hue: brightened for
        // the dark ground, never a hue swap.
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
