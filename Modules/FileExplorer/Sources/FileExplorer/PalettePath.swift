import Foundation
import Sync

/// What is at a typed path, as far as the app can see.
///
/// Three states, not a `Bool`, because the palette answers each differently: a folder is a
/// destination, a file means its enclosing folder (often what's on a clipboard), and nothing at all
/// must be said out loud rather than offered and silently dropped.
public enum PathKind: Equatable, Sendable {
    case missing
    case directory
    case file
}

/// Answers what is at a path. Injected rather than called, for the reason `PalettePath` gives.
///
/// Not `@Sendable`, deliberately: the production implementation is a memo on the `@MainActor`
/// `CommandPaletteState`, and every call is on the main actor inside one synchronous `rows`
/// computation. A closure so the caller can put something stateful behind it.
public typealias PalettePathProbe = (String) -> PathKind

/// Go to Folder: Finder's ⇧⌘G as a behaviour rather than a surface. A typed path says exactly
/// where the user means, so nothing here ranks (`PaletteRouter.folderRows` ranks names): it
/// resolves one string to one destination, or says why it can't.
///
/// ## The order of the checks is a stall guard
///
/// **Every check the index can answer runs before the one that touches the disk**, which is what
/// makes this safe on the keystroke path. The probe is a `stat`, and a `stat` under an unreachable
/// mount blocks (the hazard `FolderJumpStore.reachable` is arranged around). So a path is probed
/// only once it is inside a mounted source the pane is already showing; anything else is refused
/// without asking the disk, with a reason the palette can state without knowing what is there.
public enum PalettePath {

    /// Whether this query is someone typing a *path* rather than a *name*.
    ///
    /// A leading `/` or `~`, not "contains a slash": `Clients/Legal` is a good relative folder name
    /// that `folderRows` already matches, and as a path it would resolve against the process's
    /// working directory and be refused.
    public static func looksLikeAPath(_ query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~")
    }

    /// The absolute path a query names.
    ///
    /// `home` is injected rather than read from `NSHomeDirectory()` so the rule can be tested
    /// against a fixture root; the router passes `PaletteIndex.home`.
    ///
    /// `standardizingPath` runs after the tilde is expanded, never before: it expands `~` against
    /// the real home itself, undoing the injection. It is here for `.` and `..`: without it,
    /// `~/Documents/../Downloads` keeps a source's root as its prefix and reveals inside it.
    public static func absolute(_ query: String, home: String) -> String {
        var path = query
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        let standard = (path as NSString).standardizingPath
        guard standard.count > 1, standard.hasSuffix("/") else { return standard }
        return String(standard.dropLast())
    }

    /// The source this path is inside, if any, longest root first. Sources can nest
    /// (`~/Documents` and `~/Documents/Clients`), and the innermost is the one that shows the path
    /// at the depth typed; the first match in settings order would be whichever was added first.
    public static func owner(of path: String, in providers: [PaletteProvider]) -> PaletteProvider? {
        providers
            .filter { !$0.root.isEmpty && PathBoundary.contains(path, under: $0.root) }
            .max { $0.root.count < $1.root.count }
    }
}
