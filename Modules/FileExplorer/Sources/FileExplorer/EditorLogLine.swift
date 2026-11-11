import Events

/// One line an editor open writes, with its level: a refusal is WARN or INFO by its kind
/// (``EditorFileStore/RefusalKind``), everything else INFO. Handed to a `log` closure rather than
/// written here, so a test can read both without the shared logger.
public struct EditorLogLine: Equatable, Sendable {
    public let level: LogLevel
    public let text: String

    public init(_ level: LogLevel, _ text: String) {
        self.level = level
        self.text = text
    }

    public static func info(_ text: String) -> EditorLogLine { EditorLogLine(.info, text) }

    /// Writes the line to `Logger.shared` at its level; a warning's location tail names the caller.
    public func write(file: String = #file, line: Int = #line, function: String = #function) {
        switch level {
        case .debug: Logger.shared.debug(text)
        case .info: Logger.shared.info(text)
        case .warning: Logger.shared.warning(text, file: file, line: line, function: function)
        case .error: Logger.shared.error(text, file: file, line: line, function: function)
        }
    }
}
