import Foundation

/// What the user typed for one person in People: phones, emails and home addresses, and the
/// addresses read from papers they said are not this person's (Not Their Address).
public struct VaultContacts: Codable, Equatable, Sendable {
    /// A phone or an email as typed, its label ("Mobile", "Work", "Home") and when it was added.
    public struct Typed: Codable, Equatable, Sendable {
        public var value: String
        public var label: String?
        public var added: Date

        public init(_ value: String, label: String? = nil, added: Date) {
            self.value = value
            self.label = label.flatMap { $0.isEmpty ? nil : $0 }
            self.added = added
        }
    }

    /// A home address as typed, and the day: a typed address is as new as the day it was typed (QD).
    public struct TypedAddress: Codable, Equatable, Sendable {
        public var address: VaultAddress
        public var added: Date

        public init(_ address: VaultAddress, added: Date) {
            self.address = address
            self.added = added
        }
    }

    public var phones: [Typed] = []
    public var emails: [Typed] = []
    public var addresses: [TypedAddress] = []
    /// ``VaultAddress/key``s read from papers that are not this person's home.
    public var notTheirs: [String] = []

    public init(phones: [Typed] = [], emails: [Typed] = [], addresses: [TypedAddress] = [], notTheirs: [String] = []) {
        self.phones = phones
        self.emails = emails
        self.addresses = addresses
        self.notTheirs = notTheirs
    }

    public var isEmpty: Bool { phones.isEmpty && emails.isEmpty && addresses.isEmpty && notTheirs.isEmpty }

    /// Each field decoded alone, so one a later build shaped differently does not lose the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phones = (try? c.decodeIfPresent([Typed].self, forKey: .phones)) ?? []
        emails = (try? c.decodeIfPresent([Typed].self, forKey: .emails)) ?? []
        addresses = (try? c.decodeIfPresent([TypedAddress].self, forKey: .addresses)) ?? []
        notTheirs = (try? c.decodeIfPresent([String].self, forKey: .notTheirs)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case phones, emails, addresses, notTheirs }

    /// The labels a phone or an email may have, the first the one a new one gets.
    public static let phoneLabels = ["Mobile", "Home", "Work"]
    public static let emailLabels = ["Personal", "Work"]

    /// A US number of 10 digits (11 with a leading 1) as "(408) 555-0142"; anything else, such as
    /// "+91 98450 12345", as typed.
    public static func phoneShown(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("+") || trimmed.hasPrefix("+1") else { return trimmed }
        var digits = trimmed.filter(\.isNumber)
        guard trimmed.allSatisfy({ $0.isNumber || " ()-.+".contains($0) }) else { return trimmed }
        if digits.count == 11, digits.first == "1" { digits.removeFirst() }
        guard digits.count == 10 else { return trimmed }
        let d = Array(digits)
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }

    /// Whether `typed` could be an email: something, an @, a domain with a dot.
    public static func looksLikeEmail(_ typed: String) -> Bool {
        let parts = typed.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" "), !parts[1].contains(" ") else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    /// Whether `typed` holds enough digits to be a phone number.
    public static func looksLikePhone(_ typed: String) -> Bool {
        typed.filter(\.isNumber).count >= 7
    }
}

// MARK: Typing them

extension VaultModel {
    /// Changes what was typed for `person`, then seals it. Nothing while the Vault is not open.
    @discardableResult
    func changeContacts(of person: String, _ change: (inout VaultContacts) -> Void) -> Bool {
        guard contents == .loaded, !person.isEmpty else { return false }
        var theirs = contacts[person] ?? VaultContacts()
        change(&theirs)
        contacts[person] = theirs.isEmpty ? nil : theirs
        readingChanged = true
        saveReading()
        return true
    }

    /// Adds a phone, or with `replacing` puts it in place of the one at that index.
    @discardableResult
    public func setPhone(_ value: String, label: String?, for person: String, replacing index: Int? = nil) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VaultContacts.looksLikePhone(value) else { return false }
        let today = self.clock()
        return changeContacts(of: person) { c in
            let typed = VaultContacts.Typed(value, label: label, added: today)
            if let index, c.phones.indices.contains(index) { c.phones[index] = typed } else { c.phones.append(typed) }
        }
    }

    @discardableResult
    public func setEmail(_ value: String, label: String?, for person: String, replacing index: Int? = nil) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VaultContacts.looksLikeEmail(value) else { return false }
        let today = self.clock()
        return changeContacts(of: person) { c in
            let typed = VaultContacts.Typed(value, label: label, added: today)
            if let index, c.emails.indices.contains(index) { c.emails[index] = typed } else { c.emails.append(typed) }
        }
    }

    public func removePhone(at index: Int, for person: String) {
        changeContacts(of: person) { c in if c.phones.indices.contains(index) { c.phones.remove(at: index) } }
    }

    public func removeEmail(at index: Int, for person: String) {
        changeContacts(of: person) { c in if c.emails.indices.contains(index) { c.emails.remove(at: index) } }
    }

    /// Types `address` as the home of `person` and of each of `alsoFor` (“Same for”). Typed
    /// today, it leads until a later paper prints another. With `replacing`, an address shown
    /// (typed, or read and being corrected) gives way to it: a typed one is replaced, a read one
    /// is set aside as not theirs.
    @discardableResult
    public func setAddress(_ address: VaultAddress, for person: String, alsoFor others: [String] = [],
                           replacing old: String? = nil) -> Bool {
        let address = address.trimmed
        guard address.isComplete else { return false }
        let today = self.clock()
        var done = false
        for id in [person] + others where !id.isEmpty {
            done = changeContacts(of: id) { c in
                if let old, id == person {
                    if let at = c.addresses.firstIndex(where: { $0.address.key == old }) {
                        c.addresses.remove(at: at)
                    } else if old != address.key, !c.notTheirs.contains(old) {
                        c.notTheirs.append(old)
                    }
                }
                c.addresses.removeAll { $0.address.key == address.key }
                c.notTheirs.removeAll { $0 == address.key }
                c.addresses.append(.init(address, added: today))
            } || done
        }
        return done
    }

    /// Takes an address out of `person`'s: a typed one is removed; with `read` (papers print it)
    /// it is also not theirs, and with `everyone` (it came from Household papers) not anyone's in
    /// People.
    public func removeAddress(_ key: String, for person: String, read: Bool, everyone: Bool = false) {
        changeContacts(of: person) { $0.addresses.removeAll { $0.address.key == key } }
        guard read else { return }
        for id in everyone ? people.map(\.id) : [person] {
            changeContacts(of: id) { c in if !c.notTheirs.contains(key) { c.notTheirs.append(key) } }
        }
    }
}

extension VaultAddress {
    /// Each part without spaces at its ends; the state in capitals; the ZIP's first five digits.
    public var trimmed: VaultAddress {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return VaultAddress(street: t(street), unit: unit.map(t), city: t(city), state: t(state).uppercased(),
                            zip: String(t(zip).filter(\.isNumber).prefix(5)))
    }

    /// A street with a house number, a city, a US state and a five-digit ZIP.
    public var isComplete: Bool {
        street.first?.isNumber == true && street.contains(where: \.isLetter) && !city.isEmpty
            && VaultReading.postalStates.contains(state) && zip.count == 5
    }
}
