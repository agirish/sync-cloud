import Foundation
import ArgumentParser
import Sync
import Settings
import Events

// MARK: - Top-level command

@main
struct SyncCloudCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
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

// MARK: - Shared helpers

extension FileDifference.DifferenceType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingOnRight: return "missing-on-right"
        case .missingOnLeft: return "missing-on-left"
        case .differentDates: return "different"
        }
    }
}

extension FileDifference.SyncAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .copyToRight: return "copy-to-right"
        case .copyToLeft: return "copy-to-left"
        }
    }
}

private struct DiffSummary: Codable {
    let relativePath: String
    let leftPath: String
    let rightPath: String
    let type: String
    let action: String
    let description: String
    let leftSize: Int?
    let rightSize: Int?
}

private enum Direction: String, ExpressibleByArgument, CaseIterable {
    case auto
    case toRight = "to-right"
    case toLeft = "to-left"
}

private enum CollisionStrategy: String, ExpressibleByArgument {
    case replace
    case skip
    case keepBoth = "keep-both"
}

private func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

private func makeProvider(id: String, display: String, path: String) -> CloudProvider {
    CloudProvider(
        id: id,
        displayName: display,
        imageName: "folder",
        path: path,
        type: .iCloud
    )
}

private func resolveProviderOrPath(
    value: String,
    label: String,
    settings: SettingsManager
) -> CloudProvider {
    if let provider = settings.availableProviders.first(where: { $0.id == value || $0.displayName == value }) {
        return provider
    }
    let expanded = expandPath(value)
    return makeProvider(id: expanded, display: label, path: expanded)
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Scan two directories and print their differences."
    )

    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Flag(name: .shortAndLong, help: "Output machine-readable JSON.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by direction: \(Direction.allCases.map { $0.rawValue }.joined(separator: \", \")).")
    var direction: Direction = .auto

    func run() async throws {
        let settings = await MainActor.run { SettingsManager() }
        let leftProvider = resolveProviderOrPath(value: left, label: "Left", settings: settings)
        let rightProvider = resolveProviderOrPath(value: right, label: "Right", settings: settings)

        let leftURL = URL(fileURLWithPath: expandPath(leftProvider.path))
        let rightURL = URL(fileURLWithPath: expandPath(rightProvider.path))

        let leftInfo = try FileDiffEngine.getFilesInDirectory(leftURL)
        let rightInfo = try FileDiffEngine.getFilesInDirectory(rightURL)

        let diffs = FileDiffEngine.computeDifferences(
            left: leftProvider,
            leftURL: leftURL,
            right: rightProvider,
            rightURL: rightURL,
            leftFilesInfo: leftInfo,
            rightFilesInfo: rightInfo
        ).filter { diff in
            switch direction {
            case .auto:
                return true
            case .toRight:
                return diff.action == .copyToRight
            case .toLeft:
                return diff.action == .copyToLeft
            }
        }

        if json {
            let payload = diffs.map {
                DiffSummary(
                    relativePath: $0.relativePath,
                    leftPath: $0.leftItemPath,
                    rightPath: $0.rightItemPath,
                    type: $0.type.description,
                    action: $0.action.description,
                    description: $0.description,
                    leftSize: $0.leftFileSize,
                    rightSize: $0.rightFileSize
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        } else {
            if diffs.isEmpty {
                print("No differences found between")
                print("  Left : \(leftURL.path)")
                print("  Right: \(rightURL.path)")
                return
            }

            print("Differences (\(diffs.count)):")
            print("  Left : \(leftURL.path) [\(leftProvider.displayName)]")
            print("  Right: \(rightURL.path) [\(rightProvider.displayName)]")
            print("")

            for diff in diffs {
                let type = diff.type.description
                let action = diff.action.description
                print("- [\(type)] [\(action)] \(diff.relativePath)")
                print("    \(diff.description)")
            }
        }
    }
}

// MARK: - sync

struct SyncFiles: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Synchronize differences between two directories."
    )

    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Option(name: .shortAndLong, help: "Limit to a specific direction: auto | to-right | to-left.")
    var direction: Direction = .auto

    @Option(name: .shortAndLong, help: "Collision strategy when destination exists: replace | skip | keep-both.")
    var strategy: CollisionStrategy = .replace

    @Flag(name: .shortAndLong, help: "Run without interactive confirmation.")
    var yes: Bool = false

    func run() async throws {
        let settings = await MainActor.run { SettingsManager() }
        let leftProvider = resolveProviderOrPath(value: left, label: "Left", settings: settings)
        let rightProvider = resolveProviderOrPath(value: right, label: "Right", settings: settings)

        let leftURL = URL(fileURLWithPath: expandPath(leftProvider.path))
        let rightURL = URL(fileURLWithPath: expandPath(rightProvider.path))

        let leftInfo = try FileDiffEngine.getFilesInDirectory(leftURL)
        let rightInfo = try FileDiffEngine.getFilesInDirectory(rightURL)

        let allDiffs = FileDiffEngine.computeDifferences(
            left: leftProvider,
            leftURL: leftURL,
            right: rightProvider,
            rightURL: rightURL,
            leftFilesInfo: leftInfo,
            rightFilesInfo: rightInfo
        )

        let diffs: [FileDifference] = allDiffs.filter { diff in
            switch direction {
            case .auto:
                return true
            case .toRight:
                return diff.action == .copyToRight
            case .toLeft:
                return diff.action == .copyToLeft
            }
        }

        if diffs.isEmpty {
            print("Nothing to sync - no differences found.")
            return
        }

        print("Planned operations (\(diffs.count)):")
        for diff in diffs {
            let arrow = diff.action == .copyToRight ? "←" : "→"
            print("- \(diff.relativePath) \(arrow) [\(diff.type.description)]")
        }

        if !yes {
            print("")
            print("Proceed with these operations? [y/N]: ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Aborted.")
                return
            }
        }

        let fm = FileManager.default
        var copied = 0
        var skipped = 0
        var failed = 0

        for diff in diffs {
            let (sourcePath, targetPath): (String, String) = {
                switch diff.action {
                case .copyToRight:
                    return (diff.leftItemPath, diff.rightItemPath)
                case .copyToLeft:
                    return (diff.rightItemPath, diff.leftItemPath)
                }
            }()

            do {
                var finalTarget = targetPath
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: targetPath, isDirectory: &isDir) {
                    switch strategy {
                    case .skip:
                        skipped += 1
                        continue
                    case .replace:
                        if isDir.boolValue {
                            try fm.removeItem(atPath: targetPath)
                        }
                    case .keepBoth:
                        finalTarget = makeUniquePath(for: targetPath, fileManager: fm)
                    }
                }

                let targetURL = URL(fileURLWithPath: finalTarget)
                let parentDir = targetURL.deletingLastPathComponent().path
                if !fm.fileExists(atPath: parentDir, isDirectory: &isDir) {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
                }

                try fm.copyItem(atPath: sourcePath, toPath: finalTarget)
                copied += 1
            } catch {
                failed += 1
                let message = "Failed to copy \(diff.relativePath): \(error.localizedDescription)"
                Logger.shared.error(message, showAlert: false)
                fputs(message + "\n", stderr)
            }
        }

        print("")
        print("Sync complete. Copied: \(copied), Skipped: \(skipped), Failed: \(failed).")
    }

    private func makeUniquePath(for path: String, fileManager: FileManager) -> String {
        var url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        var dir = url.deletingLastPathComponent()

        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            let suffix = " copy\(counter == 1 ? "" : " \(counter)")"
            let newBase = base + suffix
            url = dir.appendingPathComponent(newBase).appendingPathExtension(ext)
            counter += 1
        }
        return url.path
    }
}

// MARK: - providers

struct Providers: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List discovered cloud providers and their root paths."
    )

    func run() async throws {
        let settings = await MainActor.run { SettingsManager() }
        // Ensure discovery has completed at least once.
        await settings.discoverProviders()

        if settings.availableProviders.isEmpty {
            print("No providers discovered.")
            return
        }

        print("Discovered providers:")
        for provider in settings.availableProviders {
            print("- \(provider.id)")
            print("    name : \(provider.displayName)")
            print("    type : \(provider.type.rawValue)")
            print("    path : \(provider.path)")
        }
    }
}

