import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The bar's label preference as a persisted fact. `PaneBarLabelMode` is stored as a raw string
/// under one `UserDefaults` key, so three literals decide whether the preference survives a launch:
/// the key and the two raw values. Also pins what an unrecognised stored value does.
///
/// Pinned end to end: every write uses the literal strings, and the claim is about what the header
/// then draws. Renaming the key or a case makes the header ignore the string on disk, and everyone
/// who chose Icon Only silently gets titles back; comparing `PaneBar.labelModeKey` with itself
/// can't see that. Machine-pinned, because it reads pixels back from a live renderer.
@MainActor
@Suite(.serialized) struct PaneBarLabelModeKeyTests {

    /// The persisted spellings, written out rather than referenced (see the suite note).
    private static let key = "paneBarLabelMode"
    private static let titled = "iconAndText"
    private static let plain = "iconOnly"

    private static func header() -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive",
                                    imageName: "icloud-logo", rootPath: "/Users/test/iCloud",
                                    type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onCollapse: nil,
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
    }

    /// Renders the header against a throwaway defaults suite holding `stored` (or nothing) under the
    /// label-mode key. Otherwise `@AppStorage` reads `UserDefaults.standard`, the preferences on the
    /// machine running the tests; the arrangement is seeded so a rearranged local bar can't differ
    /// from CI's.
    private func render(stored: String?, width: CGFloat = 900) -> NSBitmapImageRep {
        let defaults = ScratchDefaults("PaneBarLabelModeKeyTests")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        if let stored { defaults.set(stored, forKey: Self.key) }
        let subject = Self.header()
            .defaultAppStorage(defaults)
            .environment(\.appFontScale, 1)
            .frame(width: width, height: 90, alignment: .topLeading)
            .background(Color(red: 0.95, green: 0.95, blue: 0.96))
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 90)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 { differing += 1 }
            }
        }
        return differing
    }

    // MARK: - The literals, named

    /// The three strings, so a rename fails naming the spelling, not only as a render that stopped
    /// responding.
    @Test func theStoredSpellingsAreTheOnesOnDisk() {
        #expect(PaneBar.labelModeKey == Self.key)
        #expect(PaneBarLabelMode.iconAndText.rawValue == Self.titled)
        #expect(PaneBarLabelMode.iconOnly.rawValue == Self.plain)
        // Two cases; `PaneBarLabelMode` says why there is no Text Only. A new case must be a
        // considered one, since a persisted enum that grows silently stops round-tripping.
        #expect(PaneBarLabelMode.allCases.map(\.rawValue) == [Self.titled, Self.plain])
        // The keys are distinct, or one preference would overwrite another.
        #expect(Set([PaneBar.labelModeKey, PaneBar.arrangementKey, PaneBar.iconSizeKey,
                     PaneBar.migrationKey]).count == 4)
    }

    // MARK: - The key and the raw values, against what the header draws

    /// The literals are the ones the header reads: each raw value stored as a string under the key
    /// gives a visibly different bar. Rename the key or a raw value and both renders fall back to
    /// the same default, so this fails.
    @Test(.machinePinned(.pixelSampling)) func theStoredStringDecidesWhetherTheBarDrawsWords() {
        let titled = render(stored: Self.titled)
        let plain = render(stored: Self.plain)
        // Harness control: the same stored value twice is the same bar, so a difference below is
        // the preference, not the renderer.
        #expect(differingPixels(titled, render(stored: Self.titled)) == 0,
                "two identical renders differ — the harness is unstable, so the counts below mean nothing")
        // A word under every pill is a large difference: the titled row is drawn or it isn't.
        #expect(differingPixels(titled, plain) > 500, """
                the bar renders the same with "\(Self.titled)" and "\(Self.plain)" stored under \
                "\(Self.key)" — the header is not reading that key, or not those values
                """)
    }

    /// An unrecognised stored value (a hand-edited plist, a downgrade, a removed case) falls back to
    /// the shipped default, `iconAndText`. Reading it as `iconOnly` would turn the words off for
    /// someone who never asked.
    @Test(.machinePinned(.pixelSampling)) func anUnknownStoredValueFallsBackToTheShippedDefault() {
        let bogus = render(stored: "iconAndTextAndSomethingElse")
        #expect(differingPixels(bogus, render(stored: Self.titled)) == 0, """
                a stored value this build does not know renders differently from "\(Self.titled)" — \
                the fallback is not the shipped default
                """)
        #expect(differingPixels(bogus, render(stored: Self.plain)) > 500,
                "an unknown stored value renders as Icon Only — it turned the words off by itself")
        // And `PaneBarLabelMode(rawValue:)` really refuses the string, so the fallback is what ran.
        #expect(PaneBarLabelMode(rawValue: "iconAndTextAndSomethingElse") == nil)
    }

    /// The fallback and the `@AppStorage` default name the same case. If they disagreed, the bar
    /// would open in one mode and switch to the other when the stored value went bad. A source scan
    /// because both are private to `PaneHeader`; it names the second site if only one changes.
    @Test func bothWritersOfTheDefaultNameTheSameMode() throws {
        let code = try DashboardSource.read("DashboardViews.swift")
        #expect(code.contains("struct PaneHeader"), "this is not the header — the scan is vacuous")
        #expect(code.contains("@AppStorage(PaneBar.labelModeKey)"),
                "the header no longer stores its label mode under the shared key")
        #expect(code.contains("PaneBarLabelMode.iconAndText.rawValue"),
                "the @AppStorage default is not iconAndText")
        #expect(code.contains("PaneBarLabelMode(rawValue: labelModeRaw) ?? .iconAndText"),
                "the unknown-value fallback is not iconAndText")
    }
}
