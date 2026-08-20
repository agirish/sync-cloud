import Foundation
import Sync

/// What is at a typed path, as far as the app can see.
///
/// Three states rather than a `Bool`, because the palette answers each one differently: a folder is
/// a destination, a **file** is a destination's enclosing folder (which is what usually ends up on
/// a clipboard), and nothing at all is the one case that has to be said out loud rather than
/// offered and then silently dropped.
public enum PathKind: Equatable, Sendable {
    case missing
    case directory
    case file
}

/// Answers what is at a path. Injected rather than called, for the reason `PalettePath` gives.
///
/// **Not `@Sendable`, deliberately.** The one production implementation is a memo on
/// `CommandPaletteState`, which is `@MainActor` — the whole point of it being a closure is that the
/// caller can put something stateful behind it, and every call is on the main actor inside one
/// synchronous `rows` computation.
public typealias PalettePathProbe = (String) -> PathKind

/// **Go to Folder** — Finder's ⇧⌘G as a behaviour rather than a surface (ROADMAP_V4 §3).
///
/// A typed path is a different kind of query from a typed name, and the difference is that the user
/// has already said exactly where they mean. `PaletteRouter.folderRows` ranks folder *names* out of
/// the survey profile; nothing here ranks anything. It resolves one string to one destination, or
/// says why it cannot.
///
/// ## The order of the checks is a stall guard, not a style
///
/// Every check that can be answered from the index runs **before** the one that touches the disk,
/// and that ordering is the whole reason this is safe to run on the keystroke path. The probe is a
/// `stat`, and a `stat` under an unreachable mount blocks — the same hazard
/// `FolderJumpStore.reachable` is arranged around. So a path is only ever probed once it is known
/// to be inside a source that is **mounted** and is the one the pane is already showing. A path
/// outside every source, or inside a sleeping one, is refused without the disk being asked at all.
///
/// That also decides what the refusals say, and each is a fact the palette can state honestly
/// without knowing whether the folder is there.
public enum PalettePath {

    /// Whether this query is someone typing a *path* rather than a *name*.
    ///
    /// **A leading `/` or `~`, and not "contains a slash".** `Clients/Legal` is a perfectly good
    /// relative folder name and `folderRows` already matches it out of the survey — treating it as
    /// a path would resolve it against the process working directory and refuse it, replacing a
    /// working row with a broken one.
    public static func looksLikeAPath(_ query: String) -> Bool {
        query.hasPrefix("/") || query.hasPrefix("~")
    }

    /// The absolute path a query names.
    ///
    /// `home` is injected rather than read from `NSHomeDirectory()` so the rule can be tested
    /// against a fixture root; the router passes `PaletteIndex.home`.
    ///
    /// `standardizingPath` runs **after** the tilde is expanded, never before — it expands `~`
    /// against the real home of its own accord, which would quietly undo the injection. What it is
    /// here for is `.` and `..`: without it `~/Documents/../Downloads` keeps a source's root as its
    /// prefix and would be revealed as the relative path `../Downloads` inside it.
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

    /// The source this path is inside, if any — **longest root first**.
    ///
    /// Sources can nest: a person with `~/Documents` and `~/Documents/Clients` configured has both,
    /// and a path under the second is under the first as well. The innermost is the one that can
    /// actually show it at the depth the user typed, and taking the first match in settings order
    /// would hand the path to whichever happened to be added first.
    public static func owner(of path: String, in providers: [PaletteProvider]) -> PaletteProvider? {
        providers
            .filter { !$0.root.isEmpty && PathBoundary.contains(path, under: $0.root) }
            .max { $0.root.count < $1.root.count }
    }
}
