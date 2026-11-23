import Foundation

/// A record a choice can be made about: a saved ID (``VaultEntry``) or a waiting one
/// (``VaultFind``). Each already has the five choices as its own fields; this lets one path set
/// any of them on either (``VaultModel``'s `choose(_:for:sealingWaiting:)`, VT1).
protocol VaultChoosing {
    var pin: VaultPin? { get set }
    var assignment: VaultAssignment? { get set }
    var geo: VaultGeo? { get set }
    var card: VaultCardID? { get set }
    var chosenSource: String? { get set }
}

/// One choice the user makes about an ID from the panel.
enum VaultChoiceChange {
    case pin(VaultPin?)
    case assignment(VaultAssignment?)
    case geo(VaultGeo?)
    case card(VaultCardID?)
    case source(String?)
}

extension VaultChoosing {
    /// Sets the one field, through its own setter: a saved ID's ``VaultEntry/pin`` clears an
    /// older build's mark, as the panel's actions always have.
    mutating func apply(_ change: VaultChoiceChange) {
        switch change {
        case .pin(let pin): self.pin = pin
        case .assignment(let assignment): self.assignment = assignment
        case .geo(let geo): self.geo = geo
        case .card(let card): self.card = card
        case .source(let source): chosenSource = source
        }
    }
}

extension VaultEntry: VaultChoosing {}
extension VaultFind: VaultChoosing {}
