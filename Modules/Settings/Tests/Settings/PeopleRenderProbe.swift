import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// Renders the People surfaces to PNGs on disk so they can be looked at. Not a snapshot assertion:
/// a green suite says nothing about whether a surface is legible. Writes to `SYNCCLOUD_RENDER_DIR`
/// and is skipped when that is unset, so it costs nothing in CI and never fails a run over a pixel.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SYNCCLOUD_RENDER_DIR"] != nil,
                "set SYNCCLOUD_RENDER_DIR to write the People PNGs"))
struct PeopleRenderProbe {

    static func roster() -> [Person] {
        [Person(id: "father", displayName: "Father", relationship: "me",
                fullNames: ["Father Elder"]),
         Person(id: "daughter", displayName: "Daughter", relationship: "daughter",
                fullNames: ["Daughter Father"]),
         Person(id: "uncle", displayName: "Uncle", relationship: "brother",
                fullNames: ["Uncle Elder"]),
         Person(id: "son", displayName: "Son", relationship: "son",
                fullNames: ["Son Father"]),
         Person(id: "elder", displayName: "Elder", relationship: "father",
                fullNames: ["Elder Forebear"], aliases: ["Dad", "Grandad"]),
         Person(id: "granny", displayName: "Granny", relationship: "mother",
                fullNames: ["Granny Elder"], aliases: ["Mom", "Mother"]),
         Person(id: "mother", displayName: "Mother", relationship: "wife",
                fullNames: ["Mother Maiden", "Mother Inlaw Maiden", "Mother I Maiden",
                            "Mother Father"]),
         // Just added, no full name yet, and their only word is somebody else's surname: the one
         // state the amber line is for, included so the render shows it can appear on one row
         // and not the others.
         Person(id: "elder-2", displayName: "Elder")]
    }

    /// A profile giving each person folders and filed documents, so the rows carry the numbers a
    /// real tree would put there.
    static func profileAndMemory() -> (FolderProfile, FilingMemory) {
        var folders: [String: FolderProfileEntry] = [:]
        var memory: [String: FilingMemoryEntry] = [:]
        let plan: [(String, String, Int)] = [
            ("Immigration/OCI/Daughter", "Daughter", 6), ("School/Daughter", "Daughter", 24),
            ("Immigration/OCI/Son", "Son", 5), ("School/Son", "Son", 18),
            ("Family/Mom", "Mom", 12), ("Immigration/Passport/Granny", "Granny", 4),
            ("Family/Dad", "Dad", 9), ("Family/Uncle", "Uncle", 25),
            ("Work/Mother", "Mother", 31), ("Finance/US/Credit Accounts/Father", "Father", 88),
            // Somebody the tree files for who isn't on the roster: the gap the overview surfaces.
            // A real tree usually has none, so the fixture supplies one.
            ("Family/Ravi", "Ravi", 7), ("Immigration/Passport/Ravi", "Ravi", 2),
        ]
        for (path, person, docs) in plan {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: docs,
                                               subfolderCount: 0, axes: ["person": person])
            memory[path] = FilingMemoryEntry(docs: docs, anchors: [], idHashes: [])
        }
        let profile = FolderProfile(profileId: "t", root: "~", folders: folders,
                                    personTokens: ["daughter", "son", "mom", "granny", "dad",
                                                   "elder", "uncle", "mother", "father"],
                                    personAliases: ["mom": "granny", "dad": "elder"])
        return (profile, FilingMemory(profileId: "t", salt: "s", folders: memory))
    }

    /// A throwaway defaults suite, so the probe never touches the real log.
    static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "people-probe-\(UUID().uuidString)")!
    }

    private func write(_ view: some View, size: CGSize, name: String) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNCCLOUD_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (variant, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // A window-background fill, as in `SnapshotRendering`: without it the dark render is
            // white text on transparency, which decodes to white on white.
            let subject = view
                .frame(width: size.width)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: subject)
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: CGSize(width: size.width,
                                                            height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: dir.appendingPathComponent("\(name)-\(variant).png"))
        }
    }

    @Test func rendersTheSectionAndTheEditor() throws {
        let (profile, memory) = Self.profileAndMemory()
        let store = PeopleStore(people: Self.roster())
        let width = SettingsSheetMetrics.contentWidth(textScale: 1)

        let log = PersonVetoLog(userDefaults: Self.scratchDefaults())
        log.record(PersonVetoEvent(namedPerson: "daughter", proposedPerson: "son",
                                   fileName: "Daughter OCI.pdf",
                                   destination: "Immigration/OCI/Son",
                                   at: Date(timeIntervalSince1970: 1_786_000_000)))
        try write(
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: profile, memory: memory,
                           vetoLog: log)
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-section")

        // Rows opened, showing the evidence, caveat and buttons a shut row hides. Two, so the
        // ordinary detail sits beside the amber one.
        try write(
            VStack(alignment: .leading, spacing: 8) {
                // An `onShowPerson`, as the app wires, so the render carries "Show Their Files".
                PeopleList(store: store, profile: profile, memory: memory, vetoLog: log,
                           onShowPerson: { _ in }, initiallyExpanded: ["daughter", "elder-2"])
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-section-open")

        // The hand-arranged state: a row moved, and the way back under the list. Its own store,
        // because `move` latches `orderIsCustom` for that store's life.
        let moved = PeopleStore(people: Self.roster())
        moved.move(id: "uncle", up: true)
        try write(
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: moved, profile: profile, memory: memory, vetoLog: log,
                           onShowPerson: { _ in })
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-section-custom-order")

        // The suggestion the learning sweep produces.
        let suggestion = PersonNameSuggestion(personId: "granny", form: "Granny Elder",
                                              occurrences: 7,
                                              exampleFile: "Granny Elder - Resume, 2017.pdf")
        try write(
            VStack(alignment: .leading, spacing: 8) {
                PersonSuggestionRow(suggestion: suggestion, personName: "Granny",
                                    onAccept: {}, onDismiss: {})
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-suggestion")

        // The tester with an answer on screen, which a probe can't reach by typing.
        let facts = Dictionary(uniqueKeysWithValues: store.people.map {
            ($0.id, PersonFilingFacts.make(for: $0, registry: store.registry,
                                           profile: profile, memory: memory))
        })
        try write(
            VStack(alignment: .leading, spacing: 14) {
                PeopleTester(registry: store.registry, factsById: facts,
                             initialText: "Daughter Father - OCI Card.pdf")
                PeopleTester(registry: store.registry, factsById: facts,
                             initialText: "Mom - passport.pdf")
                PeopleTester(registry: store.registry, factsById: facts,
                             initialText: "Scan 2026-08-02.pdf")
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-tester")

        // The editor mid-edit: a person whose every word is shared, the state the sheet explains.
        try write(
            PersonEditor(person: Person(id: "daughter", displayName: "Daughter",
                                        relationship: "daughter",
                                        fullNames: ["Daughter Father"]),
                         isNew: false, roster: Self.roster(),
                         onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 480, height: 0), name: "people-editor")
    }
}
