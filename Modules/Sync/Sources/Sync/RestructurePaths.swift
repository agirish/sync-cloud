import Foundation

/// Path arithmetic the restructure surfaces share. Profile-relative paths only: `"."` is the tree
/// root, as `FolderProfile` keys it.
public enum RestructurePaths {

    /// The deepest folder every one of these paths lies in or is: `"."` when they share only the
    /// root, and for an empty list. Compared by component, never by character, or `Finance/INbox`
    /// would count as inside `Finance/IN`.
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

    /// A family's short name, for a menu verb or a filename: the last component, or `"the tree"`
    /// when the family is the tree. Both spellings of the root count: `"."`, as a profile keys it,
    /// and `""`, what dropping the last component of a top-level folder leaves. Otherwise a ⌘Z item
    /// could read "Reorganise " with nothing after it.
    public static func familyLabel(_ family: String) -> String {
        let name = (family as NSString).lastPathComponent
        return name.isEmpty || name == "." ? "the tree" : name
    }

    /// Whether `path` is `ancestor` or lies under it, compared by component.
    public static func isInside(_ path: String, of ancestor: String) -> Bool {
        let a = ancestor.split(separator: "/").map(String.init)
        let p = path.split(separator: "/").map(String.init)
        guard a.count <= p.count else { return false }
        return Array(p.prefix(a.count)) == a
    }
}
