import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// Card colors as the panel draws them: the shades, a card's title bar with and without one, and
/// the Color menu's lines.
@MainActor
@Suite struct VaultCardColorsTests {
    // MARK: The shades

    @Test func aShadeIsItsHueAtHalfSaturationDarkerOnLightThanOnDark() {
        // Blue is hue 220: at 42% lightness, (0.21, 0.35, 0.63).
        let light = VaultTintPalette.rgb(.blue, dark: false)
        #expect(abs(light.red - 0.21) < 0.001 && abs(light.green - 0.35) < 0.001 && abs(light.blue - 0.63) < 0.001,
                "\(light)")
        // At 68% on dark: p = 0.52, q = 0.84.
        let dark = VaultTintPalette.rgb(.blue, dark: true)
        #expect(abs(dark.red - 0.52) < 0.001 && abs(dark.blue - 0.84) < 0.001, "\(dark)")
        for tint in VaultTint.allCases {
            let (l, d) = (VaultTintPalette.rgb(tint, dark: false), VaultTintPalette.rgb(tint, dark: true))
            #expect(l.red + l.green + l.blue < d.red + d.green + d.blue, "\(tint) is lighter on a dark ground")
        }
    }

    @Test func noTwoShadesAreAlike() {
        for dark in [false, true] {
            let shades = VaultTint.allCases.map { VaultTintPalette.rgb($0, dark: dark) }
            for (i, a) in shades.enumerated() {
                for b in shades.dropFirst(i + 1) {
                    let apart = abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue)
                    #expect(apart > 0.12, "two shades \(apart) apart would not be told from each other")
                }
            }
        }
    }

    // MARK: A card's title bar

    static let size = CGSize(width: 300, height: 34)

    static func header(tint: VaultTint?, folded: Bool = false, washes: Bool = true) -> some View {
        VaultCardHeader(title: "Passports", symbol: "globe", count: 3, isFolded: folded, foldedSummary: "2 people",
                        tint: tint, accent: .gray, washes: washes)
            .frame(width: size.width, alignment: .leading)
            .background(Color.white)
    }

    /// The color of the bar's ground, read from its empty right end, where no word is drawn.
    static func ground(_ view: some View, folded: Bool = false, y: CGFloat = 0.5) throws -> NSColor {
        let size = CGSize(width: Self.size.width, height: folded ? 38 : Self.size.height)
        let rep = try renderInSRGBWindow(view, size: size, scheme: .light)
        return try #require(rep.colorAt(x: rep.pixelsWide - (folded ? rep.pixelsWide / 3 : 12),
                                        y: Int(CGFloat(rep.pixelsHigh) * y)))
    }

    @Test func aTintWashesTheBarAndNoTintLeavesItAsItWas() throws {
        let plain = try Self.ground(Self.header(tint: nil))
        #expect(abs(plain.redComponent - plain.blueComponent) < 0.01 && plain.redComponent > 0.98,
                "no tint: the white ground shows, \(plain)")
        let blue = try Self.ground(Self.header(tint: .blue))
        #expect(blue.blueComponent - blue.redComponent > 0.03, "a blue wash is bluer than it is red, \(blue)")
        #expect(blue.redComponent > 0.8, "and soft: the title over it stays readable, \(blue)")
        let rose = try Self.ground(Self.header(tint: .rose))
        #expect(rose.redComponent - rose.greenComponent > 0.03, "a rose wash is redder than it is green, \(rose)")
    }

    @Test func withoutAWashOnlyTheSymbolCarriesTheColor() throws {
        let ground = try Self.ground(Self.header(tint: .blue, washes: false))
        #expect(abs(ground.redComponent - ground.blueComponent) < 0.01 && ground.redComponent > 0.98, "\(ground)")
        // The symbol's chip still differs from the untinted one.
        let size = Self.size
        let tinted = try renderInSRGBWindow(Self.header(tint: .blue, washes: false), size: size, scheme: .light)
        let plain = try renderInSRGBWindow(Self.header(tint: nil, washes: false), size: size, scheme: .light)
        #expect(differingPixels(tinted, plain) > 40, "the symbol and its chip are drawn in the tint")
    }

    @Test func aFoldedCardIsWashedToItsFoot() throws {
        // Open, the bar ends in a hairline and the rows follow; folded, the bar is the whole card.
        let foot = try Self.ground(Self.header(tint: .blue, folded: true), folded: true, y: 0.93)
        #expect(foot.blueComponent - foot.redComponent > 0.03, "\(foot)")
    }

    // MARK: The Color menu

    static func menu(own: VaultCardColor?, isOn: Bool = true, pick: @escaping (VaultCardColor?) -> Void = { _ in },
                     turnOn: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSHostingMenu(rootView: VaultColorMenu(own: own, groupName: "Travel & Immigration", isOn: isOn,
                                                          pick: pick, turnOn: turnOn))
        menu.update()
        return menu
    }

    @Test func theMenuOffersTheGroupsColorEachTintAndNone() throws {
        let menu = Self.menu(own: nil)
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Same as Travel & Immigration", "Blue", "Teal", "Green", "Olive", "Clay", "Rose",
                                       "Plum", "Violet", "No Color"], "\(items.map(\.title))")
        #expect(items.filter { $0.state == .on }.map(\.title) == ["Same as Travel & Immigration"])
        #expect(items.filter { $0.image != nil }.count == 8, "each tint shows its swatch")

        let own = Self.menu(own: .tint(.plum)).items.filter { $0.state == .on }.map(\.title)
        #expect(own == ["Plum"])
        #expect(Self.menu(own: .plain).items.filter { $0.state == .on }.map(\.title) == ["No Color"])
    }

    @Test func choosingALineSetsThatColor() throws {
        var picked: [VaultCardColor?] = []
        let menu = Self.menu(own: .tint(.plum), pick: { picked.append($0) })
        for title in ["Rose", "No Color", "Same as Travel & Immigration"] {
            menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == title }))
        }
        #expect(picked == [.tint(.rose), .plain, nil])
    }

    @Test func whileColorsAreOffTheMenuOnlyOffersToTurnThemOn() throws {
        var turnedOn = 0
        let menu = Self.menu(own: .tint(.plum), isOn: false, turnOn: { turnedOn += 1 })
        #expect(menu.items.map(\.title) == ["Card Colors Are Off", "Turn On Card Colors"])
        #expect(menu.items.first?.isEnabled == false)
        menu.performActionForItem(at: 1)
        #expect(turnedOn == 1)
    }
}
