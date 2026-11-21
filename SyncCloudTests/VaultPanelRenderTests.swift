import AppKit
import CryptoKit
import Design
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// A keychain held in memory, for a Vault sealed in a temporary folder.
final class VaultPanelKeychain: KeychainStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private func key(_ query: [String: Any]) -> String {
        "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        items.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        guard items[key(attributes)] == nil, let data = attributes[kSecValueData as String] as? Data else { return errSecDuplicateItem }
        items[key(attributes)] = data
        return errSecSuccess
    }
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        guard let data = items[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data as NSData)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecItemNotFound }
}

struct VaultPanelAllows: VaultAuthenticating {
    func prove(reason: String) async -> VaultProof { .allowed }
}

/// The whole Vault panel, drawn over a made-up household and read back. Every ID here is made up.
///
/// Set `TEST_RUNNER_VAULT_PANEL_PNG` to a folder when running to keep each render as a PNG there,
/// to look at.
@MainActor
@Suite struct VaultPanelRenderTests {
    static let size = CGSize(width: 1000, height: 620)

    /// A Vault with one ID on each of several cards, unlocked.
    static func rig() async throws -> (model: VaultModel, defaults: UserDefaults, cleanUp: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-panel-\(UUID().uuidString)")
        let store = VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultPanelKeychain())
        let scratch = TestDefaults()
        let model = VaultModel(store: store, authenticator: VaultPanelAllows(), defaults: scratch.defaults,
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
        add("Harborline Mortgage loan", "0044918857", .loans, nil)
        model.people = [Person(id: "anna", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        await model.unlock()
        return (model, scratch.defaults, { try? FileManager.default.removeItem(at: folder) })
    }

    static func render(_ model: VaultModel, defaults: UserDefaults, name: String) throws -> NSBitmapImageRep {
        let panel = VaultCard(model: model, people: model.people, glassHue: .blue, onClose: {}, onOpenSettings: {},
                              onQuickLook: { _ in }, onReveal: { _ in }, onAddPerson: { _, _ in nil },
                              quickLookPath: nil, onCloseQuickLook: {})
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .defaultAppStorage(defaults)
        let rep = try renderInSRGBWindow(panel, size: size, scheme: .light)
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
