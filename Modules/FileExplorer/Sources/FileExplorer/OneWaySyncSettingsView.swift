import AppKit
import Design
import ServiceManagement
import SwiftUI
import Sync
import UserNotifications

/// **Settings ▸ Compare ▸ One-Way Sync**: the pair and its state, Pause and Choose Folders, the two
/// settings, files you stopped syncing, SyncCloud Removed, and Turn Off. Before setup, *Set Up
/// One-Way Sync…*. Hosted by Settings' Compare tab, which gives it a page of its own.
public struct OneWaySyncSettingsView: View {
    @ObservedObject var controller: OneWaySyncController
    @ObservedObject var center: ActivityCenter
    /// Observed so the footer's "Dropbox app running" follows the app opening and quitting.
    @ObservedObject var cloudApps: CloudAppMonitor = .shared
    @State private var removed: (count: Int, bytes: Int64, oldest: Date?) = (0, 0, nil)
    @State private var notificationsAllowed: Bool?
    @State private var opensAtLogin: Bool?

    public init(controller: OneWaySyncController = .shared, center: ActivityCenter = .shared) {
        self.controller = controller
        self.center = center
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let refusal = controller.refusal, !controller.isSetUp {
                Text(refusalText(refusal)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let record = controller.record, let state = controller.state {
                setUp(record, state)
            } else if controller.stop == .iCloudSignedOut {
                Text("iCloud is signed out, or iCloud Drive is off: one-way sync waits until it’s back.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let other = controller.otherMac {
                HStack {
                    Text("\(other.macName) syncs iCloud to Dropbox. This Mac doesn’t.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync From This Mac Instead…") { controller.confirmSyncFromThisMacInstead(from: .main) }
                        .disabled(controller.refusal != nil)
                }
            } else {
                HStack {
                    Text("Copies chosen folders from iCloud Drive to Dropbox, one way: iCloud wins, and nothing in Dropbox is deleted outright.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Set Up One-Way Sync…") { controller.open(.setup(replacing: controller.stop != nil), from: .main) }
                        .disabled(controller.refusal != nil)
                }
            }
        }
        .scaledFont(.system(size: 12))
        .task(id: Refresh(lastSyncAt: controller.state?.lastSyncAt, removed: controller.removedRevision)) {
            removed = await controller.removedSummary()
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// What reads SyncCloud Removed's size and the rest again: a sync, or Removed emptied or
    /// restored from between syncs.
    struct Refresh: Equatable {
        var lastSyncAt: Int64?
        var removed: Int
    }

    func refusalText(_ refusal: OneWaySyncLaunchRefusal) -> String {
        switch refusal {
        case .testRunner: return "One-way sync doesn’t run under a test runner."
        case .outsideApplications: return "One-way sync runs only from SyncCloud in the Applications folder, so two copies never write beside each other."
        }
    }

    @ViewBuilder func setUp(_ record: OneWaySyncRecord, _ state: OneWaySyncSavedState) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(OneWaySyncSetupSheet.displayName(URL(fileURLWithPath: record.iCloudParent.path), side: .iCloud)
                     + " → " + OneWaySyncSetupSheet.displayName(URL(fileURLWithPath: record.dropboxParent.path), side: .dropbox))
                    .fontWeight(.semibold)
                Text(controller.summary).foregroundStyle(.secondary)
                if let ladder = controller.ladder { Text(ladder.title()).foregroundStyle(ladder.isProblem ? OneWaySyncPalette.hold : .secondary) }
            }
            Spacer()
            if controller.isPaused {
                Button("Resume…") { Task { await controller.confirmResume() } }
            } else {
                Button("Pause") { controller.pause() }
            }
            Button("Sync Now") { controller.syncNow() }
                .disabled(controller.syncNowRefusal != nil)
                .help(controller.syncNowRefusal ?? "Sync the changes in iCloud to Dropbox now")
            Button("Choose Folders…") { controller.open(.chooseFolders, from: .main) }
                .disabled(controller.isRunning)
        }
        Divider()
        HStack {
            Text("If a Dropbox file is deleted, renamed or moved")
            Spacer()
            Picker("If a Dropbox file is deleted, renamed or moved", selection: Binding(
                get: { state.settings.whenDeletedRenamedOrMoved },
                set: { controller.setWhenDeletedRenamedOrMoved($0) })) {
                Text("Match iCloud").tag(OneWaySyncSettings.WhenDeletedRenamedOrMoved.matchICloud)
                Text("Ask Me").tag(OneWaySyncSettings.WhenDeletedRenamedOrMoved.askMe)
            }
            .labelsHidden()
            .fixedSize()
        }
        HStack {
            Text("If a Dropbox file is edited")
            Spacer()
            Picker("If a Dropbox file is edited", selection: Binding(
                get: { state.settings.whenEdited },
                set: { value in
                    if value == .useICloud, !controller.confirmUseICloudsOnEdit() { return }
                    controller.setWhenEdited(value)
                })) {
                Text("Ask Me").tag(OneWaySyncSettings.WhenEdited.askMe)
                Text("Use iCloud’s").tag(OneWaySyncSettings.WhenEdited.useICloud)
            }
            .labelsHidden()
            .fixedSize()
        }
        Text("A changed setting applies to changes found from then on.").foregroundStyle(.secondary).scaledFont(.system(size: 11))
        Divider()
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Files you stopped syncing").fontWeight(.semibold)
                let count = controller.exclusions.files.count
                Text(count == 0 ? "None" : (count == 1 ? "1 file" : "\(count) files") + " · stays as it is in Dropbox").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show…") { controller.open(.stoppedFiles, from: .main) }
                .disabled(controller.exclusions.files.isEmpty)
        }
        Divider()
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SyncCloud Removed").fontWeight(.semibold)
                Text(removedLine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show") { controller.showRemoved() }
            Button("Choose Items to Empty…") { controller.open(.chooseItemsToEmpty, from: .main) }
                .disabled(removed.count == 0)
        }
        Divider()
        HStack(alignment: .top) {
            Text(footer).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if controller.otherMac != nil {
                Button("Sync From This Mac Instead…") { controller.confirmSyncFromThisMacInstead(from: .main) }
            }
            Button("Turn Off One-Way Sync…") { controller.confirmTurnOff() }
                .disabled(controller.isRunning || controller.isAnswering)
        }
    }

    var removedLine: String { Self.removedLine(count: removed.count, bytes: removed.bytes, oldest: removed.oldest, now: Date()) }

    static func removedLine(count: Int, bytes: Int64, oldest: Date?, now: Date) -> String {
        var parts = ["Dropbox ▸ SyncCloud Removed", count == 1 ? "1 item" : "\(count.formatted()) items", OneWaySyncWords.bytes(bytes)]
        if let oldest {
            let days = Int(now.timeIntervalSince(oldest) / 86_400)
            parts.append(days < 1 ? "oldest today" : days == 1 ? "oldest 1 day" : days < 60 ? "oldest \(days) days" : "oldest \(days / 30) months")
        }
        // DJ sends a file's eighth kept version on to Dropbox's deleted files on its own.
        parts.append("emptied when you choose, or past seven versions of one file")
        return parts.joined(separator: " · ")
    }

    var footer: String {
        var parts: [String] = []
        let notify = UserDefaults.standard.bool(forKey: OneWaySyncNoticeBoard.notifyKey)
        if let opensAtLogin {
            parts.append(opensAtLogin ? "opens at login" : "doesn’t open at login (Settings ▸ General)")
        }
        parts.append(notify ? (notificationsAllowed == false ? "notifications on, but macOS doesn’t allow them" : "notifications on") : "notifications off")
        parts.append(cloudApps.statusModel.runningSince[.dropbox] != nil ? "Dropbox app running" : "Dropbox app not running")
        if let other = controller.otherMac {
            parts.append("\(other.macName) syncs; this Mac doesn’t")
        } else {
            parts.append("only this Mac syncs; to sync from another Mac, use Sync From This Mac Instead… on it")
        }
        return parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }
}
