import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// **The bar's label preference, as a persisted fact.** `PaneBarLabelMode` is stored as a raw string
/// under one `UserDefaults` key, so three literals decide whether a preference someone set survives
/// the next launch: the key, and the two raw values. Nothing pinned any of them, and nothing asked
/// what a *stored* value this build does not recognise does.
///
/// **Pinned end to end rather than against the constants.** Every write below uses the literal
/// strings — `"paneBarLabelMode"`, `"iconAndText"`, `"iconOnly"` — and the claim is made about what
/// the header then DRAWS. That is what makes it a persistence test: renaming the key or a case makes
/// the header stop responding to the string on disk, which is exactly the regression (everyone who
/// chose Icon Only silently gets titles back), and comparing `PaneBar.labelModeKey` against itself
/// would not see it. The value assertions are kept as well, because they name the broken literal
/// when a render assertion fails.
///
/// `.machinePinned(.pixelSampling)` — it reads pixels back out of a live renderer, like
/// `PaneBarLadderTests`.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneBarLabelModeKeyTests {

    /// The persisted spellings. Written out rather than referenced, on purpose — see the suite note.
    private static let key = "paneBarLabelMode"
    private static let titled = "iconAndText"
    private static let plain = "iconOnly"

    private static func header() -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive",
                                    imageName: "icloud-logo", path: "/Users/test/iCloud",
                                    type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onCollapse: nil,
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
    }

    /// Renders the header against a **throwaway defaults suite** carrying `stored` (or nothing) under
    /// the label-mode key.
    ///
    /// The suite is not a nicety: `@AppStorage` reads `UserDefaults.standard` otherwise — the pane
    /// bar preferences **on the machine running the tests**, in a domain shared with the owner's
    /// other projects. `PaneBarCustomizeSheetTests` injects one for the same reason, and the
    /// arrangement is seeded here for the same reason it is there: a developer who had rearranged
    /// their own bar would otherwise render a different bar from CI's.
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

    /// The three strings, so a rename fails with the spelling in the message rather than only as a
    /// render that stopped responding.
    @Test func theStoredSpellingsAreTheOnesOnDisk() {
        #expect(PaneBar.labelModeKey == Self.key)
        #expect(PaneBarLabelMode.iconAndText.rawValue == Self.titled)
        #expect(PaneBarLabelMode.iconOnly.rawValue == Self.plain)
        // Two cases, and the absence of a third is a decision (`PaneBarLabelMode` says why Text Only
        // is not there). A new case is fine — it just has to be a considered one, and a persisted
        // enum growing a case silently is how a stored value stops round-tripping.
        #expect(PaneBarLabelMode.allCases.map(\.rawValue) == [Self.titled, Self.plain])
        // The key is its own: sharing a string with the arrangement or the icon size would have one
        // preference overwrite another.
        #expect(Set([PaneBar.labelModeKey, PaneBar.arrangementKey, PaneBar.iconSizeKey,
                     PaneBar.migrationKey]).count == 4)
    }

    // MARK: - The key and the raw values, against what the header draws

    /// **The literals are the ones the header actually reads.** Storing each raw value under the key
    /// — as strings, the way a plist holds them — produces two visibly different bars.
    ///
    /// If the key were renamed, or either raw value were, both writes would be ignored and both
    /// renders would be the default bar: identical, and this fails.
    @Test func theStoredStringDecidesWhetherTheBarDrawsWords() {
        let titled = render(stored: Self.titled)
        let plain = render(stored: Self.plain)
        // The harness control: the same stored value twice is the same bar, so a difference below is
        // the preference and not the renderer.
        #expect(differingPixels(titled, render(stored: Self.titled)) == 0,
                "two identical renders differ — the harness is unstable, so the counts below mean nothing")
        // A word under every pill is a large, unmistakable difference; the whole titled row is drawn
        // or it is not.
        #expect(differingPixels(titled, plain) > 500, """
                the bar renders the same with "\(Self.titled)" and "\(Self.plain)" stored under \
                "\(Self.key)" — the header is not reading that key, or not those values
                """)
    }

    /// **A stored value this build does not recognise falls back to the shipped default**, which is
    /// `iconAndText`. This is the case a hand-edited plist, a downgrade or a removed case produces,
    /// and the alternative — an unrecognised string reading as `iconOnly` — would silently turn the
    /// words off for someone who never asked.
    @Test func anUnknownStoredValueFallsBackToTheShippedDefault() {
        let bogus = render(stored: "iconAndTextAndSomethingElse")
        #expect(differingPixels(bogus, render(stored: Self.titled)) == 0, """
                a stored value this build does not know renders differently from "\(Self.titled)" — \
                the fallback is not the shipped default
                """)
        #expect(differingPixels(bogus, render(stored: Self.plain)) > 500,
                "an unknown stored value renders as Icon Only — it turned the words off by itself")
        // The rule and its fallback answer differently, or the two lines above are one claim made
        // twice: `PaneBarLabelMode(rawValue:)` really does refuse the string.
        #expect(PaneBarLabelMode(rawValue: "iconAndTextAndSomethingElse") == nil)
    }

    /// The fallback and the `@AppStorage` default are the **same** case, read off the header's own
    /// source. Two places name it, and a build where they disagreed would open at one mode and fall
    /// back to the other — a preference that changes when the stored value goes bad.
    ///
    /// A scan, because both are private to `PaneHeader`; the renders above are what prove the
    /// behaviour, and this is what names the second writer if only one of them is changed.
    @Test func bothWritersOfTheDefaultNameTheSameMode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/DashboardViews.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        #expect(code.contains("struct PaneHeader"), "this is not the header — the scan is vacuous")
        #expect(code.contains("@AppStorage(PaneBar.labelModeKey)"),
                "the header no longer stores its label mode under the shared key")
        #expect(code.contains("PaneBarLabelMode.iconAndText.rawValue"),
                "the @AppStorage default is not iconAndText")
        #expect(code.contains("PaneBarLabelMode(rawValue: labelModeRaw) ?? .iconAndText"),
                "the unknown-value fallback is not iconAndText")
    }
}
