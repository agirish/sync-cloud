import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// Card colors as the panel draws them: the shades, a card's title bar with and without one, and
/// its title's menu, and the Color choice.
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

    // MARK: The title's menu

    static func titleMenu(folded: Bool = false, allFolded: Bool = false, toggle: @escaping () -> Void = {},
                          toggleAll: @escaping () -> Void = {}, color: (() -> Void)? = {}) -> NSMenu {
        let menu = NSHostingMenu(rootView: VaultCardTitleMenu(isFolded: folded, allFolded: allFolded, toggle: toggle,
                                                              toggleAll: toggleAll, color: color))
        menu.update()
        return menu
    }

    /// A submenu shuts whenever the Vault's rows change under the open menu, which Refresh does as
    /// the Vault opens: the colors were in one, and it closed before a color could be picked.
    @Test func theTitlesMenuHasNoSubmenuAndColorOpensTheChoice() throws {
        var opened = 0
        let menu = Self.titleMenu(color: { opened += 1 })
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Collapse", "Collapse All Cards", "Color…"])
        #expect(menu.items.allSatisfy { $0.submenu == nil }, "flat: nothing here can be shut by a change behind it")
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Color…" }))
        #expect(opened == 1)

        let folded = Self.titleMenu(folded: true, allFolded: true)
        #expect(folded.items.prefix(2).map(\.title) == ["Expand", "Expand All Cards"])
        // Other Finds' cards have no color to choose.
        #expect(Self.titleMenu(color: nil).items.map(\.title) == ["Collapse", "Collapse All Cards"])
    }

    // MARK: The Color choice

    static func choice(own: VaultCardColor? = nil, group: VaultCardColor? = .tint(.blue), isOn: Bool = true) -> VaultColorChoice {
        VaultColorChoice(card: .builtIn(.passport), title: "Passports", own: own, group: group == nil ? nil : "travel",
                         groupName: group == nil ? nil : "Travel & Immigration", groupColor: group,
                         others: ["Visas"], isOn: isOn)
    }

    static let popoverSize = CGSize(width: VaultColorPopover.width, height: 210)

    static func popover(_ choice: VaultColorChoice, pickCard: @escaping (VaultCardColor?) -> Void = { _ in },
                        pickGroup: @escaping (VaultCardColor) -> Void = { _ in }, turnOn: @escaping () -> Void = {}) -> some View {
        VaultColorPopover(choice: choice, accent: .gray, pickCard: pickCard, pickGroup: pickGroup, turnOn: turnOn)
            .frame(width: popoverSize.width, height: popoverSize.height, alignment: .topLeading)
            .background(Color.white)
    }

    static func shade(_ tint: VaultTint) -> Color {
        let parts = VaultTintPalette.rgb(tint, dark: false)
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue)
    }

    /// The rows of pixels a tint's swatches are drawn on, top to bottom, as (first, last) per run.
    static func rows(of tint: VaultTint, in rep: NSBitmapImageRep) throws -> [(first: Int, last: Int)] {
        let target = try #require(NSColor(shade(tint)).usingColorSpace(.sRGB))
        var runs: [(first: Int, last: Int)] = []
        for y in 0..<rep.pixelsHigh {
            let hit = (0..<rep.pixelsWide).contains { x in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return max(abs(c.redComponent - target.redComponent), abs(c.greenComponent - target.greenComponent),
                           abs(c.blueComponent - target.blueComponent)) < 0.02
            }
            guard hit else { continue }
            if let last = runs.last, last.last == y - 1 { runs[runs.count - 1].last = y } else { runs.append((y, y)) }
        }
        return runs
    }

    @Test func theCardAndItsGroupEachHaveARowOfEveryColor() throws {
        let rep = try renderInSRGBWindow(Self.popover(Self.choice()), size: Self.popoverSize, scheme: .light)
        for tint in VaultTint.allCases {
            #expect(try Self.rows(of: tint, in: rep).count == 2, "\(tint): one swatch for the card, one for its group")
        }
        // A card listed under no group has only its own row.
        let alone = try renderInSRGBWindow(Self.popover(Self.choice(group: nil)), size: Self.popoverSize, scheme: .light)
        #expect(try Self.rows(of: .teal, in: alone).count == 1)
    }

    @Test func theChosenColorIsRingedInItsOwnRowAndNotInTheOther() throws {
        // Following its group, nothing in the card's row is ringed; the group's blue is.
        let follows = try renderInSRGBWindow(Self.popover(Self.choice()), size: Self.popoverSize, scheme: .light)
        let own = try renderInSRGBWindow(Self.popover(Self.choice(own: .tint(.plum))), size: Self.popoverSize, scheme: .light)
        let rows = try Self.rows(of: .plum, in: follows)
        #expect(rows.count == 2)
        // A row's band: its swatches and the ring round one, which reaches a little past them.
        func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, row: Int) -> Int {
            var n = 0
            for y in max(0, rows[row].first - 10)...min(a.pixelsHigh - 1, rows[row].last + 10) {
                for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { n += 1 }
            }
            return n
        }
        #expect(differing(follows, own, row: 0) > 100, "the card's row: a ring round plum")
        #expect(differing(follows, own, row: 1) == 0, "the group's row keeps its ring where it was")

        let rose = try renderInSRGBWindow(Self.popover(Self.choice(group: .tint(.rose))), size: Self.popoverSize, scheme: .light)
        #expect(differing(follows, rose, row: 1) > 100, "the group's ring moved to rose")
        #expect(differing(follows, rose, row: 0) == 0, "and the card's row did not change")
    }

    @Test func aClickOnASwatchSetsThatRowsColorAndNoOther() async throws {
        var card: [VaultCardColor?] = [], group: [VaultCardColor] = []
        let view = Self.popover(Self.choice(), pickCard: { card.append($0) }, pickGroup: { group.append($0) })
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: Self.popoverSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Ordered in, as a click needs; never made key (`clickDown`).
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let rep = try snapshot(host)
        let scale = CGFloat(rep.pixelsHigh) / Self.popoverSize.height
        let rows = try Self.rows(of: .clay, in: rep)
        #expect(rows.count == 2)
        // Clay is the fifth swatch, Rose the sixth: by the row's own numbers.
        func x(_ index: CGFloat) -> CGFloat { 14 + index * (VaultColorPopover.swatch + VaultColorPopover.gap) + VaultColorPopover.swatch / 2 }
        func y(_ run: (first: Int, last: Int)) -> CGFloat {
            let fromTop = CGFloat(run.first + run.last) / 2 / scale
            return host.isFlipped ? fromTop : Self.popoverSize.height - fromTop
        }
        click(host.convert(NSPoint(x: x(4), y: y(rows[0])), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(card == [.tint(.clay)], "the upper row is the card's: \(card)")
        #expect(group.isEmpty)
        click(host.convert(NSPoint(x: x(5), y: y(rows[1])), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(group == [.tint(.rose)], "the lower row is the group's: \(group)")
        #expect(card == [.tint(.clay)], "and it left the card's alone")
    }

    @Test func whileColorsAreOffTheChoiceOnlyOffersToTurnThemOn() throws {
        let off = try renderInSRGBWindow(Self.popover(Self.choice(own: .tint(.plum), isOn: false)), size: Self.popoverSize, scheme: .light)
        for tint in VaultTint.allCases {
            #expect(try Self.rows(of: tint, in: off).isEmpty, "no \(tint) swatch while colors are off")
        }
        let on = try renderInSRGBWindow(Self.popover(Self.choice(own: .tint(.plum))), size: Self.popoverSize, scheme: .light)
        #expect(differingPixels(off, on) > 2000)
    }
}
