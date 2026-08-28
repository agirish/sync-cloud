import Foundation

/// Path arithmetic the restructure surfaces share. Profile-relative paths only — `"."` is the
/// profile's own spelling for the tree root, the way `FolderProfile` keys it.
public enum RestructurePaths {

    /// The deepest folder every one of these paths lies in or is. `"."` when they share nothing
    /// but the root, and for the empty list.
    ///
    /// **Components, never characters.** A prefix match on the string would make `Finance/INbox`
    /// a child of `Finance/IN`, and every caller here is deciding what to call a family or where
    /// to write a manifest against.
    public static func commonAncestor(of paths: [String]) -> String {
        var shared: [String]?
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard let current = shared else { shared = components; continue }
            shared = Array(zip(current, components).prefix { $0.0 == $0.1 }.map(\.0))
        }
        guard let shared, !shared.isEmpty else { return "." }
        return shared.joined(separator: "/")
    }

    /// A family's short name, for a menu verb or a filename — the last component, or `"the tree"`
    /// when the family IS the tree.
    ///
    /// Two spellings reach that state and both have to be caught: `"."`, which is how a profile
    /// keys the root, and `""`, which is what deleting the last component of a top-level folder
    /// leaves. `"Reorganise "` with nothing after it was a real ⌘Z menu item for a pair whose
    /// parent sits at the top of the tree.
    public static func familyLabel(_ family: String) -> String {
        let name = (family as NSString).lastPathComponent
        return name.isEmpty || name == "." ? "the tree" : name
    }

    /// Whether `path` is `ancestor` or lies underneath it — the containment test, by component.
    public static func isInside(_ path: String, of ancestor: String) -> Bool {
        let a = ancestor.split(separator: "/").map(String.init)
        let p = path.split(separator: "/").map(String.init)
        guard a.count <= p.count else { return false }
        return Array(p.prefix(a.count)) == a
    }
}
