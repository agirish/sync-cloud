import Foundation
import Sync

/// A Restructure verb the menu asked for, waiting for the workspace to carry it out.
///
/// **A value, not a call.** ROADMAP_V5 §11's `Plan This Folder's Shape…` and
/// `Set Up Like Its Siblings` act on surfaces the workspace owns, and a sheet presented from the
/// menu bar would sit outside the anchor that keeps it alive when the lens changes — the exact
/// teardown-mid-apply bug the two existing sheets were moved to a stable anchor to fix. So the
/// menu writes a request and the workspace opens its own sheet.
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
