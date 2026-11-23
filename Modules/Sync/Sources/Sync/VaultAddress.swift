import Foundation

/// A US home address as a paper prints it: a street line, perhaps a unit, a city, a state and a ZIP.
public struct VaultAddress: Codable, Equatable, Hashable, Sendable {
    /// "2841 Larkspur Lane": the house number and the street.
    public var street: String
    /// "Apt 6", when the paper prints one.
    public var unit: String?
    public var city: String
    /// Two letters: "CA".
    public var state: String
    /// Five digits: a ZIP+4's last four are left off, as two papers of one home differ in them.
    public var zip: String

    public init(street: String, unit: String? = nil, city: String, state: String, zip: String) {
        self.street = street
        self.unit = unit.flatMap { $0.isEmpty ? nil : $0 }
        self.city = city
        self.state = state
        self.zip = zip
    }

    /// One line, as forms and Copy take it: "2841 Larkspur Lane, Apt 6, San Jose, CA 95132".
    public var oneLine: String {
        ([street] + [unit].compactMap { $0 } + [city]).joined(separator: ", ") + ", \(state) \(zip)"
    }

    /// What makes two printings one address: the house number, the street's first word that is not
    /// a direction, and the ZIP. "2841 LARKSPUR LN" and "2841 Larkspur Lane" are one address;
    /// the unit is left out, as one paper prints it and the next may not.
    public var key: String {
        let words = street.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let number = words.first ?? ""
        let name = words.dropFirst().first { !Self.directions.contains($0) } ?? ""
        return "\(number) \(name) \(zip)"
    }

    private static let directions: Set<String> = ["n", "s", "e", "w", "ne", "nw", "se", "sw",
                                                  "north", "south", "east", "west"]

    /// The address as it is shown: a printing in capitals is put in title case ("2841 LARKSPUR LN"
    /// is "2841 Larkspur Ln"), one in mixed case is kept as printed; the state in capitals.
    public var tidied: VaultAddress {
        func tidy(_ s: String) -> String {
            guard s == s.uppercased(), s.contains(where: \.isLetter) else { return s }
            return s.split(separator: " ").map { word in
                // "1ST" is "1st", "APT" is "Apt".
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        }
        return VaultAddress(street: tidy(street), unit: unit.map(tidy), city: tidy(city), state: state.uppercased(), zip: zip)
    }

    /// Whether this printing looks tidier than `other`: mixed case over capitals, then one that
    /// names its unit.
    func isTidier(than other: VaultAddress) -> Bool {
        let (mine, theirs) = (street != street.uppercased(), other.street != other.street.uppercased())
        if mine != theirs { return mine }
        return unit != nil && other.unit == nil
    }
}

/// An address one paper printed, and the paper's date: what orders a household's addresses, the
/// newest leading.
public struct VaultPrintedAddress: Codable, Equatable, Hashable, Sendable {
    public var address: VaultAddress
    /// The paper's own date: a license's issue date, a bill's month. Nil when the paper gives none.
    public var dated: Date?

    public init(_ address: VaultAddress, dated: Date?) {
        self.address = address
        self.dated = dated
    }
}

extension VaultReading {
    /// The two-letter codes a city line may end with: the states, DC and Puerto Rico.
    static let postalStates: Set<String> = Set(usStates.values).union(["DC", "PR"])

    /// "SAN JOSE, CA 95132-1234", "San Jose CA 95132": a city, a state and a ZIP, ending the line.
    private static let cityLinePattern = try! NSRegularExpression(
        pattern: #"^\s*([A-Za-z][A-Za-z .'-]*?)\s*,?\s+([A-Za-z]{2})\.?\s+([0-9]{5})(?:\s*-?\s*[0-9]{4})?\s*$"#)

    /// "2841 LARKSPUR LN", "12 N 1st St Apt 6": a house number, then words.
    private static let streetLinePattern = try! NSRegularExpression(
        pattern: #"^\s*([0-9]{1,6}[A-Za-z]?(?:-[0-9A-Za-z]+)?)\s+([A-Za-z0-9][A-Za-z0-9 .,'#-]*?)\s*$"#)

    /// A unit at a street line's end, or on a line of its own: "APT 6", "Unit 12B", "Ste. 200", "#6".
    private static let unitPattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s,]+)((?:APT|APARTMENT|UNIT|STE|SUITE)\.?\s*#?\s*[A-Za-z0-9-]+|#\s*[A-Za-z0-9-]+)\s*$"#,
        options: [.caseInsensitive])

    /// Words above a name that make its block someone else's address, or not the home: where a
    /// bill's service is, or where payments go.
    private static let notHomeCues = ["service address", "service location", "service for", "property address",
                                      "premises", "remit", "payment address", "pay to", "payable to",
                                      "send payment", "mail payment", "make checks"]

    /// The city line's parts, when `line` is one.
    static func cityLine(_ line: String) -> (city: String, state: String, zip: String)? {
        let ns = line as NSString
        guard let m = cityLinePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let state = ns.substring(with: m.range(at: 2)).uppercased()
        guard postalStates.contains(state) else { return nil }
        let city = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard city.filter(\.isLetter).count >= 2 else { return nil }
        return (city, state, ns.substring(with: m.range(at: 3)))
    }

    /// The street and its unit, when `line` is a street line.
    static func streetLine(_ line: String) -> (street: String, unit: String?)? {
        let ns = line as NSString
        guard let m = streetLinePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var rest = ns.substring(with: m.range(at: 2))
        let words = rest.split(separator: " ")
        guard words.contains(where: { $0.filter(\.isLetter).count >= 2 }), words.count <= 8 else { return nil }
        var unit: String?
        let restNS = rest as NSString
        if let u = unitPattern.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)),
           u.range.location > 0 {
            unit = restNS.substring(with: u.range(at: 1))
            rest = restNS.substring(to: u.range.location).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",")))
        }
        // A P.O. Box never gets here: its line starts with a word, not a house number.
        return (ns.substring(with: m.range(at: 1)) + " " + rest, unit)
    }

    /// A unit on a line of its own: "APT 6".
    static func unitLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let m = unitPattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length == ns.length else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func isPostBox(_ line: String) -> Bool {
        let squeezed = line.lowercased().filter { $0.isLetter || $0.isNumber }
        return squeezed.hasPrefix("pobox") || squeezed.contains("pobox") || squeezed.hasPrefix("box")
            || squeezed.contains("postofficebox")
    }

    /// The address a paper is mailed to: a line naming someone in `people`, the street under it
    /// (a unit perhaps on its own line), then the city line. The first such block, page by page.
    ///
    /// A page is lines, not places on it, so the block is found by its order alone. A block under
    /// words that make it a service or payment address is passed over, and so is a P.O. Box: a
    /// home address is never guessed. With nobody in `people`, nothing is read.
    static func mailingAddress(in pages: [[String]], people: [Person]) -> VaultAddress? {
        guard !people.isEmpty else { return nil }
        let registry = PersonRegistry(people: people)
        for page in pages {
            for (index, line) in page.enumerated() {
                guard let city = cityLine(line), index >= 2 else { continue }
                var at = index - 1
                var unit = unitLine(page[at])
                if unit != nil { at -= 1 }
                guard at >= 1, let street = streetLine(page[at]) else { continue }
                unit = unit ?? street.unit
                // The name: on the line above the street, or the one above that ("C/O", a second name).
                let names = (max(0, at - 2)..<at).reversed().first { i in
                    let text = page[i]
                    return !text.contains(where: \.isNumber) && !registry.detect(in: text).isEmpty
                }
                guard let name = names else { continue }
                let above = page[max(0, name - 2)...name].joined(separator: " ").lowercased()
                guard !notHomeCues.contains(where: above.contains) else { continue }
                return VaultAddress(street: street.street, unit: unit, city: city.city, state: city.state, zip: city.zip)
            }
        }
        return nil
    }
}
