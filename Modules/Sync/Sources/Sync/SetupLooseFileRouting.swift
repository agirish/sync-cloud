import Foundation

/// Where the files sitting loose at the top of a learned tree would go, by name alone.
///
/// The Structure screen's second view, and setup's only claim about filing before the user approves
/// anything. Name-only on purpose: no document has been opened yet, so this is the evidence To File
/// has on its first run, and the preview stays honest. Nothing moves; the routes are shown and
/// thrown away. It lives here because no other caller ranks with `contentSnippet: nil`.
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

    /// The bar a name-only ranking has to clear to be shown as an answer. Shared with
    /// ``FilingEngine/Ranking/hasConfidentHome`` and `FileSyncManager+FilingRoute`, so setup's
    /// count and To File's tiers agree on what "ready" means.
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
