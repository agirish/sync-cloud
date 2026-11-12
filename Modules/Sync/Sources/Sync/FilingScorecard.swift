import Events
import Foundation

/// TE341: how often a filing kept the first folder it was offered (decisions NH–NL).
///
/// One record per filing that moved a file: what was offered first, how sure, what chose it, and
/// where the file went. Read back as the line above To File's cards and the Details sheet. Kept on
/// this Mac, a year at most; Undo removes a filing's record (``FilingScorecardStore/forget(landedAt:)``).
///
/// "Kept" means the file went into exactly the folder offered first, which is what the held-out
/// replay's top-1 counts (`FilingCardReplayTests`), so the two numbers mean the same thing. A
/// folder inside it is "deeper" (decision NI), neither kept nor changed.
public enum FilingScorecard {

    /// Whether the line shows above To File's cards. Hide, View ▸ Filing Scorecard and Settings
    /// all write it (decision NK). Counting goes on either way.
    public static let shownDefaultsKey = "filingScorecardShown"

    /// The filing change records are stamped with. Bump it, and add a ``revisions`` entry, in the
    /// commit of any change to how filing chooses a folder, so Details can show before and after.
    public static let revision = 1

    /// Each filing change since counting began, oldest first. The first entry's label is never
    /// shown: the oldest row in range reads "Before".
    public static let revisions: [Revision] = [
        Revision(number: 1, date: day(2026, 11, 11), name: "counting starts"),
    ]

    public struct Revision: Sendable, Equatable {
        public let number: Int
        public let date: Date
        public let name: String
    }

    /// The held-out replay's share right first time per confidence, measured 1 Nov
    /// (`FilingCardReplayTests`, a510c116c). Update with the replay.
    public static let replay: [FilingConfidence: Double] = [.high: 0.767, .medium: 0.565, .low: 0.29]

    /// Records older than this are dropped.
    public static let keptFor: TimeInterval = 366 * 24 * 60 * 60

    /// What made the first pick.
    public enum Evidence: String, Codable, Sendable, CaseIterable {
        /// A rule he saved.
        case rule
        /// The folder survey, by the file's name.
        case survey
        /// Words read from page 1.
        case page
        /// The on-device model a scan asks (Settings' "Suggest folders with Apple Intelligence").
        case model
        /// One or more words of the name, outside the survey.
        case name

        public var label: String {
            switch self {
            case .rule: return "Your rule"
            case .survey: return "Folder survey"
            case .page: return "Page 1"
            case .model: return "Apple Intelligence"
            case .name: return "Name word"
            }
        }

        /// The kind of evidence a card's folder rests on.
        public init(_ destination: FilingDestination) {
            if destination.remembered { self = .rule }
            else if destination.fromAI { self = .model }
            else if destination.fromContent { self = .page }
            else if destination.fromSurvey { self = .survey }
            else { self = .name }
        }
    }

    /// Who offered the first pick. Only this Mac's picks make the line; Claude's (Refine) and
    /// Rules' filings are the sheet's last line.
    public enum Picker: String, Codable, Sendable {
        case mac, claude, rules
    }

    public enum Verdict: String, Codable, Sendable {
        case kept, deeper, changed
    }

    /// Where a changed file went instead.
    public enum Change: String, Codable, Sendable {
        /// The second folder offered.
        case runnerUp
        /// A folder made after the offer, not one the card offered.
        case newFolder
        case other
    }

    /// What a card offered, kept from when it was first shown so Try Another and Choose a Folder
    /// can't erase it.
    public struct Offer: Codable, Equatable, Sendable {
        public var path: String
        public var confidence: FilingConfidence
        public var evidence: Evidence
        public var picker: Picker
        public var runnerUp: String?
        /// New folders the card itself offered: going to one is never "your new folder".
        public var offeredNew: [String]
        /// The survey root it was offered under, for the area.
        public var root: String?
        public var at: Date

        public init(path: String, confidence: FilingConfidence, evidence: Evidence, picker: Picker,
                    runnerUp: String? = nil, offeredNew: [String] = [], root: String? = nil, at: Date = Date()) {
            self.path = path
            self.confidence = confidence
            self.evidence = evidence
            self.picker = picker
            self.runnerUp = runnerUp
            self.offeredNew = offeredNew
            self.root = root
            self.at = at
        }

        /// The same offer whenever it was made: a rescan offering the same folders gives an equal
        /// card, as the scan caches expect.
        public static func == (a: Offer, b: Offer) -> Bool {
            (a.path, a.confidence, a.evidence, a.picker) == (b.path, b.confidence, b.evidence, b.picker)
                && (a.runnerUp, a.offeredNew, a.root) == (b.runnerUp, b.offeredNew, b.root)
        }

        /// An Ask Claude answer's offer: its first folder and runner-up.
        public init?(_ list: [FilingHelpAnswer.Suggestion], root: String?, at: Date = Date()) {
            guard let best = list.first else { return nil }
            self.init(path: best.folder, confidence: best.confidence, evidence: best.evidence, picker: .mac,
                      runnerUp: list.dropFirst().first?.folder, offeredNew: list.filter(\.isNew).map(\.folder),
                      root: root, at: at)
        }

        /// A To File card's offer: its leading folder and runner-up as they stand. `picker` is
        /// `.claude` only for an answer Refine moved the card to.
        public init?(_ candidates: [FilingDestination], root: String?, picker: Picker = .mac, at: Date = Date()) {
            guard let best = candidates.first else { return nil }
            self.init(path: best.path, confidence: best.confidence, evidence: Evidence(best),
                      picker: picker,
                      runnerUp: candidates.dropFirst().first?.path,
                      offeredNew: candidates.filter(\.isNew).map(\.path), root: root, at: at)
        }
    }

    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var at: Date
        public var picker: Picker
        public var confidence: FilingConfidence?
        public var evidence: Evidence?
        /// The folder offered first; nil for a rule's filing.
        public var offered: String?
        /// The folder the file landed in.
        public var landed: String
        /// The file as it landed: Undo finds the record by it.
        public var file: String
        public var root: String?
        public var verdict: Verdict
        public var change: Change?
        public var revision: Int

        public init(id: UUID = UUID(), at: Date = Date(), picker: Picker, confidence: FilingConfidence?,
                    evidence: Evidence?, offered: String?, landed: String, file: String, root: String?,
                    verdict: Verdict, change: Change? = nil, revision: Int = FilingScorecard.revision) {
            self.id = id
            self.at = at
            self.picker = picker
            self.confidence = confidence
            self.evidence = evidence
            self.offered = offered
            self.landed = landed
            self.file = file
            self.root = root
            self.verdict = verdict
            self.change = change
            self.revision = revision
        }

        public var fileName: String { (file as NSString).lastPathComponent }

        /// The top folder under the root it landed in, or nil outside it.
        public var area: String? {
            guard let root, let rel = PathBoundary.relativize(landed, under: root), !rel.isEmpty else { return nil }
            return rel.split(separator: "/").first.map(String.init)
        }
    }

    /// The record for a file that went into `landedFile` after `offer`.
    /// - `folderCreated`: when the landed folder was made, read only for a change.
    public static func record(_ offer: Offer, landedFile: String, at now: Date = Date(),
                              folderCreated: (String) -> Date? = Self.creationDate) -> Record {
        let landed = (landedFile as NSString).deletingLastPathComponent
        let (verdict, change) = judge(offer, landed: landed, folderCreated: folderCreated)
        return Record(at: now, picker: offer.picker, confidence: offer.confidence, evidence: offer.evidence,
                      offered: offer.path, landed: landed, file: landedFile, root: offer.root,
                      verdict: verdict, change: change)
    }

    /// An applied Ask Claude card's filing rows: each that moved, judged against what it offered.
    /// `landed`: where each row's file landed, by row id.
    public static func records(_ plan: AskClaudePlan, landed: [Int: String], at now: Date = Date(),
                               folderCreated: (String) -> Date? = Self.creationDate) -> [Record] {
        plan.rows.compactMap { row in
            guard row.applied == true, case .move = row.change, let offer = row.offer,
                  let file = landed[row.id] else { return nil }
            return record(offer, landedFile: file, at: now, folderCreated: folderCreated)
        }
    }

    /// A rule's filing: one folder offered, so no verdict to judge. Counted as kept, shown apart.
    public static func ruleRecord(landedFile: String, root: String?, at now: Date = Date()) -> Record {
        Record(at: now, picker: .rules, confidence: nil, evidence: nil, offered: nil,
               landed: (landedFile as NSString).deletingLastPathComponent, file: landedFile, root: root,
               verdict: .kept)
    }

    static func judge(_ offer: Offer, landed: String,
                      folderCreated: (String) -> Date?) -> (Verdict, Change?) {
        if let rel = PathBoundary.relativize(landed, under: offer.path) {
            return (rel.isEmpty ? .kept : .deeper, nil)
        }
        // The new folder it offered, renamed before filing: the same place under his name.
        let parent = { (path: String) in (path as NSString).deletingLastPathComponent }
        if offer.offeredNew.contains(offer.path), PathBoundary.relativize(parent(landed), under: parent(offer.path)) == "",
           let made = folderCreated(landed), made >= offer.at {
            return (.kept, nil)
        }
        if let runnerUp = offer.runnerUp, PathBoundary.relativize(landed, under: runnerUp) == "" {
            return (.changed, .runnerUp)
        }
        let offeredNew = offer.offeredNew.contains { PathBoundary.relativize(landed, under: $0) == "" }
        if !offeredNew, let made = folderCreated(landed), made > offer.at {
            return (.changed, .newFolder)
        }
        return (.changed, .other)
    }

    public static func creationDate(_ folder: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: folder))?[.creationDate] as? Date
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day) = (y, m, d)
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - Summary

extension FilingScorecard {

    /// The time range Details shows (decision NL).
    public enum Range: String, CaseIterable, Identifiable, Sendable {
        case days30, days90, all
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .days30: return "30 Days"
            case .days90: return "90 Days"
            case .all: return "All"
            }
        }
        var days: Int? {
            switch self {
            case .days30: return 30
            case .days90: return 90
            case .all: return nil
            }
        }
        func admits(_ date: Date, now: Date) -> Bool {
            guard let days else { return true }
            return date > now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        }
    }

    /// One bar: how a group's filings split.
    public struct Tally: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public var label: String
        public var kept = 0
        public var deeper = 0
        public var changed = 0
        /// The replay's rate for this group, when there is one.
        public var replay: Double?
        public var total: Int { kept + deeper + changed }

        public init(label: String, kept: Int = 0, deeper: Int = 0, changed: Int = 0, replay: Double? = nil) {
            self.label = label
            self.kept = kept
            self.deeper = deeper
            self.changed = changed
            self.replay = replay
        }

        mutating func add(_ verdict: Verdict) {
            switch verdict {
            case .kept: kept += 1
            case .deeper: deeper += 1
            case .changed: changed += 1
            }
        }
    }

    /// The same change made more than once: a rule would save making it again.
    public struct Repeat: Equatable, Sendable {
        public var offered: String
        public var landed: String
        public var count: Int
        /// The newest of them, for the rule.
        public var latest: Record
    }

    public struct Summary: Equatable, Sendable {
        /// This Mac's picks.
        public var all = Tally(label: "")
        public var runnerUp = 0
        public var newFolder = 0
        public var other = 0
        /// Empty unless the range holds filings from two filing changes or more.
        public var byUpdate: [Tally] = []
        public var byConfidence: [Tally] = []
        public var byEvidence: [Tally] = []
        public var byArea: [Tally] = []
        /// Changed filings, newest first.
        public var changes: [Record] = []
        public var repeats: [Repeat] = []
        /// Claude's Refine answers.
        public var refine = Tally(label: "Refine")
        public var rules = 0
    }

    public static func summary(_ records: [Record], range: Range, now: Date = Date()) -> Summary {
        var s = Summary()
        let inRange = records.filter { range.admits($0.at, now: now) }
        var updates: [Int: Tally] = [:]
        var confidence: [FilingConfidence: Tally] = [:]
        var evidence: [Evidence: Tally] = [:]
        var areas: [String: Tally] = [:]
        var pairs: [String: Repeat] = [:]
        for r in inRange {
            switch r.picker {
            case .rules: s.rules += 1; continue
            case .claude: s.refine.add(r.verdict); continue
            case .mac: break
            }
            s.all.add(r.verdict)
            updates[r.revision, default: Tally(label: "")].add(r.verdict)
            if let c = r.confidence { confidence[c, default: Tally(label: label(c), replay: replay[c])].add(r.verdict) }
            if let e = r.evidence { evidence[e, default: Tally(label: e.label)].add(r.verdict) }
            if let a = r.area { areas[a, default: Tally(label: a)].add(r.verdict) }
            guard r.verdict == .changed else { continue }
            switch r.change ?? .other {
            case .runnerUp: s.runnerUp += 1
            case .newFolder: s.newFolder += 1
            case .other: s.other += 1
            }
            s.changes.append(r)
            if let offered = r.offered {
                let key = offered + "\u{0}" + r.landed
                if var seen = pairs[key] {
                    seen.count += 1
                    if r.at > seen.latest.at { seen.latest = r }
                    pairs[key] = seen
                } else {
                    pairs[key] = Repeat(offered: offered, landed: r.landed, count: 1, latest: r)
                }
            }
        }
        s.changes.sort { $0.at > $1.at }
        s.repeats = pairs.values.filter { $0.count > 1 }.sorted { ($0.count, $0.latest.at) > ($1.count, $1.latest.at) }
        if updates.count > 1 {
            let oldest = updates.keys.min()
            s.byUpdate = updates.keys.sorted(by: >).map { n in
                var t = updates[n]!
                t.label = n == oldest ? "Before" : revisionLabel(n)
                return t
            }
        }
        s.byConfidence = [FilingConfidence.high, .medium, .low].compactMap { confidence[$0] }
        s.byEvidence = Evidence.allCases.compactMap { evidence[$0] }
        s.byArea = areas.values.sorted { ($0.total, $1.label) > ($1.total, $0.label) }
        return s
    }

    /// The confidence as To File's sections name it.
    public static func label(_ c: FilingConfidence) -> String {
        switch c {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Needs your pick"
        }
    }

    static func revisionLabel(_ n: Int) -> String {
        guard let r = revisions.first(where: { $0.number == n }) else { return "Update \(n)" }
        return r.date.formatted(.dateTime.day().month(.abbreviated)) + " · " + r.name
    }

    /// The line above To File's cards: always one line, so filing never moves the cards.
    /// - `hasAny`: whether anything was ever recorded.
    public static func line(_ s: Summary, hasAny: Bool) -> String {
        if s.all.total > 0 { return "First pick kept \(s.all.kept) of \(s.all.total) · last 30 days" }
        return hasAny ? "First pick kept: none in the last 30 days" : "First pick kept: none yet"
    }

    /// A folder as Details shows it: from the area down, joined with ›.
    public static func display(_ folder: String, root: String?) -> String {
        if let root, let rel = PathBoundary.relativize(folder, under: root), !rel.isEmpty {
            return rel.split(separator: "/").joined(separator: " › ")
        }
        return (folder as NSString).lastPathComponent
    }
}

// MARK: - Store

/// The records, in `~/Library/Application Support/SyncCloud/filing-scorecard.jsonl`, one JSON line
/// each. Small (a year of filings), so each change rewrites the file, off the main actor.
@MainActor
public final class FilingScorecardStore: ObservableObject {
    public static let shared = FilingScorecardStore()

    @Published public private(set) var records: [FilingScorecard.Record] = []
    /// Whether anything was ever recorded, for the line's "none yet".
    public var hasAny: Bool { !records.isEmpty }
    public let fileURL: URL?
    private let queue = DispatchQueue(label: "SyncCloud.FilingScorecard.write")
    /// Dates as numbers, as Sync History writes them: they round-trip exactly.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    /// nil keeps the records in memory only.
    public init(fileURL: URL? = FilingScorecardStore.defaultFileURL(), now: Date = Date()) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoded = lines.compactMap { try? Self.decoder.decode(FilingScorecard.Record.self, from: Data($0)) }
        records = decoded.filter { now.timeIntervalSince($0.at) < FilingScorecard.keptFor }
        if records.count != lines.count { save() }
    }

    /// The real file, or under a test runner a per-process temp file, as Sync History does.
    public nonisolated static func defaultFileURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
        if executable == "swiftpm-testing-helper" || executable == "xctest" || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return PerProcessTestFile.url(stem: "sync-cloud-filing-scorecard-tests", extension: "jsonl")
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/filing-scorecard.jsonl")
    }

    public func append(_ new: [FilingScorecard.Record]) {
        guard !new.isEmpty else { return }
        records.append(contentsOf: new)
        save()
    }

    /// Undo moved these files back: their filings no longer count. A redo doesn't count them again.
    public func forget(landedAt files: [String]) {
        let gone = Set(files.map { ($0 as NSString).standardizingPath })
        let kept = records.filter { !gone.contains(($0.file as NSString).standardizingPath) }
        guard kept.count != records.count else { return }
        let n = records.count - kept.count
        records = kept
        save()
        Logger.shared.info("Filing scorecard: Undo took back \(n) filing\(n == 1 ? "" : "s")")
    }

    public func summary(_ range: FilingScorecard.Range, now: Date = Date()) -> FilingScorecard.Summary {
        FilingScorecard.summary(records, range: range, now: now)
    }

    private func save() {
        guard let fileURL else { return }
        let lines = records.compactMap { try? Self.encoder.encode($0) }
        var data = Data()
        for line in lines { data.append(line); data.append(UInt8(ascii: "\n")) }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                _ = Logger.shared.warning("Filing scorecard: couldn’t write \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
