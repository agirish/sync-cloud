import Testing
import Foundation
import Design
import Sync
@testable import Settings

/// Holds the settings catalog to the Settings it describes. A control added or renamed in Settings,
/// a default changed in a view, or a help text reworded fails here until the catalog says the same,
/// which is what lets Ask Claude trust it.
@MainActor
@Suite struct SettingsCatalogTests {

    /// `Modules/Settings/Sources/Settings`, read the way `SettingsSearchTests` reads it.
    private static let sourcesDirectory = URL(fileURLWithPath: #filePath)   // …/Tests/Settings/SettingsCatalogTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Settings")

    /// Every Settings source but the catalog itself, joined: what the views and their helpers say.
    private static let settingsSources: String = {
        let files = (try? FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsCatalog.swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }()

    // MARK: - Shape

    @Test func theSourcesWereFound() {
        // Guards every scan below against reading nothing and passing.
        #expect(Self.settingsSources.contains("@AppStorage("))
        #expect(Self.settingsSources.count > 100_000)
    }

    @Test func idsAreUniqueAndEveryDependencyExists() {
        let ids = SettingsCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for entry in SettingsCatalog.all {
            for dependency in entry.dependsOn {
                #expect(SettingsCatalog.entry(dependency) != nil, "\(entry.id) depends on missing \(dependency)")
            }
        }
    }

    @Test func everyValueSettingHasAChoiceForItsDefault() {
        for entry in SettingsCatalog.all {
            guard let value = entry.defaultValue else { continue }
            switch entry.control {
            case .menu(let choices), .segmented(let choices), .swatches(let choices):
                #expect(choices.contains { $0.value == value }, "\(entry.id): default \(value) is not a choice")
            default:
                break
            }
        }
    }

    // MARK: - The search index

    @Test func everySearchIndexRowReachesAnEntry() {
        let titles = Set(SettingsCatalog.all.flatMap(\.indexTitles))
        for row in SettingsSearchIndex.all {
            #expect(titles.contains(row.title), "index row “\(row.title)” reaches no catalog entry")
        }
    }

    @Test func everyIndexTitleTheCatalogNamesIsARealRow() {
        let rows = Set(SettingsSearchIndex.all.map(\.title))
        for entry in SettingsCatalog.all {
            for title in entry.indexTitles {
                #expect(rows.contains(title), "\(entry.id) names index row “\(title)”, which doesn't exist")
            }
        }
    }

    @Test func anIndexedEntrySitsOnItsRowsTab() {
        for entry in SettingsCatalog.all {
            for title in entry.indexTitles {
                guard let row = SettingsSearchIndex.all.first(where: { $0.title == title }) else { continue }
                #expect(row.tab == entry.tab, "\(entry.id) is on \(entry.tab), its index row on \(row.tab)")
            }
        }
    }

    // MARK: - Stored keys and their defaults

    /// `(keySource, defaultSource)` for every `@AppStorage` binding in the Settings sources. A
    /// default that wraps onto the next line is read from there.
    private static let appStorageBindings: [(key: String, value: String)] = {
        let lines = settingsSources.components(separatedBy: "\n")
        var found: [(String, String)] = []
        for (index, line) in lines.enumerated() {
            guard let open = line.range(of: "@AppStorage("),
                  let close = line[open.upperBound...].firstIndex(of: ")") else { continue }
            let key = String(line[open.upperBound..<close])
            var value = line[close...].components(separatedBy: "=").dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty, index + 1 < lines.count {
                value = lines[index + 1].trimmingCharacters(in: .whitespaces)
            }
            found.append((key, value))
        }
        return found
    }()

    @Test func everyStoredKeyASettingsControlBindsIsCatalogued() {
        #expect(!Self.appStorageBindings.isEmpty)
        let catalogued: Set<String> = Set(SettingsCatalog.all.compactMap {
            if case .appStorage(_, let keySource, _) = $0.storage { return keySource }
            return nil
        })
        for binding in Self.appStorageBindings {
            #expect(catalogued.contains(binding.key) || SettingsCatalog.excludedAppStorageKeySources.contains(binding.key),
                    "@AppStorage(\(binding.key)) in Settings is neither catalogued nor excluded")
        }
    }

    @Test func everyCataloguedDefaultIsTheOneItsViewUses() {
        for entry in SettingsCatalog.all {
            guard case .appStorage(_, let keySource, let defaultSource) = entry.storage else { continue }
            let uses = Self.appStorageBindings.filter { $0.key == keySource }
            // A key a Settings view doesn't bind is the catalog's alone (none today); one it binds
            // must start from the same default, everywhere it is bound.
            #expect(!uses.isEmpty, "\(entry.id): no Settings view binds \(keySource)")
            for use in uses {
                #expect(use.value == defaultSource, "\(entry.id): the view starts \(keySource) at “\(use.value)”, the catalog at “\(defaultSource)”")
            }
        }
    }

    @Test func settingsManagersDefaultsAreTheCatalogs() {
        let suite = "SettingsCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { wipeDefaultsSuite(suite) }
        let manager = SettingsManager(userDefaults: defaults)
        let read: [String: SettingValue] = [
            "general.sortPanesBy": .string(manager.defaultSortOption.rawValue),
            "sources.folderNameRule": .string(manager.folderNameRule.rawValue),
            "sync.whenFileExists": .string(manager.conflictPolicy.rawValue),
            "sync.dateTolerance": .double(manager.dateToleranceSeconds),
            "sync.verifySameSize": .bool(manager.autoVerifySameSizeDuringScan),
            "sync.rescanOnChange": .bool(manager.rescanWhenFilesChange),
            "sync.ignoreGoogleDriveNewer": .bool(manager.ignoreGoogleDriveNewerDateOnly),
            "sync.rememberIgnored": .bool(manager.rememberIgnoredItems),
        ]
        for (id, value) in read {
            #expect(SettingsCatalog.entry(id)?.defaultValue == value, "\(id): SettingsManager starts at \(value)")
        }
        // Every manager-owned entry with a default is in the table above.
        for entry in SettingsCatalog.all where entry.defaultValue != nil {
            if case .settingsManager = entry.storage, entry.target == .app {
                #expect(read[entry.id] != nil, "\(entry.id) has a default the test doesn't read")
            }
        }
    }

    // MARK: - Words

    @Test func everyHelpTextIsSettingsOwn() {
        for entry in SettingsCatalog.all {
            guard let help = entry.help else { continue }
            #expect(Self.settingsSources.contains(help), "\(entry.id): help text isn't Settings' own")
        }
    }

    @Test func everyOneWaySyncControlIsCatalogued() throws {
        // One-Way Sync's view lives in FileExplorer, which the search index's scan never reads, so
        // its controls are checked here.
        let file = Self.sourcesDirectory
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FileExplorer/Sources/FileExplorer/OneWaySyncSettingsView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?:Picker|Button)\("([^"]+)""#)
        let labels = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        #expect(labels.count >= 10)
        let known = Set(SettingsCatalog.all.flatMap { [$0.label] + $0.otherLabels })
        for label in labels {
            #expect(known.contains(label), "One-Way Sync's “\(label)” isn't catalogued")
        }
    }

    // MARK: - Who may change what

    @Test func onlyLookAndFeelIsDirect() {
        let direct = SettingsCatalog.all.filter { $0.tier == .direct }
        for entry in direct {
            #expect([.appearance, .readability].contains(entry.tab) || entry.id == "general.sortPanesBy",
                    "\(entry.id) is Direct but isn't look and feel")
        }
    }

    /// What `get` tells Claude it may change itself, the writer can set. An entry with no value of
    /// its own (like Size & spacing) must not be Direct, or every set of it is refused.
    @Test func whatClaudeMayChangeItselfCanBeWritten() {
        for entry in SettingsCatalog.all where entry.tier == .direct || entry.tier == .directWhenTightening {
            #expect(SettingsWriter.canWrite(entry), "\(entry.id) is \(entry.tier) but can’t be written")
        }
    }

    /// On, Refine sends Claude excerpts of the files it read, so turning it on raises its access.
    @Test func readingFileContentsRaisesWhatClaudeSees() throws {
        let contents = try #require(SettingsCatalog.entry("intelligence.readContents"))
        #expect(contents.raises(from: .bool(false), to: .bool(true)))
        #expect(!contents.raises(from: .bool(true), to: .bool(false)))
    }

    @Test func tighteningIsOnlyForWhatRaisesClaudesReach() {
        for entry in SettingsCatalog.all where entry.tier == .directWhenTightening {
            #expect(entry.raises != nil, "\(entry.id) tightens but nothing raises it")
        }
    }

    @Test func noLimitAndOffCountAsTheHighest() throws {
        let limit = try #require(SettingsCatalog.entry("intelligence.monthlyLimit"))
        #expect(limit.raises(from: .double(25), to: .double(0)))       // No limit
        #expect(limit.raises(from: .double(25), to: .double(50)))
        #expect(!limit.raises(from: .double(25), to: .double(10)))
        #expect(!limit.raises(from: .double(0), to: .double(100)))     // from No limit, anything is lower
        let cap = try #require(SettingsCatalog.entry("intelligence.monthlyCap"))
        #expect(cap.raises(from: .double(5), to: .double(0)))           // Off
    }

    @Test func aPricierModelRaises() throws {
        let model = try #require(SettingsCatalog.entry("intelligence.askClaudeModel"))
        #expect(model.raises(from: .string(AskClaudeModels.haiku.id), to: .string(AskClaudeModels.sonnet.id)))
        #expect(model.raises(from: .string(AskClaudeModels.sonnet.id), to: .string(AskClaudeModels.opus.id)))
        #expect(!model.raises(from: .string(AskClaudeModels.opus.id), to: .string(AskClaudeModels.haiku.id)))
        let answers = try #require(SettingsCatalog.entry("intelligence.answers"))
        #expect(answers.raises(from: .string("brief"), to: .string("detailed")))
    }

    @Test func aModelOrStyleChangeCarriesOnInTheChatAndHidingStartsANewOne() throws {
        // The open chat carries on under a new model or style; hiding a folder still starts a new
        // one, so what Claude saw of it goes.
        for id in ["intelligence.askClaudeModel", "intelligence.answers"] {
            #expect(try #require(SettingsCatalog.entry(id)).effects.contains(.newChat) == false, "\(id)")
        }
        #expect(SettingsCatalog.all.contains { $0.effects.contains(.newChat) && $0.privacy == .countOnly })
    }

    @Test func turningASafeguardOffIsLessSafe() throws {
        let confirm = try #require(SettingsCatalog.entry("sync.confirmTransfer"))
        #expect(confirm.isLessSafe(from: .bool(true), to: .bool(false)))
        #expect(!confirm.isLessSafe(from: .bool(false), to: .bool(true)))
        let conflicts = try #require(SettingsCatalog.entry("sync.whenFileExists"))
        #expect(conflicts.isLessSafe(from: .string("ask"), to: .string("replace")))
        #expect(!conflicts.isLessSafe(from: .string("ask"), to: .string("keepBoth")))
        let source = try #require(SettingsCatalog.entry("sources.enabled"))
        #expect(source.isLessSafe(from: .bool(true), to: .bool(false)))
        #expect(source.raises(from: .bool(false), to: .bool(true)))
    }

    @Test func theKeyAndTheHiddenListNeverReachClaude() throws {
        #expect(try #require(SettingsCatalog.entry("intelligence.apiKey")).privacy == .secret)
        #expect(try #require(SettingsCatalog.entry("intelligence.apiKeyReveal")).tier == .notInChat)
        #expect(try #require(SettingsCatalog.entry("intelligence.hidden")).privacy == .countOnly)
    }
}
