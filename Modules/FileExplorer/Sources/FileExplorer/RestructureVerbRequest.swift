import Foundation
import Sync

/// A Restructure verb the menu asked for, waiting for the workspace to carry it out.
///
/// A value, not a call: `Plan This Folder's Shape…` and `Set Up Like Its Siblings` act on
/// surfaces the workspace owns, and a sheet presented from the menu bar would sit outside the
/// stable anchor that keeps it alive when the lens changes, so it could be torn down mid-apply.
/// So the menu writes a request and the workspace opens its own sheet.
public struct RestructureVerbRequest: Equatable, Sendable, Identifiable {
    public let verb: RestructureVerbResolver.Verb
    /// The folder the selection named, absolute — resolved to a finding by the workspace, against
    /// the findings as they stand when it runs rather than when the menu was drawn.
    public let folder: String
    /// Distinguishes two requests for the same folder and verb, so pressing a menu item twice
    /// re-fires rather than being swallowed as "no change".
    public let id: UUID

    public init(verb: RestructureVerbResolver.Verb, folder: String, id: UUID = UUID()) {
        self.verb = verb
        self.folder = folder
        self.id = id
    }
}
