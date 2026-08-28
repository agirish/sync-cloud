import Foundation
import Sync

/// `synccloud restructure` — the structure detectors over the active folder profile, from a
/// terminal (ROADMAP_V5 §13).
///
/// **Report-only, deliberately and permanently for 5.0.** No `--apply`, no `--plan`: §5.5's six
/// invariants are all about a person reading a manifest before anything moves, and a flag that
/// skips the reading skips the invariants.
///
/// Built *with* §5.2 rather than after it, for a testing reason as much as a user one: the
/// detectors are pure functions of the profile, so this command is the only way to run the whole
/// set over a real tree without a Mac in front of you — and it retires the throwaway Python
/// re-implementation every number in the roadmap used to come from, making the next audit a diff
/// instead of a rewrite.
public enum RestructureReporting {

    /// The command's whole result, and a **stable public format**: scripts will parse this, so
    /// fields are only ever added, never renamed. Finding rows are flattened per kind — the
    /// consumer branches on `kind` and reads that kind's fields, all optional except the identity.
    public struct Output: Codable, Equatable, Sendable {
        public struct Finding: Codable, Equatable, Sendable {
            public let kind: String
            public let family: String
            public let subject: String
            /// shape only: the schemes found, largest membership first.
            public struct Scheme: Codable, Equatable, Sendable {
                public let vocabulary: [String]
                public let members: [String]
            }
            public var schemes: [Scheme]?
            /// backlog only.
            public var scaffold: [String]?
            public var looseFiles: Int?
            /// shadowAxis only.
            public var target: String?
            public var targetExists: Bool?
            /// echoName only.
            public var counterpart: String?
            public var relation: String?
            /// mirroredInbox only.
            public var destination: String?
            /// looseAboveSeries only (with looseFiles).
            public var seriesFolders: Int?
            /// looseBesideContainer only.
            public var container: String?
            /// duplicatedTaxonomy only — distinct same-text documents spanning the pair.
            public var matchedDocuments: Int?
        }

        public struct Crowding: Codable, Equatable, Sendable {
            public let passThrough: [String]
            public let singleFileLeaf: [String]
            public let empty: [String]
        }

        public let schemaVersion: Int
        public let profileId: String
        public let root: String
        public let folderCount: Int
        public let findings: [Finding]
        public let crowding: Crowding
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noProfilesDirectory
        case noActiveProfile(directory: String)
        case unreadableProfile(id: String, directory: String)

        public var errorDescription: String? {
            switch self {
            case .noProfilesDirectory:
                return "No profiles directory. SyncCloud has never surveyed a tree on this "
                    + "machine — run the app's setup once, or pass --profiles-dir."
            case .noActiveProfile(let directory):
                return "No active profile in \(directory). Run the app's setup once to derive "
                    + "one, or pass --profiles-dir at a directory whose profiles.json names one."
            case .unreadableProfile(let id, let directory):
                return "The active profile '\(id)' in \(directory) could not be read. "
                    + "The lens would show its setup card for the same reason."
            }
        }
    }

    /// Loads the profile exactly where the app does — `profiles.json` names the active id, and
    /// `folder-profile.json` under it is the input — and runs the whole detector set on it.
    /// No walk, no app running; `directory` overrides for fixtures.
    public static func report(profilesDirectory: URL? = nil) throws -> Output {
        guard let directory = profilesDirectory ?? FilingProfileStore.defaultDirectory() else {
            throw Failure.noProfilesDirectory
        }
        guard let id = FilingProfileStore.activeProfileId(in: directory) else {
            throw Failure.noActiveProfile(directory: directory.path)
        }
        guard let profile = FilingProfileStore.profile(id: id, in: directory) else {
            throw Failure.unreadableProfile(id: id, directory: directory.path)
        }
        return output(for: profile, id: id)
    }

    static func output(for profile: FolderProfile, id: String) -> Output {
        let report = StructureDetectors.run(in: profile)
        let weights = report.deadWeight
        func paths(_ class: DeadWeightClass) -> [String] {
            weights.filter { $0.value == `class` }.map(\.key).sorted()
        }
        return Output(
            schemaVersion: 1,
            profileId: id,
            root: profile.root,
            folderCount: profile.folders.count,
            findings: report.findings.map(finding(for:)),
            crowding: Output.Crowding(passThrough: paths(.passThrough),
                                      singleFileLeaf: paths(.singleFileLeaf),
                                      empty: paths(.empty)))
    }

    static func finding(for finding: StructureFinding) -> Output.Finding {
        var out = Output.Finding(kind: finding.kind.rawValue, family: finding.family,
                                 subject: finding.subject)
        switch finding.detail {
        case .backlog(let scaffold, let looseFiles):
            out.scaffold = scaffold
            out.looseFiles = looseFiles
        case .shadowAxis(let target, let targetExists):
            out.target = target
            out.targetExists = targetExists
        case .echoName(let counterpart, let relation):
            out.counterpart = counterpart
            out.relation = relation == .parentChild ? "parentChild" : "sibling"
        case .mirroredInbox(let destination):
            out.destination = destination
        case .looseAboveSeries(let looseFiles, let seriesFolders):
            out.looseFiles = looseFiles
            out.seriesFolders = seriesFolders
        case .looseBesideContainer(let container):
            out.container = container
        case .duplicatedTaxonomy(let counterpart, let matchedDocuments):
            // Reachable only if the CLI ever grows a scan-backed run — the profile-pure
            // detectors it reports today never produce this kind — but the wire fields exist
            // now, so a future scan-backed report does not move the schema.
            out.counterpart = counterpart
            out.matchedDocuments = matchedDocuments
        case nil:
            break
        }
        if finding.kind == .shape {
            out.schemes = finding.schemes.map {
                Output.Finding.Scheme(vocabulary: $0.vocabulary, members: $0.members)
            }
        }
        return out
    }

    /// The `--json` rendering: sorted keys so two runs over one tree diff clean.
    public static func renderJSON(_ output: Output) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    /// The default rendering: the lens's answer, in terminal shape. One line per finding, the
    /// crowding counts as a footer — counts, not 609 paths, which is what `--json` is for.
    public static func renderText(_ output: Output) -> String {
        var lines: [String] = []
        if output.findings.isEmpty {
            lines.append("The tree agrees with itself — no structure findings "
                         + "(\(output.folderCount) folders).")
        } else {
            lines.append("\(output.findings.count) structure finding(s) in "
                         + "\(output.folderCount) folders:")
            for finding in output.findings {
                lines.append("  [\(finding.kind)] \(finding.subject)\(detailSuffix(finding))")
            }
        }
        lines.append("Crowding: \(output.crowding.passThrough.count) pass-through · "
                     + "\(output.crowding.singleFileLeaf.count) single-file · "
                     + "\(output.crowding.empty.count) empty")
        return lines.joined(separator: "\n")
    }

    static func detailSuffix(_ finding: Output.Finding) -> String {
        if let schemes = finding.schemes { return " — \(schemes.count) schemes" }
        if let scaffold = finding.scaffold {
            let shape = scaffold.isEmpty ? "no shared shape to copy"
                                         : "scaffold \(scaffold.joined(separator: ", "))"
            return " — \(count(finding.looseFiles ?? 0, "file")), no folders yet (\(shape))"
        }
        if let target = finding.target {
            return " — hides the year \(target)"
                + ((finding.targetExists ?? false) ? ", which exists beside it" : "")
        }
        if let counterpart = finding.counterpart {
            return " — echoes \(counterpart)"
        }
        if let destination = finding.destination { return " — mirrors \(destination)" }
        if let seriesFolders = finding.seriesFolders {
            return " — \(count(finding.looseFiles ?? 0, "file")) above \(seriesFolders) year folders"
        }
        if let container = finding.container { return " — belongs in \(container)" }
        return ""
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
