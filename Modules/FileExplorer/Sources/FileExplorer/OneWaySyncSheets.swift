import AppKit
import Design
import QuickLook
import SwiftUI
import Sync

/// **Presents one-way sync's sheets** over the window that asked for them (`OneWaySyncSheetHost`).
public struct OneWaySyncSheets: ViewModifier {
    @ObservedObject var controller: OneWaySyncController
    let host: OneWaySyncSheetHost

    public init(controller: OneWaySyncController = .shared, host: OneWaySyncSheetHost) {
        self.controller = controller
        self.host = host
    }

    public func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { controller.sheetHost == host ? controller.sheet : nil },
            set: { if $0 == nil, controller.sheetHost == host { controller.sheet = nil } }
        )) { sheet in
            OneWaySyncSheetView(sheet: sheet, controller: controller)
                .presentedNativeControlAccent()
        }
    }
}

public extension View {
    func oneWaySyncSheets(host: OneWaySyncSheetHost, controller: OneWaySyncController = .shared) -> some View {
        modifier(OneWaySyncSheets(controller: controller, host: host))
    }
}

struct OneWaySyncSheetView: View {
    let sheet: OneWaySyncSheet
    @ObservedObject var controller: OneWaySyncController

    var body: some View {
        switch sheet {
        case .setup(let replacing): OneWaySyncSetupSheet(controller: controller, replacing: replacing, choosingFolders: false)
        case .chooseFolders: OneWaySyncSetupSheet(controller: controller, replacing: false, choosingFolders: true)
        case .overview: OneWaySyncOverviewSheet(controller: controller)
        case .review(let folder): OneWaySyncReviewSheet(controller: controller, folder: folder)
        case .chooseVersion(let subject): OneWaySyncVersionSheet(controller: controller, subject: subject)
        case .renameICloud(let subject): OneWaySyncRenameSheet(controller: controller, subject: subject)
        case .reverse(let id): OneWaySyncReverseSheet(controller: controller, entryID: id)
        case .chooseItemsToEmpty: OneWaySyncEmptySheet(controller: controller)
        case .stoppedFiles: OneWaySyncStoppedFilesSheet(controller: controller)
        case .group(let folder): OneWaySyncGroupSheet(controller: controller, folder: folder)
        }
    }
}

/// A sheet's frame: its title, its body, its buttons along the bottom.
struct OneWaySyncSheetFrame<Content: View, Actions: View>: View {
    let title: String
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).scaledFont(.headline)
            content()
            HStack(spacing: 8) {
                Spacer()
                actions()
            }
        }
        .padding(18)
        .frame(width: width)
    }
}

/// A side's chip: iCloud the source, Dropbox the copy.
struct OneWaySyncSideChip: View {
    let side: OneWaySyncSide
    var label: String?

    var body: some View {
        let color = side == .iCloud ? OneWaySyncPalette.source : OneWaySyncPalette.copy
        HStack(spacing: 4) {
            Image(systemName: side == .iCloud ? "pencil" : "lock.fill").imageScale(.small).foregroundStyle(color)
            Text(label ?? (side == .iCloud ? "Changes made here" : "Kept as a copy"))
        }
        .scaledFont(.system(size: 11, weight: .semibold))
        // The words in ink, the colour in the wash and the glyph (DS1).
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

// MARK: - Setup

/// **Set Up One-Way Sync in three steps** (decision EE, TE253) — and *Review First Run…*: which
/// folders, what to do when a Dropbox copy is changed, then what the first sync will do and Start.
/// It opens on the folders Compare shows when one is in iCloud and the other in Dropbox. *Choose
/// Folders…* is its first step alone.
struct OneWaySyncSetupSheet: View {
    @ObservedObject var controller: OneWaySyncController
    let replacing: Bool
    let choosingFolders: Bool
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case folders, dropboxEdits, check

        var title: String {
            switch self {
            case .folders: return "Folders"
            case .dropboxEdits: return "Dropbox edits"
            case .check: return "Check & start"
            }
        }
    }

    @State private var step = Step.folders
    @State private var iCloudParent = OneWaySyncSetup.defaultICloudParent()
    @State private var dropboxParent = OneWaySyncSetup.dropboxAccountFolder().map(OneWaySyncSetup.defaultDropboxParent(account:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage/Dropbox/Documents")
    @State private var draft: OneWaySyncSetupDraft?
    @State private var ticked: Set<String> = []
    @State private var whenDeleted: OneWaySyncSettings.WhenDeletedRenamedOrMoved = .matchICloud
    @State private var whenEdited: OneWaySyncSettings.WhenEdited = .askMe
    @State private var notify = true
    @State private var notShared = false
    @State private var preview: OneWaySyncLook?
    @State private var previewing = false
    @State private var showing: String?
    @State private var problem: String?
    @State private var starting = false
    @State private var gateTick = 0
    /// This Mac's free space, read off the main thread with each preview.
    @State private var freeSpace: Int64?
    /// Opened on Compare's two folders.
    @State private var fromPanes = false

    var title: String {
        choosingFolders ? "Choose Folders" : replacing ? "Review First Run" : "Set Up One-Way Sync"
    }

    var body: some View {
        OneWaySyncSheetFrame(title: title, width: 600) {
            VStack(alignment: .leading, spacing: 14) {
                if !choosingFolders { stepper }
                switch choosingFolders ? .folders : step {
                case .folders: foldersStep
                case .dropboxEdits: dropboxEditsStep
                case .check: checkStep
                }
                if let problem {
                    Text(problem).foregroundStyle(OneWaySyncPalette.hold).scaledFont(.system(size: 12))
                }
            }
        } actions: {
            if choosingFolders {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveFolders() }
                    .keyboardShortcut(.defaultAction)
                    .accentedProminent()
                    .disabled(draft == nil || controller.isRunning || controller.isAnswering)
            } else {
                if step == .folders {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .folders }
                        .keyboardShortcut(.cancelAction)
                }
                if step == .check {
                    Button(starting ? "Starting…" : "Start Syncing") { start() }
                        .keyboardShortcut(.defaultAction)
                        .accentedProminent()
                        .disabled(startRefusal != nil)
                        .help(startRefusal ?? "Checks both sides again, then runs the first sync")
                } else {
                    Button("Next") {
                        step = Step(rawValue: step.rawValue + 1) ?? .check
                        if step == .check { Task { await refreshPreview() } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accentedProminent()
                    .disabled(step == .folders && (ticked.isEmpty || draft?.problem != nil))
                }
            }
        }
        .task { await load(selectAll: nil) }
        .onAppear { if !choosingFolders { controller.setupOpened(dropboxParent: dropboxParent) } }
        .onDisappear {
            controller.setupPrefill = nil
            if !choosingFolders { controller.setupClosed() }
        }
        .task {
            // The gate's words change as Dropbox catches up.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                gateTick += 1
            }
        }
    }

    var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Text("\(item.rawValue + 1) \(item.title)")
                    .scaledFont(.system(size: 11, weight: item == step ? .semibold : .regular))
                    .foregroundStyle(item == step ? .primary : .secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(item == step ? OneWaySyncPalette.source.opacity(0.14) : Color.primary.opacity(0.05)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3, \(step.title)")
    }

    var startRefusal: String? {
        _ = gateTick
        if starting { return "Starting" }
        if controller.isRunning || controller.isAnswering { return "A sync is running" }
        if draft?.problem != nil { return draft?.problem }
        if ticked.isEmpty { return "Tick at least one folder" }
        if preview == nil { return "Working out what the first sync will do" }
        if !notShared { return "Confirm these folders aren’t shared on Dropbox" }
        return controller.firstRunGate
    }

    var settings: OneWaySyncSettings {
        OneWaySyncSettings(whenDeletedRenamedOrMoved: whenDeleted, whenEdited: whenEdited)
    }

    /// Nothing is ticked for you, ever: a pair opened from the panes can be your whole Documents
    /// (on 31 Oct it was, with every folder ticked). Only *Review First Run* and *Choose Folders*
    /// start from the folders already synced, and a folder made in Dropbox here is ticked.
    func load(selectAll _: Bool?) async {
        if draft == nil {
            if let prefill = controller.setupPrefill, !choosingFolders {
                iCloudParent = prefill.iCloud
                dropboxParent = prefill.dropbox
                fromPanes = true
                controller.setupOpened(dropboxParent: dropboxParent)
            } else if let record = controller.record {
                // The sync as set up: Review First Run and Choose Folders start from its pair.
                iCloudParent = URL(fileURLWithPath: record.iCloudParent.path)
                dropboxParent = URL(fileURLWithPath: record.dropboxParent.path)
            }
        }
        if let state = controller.state {
            whenDeleted = state.settings.whenDeletedRenamedOrMoved
            whenEdited = state.settings.whenEdited
        }
        var draft = await controller.draft(iCloudParent: iCloudParent, dropboxParent: dropboxParent)
        // The panes showing a folder that is itself one to sync (Columns open on SyncCloud Test ▸
        // Family): the pair is the folders that hold it.
        if fromPanes, self.draft == nil, !draft.choices.contains(where: \.canTick),
           iCloudParent.lastPathComponent == dropboxParent.lastPathComponent {
            let up = await controller.draft(iCloudParent: iCloudParent.deletingLastPathComponent(),
                                            dropboxParent: dropboxParent.deletingLastPathComponent())
            if up.problem == nil, up.choices.contains(where: { $0.canTick && $0.name == iCloudParent.lastPathComponent }) {
                iCloudParent = up.iCloudParent
                dropboxParent = up.dropboxParent
                controller.setupOpened(dropboxParent: dropboxParent)
                draft = up
            }
        }
        self.draft = draft
        ticked = Self.ticks(offered: Set(draft.choices.filter(\.canTick).map(\.name)),
                            synced: controller.record.map { Set($0.syncedFolders.map(\.iCloudPath)) },
                            startsFromSynced: choosingFolders || (replacing && ticked.isEmpty && !fromPanes), current: ticked)
        preview = nil
    }

    /// What is ticked once the folders are read: the synced folders, for *Choose Folders* and
    /// *Review First Run*; otherwise only what you ticked yourself that is still offered. Never
    /// everything offered.
    nonisolated static func ticks(offered: Set<String>, synced: Set<String>?, startsFromSynced: Bool,
                                  current: Set<String>) -> Set<String> {
        if startsFromSynced, let synced { return synced.intersection(offered) }
        return current.intersection(offered)
    }

    func refreshPreview() async {
        guard !choosingFolders, let draft, draft.problem == nil, !ticked.isEmpty else {
            preview = nil
            return
        }
        previewing = true
        preview = await controller.preview(draft, folders: Array(ticked), settings: settings)
        freeSpace = await Task.detached(priority: .utility) {
            try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }.value ?? nil
        previewing = false
    }

    // MARK: Step 1

    @ViewBuilder var foldersStep: some View {
        if !choosingFolders {
            HStack(alignment: .center, spacing: 10) {
                end(.iCloud, url: iCloudParent) { iCloudParent = $0 }
                Image(systemName: "arrow.right").scaledFont(.system(size: 18, weight: .semibold)).foregroundStyle(OneWaySyncPalette.source)
                end(.dropbox, url: dropboxParent) { dropboxParent = $0 }
            }
        }
        Text(choosingFolders ? "Which folders should Dropbox keep a copy of?" : "Which folders should Dropbox keep a copy of?")
            .scaledFont(.system(size: 13, weight: .semibold))
        folderList
        Text("Folders with the same name in both are offered. Folders macOS reports as shared, and the ones Dropbox looks after (Apps, Camera Uploads), aren’t; you confirm none is shared on Dropbox before starting.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func end(_ side: OneWaySyncSide, url: URL, set: @escaping (URL) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            OneWaySyncSideChip(side: side)
            Text(Self.displayName(url, side: side))
                .fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(url.path)
            Button("Choose Another…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = url
                panel.message = side == .iCloud ? "Choose the iCloud folder whose changes go to Dropbox"
                                                : "Choose the Dropbox folder to keep as a copy"
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                set(chosen)
                // Quiet since the sheet opened means quiet where it now points.
                if side == .dropbox { controller.setupOpened(dropboxParent: chosen) }
                Task { await load(selectAll: false) }
            }
            .buttonStyle(.link)
            .scaledFont(.system(size: 11))
        }
        .scaledFont(.system(size: 12))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// "iCloud Drive ▸ Documents", "Dropbox ▸ Documents ▸ SyncCloud Test".
    static func displayName(_ url: URL, side: OneWaySyncSide) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let iCloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloudRoot { return "iCloud Drive" }
        if path.hasPrefix(iCloudRoot + "/") {
            return "iCloud Drive ▸ " + path.dropFirst(iCloudRoot.count + 1).split(separator: "/").joined(separator: " ▸ ")
        }
        // iCloud's Documents reached through the Mac's own: say it the way the panes do.
        let documents = OneWaySyncDisk.canonicalPath(OneWaySyncSetup.defaultICloudParent())
        let canonical = OneWaySyncDisk.canonicalPath(url)
        if side == .iCloud, canonical == documents || canonical.hasPrefix(documents + "/") {
            return "iCloud Drive ▸ Documents" + canonical.dropFirst(documents.count).split(separator: "/").map { " ▸ " + $0 }.joined()
        }
        if let account = OneWaySyncSetup.accountFolder(containing: url) {
            let rest = canonical.dropFirst(account.path.count).split(separator: "/")
            return ([account.lastPathComponent] + rest.map(String.init)).joined(separator: " ▸ ")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var folderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft {
                if draft.choices.isEmpty {
                    Text("Neither folder has folders in it yet.").foregroundStyle(.secondary).padding(8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(draft.choices.filter { $0.canTick || $0.place == .onlyInICloud }) { choice in
                            folderRow(choice)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
            } else {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder func folderRow(_ choice: OneWaySyncFolderChoice) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { ticked.contains(choice.name) },
                set: { on in
                    if on { ticked.insert(choice.name) } else { ticked.remove(choice.name) }
                    preview = nil
                }
            )) {
                Text(choice.name)
            }
            .disabled(!choice.canTick)
            Spacer()
            if choice.place == .onlyInICloud {
                Text("only in iCloud ·").foregroundStyle(.secondary)
                Button("Add to Dropbox") { createInDropbox(choice.name) }
                    .buttonStyle(.link)
            }
        }
        .scaledFont(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    func createInDropbox(_ name: String) {
        let places = OneWaySyncPlaces(iCloudParent: iCloudParent, dropboxParent: dropboxParent,
                                      dropboxAccountFolder: draft?.dropboxAccount ?? dropboxParent, staging: OneWaySyncPlaces.defaultStaging())
        do { try OneWaySyncAnswers.createInDropbox(name, places: places) } catch {
            problem = "\(name) couldn’t be made in Dropbox: \(OneWaySyncRun.describe(error))"
            return
        }
        ticked.insert(name)
        // SyncCloud's own folder, and Dropbox's answer to it, aren't Dropbox bringing changes in.
        controller.setupOpened(dropboxParent: dropboxParent)
        Task { await load(selectAll: false) }
    }

    // MARK: Step 2

    @ViewBuilder var dropboxEditsStep: some View {
        Text("If someone edits a copy in Dropbox, on the web or a phone")
            .scaledFont(.system(size: 13, weight: .semibold))
        choice("Ask me which to keep", "The file waits, and you choose in Activity. Everything else keeps syncing.",
               on: whenEdited == .askMe) { whenEdited = .askMe }
        choice("Put iCloud’s back", "Dropbox’s edit is kept in Dropbox ▸ SyncCloud Removed.",
               on: whenEdited == .useICloud) {
            if controller.confirmUseICloudsOnEdit() { whenEdited = .useICloud }
        }
        Text("If someone renames, moves or deletes a copy in Dropbox")
            .scaledFont(.system(size: 13, weight: .semibold))
            .padding(.top, 4)
        choice("Put it back as it is in iCloud", "A second time in a day, it asks you.",
               on: whenDeleted == .matchICloud) { whenDeleted = .matchICloud }
        choice("Ask me", "The file waits, and you choose in Activity.", on: whenDeleted == .askMe) { whenDeleted = .askMe }
        Toggle("Tell me with a notification when something needs me", isOn: $notify)
            .padding(.top, 4)
    }

    func choice(_ title: String, _ detail: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? OneWaySyncPalette.source : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(on ? OneWaySyncPalette.source : Color.primary.opacity(0.12), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaledFont(.system(size: 12))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Step 3

    @ViewBuilder var checkStep: some View {
        Text("The first sync will")
            .scaledFont(.system(size: 13, weight: .semibold))
        if let preview {
            let summary = preview.summary
            let waits = preview.plan.waits.filter { $0.reason.needsYou }
            HStack(spacing: 8) {
                number(summary.copies, "copy to Dropbox")
                number(summary.replaces, "replace with iCloud’s newer version", show: "replace")
                number(waits.count, "wait for you to choose", show: "waits", waits: true)
            }
            if summary.moves + summary.same + summary.dropboxOnly > 0 {
                Text([summary.moves > 0 ? "rename \(summary.moves) in Dropbox to match" : nil,
                      summary.same > 0 ? "\(summary.same) already the same" : nil,
                      summary.dropboxOnly > 0 ? "\(summary.dropboxOnly) only in Dropbox, left alone" : nil]
                        .compactMap { $0 }.joined(separator: " · ").capitalizedFirst)
                    .scaledFont(.system(size: 12))
            }
            if showing == "replace" {
                pathList(preview.plan.steps.compactMap { step in
                    if case .replace(let path, _, _, _) = step.action { return path }
                    return nil
                })
            }
            if showing == "waits" { pathList(waits.map { OneWaySyncWords.subject($0.subject) }) }
            Text(costLine(preview))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading both folders…").foregroundStyle(.secondary)
            }
        }
        Toggle("These folders aren’t shared with anyone on Dropbox", isOn: $notShared)
            .padding(.top, 4)
        Text("SyncCloud can’t see Dropbox’s sharing; a shared folder would send your changes to everyone in it.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if preview != nil, let gate = startRefusal, gate != "Confirm these folders aren’t shared on Dropbox" {
            Text(gate).scaledFont(.system(size: 11)).foregroundStyle(OneWaySyncPalette.hold)
        }
    }

    func number(_ value: Int, _ label: String, show: String? = nil, waits: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").scaledFont(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).scaledFont(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let show, value > 0 {
                Button(showing == show ? "Hide" : "Show") { showing = showing == show ? nil : show }
                    .buttonStyle(.link)
                    .scaledFont(.system(size: 11))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.control)
            .fill(waits && value > 0 ? OneWaySyncPalette.hold.opacity(0.12) : Color.primary.opacity(0.04)))
    }

    func pathList(_ paths: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90)
    }

    func costLine(_ look: OneWaySyncLook) -> String {
        let summary = look.summary
        var parts: [String] = []
        parts.append(summary.downloadBytes > 0
                     ? "Downloads \(OneWaySyncWords.bytes(summary.downloadBytes)) from iCloud to copy and compare"
                     : "Nothing to download from iCloud")
        parts.append("Dropbox keeps a full copy on this Mac: \(OneWaySyncWords.bytes(summary.syncedBytes))")
        if let free = freeSpace {
            parts.append("\(OneWaySyncWords.bytes(max(0, free - summary.copyBytes - summary.replaceBytes - summary.downloadBytes))) free after")
        }
        if summary.replaces > 0 {
            parts.append("Dropbox’s \(summary.replaces) replaced version\(summary.replaces == 1 ? "" : "s") kept in SyncCloud Removed")
        }
        return parts.joined(separator: " · ")
    }

    func start() {
        guard let draft else { return }
        starting = true
        problem = nil
        Task {
            if let failure = await controller.startFirstRun(draft, folders: Array(ticked), settings: settings, notify: notify) {
                problem = failure
                starting = false
            } else {
                dismiss()
            }
        }
    }

    func saveFolders() {
        guard let draft else { return }
        if let failure = controller.chooseFolders(Array(ticked), draft: draft) {
            problem = failure
        } else {
            dismiss()
            controller.syncNow()
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - The sync at a glance

/// **The sync's overview** (ED): its pair, how it stands, what needs you, and its controls — from
/// the differences bar's pill and Compare's sidebar.
struct OneWaySyncOverviewSheet: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OneWaySyncSheetFrame(title: "One-Way Sync", width: 560) {
            VStack(alignment: .leading, spacing: 12) {
                if let record = controller.record {
                    HStack(alignment: .top, spacing: 10) {
                        side(.iCloud, record.iCloudParent.path)
                        Image(systemName: "arrow.right").foregroundStyle(OneWaySyncPalette.source)
                        side(.dropbox, record.dropboxParent.path)
                    }
                    Text(record.syncedFolders.map(\.iCloudPath).sorted().joined(separator: ", "))
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if controller.activity != nil { ProgressView().controlSize(.small) }
                    Text(controller.activity ?? controller.ladder?.title() ?? "Not set up")
                        .fontWeight(.semibold)
                    Spacer()
                    if controller.isRunning {
                        Button("Stop") { controller.cancel() }
                    } else {
                        Button("Sync Now") { controller.syncNow() }
                            .disabled(controller.syncNowRefusal != nil)
                            .help(controller.syncNowRefusal ?? "Copy what changed in iCloud to Dropbox now")
                    }
                    if controller.isPaused {
                        Button("Resume") { controller.resume() }
                    } else {
                        Button("Pause") { controller.pause() }
                    }
                }
                if !center.oneWaySync.rows.isEmpty {
                    ScrollView { OneWaySyncNowRows(center: center, controller: controller, host: .main) }
                        .frame(maxHeight: 280)
                        .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.12)))
                } else if controller.isSetUp {
                    Text("Nothing needs you.").foregroundStyle(.secondary)
                }
            }
            .scaledFont(.system(size: 12))
        } actions: {
            Button("Choose Folders…") { controller.open(.chooseFolders, from: .main) }
                .disabled(controller.isRunning || !controller.isSetUp)
            Button("Open Activity") { dismiss(); controller.onOpenActivity() }
            Button("Settings…") { dismiss(); controller.onOpenSettings() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
        }
    }

    func side(_ side: OneWaySyncSide, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            OneWaySyncSideChip(side: side)
            Text(OneWaySyncSetupSheet.displayName(URL(fileURLWithPath: path), side: side))
                .lineLimit(2).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Review removals

/// **Review…** for the removal limit: each removal and replacement waiting, ticked to go ahead.
struct OneWaySyncReviewSheet: View {
    @ObservedObject var controller: OneWaySyncController
    let folder: String?
    @Environment(\.dismiss) private var dismiss
    @State private var look: OneWaySyncLook?
    @State private var pending: [OneWaySyncPendingRemoval] = []
    @State private var ticked: Set<UInt64> = []

    var body: some View {
        OneWaySyncSheetFrame(title: (folder.map { "\($0): " } ?? "") + "\(pending.count) removals", width: 560) {
            VStack(alignment: .leading, spacing: 10) {
                if look == nil {
                    ProgressView().controlSize(.small)
                } else if pending.isEmpty {
                    Text("Nothing waits on the removal limit now.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(pending) { item in
                                HStack {
                                    Toggle(isOn: Binding(get: { ticked.contains(item.record) },
                                                         set: { if $0 { ticked.insert(item.record) } else { ticked.remove(item.record) } })) {
                                        Text(item.iCloudPath).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(describe(item.kind)).foregroundStyle(.secondary).scaledFont(.system(size: 11))
                                }
                                .padding(.vertical, 3)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                Text("Ticked files go ahead; Dropbox’s copies go to SyncCloud Removed. Unticked removals stay in Dropbox as Dropbox-only files; unticked replacements keep Dropbox’s version and are listed as files you stopped syncing. What you confirm here doesn’t count toward the limit.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Keep All in Dropbox") {
                if let look { controller.applyReview(go: [], keep: pending, look: look) }
                dismiss()
            }
            .disabled(pending.isEmpty || controller.isRunning || controller.isAnswering)
            Button("Apply \(ticked.count)") {
                if let look {
                    controller.applyReview(go: pending.filter { ticked.contains($0.record) },
                                           keep: pending.filter { !ticked.contains($0.record) }, look: look)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
                .accentedProminent()
            .disabled(pending.isEmpty || controller.isRunning || controller.isAnswering)
        }
        .task {
            look = await controller.freshLook()
            if let look { pending = OneWaySyncAnswers.pendingRemovals(in: look, folder: folder) }
            ticked = Set(pending.map(\.record))
        }
    }

    func describe(_ kind: OneWaySyncPendingRemoval.Kind) -> String {
        switch kind {
        case .deleted: return "deleted"
        case .movedOut(let to): return "moved to \(OneWaySyncPath.top(to))"
        case .replaced: return "edited · replace"
        }
    }
}

// MARK: - Choose a Version

/// **Choose a Version…**: iCloud's and Dropbox's, side by side, and which to keep.
struct OneWaySyncVersionSheet: View {
    @ObservedObject var controller: OneWaySyncController
    let subject: OneWaySyncWait.Subject
    @Environment(\.dismiss) private var dismiss
    @State private var versions: OneWaySyncVersions?
    @State private var loaded = false
    @State private var working = false
    @State private var problem: String?
    @State private var previewing: URL?

    var body: some View {
        OneWaySyncSheetFrame(title: OneWaySyncPath.name(OneWaySyncWords.subject(subject)), width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                if let versions {
                    version(.iCloud, versions.iCloud)
                    version(.dropbox, versions.dropbox)
                } else if loaded {
                    Text("This file no longer waits.").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Use iCloud’s moves Dropbox’s edit to SyncCloud Removed. Copy Dropbox’s into iCloud keeps iCloud’s current version in SyncCloud Removed; it is offered only when iCloud’s file is downloaded and current.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).foregroundStyle(OneWaySyncPalette.hold).scaledFont(.system(size: 12)) }
            }
        } actions: {
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Quick Look Both") { previewing = urls.first }
                .disabled(urls.isEmpty)
            Button("Copy Dropbox’s into iCloud") { act { await controller.copyDropboxsIntoICloud($0) } }
                .disabled(versions?.canCopyDropboxsIntoICloud != true || working || controller.isRunning || controller.isAnswering)
            Button("Use iCloud’s") { act { await controller.useICloudsVersion($0) } }
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
                .disabled(versions?.dropbox == nil || working || controller.isRunning || controller.isAnswering)
        }
        .quickLookPreview($previewing, in: urls)
        .task {
            if let look = await controller.freshLook() { versions = OneWaySyncAnswers.versions(for: subject, in: look) }
            loaded = true
        }
    }

    var urls: [URL] {
        guard let versions, let record = controller.record else { return [] }
        let places = controller.places(for: record)
        var urls: [URL] = []
        if let i = versions.iCloud, i.isDownloaded { urls.append(places.iCloudParent.appendingPathComponent(i.path)) }
        if let d = versions.dropbox { urls.append(places.dropboxParent.appendingPathComponent(d.path)) }
        return urls
    }

    func act(_ work: @escaping (OneWaySyncVersions) async -> String?) {
        guard let versions else { return }
        working = true
        Task {
            if let failure = await work(versions) {
                problem = failure
                working = false
            } else {
                dismiss()
            }
        }
    }

    func version(_ side: OneWaySyncSide, _ item: OneWaySyncItem?) -> some View {
        HStack(spacing: 10) {
            OneWaySyncSideChip(side: side, label: side == .iCloud ? "iCloud" : "Dropbox")
            if let item {
                Text("Modified \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                Spacer()
                Text(OneWaySyncWords.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                if !item.isDownloaded { Text("not downloaded").foregroundStyle(.secondary) }
            } else {
                Text(side == .iCloud ? "Deleted in iCloud" : "Not in Dropbox").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .scaledFont(.system(size: 12))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: - Rename iCloud's

struct OneWaySyncRenameSheet: View {
    @ObservedObject var controller: OneWaySyncController
    let subject: OneWaySyncWait.Subject
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var versions: OneWaySyncVersions?
    @State private var problem: String?

    var body: some View {
        OneWaySyncSheetFrame(title: "Rename iCloud’s \(OneWaySyncPath.name(OneWaySyncWords.subject(subject)))", width: 440) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A file only in Dropbox has this name with other contents. Give iCloud’s file another name and the sync copies it under that one; the Dropbox file is left alone.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("New name", text: $name)
                if let problem { Text(problem).foregroundStyle(OneWaySyncPalette.hold).scaledFont(.system(size: 12)) }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Rename") {
                guard let versions else { return }
                Task {
                    if let failure = await controller.renameICloud(versions, to: name) { problem = failure } else { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction)
                .accentedProminent()
            .disabled(versions == nil || name.isEmpty || name == OneWaySyncPath.name(versions?.iCloudPath ?? "")
                      || controller.isRunning || controller.isAnswering)
        }
        .task {
            if let look = await controller.freshLook() { versions = OneWaySyncAnswers.versions(for: subject, in: look) }
            name = OneWaySyncPath.name(versions?.iCloudPath ?? "")
        }
    }
}

// MARK: - Reverse in iCloud

/// **Reverse in iCloud · sync of 10:14** (DE): the changes of one sync that can be undone in
/// iCloud, using Dropbox's copies.
struct OneWaySyncReverseSheet: View {
    @ObservedObject var controller: OneWaySyncController
    let entryID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var entry: OneWaySyncHistoryEntry?
    @State private var reversals: [OneWaySyncReversal] = []
    @State private var ticked: Set<Int> = []
    @State private var loaded = false
    @State private var failures: [String] = []

    var title: String {
        guard let entry else { return "Reverse in iCloud" }
        return "Reverse in iCloud · sync of " + Date(timeIntervalSince1970: TimeInterval(entry.startedAt)).formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        OneWaySyncSheetFrame(title: title, width: 560) {
            VStack(alignment: .leading, spacing: 10) {
                if !loaded {
                    ProgressView().controlSize(.small)
                } else if reversals.isEmpty {
                    Text("Nothing in this sync can be reversed now: each item has to be unchanged on both sides since, and downloaded in iCloud.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(reversals) { reversal in
                                HStack {
                                    Toggle(isOn: Binding(get: { ticked.contains(reversal.step) },
                                                         set: { if $0 { ticked.insert(reversal.step) } else { ticked.remove(reversal.step) } })) {
                                        Text(reversal.item).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(reversal.summary).foregroundStyle(.secondary).scaledFont(.system(size: 11))
                                }
                                .padding(.vertical, 3)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                Text("Changes are reversed in iCloud using Dropbox’s copies: deleted files come back, renames and moves are undone, an edit returns to the version this sync replaced while SyncCloud Removed still holds it. iCloud’s current version is kept there first for items whose contents change. A name now taken keeps both. The sync then carries on as usual.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(failures, id: \.self) { Text($0).foregroundStyle(OneWaySyncPalette.hold).scaledFont(.system(size: 11)) }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Reverse \(ticked.count) in iCloud") {
                let chosen = reversals.filter { ticked.contains($0.step) }
                Task {
                    failures = await controller.reverse(chosen)
                    if failures.isEmpty { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction)
                .accentedProminent()
            .disabled(ticked.isEmpty || controller.isRunning || controller.isAnswering)
        }
        .task {
            entry = controller.store?.history.entry(entryID)
            if let entry, controller.reversible(entry), let look = await controller.freshLook() {
                let removed = await controller.removedItems()
                reversals = OneWaySyncAnswers.reversals(of: entry, look: look, removed: removed)
            }
            loaded = true
        }
    }
}

// MARK: - Choose Items to Empty

/// **Choose Items to Empty…** — SyncCloud Removed by age or size; the chosen go to Dropbox's own
/// deleted files (DB).
struct OneWaySyncEmptySheet: View {
    @ObservedObject var controller: OneWaySyncController
    @Environment(\.dismiss) private var dismiss
    @State private var items: [OneWaySyncRemovedItem] = []
    @State private var ticked: Set<String> = []
    @State private var bySize = false
    @State private var loaded = false

    var body: some View {
        OneWaySyncSheetFrame(title: "SyncCloud Removed · \(items.count) items · \(OneWaySyncWords.bytes(items.reduce(0) { $0 + $1.size }))", width: 600) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Order", selection: $bySize) {
                    Text("Oldest first").tag(false)
                    Text("Largest first").tag(true)
                }
                .fixedSize()
                if !loaded { ProgressView().controlSize(.small) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sorted, id: \.path) { item in
                            HStack {
                                Toggle(isOn: Binding(get: { ticked.contains(item.path) },
                                                     set: { if $0 { ticked.insert(item.path) } else { ticked.remove(item.path) } })) {
                                    Text(item.origin.dropboxPath).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: TimeInterval(item.origin.removedAt)).formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                                Text(OneWaySyncWords.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                            .scaledFont(.system(size: 11))
                            .padding(.vertical, 2)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 300)
                Text("Emptied items go to Dropbox’s own deleted files, which keeps them for as long as your Dropbox plan does. Nothing goes to this Mac’s Trash.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Empty \(ticked.count)") {
                let chosen = items.filter { ticked.contains($0.path) }
                Task { await controller.empty(chosen); dismiss() }
            }
            .disabled(ticked.isEmpty || controller.isRunning || controller.isAnswering)
        }
        .task {
            items = await controller.removedItems()
            loaded = true
        }
    }

    var sorted: [OneWaySyncRemovedItem] {
        bySize ? items.sorted { $0.size > $1.size } : items
    }
}

// MARK: - Files you stopped syncing

struct OneWaySyncStoppedFilesSheet: View {
    @ObservedObject var controller: OneWaySyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OneWaySyncSheetFrame(title: "Files You Stopped Syncing", width: 520) {
            VStack(alignment: .leading, spacing: 0) {
                if controller.exclusions.files.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                }
                ForEach(controller.exclusions.files, id: \.self) { exclusion in
                    HStack {
                        Text(exclusion.iCloudPath).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Button("Show") { controller.reveal(exclusion) }
                        Button("Sync Again…") { controller.syncAgain(exclusion) }
                            .disabled(controller.syncNowRefusal != nil)
                    }
                    .controlSize(.small)
                    .padding(.vertical, 3)
                    Divider()
                }
                Text("Each stays as it is in Dropbox. Sync Again compares the two: the same contents are recorded as synced; others wait for you.")
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                .accentedProminent()
        }
    }
}

// MARK: - A folder's file rows, folded

struct OneWaySyncGroupSheet: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter = .shared
    let folder: String
    @Environment(\.dismiss) private var dismiss

    var members: [OneWaySyncNotice] {
        center.oneWaySync.needsYou.first { $0.id == "group:" + folder }?.members ?? []
    }

    var body: some View {
        OneWaySyncSheetFrame(title: "\(folder): \(members.count) files wait for you", width: 600) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(members) { notice in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(notice.title).scaledFont(.system(size: 12, weight: .semibold))
                            HStack(spacing: 6) {
                                ForEach(notice.buttons, id: \.self) { button in
                                    Button(button.title) {
                                        // The answer's own sheet takes this one's place; one that
                                        // opens none leaves this open for the next file.
                                        controller.perform(button, row: OneWaySyncNoticeRow(notice), from: controller.sheetHost)
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                .accentedProminent()
        }
    }
}
