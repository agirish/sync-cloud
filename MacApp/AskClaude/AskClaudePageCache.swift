import Foundation

/// Page 1 of each file filing help has read in this chat, in memory, so a loose-files card's
/// Next ranks its look-ahead again without reading it again (TE343). Keyed by the file and its
/// date modified, so a changed file is read afresh; ranking always runs anew, so a rule saved or
/// a filing taught since counts at once. New Chat clears it.
@MainActor
final class AskClaudePageCache {

    private struct Key: Hashable {
        let path: String
        let modified: Date?
        /// Read without OCR: a picture's light read is empty, so it never stands in for a full one.
        let light: Bool
    }

    /// Enough for four look-aheads; the oldest go first.
    static let capacity = 200

    private var pages: [Key: String] = [:]
    private var order: [Key] = []

    /// Page 1 of `path`, kept or read with `read`. A full read serves a light one too. Nothing is
    /// kept for an empty answer: a cloud-only file is never read, and may be here, unchanged in
    /// date, the next time.
    func page(_ path: String, light: Bool, read: (String) async -> String?) async -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let full = Key(path: path, modified: modified, light: false)
        if let page = pages[full] { return page }
        let key = Key(path: path, modified: modified, light: light)
        if light, let page = pages[key] { return page }
        guard let page = await read(path), !page.isEmpty else { return nil }
        keep(page, key)
        return page
    }

    var count: Int { pages.count }

    func removeAll() {
        pages = [:]
        order = []
    }

    private func keep(_ page: String, _ key: Key) {
        if pages.updateValue(page, forKey: key) == nil { order.append(key) }
        while order.count > Self.capacity { pages[order.removeFirst()] = nil }
    }
}
