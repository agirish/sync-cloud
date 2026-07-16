import Foundation
import ArgumentParser
import Sync
import SyncCloudCLICore

// MARK: - Top-level command
//
// The executable target is a thin argument-parse-and-delegate shell: every command body lives
// in SyncCloudCLICore's `CommandRunner` (unit-tested there), wired to its real edges — settings
// discovery, the app log, stdout/stderr — in Commands.swift.

@main
struct SyncCloudCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "synccloud",
        abstract: "Command line interface for SyncCloud.",
        discussion: """
        A git-like CLI for comparing and synchronizing two directories, with smart defaults for common cloud providers.
        """,
        subcommands: [
            Scan.self,
            SyncFiles.self,
            Providers.self
        ],
        defaultSubcommand: Scan.self
    )
}

// MARK: - Shared options

extension Direction: ExpressibleByArgument {}
extension CollisionStrategy: ExpressibleByArgument {}

/// The options `scan` and `sync` share verbatim: the two sides plus the difference filters.
/// Declared once and pulled in via `@OptionGroup` so the subcommands cannot drift apart
/// flag-by-flag.
struct CommonOptions: ParsableArguments {
    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Option(name: .shortAndLong, help: "Limit to a specific direction: auto | to-right | to-left.")
    var direction: Direction = .auto

    @Flag(name: .customLong("show-hidden"), help: "Include hidden files and folders.")
    var showHidden: Bool = false

    @Option(name: .long, help: "Paths to ignore.")
    var ignore: [String] = []
}
