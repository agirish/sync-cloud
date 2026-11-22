import CryptoKit
import EventsTestSupport
import Foundation
import Security
import Testing
@testable import Sync

/// The sealed file and its key (``VaultStore``, ``VaultFile``, ``VaultKeychain``).
@Suite struct VaultStoreTests {
    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    static func entry(_ title: String, _ value: String, person: String? = nil) -> VaultEntry {
        VaultEntry(title: title, value: value, personID: person, note: "A note", kind: .home, addedAt: day)
    }

    @Test func whatIsSavedComesBackAndTheFileHoldsNoneOfItInTheClear() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        let entries = [Self.entry("Mortgage loan number", "0482917365"),
                       Self.entry("Health plan member ID", "XEH482917365", person: "shweta")]

        try store.save(entries)
        #expect(try store.load() == entries)

        let bytes = try Data(contentsOf: scratch.fileURL)
        #expect(bytes.prefix(8) == Data("SCVAULT1".utf8))
        for secret in ["0482917365", "XEH482917365", "Mortgage", "shweta", "A note"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) is readable in the sealed file")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func readingAnEmptyVaultMakesNoKeyAndNoFile() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)

        #expect(try store.load() == [])
        #expect(keychain.adds == 0)
        #expect(!store.hasFile)
    }

    @Test func theKeyIsMadeOnceAndIsThirtyTwoBytesNeverSynchronised() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)

        try store.save([Self.entry("A", "1111111")])
        try store.save([Self.entry("B", "2222222")])

        #expect(keychain.adds == 1, "a second key would orphan what the first sealed")
        #expect(keychain.itemData?.count == 32)
        #expect(keychain.lastAdded?[kSecAttrService as String] as? String == "com.synccloud.vault-key")
        #expect(keychain.lastAdded?[kSecAttrSynchronizable as String] == nil)
    }

    @Test func aFileWithoutItsKeyIsAnErrorAndIsNeverWrittenOver() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry("Passport", "A38291647")])
        let sealed = try Data(contentsOf: scratch.fileURL)

        keychain.itemData = nil   // the key went away: another Mac, or removed in Keychain Access

        #expect(throws: VaultError.keyMissing) { try store.load() }
        #expect(throws: VaultError.keyMissing) { try store.save([Self.entry("New", "9999999")]) }
        #expect(try Data(contentsOf: scratch.fileURL) == sealed, "the unreadable file was replaced")
        #expect(keychain.adds == 1, "a new key was made over a file it cannot open")
    }

    @Test func aRefusedKeychainIsReportedNotTakenForAnEmptyVault() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry("Passport", "A38291647")])

        keychain.forcedCopyStatus = errSecInteractionNotAllowed
        #expect(throws: VaultError.keyUnreadable(errSecInteractionNotAllowed)) { try store.load() }
        #expect(throws: VaultError.keyUnreadable(errSecInteractionNotAllowed)) { try store.save([]) }
    }

    @Test func aKeyTheKeychainWillNotKeepSavesNothing() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        keychain.forcedAddStatus = errSecAuthFailed
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)

        #expect(throws: VaultError.keyNotSaved(errSecAuthFailed)) { try store.save([Self.entry("A", "1111111")]) }
        #expect(!store.hasFile)
    }

    @Test func aDamagedOrForeignFileDoesNotOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try VaultFile.seal([Self.entry("Passport", "A38291647")], with: key)

        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        #expect(throws: VaultError.wrongKeyOrDamaged) { try VaultFile.open(flipped, with: key) }
        #expect(throws: VaultError.wrongKeyOrDamaged) { try VaultFile.open(sealed, with: SymmetricKey(size: .bits256)) }

        var laterFormat = sealed
        laterFormat[7] = UInt8(ascii: "2")
        #expect(throws: VaultError.unreadableFile) { try VaultFile.open(laterFormat, with: key) }
        #expect(throws: VaultError.unreadableFile) { try VaultFile.open(Data("SCVAULT1".utf8), with: key) }
        #expect(throws: VaultError.unreadableFile) { try VaultFile.open(Data("not a vault".utf8), with: key) }
    }

    @Test func aStoredItemThatIsNotAKeyIsUnreadableNotMissing() {
        let keychain = VaultFakeKeychain()
        keychain.itemData = Data("too short".utf8)
        #expect(VaultKeychain.read(from: keychain) == .unreadable(errSecDecode))
        keychain.itemData = nil
        #expect(VaultKeychain.read(from: keychain) == .notCreated)
    }
}

/// How a hidden number is drawn, and how a shown one is read out (``VaultMask``, ``VaultEntry``).
@Suite struct VaultMaskTests {
    @Test func allButTheLastFourAreDotsAndSeparatorsStay() {
        #expect(VaultMask.masked("0482917365") == "••••••7365")
        #expect(VaultMask.masked("(408) 555-0142") == "(•••) •••-0142")
        #expect(VaultMask.masked("HO-4829173") == "••-•••9173")
        #expect(VaultMask.masked("8155 10 012 3456789") == "•••• •• ••• •••6789")
        #expect(VaultMask.masked("XEH482917365") == "••••••••7365")
    }

    @Test func aNumberOfFourOrFewerIsHiddenWhole() {
        #expect(VaultMask.masked("4821") == "••••")
        #expect(VaultMask.masked("12") == "••")
        #expect(VaultMask.masked("") == "")
    }

    @Test func largeTypeReadsInFoursWithoutSeparators() {
        #expect(VaultMask.groups("XEH482917365") == ["XEH4", "8291", "7365"])
        #expect(VaultMask.groups("(408) 555-0142") == ["4085", "5501", "42"])
        #expect(VaultMask.groups("") == [])
    }

    @Test func largeTypeGroupsAnIDAsItsDocumentPrintsIt() {
        // Its own pattern, where the kind has one and the length fits.
        #expect(VaultMask.printed("ABCPE1234F", as: .pan) == ["ABCPE", "1234", "F"])
        #expect(VaultMask.printed("123456789", as: .ssn) == ["123", "45", "6789"])
        #expect(VaultMask.printed("12345678", as: .ssn) == ["1234", "5678"], "a misread length falls back to fours")
        // As written, a long run cut in fours.
        #expect(VaultMask.printed("123-45-6789", as: .ssn) == ["123", "45", "6789"])
        #expect(VaultMask.printed("(408) 555-0142", as: .utilities) == ["408", "555", "0142"])
        #expect(VaultMask.printed("KA05 20090001234", as: .driversLicense) == ["KA05", "2009", "0001", "234"])
        // Else fours.
        #expect(VaultMask.printed("D1234567", as: .driversLicense) == ["D123", "4567"])
        #expect(VaultMask.printed("234567890123", as: .aadhaar) == ["2345", "6789", "0123"])
        #expect(VaultMask.printed("", as: nil) == [])
    }

    @Test func anEntryNeverPrintsItsNumber() {
        let entry = VaultEntry(title: "Passport", value: "A38291647", addedAt: VaultStoreTests.day)
        for text in ["\(entry)", String(describing: entry), String(reflecting: entry), "\([entry])"] {
            #expect(!text.contains("A38291647"), "\(text)")
            #expect(text.contains("1647"))
        }
        var dumped = ""
        dump(entry, to: &dumped)
        #expect(!dumped.contains("A38291647"))
    }
}
