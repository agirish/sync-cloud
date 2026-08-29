import Foundation

/// §5.6: Refine with Claude — **on the mapping, never on the apply.** The plan is derived
/// mechanically from the mapping, so by apply time there is no judgement left; the judgement is
/// *what should these folders be called*, the one question the tree cannot answer and a model
/// can. Accepting a proposal edits the mapping; the plan re-derives and is reviewed exactly as
/// before — there is no path to the disk that skips the manifest.
///
/// Request/response shaping is pure and lives here (``CloudFilingProtocol``'s split): the app
/// side only does the network call and the spend bookkeeping.
public struct MappingRefineRequest: Sendable, Equatable {
    public let family: String
    /// Member folder names, for the model to see the eras the mapping spans.
    public let members: [String]
    /// The mapping as the user has it — source name → target, nil = keep.
    public let rows: [RestructureMapping.Row]
    /// The candidate vocabularies — each scheme's shared names, plus whatever the user added.
    public let candidateVocabularies: [[String]]
    /// Up to five file names per source folder — the toggle's payload, and the evidence class
    /// that settled I-129 vs I-539 on 6 Aug. Empty when the toggle is off. **File contents
    /// never** ride in a mapping refine; that is the disclosure's third clause and this type
    /// simply has nowhere to put them.
    public let sampleFileNames: [String: [String]]

    public init(family: String, members: [String], rows: [RestructureMapping.Row],
                candidateVocabularies: [[String]], sampleFileNames: [String: [String]] = [:]) {
        self.family = family
        self.members = members
        self.rows = rows
        self.candidateVocabularies = candidateVocabularies
        self.sampleFileNames = sampleFileNames
    }
}

/// One row of the model's answer — a proposal, a keep, or a decline, each with its written why.
///
/// **`declined` is a first-class outcome, not an absence**: a model that answers every row is
/// guessing on some of them, and the row where it says so is rendered like any other (§5.6).
public struct MappingRefineProposal: Sendable, Equatable, Identifiable {
    public enum Verdict: Equatable, Sendable {
        /// Map `source` to this target name.
        case propose(target: String)
        /// Leave the source where and as it stands.
        case keep
        /// The model does not know — and said so.
        case declined
    }

    public let source: String
    public let verdict: Verdict
    /// The written justification — every proposal carries one, or a reviewer is being asked to
    /// trust rather than to review.
    public let why: String

    public var id: String { source }

    public init(source: String, verdict: Verdict, why: String) {
        self.source = source
        self.verdict = verdict
        self.why = why
    }
}

/// The seam the app injects on ``FileSyncManager`` — nil when no key is stored, which is the
/// sheet's invitation state. Returns nil on a hard failure (the sheet says so), an array
/// otherwise.
public typealias MappingRefiner =
    @Sendable (_ request: MappingRefineRequest) async -> [MappingRefineProposal]?

/// The wire shape — one tool-forced Messages call, mirroring ``CloudFilingProtocol``'s pattern
/// so the transport, the spend store and the model picker are shared unchanged.
public enum MappingRefineProtocol {

    public static let toolName = "mapping_proposals"

    /// The request body. The payload is exactly what the sheet disclosed: folder paths and
    /// candidate names always, sample file names only when the caller put them in the request.
    public static func requestBody(model: String = CloudFilingProtocol.defaultModel,
                                   request: MappingRefineRequest) -> [String: Any] {
        let instructions = """
        You are helping name folders consistently inside one recurring family of folders (for \
        example, one folder per tax year). You will see the family's member folders, the distinct \
        child-folder names that occur across them, the candidate vocabularies that already exist, \
        and the user's current mapping of each name (a target name, or keep). For each source \
        name, either propose the target name it should map to, say keep, or DECLINE when the \
        evidence given is not enough to know.

        Rules:
        • Prefer names from the candidate vocabularies; propose a new name only when every \
        candidate is wrong for the meaning.
        • Two different concepts must not be merged: if two source names mean different things \
        (a petition and an application, a form and a receipt), map them to different targets and \
        say why.
        • Declining is a good answer. Never guess to fill a row.
        • One short written justification per row — the user reviews these one by one.
        """

        var userText = "Family: \(request.family)\n"
        userText += "Members: \(request.members.joined(separator: ", "))\n"
        userText += "Candidate vocabularies:\n"
        for vocabulary in request.candidateVocabularies {
            userText += "  • \(vocabulary.joined(separator: " · "))\n"
        }
        userText += "\nSource names and the user's current mapping:\n"
        for row in request.rows {
            userText += "- \(row.source) → \(row.target ?? "keep")\n"
            if let samples = request.sampleFileNames[row.source], !samples.isEmpty {
                userText += "    files: \(samples.prefix(5).joined(separator: ", "))\n"
            }
        }
        userText += "\nAnswer for every source name."

        let tool: [String: Any] = [
            "name": toolName,
            "description": "Return one verdict per source folder name.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "proposals": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "source": ["type": "string",
                                           "description": "the source name, exactly as given"],
                                "verdict": ["type": "string",
                                            "enum": ["propose", "keep", "declined"]],
                                "target": ["type": "string",
                                           "description": "the proposed target name; empty unless verdict is propose"],
                                "why": ["type": "string",
                                        "description": "one short sentence of justification"],
                            ],
                            "required": ["source", "verdict", "target", "why"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["proposals"],
                "additionalProperties": false,
            ],
        ]

        return [
            "model": model,
            "max_tokens": min(8192, 512 + request.rows.count * 80),
            "system": [["type": "text", "text": instructions]],
            "messages": [["role": "user", "content": userText]],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": toolName],
        ]
    }

    /// Parses the response into proposals — nil for an error or an unreadable shape (the caller
    /// says the pass failed), never a silent partial guess: a row with an unknown verdict string
    /// is dropped rather than coerced.
    public static func parseProposals(responseData: Data,
                                      rows: [RestructureMapping.Row]) -> [MappingRefineProposal]? {
        guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else { return nil }
        if (root["type"] as? String) == "error" { return nil }
        guard let content = root["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let proposals = input["proposals"] as? [[String: Any]] else { return nil }
        // Only rows that were asked about may answer — a hallucinated source name is dropped. An
        // answer differing from the asked name only by case is the model being sloppy about a
        // real row, so it maps back to the asked spelling rather than being dropped as invented.
        let asked = Set(rows.map(\.source))
        let askedByLowered = Dictionary(rows.map { ($0.source.lowercased(), $0.source) },
                                        uniquingKeysWith: { first, _ in first })
        // First answer per source wins: a model working a long list sometimes answers a row
        // twice, and two proposals sharing one id break the sheet's ForEach and would write the
        // same mapping row from two contradictory cards.
        var seen: Set<String> = []
        var out: [MappingRefineProposal] = []
        for entry in proposals {
            guard let raw = entry["source"] as? String,
                  let source = asked.contains(raw) ? raw : askedByLowered[raw.lowercased()],
                  let verdictRaw = entry["verdict"] as? String,
                  let why = entry["why"] as? String,
                  !seen.contains(source) else { continue }
            let verdict: MappingRefineProposal.Verdict
            switch verdictRaw {
            case "keep": verdict = .keep
            case "declined": verdict = .declined
            case "propose":
                // A model-proposed target is a FOLDER NAME, and the planner's rule is the one
                // spelling of that — a path-shaped answer ("Tax/2024", "../Shared") accepted
                // here would flow into a mapping row and aim a rename outside the family. The
                // derivation's `.invalidTargetName` refusal backstops this, but a proposal the
                // user can accept should not be one the plan must then refuse.
                guard let target = entry["target"] as? String,
                      RestructurePlanner.isValidTargetName(target) else { continue }
                // A tool-forced schema makes `target` mandatory, so a model with nothing to
                // change answers `A → A` instead of keep — normalised here, or the degenerate
                // self-proposal would even earn a false "swaps places with itself" label.
                // Compared against the model's RAW spelling too: "claims → claims" is a keep
                // even after the source is mapped back to the asked "Claims", or the case fix
                // would turn the model's no-op into a down-casing proposal it never made.
                verdict = target == source || target == raw ? .keep : .propose(target: target)
            default:
                continue
            }
            // The dedupe slot is taken by the first VALID answer — a malformed first entry for
            // a row must not swallow the good one behind it.
            seen.insert(source)
            out.append(MappingRefineProposal(source: source, verdict: verdict, why: why))
        }
        return out
    }

    /// A rough token estimate for the pre-flight quote — the request's text sizes over four
    /// chars a token, plus the same output budget the body reserves. Rough is fine: the quote's
    /// job is the right order of magnitude and the same caps arithmetic as every other paid call.
    public static func estimateTokens(request: MappingRefineRequest) -> (input: Int, output: Int) {
        var chars = 900   // instructions + tool schema, measured order of magnitude
        chars += request.family.count + request.members.joined().count
        chars += request.candidateVocabularies.flatMap { $0 }.joined().count
        for row in request.rows {
            chars += row.source.count + (row.target?.count ?? 4) + 8
            chars += (request.sampleFileNames[row.source] ?? []).joined().count
        }
        return (input: chars / 4, output: min(8192, 512 + request.rows.count * 80))
    }

    /// The pre-flight cost at list prices — nil for an unpriced model, which the caller must
    /// treat as "may not run", never as free (`CloudFilingProtocol`'s own rule).
    public static func estimatedCostUSD(model: String,
                                        request: MappingRefineRequest) -> Double? {
        guard let pricing = CloudFilingProtocol.pricing(for: model) else { return nil }
        let tokens = estimateTokens(request: request)
        return Double(tokens.input) / 1_000_000 * pricing.input
            + Double(tokens.output) / 1_000_000 * pricing.output
    }

    /// The adjacency rule §5.6 orders: a proposal that *reverses* another proposal, or reverses
    /// the user's own row, is labelled — or a reviewer reads the pair as a bug. Returns the
    /// sentence for `proposal`, or nil when nothing is reversed.
    public static func reversalNote(for proposal: MappingRefineProposal,
                                    among proposals: [MappingRefineProposal],
                                    rows: [RestructureMapping.Row]) -> String? {
        guard case .propose(let target) = proposal.verdict else { return nil }
        // Another proposal sending the target's name to this source's name: a swap. Never the
        // proposal itself — `parseProposals` normalises `A → A` to keep, and this guard keeps
        // the rule safe against a caller that did not.
        if proposals.contains(where: { other in
            other.source != proposal.source
                && other.source == target && other.verdict == .propose(target: proposal.source)
        }) {
            return "swaps places with \(target) — the two proposals reverse each other"
        }
        // The user's own mapping goes the other way.
        if rows.contains(where: { $0.source == target && $0.target == proposal.source }) {
            return "reverses your \(target) → \(proposal.source)"
        }
        return nil
    }
}
