import Foundation
@testable import Sync

/// What the Vault's tests share beyond their own suite: dates, a page read, a find's detail, a
/// license front and a merged copy of one, and a model whose proof lets something happen while it
/// is asked. Every number in them is made up.
enum VaultFixtures {
    typealias Rig = VaultModelTests.Rig

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { VaultReadingTests.day(y, m, d) }

    /// One page's finds, as the readers give them.
    static func read(_ lines: [String]) -> [VaultFind] { VaultIDReadingTests.read(lines) }

    static func detail(_ find: VaultFind?, _ label: String) -> VaultDetail.Value? {
        VaultTravelReadingTests.detail(find, label)
    }

    /// A California license front, expiry and all.
    nonisolated static let licensePage = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 05/16/2030", "LN ERIKSSON", "FN ANNA"]

    /// The same front with no expiry, and with one.
    static let licenseFront = ["California USA DRIVER LICENSE", "DL D1234567", "LN ERIKSSON", "FN ANNA"]
    static func front(expiring: String) -> [String] { licenseFront + ["EXP " + expiring] }

    /// One reading of license D1234567, for merging copies.
    static func license(_ details: [VaultDetail], dated: Date?, until: Date?, path: String) -> VaultFind {
        VaultFind(title: "Driver’s license · CA", value: "D1234567", note: "",
                  facts: VaultReadFacts(category: .driversLicense, issuer: "USA", dated: dated, validUntil: until,
                                        details: details, sources: [VaultSource(path: path, role: "Driver’s license", rank: 40)]))
    }

    /// A proof that, while it is asked, lets something else happen: the panel closing, say.
    final class InterruptingProof: VaultAuthenticating, @unchecked Sendable {
        var during: (@MainActor () -> Void)?
        func prove(reason: String) async -> VaultProof {
            await during?()
            return .allowed
        }
    }

    /// Asks for every number, and locks when the panel closes.
    static func everyNumber(_ rig: Rig) {
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        rig.defaults.set(VaultLockSettings.Relock.whenClosed.rawValue, forKey: VaultLockSettings.relockKey)
    }

    /// A model asking `proof`, copying into `copied` when given.
    @MainActor static func model(_ rig: Rig, proof: InterruptingProof, copied: Rig.Box? = nil) -> VaultModel {
        let clock = rig.clock
        return VaultModel(store: rig.store, authenticator: proof, defaults: rig.defaults,
                          clock: { clock.now }, copyToPasteboard: { copied?.copied.append($0) })
    }
}
