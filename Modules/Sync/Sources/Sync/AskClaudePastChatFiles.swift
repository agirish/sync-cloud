import Events
import Foundation

/// How long Ask Claude keeps a past chat on this Mac (decision IL: 30 days by default).
public enum AskClaudePastChatKeep: String, CaseIterable, Sendable {
    case week
    case month
    case forever

    public static let defaultsKey = "askClaudeKeepPastChats"
    public static let standard: AskClaudePastChatKeep = .month

    public static func stored(in defaults: UserDefaults) -> AskClaudePastChatKeep {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? standard
    }

    /// Days a chat is kept after its last question; nil keeps it until it is deleted.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .forever: nil
        }
    }

    public var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .forever: "Until I delete them"
        }
    }

    /// The panel's subtitle over the list.
    public var subtitle: String {
        switch self {
        case .week: "Kept on this Mac for 7 days"
        case .month: "Kept on this Mac for 30 days"
        case .forever: "Kept on this Mac until you delete them"
        }
    }
}

/// The folder of Ask Claude's past chats, one file per chat, read and pruned without decoding them.
/// The app decodes what is in them; Settings counts and clears them.
///
/// Each file's modification date is set to the chat's last question, so pruning goes by when it was
/// last used, not by when it was put away.
public struct AskClaudePastChatFiles: Sendable {
    /// Posted after chats are added, deleted or pruned, so an open list and Settings' count follow.
    public static let didChange = Notification.Name("AskClaudePastChatsDidChange")

    public static let defaultFolder: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SyncCloud/AskClaude/Past", isDirectory: true)

    public struct Entry: Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public let lastAsked: Date
        public let bytes: Int
    }

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func url(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".json")
    }

    /// The chats on disk, newest first. A file not named for a chat is left alone.
    public func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url -> Entry? in
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(id: id, url: url, lastAsked: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
        }
        .sorted { $0.lastAsked > $1.lastAsked }
    }

    /// Writes one chat, dated by its last question.
    public func write(_ data: Data, id: UUID, lastAsked: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(for: id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: lastAsked], ofItemAtPath: url.path)
    }

    public func read(_ id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: url(for: id))
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return false
        } catch {
            Logger.shared.warning("Ask Claude: a past chat couldn’t be deleted — \(error.localizedDescription)")
            return false
        }
    }

    /// The chats a keep length would delete now.
    public func expired(keep: AskClaudePastChatKeep, now: Date) -> [Entry] {
        guard let days = keep.days else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries().filter { $0.lastAsked < cutoff }
    }

    /// Deletes the chats past the keep length. Returns how many went.
    @discardableResult
    public func prune(keep: AskClaudePastChatKeep, now: Date) -> Int {
        let gone = expired(keep: keep, now: now).filter { delete($0.id) }.count
        if gone > 0 {
            Logger.shared.info("Ask Claude: deleted \(gone) past chat\(gone == 1 ? "" : "s") older than \(keep.label)")
        }
        return gone
    }

    /// Clear All: every past chat. Returns how many went.
    @discardableResult
    public func clearAll() -> Int {
        let gone = entries().filter { delete($0.id) }.count
        Logger.shared.info("Ask Claude: Clear All deleted \(gone) past chat\(gone == 1 ? "" : "s")")
        return gone
    }

    /// "14 chats, 840 KB", or nil with none.
    public static func describe(_ entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let bytes = entries.reduce(0) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(entries.count) chat\(entries.count == 1 ? "" : "s"), \(size)"
    }
}
