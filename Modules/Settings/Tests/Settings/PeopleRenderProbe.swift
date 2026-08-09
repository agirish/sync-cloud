import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// Renders the People surfaces to PNGs on disk so they can be **looked at**.
///
/// Not a snapshot assertion: this exists because a green suite has repeatedly said nothing about
/// whether a surface is legible, and the only fix that has ever worked is rendering it and reading
/// the image back. Writes to `SYNCCLOUD_RENDER_DIR` and is skipped when that is unset, so it costs
/// nothing in CI and never fails a run over a pixel.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SYNCCLOUD_RENDER_DIR"] != nil,
                "set SYNCCLOUD_RENDER_DIR to write the People PNGs"))
struct PeopleRenderProbe {

    static func roster() -> [Person] {
        [Person(id: "abhishek", displayName: "Abhishek", relationship: "me",
                fullNames: ["Abhishek Girish"]),
         Person(id: "aditi", displayName: "Aditi", relationship: "daughter",
                fullNames: ["Aditi Abhishek"]),
         Person(id: "anuraag", displayName: "Anuraag", relationship: "brother",
                fullNames: ["Anuraag Girish"]),
         Person(id: "divit", displayName: "Divit", relationship: "son",
                fullNames: ["Divit Abhishek"]),
         Person(id: "girish", displayName: "Girish", relationship: "father",
                fullNames: ["Girish Krishnamurthy"], aliases: ["Dad", "Father"]),
         Person(id: "muktha", displayName: "Muktha", relationship: "mother",
                fullNames: ["Muktha Girish"], aliases: ["Mom", "Mother"]),
         Person(id: "shweta", displayName: "Shweta", relationship: "wife",
                fullNames: ["Shweta Dani", "Shweta Ravindra Dani", "Shweta R Dani",
                            "Shweta Abhishek"]),
         // Just added, no full name yet, and their only word is somebody else's surname — the one
         // state the amber line is for. Included so the render PROVES that line can appear; the
         // first pass tinted all seven rows amber and the fix could otherwise have removed it
         // entirely without the picture changing.
         Person(id: "girish-2", displayName: "Girish")]
    }

    /// A profile giving each person folders and filed documents, so the rows carry the numbers a
    /// real tree would put there.
    static func profileAndMemory() -> (FolderProfile, FilingMemory) {
        var folders: [String: FolderProfileEntry] = [:]
        var memory: [String: FilingMemoryEntry] = [:]
        let plan: [(String, String, Int)] = [
            ("Immigration/OCI/Aditi", "Aditi", 6), ("School/Aditi", "Aditi", 24),
            ("Immigration/OCI/Divit", "Divit", 5), ("School/Divit", "Divit", 18),
            ("Family/Mom", "Mom", 12), ("Immigration/Passport/Muktha", "Muktha", 4),
            ("Family/Dad", "Dad", 9), ("Family/Anuraag", "Anuraag", 25),
            ("Work/Shweta", "Shweta", 31), ("Finance/US/Credit Accounts/Abhishek", "Abhishek", 88),
        ]
        for (path, person, docs) in plan {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: docs,
                                               subfolderCount: 0, axes: ["person": person])
            memory[path] = FilingMemoryEntry(docs: docs, anchors: [], idHashes: [])
        }
        let profile = FolderProfile(profileId: "t", root: "~", folders: folders,
                                    personTokens: ["aditi", "divit", "mom", "muktha", "dad",
                                                   "girish", "anuraag", "shweta", "abhishek"],
                                    personAliases: ["mom": "muktha", "dad": "girish"])
        return (profile, FilingMemory(profileId: "t", salt: "s", folders: memory))
    }

    private func write(_ view: some View, size: CGSize, name: String) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNCCLOUD_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (variant, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // **A window-background fill, for the reason `SnapshotRendering` gives.** Without it the
            // dark render is white text on transparency, which decodes to white-on-white and reads
            // as "dark mode is broken" — it was my harness, not the view.
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

        try write(
            VStack(alignment: .leading, spacing: 8) {
                PeopleList(store: store, profile: profile, memory: memory)
            }
            .padding(16),
            size: CGSize(width: width, height: 0), name: "people-section")

        // The editor mid-edit: a person whose every word is shared, which is the state the sheet
        // exists to explain.
        try write(
            PersonEditor(person: Person(id: "aditi", displayName: "Aditi",
                                        relationship: "daughter",
                                        fullNames: ["Aditi Abhishek"]),
                         isNew: false, roster: Self.roster(),
                         onSave: { _ in }, onCancel: {}),
            size: CGSize(width: 480, height: 0), name: "people-editor")
    }
}
