import AppKit
import CryptoKit
import Design
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The whole Vault panel, drawn over a made-up household and read back. Every ID here is made up.
///
/// Set `TEST_RUNNER_VAULT_PANEL_PNG` to a folder when running to keep each render as a PNG there,
/// to look at.
@MainActor
@Suite struct VaultPanelRenderTests {
    static let size = CGSize(width: 1000, height: 620)

    /// A Vault with one ID on each of several cards, unlocked.
    static func rig() async throws -> (model: VaultModel, defaults: UserDefaults, proof: VaultFakeAuthenticator, cleanUp: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-panel-\(UUID().uuidString)")
        let store = VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultFakeKeychain())
        let scratch = TestDefaults()
        // Locked only by closing: a render late in a slow run must not find it timed out.
        scratch.defaults.set(VaultLockSettings.Relock.whenClosed.rawValue, forKey: VaultLockSettings.relockKey)
        let proof = VaultFakeAuthenticator()
        let model = VaultModel(store: store, authenticator: proof, defaults: scratch.defaults,
                               copyToPasteboard: { _ in })
        await model.opened()
        func add(_ title: String, _ value: String, _ category: VaultCategory, _ person: String?) {
            var draft = VaultModel.Draft(title: title, value: value, personID: person, category: category)
            draft.isHousehold = person == nil
            _ = model.add(draft)
        }
        add("Passport", "A38291647", .passport, "anna")
        add("Passport", "C20430432", .passport, "erik")
        add("Visa", "20251234567", .usVisa, "erik")
        add("Social Security number", "123-45-6789", .ssn, "anna")
        add("Blue Harbor PPO member ID", "XEH123456789", .health, "anna")
        add("Bay Water District account", "58210-44719", .utilities, nil)
        add("Harborline Mortgage loan", "0044918853", .loans, nil)
        model.people = [Person(id: "anna", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        await model.unlock()
        return (model, scratch.defaults, proof, { try? FileManager.default.removeItem(at: folder) })
    }

    static func render(_ model: VaultModel, defaults: UserDefaults, name: String, scheme: ColorScheme = .light) throws -> NSBitmapImageRep {
        let panel = VaultCard(model: model, glassHue: .blue, onClose: {}, onOpenSettings: {},
                              onQuickLook: { _ in }, onReveal: { _ in }, onAddPerson: { _, _ in nil },
                              quickLookPath: nil, onCloseQuickLook: {})
            .frame(width: size.width, height: size.height)
            .background(scheme == .dark ? Color.black : Color.white)
            .defaultAppStorage(defaults)
        let rep = try renderInSRGBWindow(panel, size: size, scheme: scheme)
        if let folder = ProcessInfo.processInfo.environment["VAULT_PANEL_PNG"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        return rep
    }

    /// A tint at the title bar's strength over the white a card sits on in this render.
    static func wash(_ tint: VaultTint) -> Color {
        let parts = VaultTintPalette.rgb(tint, dark: false), a = VaultTintPalette.wash(dark: false)
        return Color(.sRGB, red: 1 - (1 - parts.red) * a, green: 1 - (1 - parts.green) * a, blue: 1 - (1 - parts.blue) * a)
    }

    /// A tint at the strength under a card's rows, over the white a card sits on in this render.
    static func bodyWash(_ tint: VaultTint) -> Color {
        let parts = VaultTintPalette.rgb(tint, dark: false), a = VaultTintPalette.bodyWash(dark: false)
        return Color(.sRGB, red: 1 - (1 - parts.red) * a, green: 1 - (1 - parts.green) * a, blue: 1 - (1 - parts.blue) * a)
    }

    /// The whole card is in its color, the rows under a lighter wash than the title.
    @Test func aCardsRowsLieUnderALighterWashOfItsColorAndOffLeavesNone() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        // One wall of cards, so every group's are in this window: the headings take room the
        // last group's cards would need, and colors are what is measured here.
        rig.model.showsGroupHeadings = false
        let on = try Self.render(rig.model, defaults: rig.defaults, name: "body-on")
        var colors = rig.model.colors
        colors.isOn = false
        rig.model.setColors(colors)
        let off = try Self.render(rig.model, defaults: rig.defaults, name: "body-off")
        // A wash this light is close to the greys of the panel's own buttons, so each is counted
        // against the same panel with colors off: what the wash adds is the rows' ground.
        // A one-row card's ground is about 13,000 points square; the count is in pixels, four to a
        // point on this Mac's display and one on the hosted runner's.
        let scale = Double(on.pixelsWide) / Double(Self.size.width)
        for tint in [VaultTint.blue, .violet, .rose, .green] {
            let (washed, plain) = (try pixels(near: Self.bodyWash(tint), in: on), try pixels(near: Self.bodyWash(tint), in: off))
            #expect(Double(washed - plain) > 5_000 * scale * scale, "\(tint) under its cards' rows: \(plain) → \(washed)")
        }
        #expect(VaultTintPalette.bodyWash(dark: false) < VaultTintPalette.wash(dark: false), "lighter than the title's")
        #expect(VaultTintPalette.bodyWash(dark: true) < VaultTintPalette.wash(dark: true))
    }

    /// What differs in the cards' column between a render with one row chosen and a render with
    /// another: the two rows' grounds, apart, the upper first. For each, how bright each render is
    /// over it and how far from grey the second is, on average.
    static func grounds(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> [(count: Int, lightA: Double, lightB: Double, hueB: Double)] {
        var rows: [Int: [(NSColor, NSColor)]] = [:]
        // The cards are the left part; an ID's details, which also change with the choice, the right.
        for y in 0..<a.pixelsHigh {
            for x in 0..<(a.pixelsWide * 6 / 10) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y), p != q else { continue }
                rows[y, default: []].append((p, q))
            }
        }
        // Two runs of rows of pixels with a gap between: one chosen row, then the other.
        var runs: [[Int]] = []
        for y in rows.keys.sorted() {
            if let last = runs.last?.last, y - last < 12 { runs[runs.count - 1].append(y) } else { runs.append([y]) }
        }
        return runs.map { ys in
            let pairs = ys.flatMap { rows[$0] ?? [] }
            func light(_ c: NSColor) -> Double { Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 }
            let n = Double(max(pairs.count, 1))
            return (pairs.count, pairs.map { light($0.0) }.reduce(0, +) / n, pairs.map { light($0.1) }.reduce(0, +) / n,
                    pairs.map { Double(abs($0.1.blueComponent - $0.1.redComponent) + abs($0.1.greenComponent - $0.1.redComponent)) }.reduce(0, +) / n)
        }
    }

    @Test func theChosenRowIsALightLiftOffItsCardAndNotAFillInTheWindowsHue() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        // Passports is the first card and Health & Medical lies under it; the panel always has a row chosen.
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .passport }?.id)
        let upper = try Self.render(rig.model, defaults: rig.defaults, name: "chosen-passport")
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .health }?.id)
        let lower = try Self.render(rig.model, defaults: rig.defaults, name: "chosen-health")
        let grounds = try Self.grounds(upper, lower)
        #expect(grounds.count == 2, "two rows changed, the one let go and the one chosen: \(grounds.map(\.count))")
        let (passport, health) = (try #require(grounds.first), try #require(grounds.last))
        #expect(passport.count > 3000 && health.count > 3000)
        #expect(health.lightB > health.lightA + 0.015, "chosen, the rose card's row is lighter than the card: \(health.lightA) → \(health.lightB)")
        #expect(passport.lightA > passport.lightB + 0.015, "and the row let go is back to its card's blue: \(passport.lightB) → \(passport.lightA)")
        // The window's hue in this render is blue: a fill in it would be far from grey.
        #expect(health.hueB < 0.02, "the lift has no color of its own: \(health.hueB)")
    }

    /// White would not show on a card with no color: there the chosen row is a quiet grey.
    @Test func onACardWithNoColorTheChosenRowIsAQuietGreyAndStillNotTheWindowsHue() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        var colors = rig.model.colors
        colors.isOn = false
        rig.model.setColors(colors)
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .passport }?.id)
        let upper = try Self.render(rig.model, defaults: rig.defaults, name: "plain-passport")
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .health }?.id)
        let lower = try Self.render(rig.model, defaults: rig.defaults, name: "plain-health")
        let grounds = try Self.grounds(upper, lower)
        #expect(grounds.count == 2, "\(grounds.map(\.count))")
        let health = try #require(grounds.last)
        #expect(health.count > 3000)
        #expect(health.lightB < health.lightA - 0.03, "seen against the plain card: \(health.lightA) → \(health.lightB)")
        #expect(health.hueB < 0.02, "grey, with no color of its own: \(health.hueB)")
    }

    @Test func onADarkCardTheChosenRowIsLiftedLighterToo() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .passport }?.id)
        let upper = try Self.render(rig.model, defaults: rig.defaults, name: "chosen-dark-passport", scheme: .dark)
        rig.model.selection = try #require(rig.model.rows.first { $0.category == .health }?.id)
        let lower = try Self.render(rig.model, defaults: rig.defaults, name: "chosen-dark-health", scheme: .dark)
        let grounds = try Self.grounds(upper, lower)
        #expect(grounds.count == 2, "\(grounds.map(\.count))")
        let (passport, health) = (try #require(grounds.first), try #require(grounds.last))
        #expect(health.lightB > health.lightA + 0.015, "\(health.lightA) → \(health.lightB)")
        #expect(passport.lightA > passport.lightB + 0.015, "\(passport.lightB) → \(passport.lightA)")
    }

    @Test func eachCardsTitleBarIsWashedInItsGroupsColorAndOffLeavesNone() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        let on = try Self.render(rig.model, defaults: rig.defaults, name: "colors-on")
        // Travel & Immigration is blue (Passports, Visas), Legal & IDs violet, Health rose, Home & Money green.
        for tint in [VaultTint.blue, .violet, .rose, .green] {
            #expect(try pixels(near: Self.wash(tint), in: on) > 1500, "a title bar washed \(tint)")
        }
        #expect(try pixels(near: Self.wash(.olive), in: on) < 50, "and none in a color no card has")

        var colors = rig.model.colors
        colors.isOn = false
        rig.model.setColors(colors)
        let off = try Self.render(rig.model, defaults: rig.defaults, name: "colors-off")
        for tint in [VaultTint.blue, .violet, .rose, .green] {
            #expect(try pixels(near: Self.wash(tint), in: off) < 50, "off, no title bar is washed \(tint)")
        }
    }

    @Test func aCardsOwnColorReplacesItsGroupsOnThatCardAlone() async throws {
        let rig = try await Self.rig(); defer { rig.cleanUp() }
        let before = try Self.render(rig.model, defaults: rig.defaults, name: "own-before")
        rig.model.setColor(.tint(.olive), of: .builtIn(.usVisa))
        let after = try Self.render(rig.model, defaults: rig.defaults, name: "own-after")
        #expect(try pixels(near: Self.wash(.olive), in: after) > 1500, "Visas is olive now")
        let (blueBefore, blueAfter) = (try pixels(near: Self.wash(.blue), in: before), try pixels(near: Self.wash(.blue), in: after))
        #expect(blueAfter > 1500 && blueAfter < blueBefore, "and Passports stays blue: \(blueBefore) → \(blueAfter)")
    }
}
