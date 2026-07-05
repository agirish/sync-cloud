import Foundation
import ArgumentParser
import Sync
import Settings
import Events

// MARK: - Top-level command

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

// MARK: - Shared helpers

private func diffTypeString(_ type: FileDifference.DifferenceType) -> String {
    switch type {
    case .missingOnRight: return "missing-on-right"
    case .missingOnLeft: return "missing-on-left"
    case .differentDates: return "different"
    }
}

private func diffActionString(_ action: FileDifference.SyncAction) -> String {
    switch action {
    case .copyToRight: return "copy-to-right"
    case .copyToLeft: return "copy-to-left"
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

enum Direction: String, ExpressibleByArgument, CaseIterable {
    case auto
    case toRight = "to-right"
    case toLeft = "to-left"
}

enum CollisionStrategy: String, ExpressibleByArgument {
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

@MainActor
private func resolveProviderOrPath(
    value: String,
    label: String,
    settings: SettingsManager
) throws -> CloudProvider {
    if let provider = settings.availableProviders.first(where: { $0.id == value || $0.displayName == value }) {
        return provider
    }
    let expanded = expandPath(value)
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
    if !exists {
        throw ValidationError("Path or provider '\(value)' for \(label) could not be found.")
    }
    return makeProvider(id: expanded, display: label, path: expanded)
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan two directories and print their differences."
    )

    @Option(name: [.customShort("L"), .long], help: "Left side provider id or path.")
    var left: String

    @Option(name: [.customShort("R"), .long], help: "Right side provider id or path.")
    var right: String

    @Flag(name: .shortAndLong, help: "Output machine-readable JSON.")
    var json: Bool = false

    @Option(name: .shortAndLong, help: "Filter by direction: auto, to-right, to-left.")
    var direction: Direction = .auto

    @Flag(name: .customLong("show-hidden"), help: "Include hidden files and folders.")
    var showHidden: Bool = false

    @Option(name: .long, help: "Paths to ignore.")
    var ignore: [String] = []

    func run() async throws {
        let settings = await MainActor.run { SettingsManager(autoDiscover: false) }
        await settings.discoverProviders()
        let leftProvider = try await MainActor.run { try resolveProviderOrPath(value: left, label: "Left", settings: settings) }
        let rightProvider = try await MainActor.run { try resolveProviderOrPath(value: right, label: "Right", settings: settings) }

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
            if !showHidden && FileSyncManager.isHiddenPath(diff.relativePath) {
                return false
            }
            if !ignore.isEmpty && FileSyncManager.isIgnoredPath(diff.relativePath, ignored: Set(ignore)) {
                return false
            }
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
                    type: diffTypeString($0.type),
                    action: diffActionString($0.action),
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
                let type = diffTypeString(diff.type)
                let action = diffActionString(diff.action)
                print("- [\(type)] [\(action)] \(diff.relativePath)")
                print("    \(diff.description)")
            }
        }
    }
}

// MARK: - sync

struct SyncFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
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
    var strategy: CollisionStrategy = .skip

    @Flag(name: .shortAndLong, help: "Run without interactive confirmation.")
    var yes: Bool = false
    
    @Flag(name: .customLong("show-hidden"), help: "Include hidden files and folders.")
    var showHidden: Bool = false

    @Option(name: .long, help: "Paths to ignore.")
    var ignore: [String] = []

    @Flag(name: .customLong("fail-fast"), help: "Abort the synchronization immediately if any file copy fails.")
    var failFast: Bool = false

    @Flag(name: .long, help: "Verify file contents using checksums before syncing files with different dates but identical sizes.")
    var verify: Bool = false

    func run() async throws {
        let settings = await MainActor.run { SettingsManager(autoDiscover: false) }
        await settings.discoverProviders()
        let leftProvider = try await MainActor.run { try resolveProviderOrPath(value: left, label: "Left", settings: settings) }
        let rightProvider = try await MainActor.run { try resolveProviderOrPath(value: right, label: "Right", settings: settings) }

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

        var diffs: [FileDifference] = allDiffs.filter { diff in
            if !showHidden && FileSyncManager.isHiddenPath(diff.relativePath) {
                return false
            }
            if !ignore.isEmpty && FileSyncManager.isIgnoredPath(diff.relativePath, ignored: Set(ignore)) {
                return false
            }
            switch direction {
            case .auto:
                return true
            case .toRight:
                return diff.action == .copyToRight
            case .toLeft:
                return diff.action == .copyToLeft
            }
        }
        
        if verify {
            print("Verifying files with matching sizes...")
            var verifiedCount = 0
            var i = 0
            while i < diffs.count {
                let diff = diffs[i]
                if diff.type == .differentDates && diff.sizesMatch {
                    let same = await FileContentVerifier.filesHaveSameContent(
                        leftPath: diff.leftItemPath,
                        rightPath: diff.rightItemPath,
                        fileManager: FileManager.default
                    )
                    if same == true {
                        diffs.remove(at: i)
                        verifiedCount += 1
                        continue
                    }
                }
                i += 1
            }
            if verifiedCount > 0 {
                print("Skipped \(verifiedCount) files that verified as identical.")
            }
        }

        if diffs.isEmpty {
            print("Nothing to sync - no differences found.")
            return
        }

        print("Planned operations (\(diffs.count)):")
        for diff in diffs {
            let arrow = diff.action == .copyToRight ? "→" : "←"
            print("- \(diff.relativePath) \(arrow) [\(diffTypeString(diff.type))]")
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
        var skippedPaths: [String] = []

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
                var finalTargetURL = URL(fileURLWithPath: targetPath)
                let sourceURL = URL(fileURLWithPath: sourcePath)
                
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: finalTargetURL.path, isDirectory: &isDir) {
                    switch strategy {
                    case .skip:
                        skipped += 1
                        skippedPaths.append(diff.relativePath)
                        continue
                    case .replace:
                        break // performFileSyncIO handles safe replacement
                    case .keepBoth:
                        finalTargetURL = FileSyncManager.generateUniqueURL(for: finalTargetURL, fileManager: fm)
                    }
                }

                _ = try FileSyncManager.performFileSyncIO(from: sourceURL, to: finalTargetURL, isMove: false, fileManager: fm)
                copied += 1
            } catch {
                failed += 1
                let message = "Failed to sync \(diff.relativePath): \(error.localizedDescription)"
                await MainActor.run { _ = Logger.shared.error(message) }
                fputs(message + "\n", stderr)
                
                if failFast {
                    fputs("Aborting due to --fail-fast.\n", stderr)
                    throw error
                }
            }
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000)

        print("")
        print("Sync complete. Copied: \(copied), Skipped: \(skipped), Failed: \(failed).")
        if skipped > 0 {
            print("Skipped files:")
            for p in skippedPaths {
                print("  \(p)")
            }
        }
    }
}

// MARK: - providers

struct Providers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List discovered cloud providers and their root paths."
    )

    func run() async throws {
        let settings = await MainActor.run { SettingsManager(autoDiscover: false) }
        // Ensure discovery has completed at least once.
        await settings.discoverProviders()

        let providers = await MainActor.run { settings.availableProviders }
        if providers.isEmpty {
            print("No providers discovered.")
            return
        }

        print("Discovered providers:")
        for provider in providers {
            print("- \(provider.id)")
            print("    name : \(provider.displayName)")
            print("    type : \(provider.type.rawValue)")
            print("    path : \(provider.path)")
        }
    }
}

