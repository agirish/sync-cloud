import Foundation

/// Where the files sitting loose at the top of a learned tree would go, by name alone.
///
/// **The Structure screen's second view, and the only claim setup makes about filing before the
/// user has approved anything.** It is name-only on purpose: the profile has just been previewed
/// and no document has been opened, so this is exactly the evidence To File will have on its first
/// run — which makes the preview honest rather than optimistic. Nothing moves; the routes are
/// shown and thrown away.
///
/// No production caller ranks with `contentSnippet: nil` today, which is why this lives here rather
/// than being borrowed from ``FileSyncManager``: the setup sheet is the first place the app has
/// reason to ask what it can tell from a name and nothing else.
public enum SetupLooseFileRouting {

    /// One loose file's proposed home.
    public struct LooseFileRoute: Sendable, Equatable, Identifiable {
        public var id: String { fileName }
        /// The file, as it sits in the root.
        public let fileName: String
        /// Where it would go, relative to the root — nil when nothing scored at all.
        public let home: String?
        /// How separated that answer was. Below ``readyBar`` the screen says "Needs your pick",
        /// which is To File's own word for the same state.
        public let confidence: FilingConfidence

        public init(fileName: String, home: String?, confidence: FilingConfidence) {
            self.fileName = fileName
            self.home = home
            self.confidence = confidence
        }

        /// Whether setup would show this one as answered.
        public var isReady: Bool { home != nil && confidence >= readyBar }
    }

    /// The bar a name-only ranking has to clear to be shown as an answer.
    ///
    /// ``FilingEngine/Ranking/hasConfidentHome`` uses the same value from the other direction, and
    /// `FileSyncManager+FilingRoute` uses it to stop an unsure name-only ranking from evicting a
    /// folder-creating suggestion. One bar, so the count setup shows and the tiers To File draws
    /// cannot disagree about what "ready" means.
    public static let readyBar: FilingConfidence = .medium

    /// Routes every loose file in `walk`, against the profile the user is about to save.
    ///
    /// The destinations are the previewed tree's own folders, uncapped: a cap here would make a
    /// file's answer depend on how many folders happened to sort before its home.
    public static func route(walk: SetupWalk, profile: FolderProfile,
                             registry: PersonRegistry? = nil) -> [LooseFileRoute] {
        let index = FilingRouter.makeIndex(
            destinations: FilingEngine.relativeFolderPaths(of: walk.tree, limit: .max),
            profile: profile, memory: nil, registry: registry)
        return walk.looseFileNames.map { name in
            let ranking = FilingRouter.rank(fileName: name, contentSnippet: nil, index: index)
            guard let best = ranking.best else {
                return LooseFileRoute(fileName: name, home: nil, confidence: .low)
            }
            return LooseFileRoute(fileName: name, home: best.relativePath,
                                  confidence: ranking.confidence)
        }
    }

    /// How many of `routes` setup would show as answered — the number beside the second view.
    public static func readyCount(_ routes: [LooseFileRoute]) -> Int {
        routes.filter(\.isReady).count
    }
}
