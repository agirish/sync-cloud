import Events
import Foundation

/// One ⌘Z or ⇧⌘Z's per-item lines, capped, so undoing a 500-item move that changed since isn't
/// 500 lines. The first ``itemsLogged`` items each get their own line, as before; every item past
/// them is kept by its kind of outcome and named when the run ends, in one line per kind
/// (``LogNames``), so no name is dropped. Each registered undo or redo makes its own when it
/// fires, so a second ⌘Z starts counting again.
///
/// The per-item banners don't copy into the log (`.notMirrored`): their lines say more, and past
/// the cap a copy per item is the flood. The last banner the run showed goes into its summary
/// line (``summaryNote``), so the log still says what the user last saw.
final class UndoRunLog: @unchecked Sendable {
    enum Level: Sendable, Comparable { case info, warning, error }

    static let itemsLogged = 20

    /// "Undo" or "Redo", and the step's name as Edit ▸ Undo shows it.
    let step: String
    let actionName: String

    private let lock = NSLock()
    private var admitted = 0
    private var past: [Kind: [String]] = [:]
    private var lastBanner: String?

    private struct Kind: Hashable { let level: Level; let words: String }

    init(_ step: String, _ actionName: String) {
        self.step = step
        self.actionName = actionName
    }

    /// Whether this item's own line is written. Past the cap the item is kept under `kind` (what
    /// happened to it, without its name) for ``closingLines()``. `banner` is what the item showed.
    func admit(_ level: Level, kind: String, name: String, banner: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let banner { lastBanner = banner }
        guard admitted >= Self.itemsLogged else { admitted += 1; return true }
        past[Kind(level: level, words: kind), default: []].append(name)
        return false
    }

    /// The summary line's tail: the last banner the run showed, which nothing else records.
    var summaryNote: String {
        lock.lock(); defer { lock.unlock() }
        return lastBanner.map { "; last message shown: “\($0)”" } ?? ""
    }

    /// One line per kind past the cap, every name in it, at the level of that kind's own lines.
    func closingLines() -> [(level: Level, text: String)] {
        lock.lock(); let past = past; lock.unlock()
        return past.keys.sorted { ($0.level, $0.words) < ($1.level, $1.words) }.flatMap { kind in
            let names = past[kind] ?? []
            return LogNames.lines("\(step) (\(actionName)): \(names.count) more item(s) \(kind.words), "
                                  + "past the first \(Self.itemsLogged) logged above", names)
                .map { (level: kind.level, text: $0) }
        }
    }

    /// Writes ``closingLines()``. Call once, as the run ends, on every exit.
    func close(_ logger: Logger) {
        for line in closingLines() {
            switch line.level {
            case .info: logger.info(line.text)
            case .warning: logger.warning(line.text)
            case .error: logger.error(line.text)
            }
        }
    }
}

extension FileSyncManager {
    /// Shows one undo or redo item's banner and writes its line, unless `run` is past its cap,
    /// which keeps the item for its closing line under `kind`. The banner shows either way.
    nonisolated static func reportUndoItem(
        _ level: UndoRunLog.Level,
        _ logMessage: String,
        kind: String,
        item: URL,
        banner: String,
        run: UndoRunLog,
        on target: FileSyncManager,
        file: String = #file, line: Int = #line, function: String = #function
    ) async {
        let writes = run.admit(level, kind: kind, name: item.path, banner: banner)
        await MainActor.run {
            if writes {
                switch level {
                case .info: Logger.shared.info(logMessage)
                case .warning: Logger.shared.warning(logMessage, file: file, line: line, function: function)
                case .error: Logger.shared.error(logMessage, file: file, line: line, function: function)
                }
            }
            target.banner = .warning(banner, log: .notMirrored)
        }
    }
}
